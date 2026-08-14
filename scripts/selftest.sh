#!/usr/bin/env bash
# Regression tests for fontfetch.
#
#   ./scripts/selftest.sh                 resolution tests only (needs network)
#   ./scripts/selftest.sh --with-keynote  also runs the full Keynote end-to-end
#
# The Keynote test drives Keynote via AppleScript and needs Automation
# permission. It installs a font, authors a deck against it, uninstalls the font,
# and checks that fontfetch puts it back — the only test that exercises the
# sandboxed-client path that motivates this whole tool.

set -uo pipefail
set +m   # no job-control chatter when the test daemon is killed
cd "$(dirname "$0")/.."

BIN=./.build/debug/fontfetch
CACHE="$HOME/Library/Application Support/fontfetch"
PASS=0; FAIL=0

ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
check(){ if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected '$2', got '$1')"; fi; }

echo "building..."
swift build >/dev/null 2>&1 || { echo "build failed"; exit 1; }

echo
echo "== hook availability =="
if $BIN status | grep -q '^hook:       available'; then
  ok "CoreText font-request hook is available"
else
  echo "  SKIP  hook unavailable — Apple has likely removed the deprecated API."
  echo "        Everything below would fail for that reason alone."
  exit 2
fi

echo
echo "== resolution =="
rm -rf "$CACHE"

$BIN fetch RalewayRoman-Regular >/dev/null 2>&1
check "$($BIN list | grep -c 'ralewayroman-regular')" "1" "resolves RalewayRoman-Regular (strips the Roman grouping token)"
check "$($BIN list | grep -c 'ralewayroman-bold')"    "1" "indexes sibling weights from one download"
check "$($BIN list | grep -c '  raleway-regular')"    "1" "also indexes the synthesized Raleway-Regular alias"

# Lora's variable instances omit postScriptNameID, so it only works if the
# verifier synthesizes Family-Style names. This is a real regression that shipped
# broken once.
$BIN fetch Lora-Bold >/dev/null 2>&1
check "$($BIN list | grep -c 'lora-bold')" "1" "resolves a weight whose font omits instance PostScript names"

# PowerPoint asks for theme fonts as a bare family with no style. Matching only
# PostScript names rejects the very file that satisfies the request.
$BIN fetch Roboto >/dev/null 2>&1
check "$($BIN list | grep -cE '^  roboto  ->')" "1" "resolves a bare family name with no style"

if $BIN fetch ZZNotARealFont-Regular >/dev/null 2>&1; then
  bad "declines a name that does not exist"
else
  ok "declines a name that does not exist"
fi

# Opening any Office document asks for these. They must cost nothing and stay
# silent rather than nagging about fonts the user cannot obtain.
if $BIN fetch Calibri-Bold >/dev/null 2>&1; then
  bad "declines a known proprietary family"
else
  ok "declines a known proprietary family"
fi
check "$($BIN list | grep -c 'calibri')" "0" "proprietary family is never cached"

echo
echo "== concurrency =="
rm -rf "$CACHE"
# Each fetch stages downloads in its own scratch directory. A shared one is a
# race: the first to finish deletes the staging area out from under the others.
for f in Karla-Regular Rubik-Regular Lora-Regular; do $BIN fetch "$f" >/dev/null 2>&1 & done
wait
check "$($BIN list | grep -cE '^  (karla|rubik|lora)-regular  ->')" "3" "three concurrent fetches all land"
check "$(ls -a "$CACHE/fonts" | grep -c incoming)" "0" "no scratch directories left behind"

echo
echo "== index hygiene =="
rm -f "$CACHE/fonts/"*.ttf
check "$($BIN verify | grep -c 'dropped')" "1" "verify drops entries whose file vanished"

if [ "${1:-}" = "--with-keynote" ]; then
  echo
  echo "== Keynote end-to-end =="
  SCRATCH=$(mktemp -d)
  trap 'rm -rf "$SCRATCH"' EXIT
  rm -rf "$CACHE"

  curl -sL -o "$SCRATCH/Lora.ttf" \
    "https://raw.githubusercontent.com/google/fonts/main/ofl/lora/Lora%5Bwght%5D.ttf"
  cp "$SCRATCH/Lora.ttf" ~/Library/Fonts/
  sleep 2

  osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "Keynote"
	set d to make new document
	tell d to tell current slide
		set t to make new text item with properties {object text:"FONTTEST", position:{80, 200}, width:700}
		tell object text of t
			set font to "Lora-Regular"
			set size to 60
		end tell
	end tell
	delay 1
	save d in POSIX file "$SCRATCH/LoraTest.key"
	delay 1
	close d saving no
	quit
end tell
APPLESCRIPT

  rm -f ~/Library/Fonts/Lora.ttf
  sleep 3

  # --quiet: the success dialog waits for a click, which would sit on screen
  # fighting the AppleScript driving Keynote.
  $BIN run --quiet -v > "$SCRATCH/daemon.log" 2>&1 &
  DAEMON=$!
  trap 'kill $DAEMON 2>/dev/null; rm -rf "$SCRATCH"' EXIT
  sleep 2

  # First open misses by design: the fetch is asynchronous so the callback can
  # return immediately rather than stalling Keynote's text layout.
  open -a Keynote "$SCRATCH/LoraTest.key"; sleep 15
  osascript -e 'tell application "Keynote" to close document 1 saving no' \
            -e 'tell application "Keynote" to quit' >/dev/null 2>&1
  sleep 3

  # Poll rather than guess: a cold Keynote start after a full quit can take
  # well over ten seconds, and a fixed sleep makes this test flap.
  open -a Keynote "$SCRATCH/LoraTest.key"
  GOT=""
  for _ in $(seq 1 20); do
    sleep 2
    GOT=$(osascript -e 'tell application "Keynote" to get font of object text of text item 4 of current slide of document 1' 2>/dev/null)
    [ -n "$GOT" ] && break
  done
  [ -z "$GOT" ] && GOT="(Keynote never opened the document)"
  check "$GOT" "Lora-Regular" "Keynote renders a font installed nowhere on the system"
  if [ "$GOT" != "Lora-Regular" ]; then
    echo "        --- daemon log ---"
    sed 's/^/        /' "$SCRATCH/daemon.log"
  fi

  osascript -e 'tell application "Keynote" to close document 1 saving no' \
            -e 'tell application "Keynote" to quit' >/dev/null 2>&1
  sleep 2
  pkill -x Keynote 2>/dev/null   # AppleScript quit can leave it up if a sheet is open
  kill $DAEMON 2>/dev/null
  wait $DAEMON 2>/dev/null
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
