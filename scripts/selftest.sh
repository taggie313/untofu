#!/usr/bin/env bash
# Regression tests for untofu.
#
#   ./scripts/selftest.sh                 resolution tests only (needs network)
#   ./scripts/selftest.sh --with-keynote  also runs the full Keynote end-to-end
#
# The Keynote test drives Keynote via AppleScript and needs Automation
# permission. It installs a font, authors a deck against it, uninstalls the font,
# and checks that untofu puts it back — the only test that exercises the
# sandboxed-client path that motivates this whole tool.

set -uo pipefail
set +m   # no job-control chatter when the test daemon is killed
cd "$(dirname "$0")/.."

BIN=./.build/debug/untofu
CACHE="$HOME/Library/Application Support/untofu"
PASS=0; FAIL=0

# Several sections wipe the cache directory, and the user's preferences live in
# it — which choices they made about update checks, which fonts they asked never
# to hear about again. Running the tests must not quietly reset those.
STATE_BACKUP=$(mktemp -d)
for f in preferences.json local-index.json; do
  [ -f "$CACHE/$f" ] && cp "$CACHE/$f" "$STATE_BACKUP/$f"
done
# local-index.json matters as much as preferences.json: it is the record of the
# permission-gated stashes, which only a deliberate `untofu folders --rescan`
# can rebuild. Losing it leaves the agent quietly serving 544 faces instead of
# 581 while the settings still say those folders are included — which is exactly
# what happened after each release run before this.
restore_prefs() {
  for f in preferences.json local-index.json; do
    [ -f "$STATE_BACKUP/$f" ] && mkdir -p "$CACHE" && cp "$STATE_BACKUP/$f" "$CACHE/$f"
  done
  # Putting the files back is not enough. A running agent holds its index in
  # memory, and the tests will have signalled it to reload at a moment when the
  # cache was wiped — leaving it serving a degraded index, from a record that is
  # now correct again, until something else happens to signal it. Observed after
  # a release: the record held its 13 gated entries and `untofu status` computed
  # 581, while the agent went on serving 544 and gated fonts substituted.
  pkill -HUP -u "$(id -u)" -f 'untofu run' 2>/dev/null
  # The install-failure test makes the fonts directory read-only to provoke a
  # failed adopt(). Interrupted between the two chmods it would leave the user's
  # cache unwritable and the agent unable to store anything it fetches, so the
  # restore belongs here, where it runs however the suite ends.
  [ -d "$CACHE/fonts" ] && chmod 755 "$CACHE/fonts" 2>/dev/null
  pkill -f 'untofu-selftest-fake' 2>/dev/null
  return 0
}
trap restore_prefs EXIT

ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
check(){ if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected '$2', got '$1')"; fi; }

# A tiny CoreText client, so the suite can drive real font requests through a
# running agent rather than only calling the CLI (which bypasses Provider).
SCRATCH_PROBE="$(mktemp -d)/ctprobe"
cat > "${SCRATCH_PROBE}.swift" <<'PROBE'
import CoreText
import Foundation
let wanted = CommandLine.arguments.dropFirst().first ?? ""
_ = CTFontCopyPostScriptName(CTFontCreateWithName(wanted as CFString, 24, nil))
PROBE
swiftc -O "${SCRATCH_PROBE}.swift" -o "$SCRATCH_PROBE" 2>/dev/null

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

# Half these tests fetch from google/fonts through GitHub's API, which allows 60
# requests an hour unauthenticated — and a couple of full runs will exhaust it.
# Without this check that shows up as nine unrelated-looking failures in three
# sections, which is a bad half hour. Say it once, at the top, instead.
REMAINING=$(curl -s ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
  https://api.github.com/rate_limit 2>/dev/null |
  sed -n 's/.*"remaining"[ :]*\([0-9]*\).*/\1/p' | head -1)
if [ -n "$REMAINING" ] && [ "$REMAINING" -lt 25 ] 2>/dev/null; then
  echo
  echo "  !! GitHub API budget is down to $REMAINING requests."
  echo "     Every fetch test below will fail, and none of it will be untofu's"
  echo "     fault. Wait for the hourly reset, or:"
  echo "       export GITHUB_TOKEN=\$(gh auth token)"
  echo
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
echo "== classification =="
# The whole reason this section exists: opening a PowerPoint deck asks for both
# "Aptos" and "Aptos Display". The first matched the proprietary set and was
# dropped silently, as intended. The second slugged to "aptosdisplay", missed the
# set by one word, went to the network and popped a dialog telling the user to go
# buy a font. Every sub-family escaped the same way.
proprietary(){ $BIN explain "$1" | grep -c '^proprietary: yes'; }
for name in "Aptos Display" "Aptos Narrow" "AptosSerif-Bold" "Segoe UI Semibold" \
            "Cambria Math" "Arial Unicode MS"; do
  check "$(proprietary "$name")" "1" "suppresses the sub-family '$name'"
done

check "$(proprietary 'Playfair Display')" "0" "does not suppress an ordinary two-word family"


# The catalogue veto. "Courier Prime" is a genuine Google family that starts with
# a proprietary one, so it is the case a naive prefix match gets wrong. Planted
# rather than downloaded: the assertion is about the veto, not about GitHub being
# reachable, and the real catalogue is wiped by the rm -rf above anyway.
FAMILIES="$CACHE/families.json"
mkdir -p "$CACHE"
# The timestamp is not read back: the veto deliberately ignores the freshness
# check so it can never trigger a network fetch of its own.
echo '{"fetched":0,"slugs":["courierprime","playfairdisplay","librebaskerville","msmadi"]}' > "$FAMILIES"
check "$(proprietary 'Courier Prime')"     "0" "catalogue vetoes suppression of Courier Prime"
check "$(proprietary 'Libre Baskerville')" "0" "catalogue vetoes suppression of Libre Baskerville"
check "$(proprietary 'Aptos Display')"     "1" "a sub-family the catalogue lacks is still suppressed"

# Reported from the wild against 0.4.3/0.4.4: Microsoft ships icon and symbol
# faces that arrive as ordinary font requests and are the opposite of fetchable.
# Each produced a dialog telling the user to go and buy an icon font. These need
# the catalogue present, because all but one are caught by the whole-word rule
# rather than by a literal slug — which is exactly the fail-open behaviour
# asserted below.
for name in "HoloLens MDL2 Assets" "MS Outlook" "MS Reference Specialty" "MS PGothic"; do
  check "$(proprietary "$name")" "1" "suppresses the symbol font '$name'"
done
# "ms" is in the set as a bare vendor prefix, so the catalogue veto is the only
# thing standing between Google's "Ms Madi" and being silently unfetchable.
check "$(proprietary 'Ms Madi')" "0" "catalogue veto protects Ms Madi from the 'ms' prefix"

# A cold install has no catalogue to consult. Suppressing on a guess would
# silently disable the one thing this tool does, so the word rule stands down —
# except for the handful of sub-families named outright in the set.
rm -f "$FAMILIES"
check "$(proprietary 'Courier Prime')" "0" "with no catalogue, does not suppress Courier Prime either"
check "$(proprietary 'Aptos Display')" "1" "with no catalogue, still suppresses Aptos Display"
# ...but a name caught only by the whole-word rule is NOT suppressed without a
# catalogue to veto against. Deliberate: a spurious dialog is noise, a spurious
# suppression silently disables the tool. Asserted so the trade-off is visible.
check "$(proprietary 'MS Outlook')" "0" "with no catalogue, the word rule stands down for MS Outlook"
check "$(proprietary 'MS Reference Specialty')" "1" "but a literal slug is suppressed regardless"

echo
echo "== local fonts =="
# Most "missing" fonts are on the disk already and merely registered to nobody.
# The portable half of this uses a font planted in ~/Downloads, so it runs the
# same on a machine with no Office and no Adobe installed.
LOCALSRC="$CACHE/fonts/local-selftest.ttf"
rm -rf "$CACHE"; mkdir -p "$CACHE/fonts"
curl -sL -o "$LOCALSRC" \
  "https://raw.githubusercontent.com/google/fonts/main/ofl/lora/Lora%5Bwght%5D.ttf"
PLANTED="$HOME/Downloads/untofu-selftest-Lora.ttf"
# The sections above wipe the cache directory, and the user's preferences live
# in it — so without putting them back first, every test below would see a
# freshly-defaulted "not opted in" and skip itself no matter how the machine is
# actually configured.
restore_prefs
# Downloads is gated by TCC, and the tests must never be the thing that makes
# macOS interrupt someone. Run these only where the user has already opted in.
PERSONAL=$($BIN folders | grep -c '^Also searched')
if [ "$PERSONAL" != "1" ]; then
  echo "  SKIP  gated-stash tests -- 'untofu folders --allow' not enabled;"
  echo "        running them would fire a permission prompt at you"
elif [ -s "$LOCALSRC" ]; then
  cp "$LOCALSRC" "$PLANTED"

  # A plain run must NOT pick it up: the CLI does not walk gated stashes either
  # unless asked. Only --rescan does, and only because the user typed it.
  $BIN local >/dev/null 2>&1
  check "$($BIN explain Lora-Regular | grep -c '^local: *Downloads')" "0" \
        "a new font in a gated folder is not picked up without --rescan"

  $BIN folders --rescan >/dev/null 2>&1
  check "$($BIN explain Lora-Regular | grep -c '^local: *Downloads')" "1" \
        "--rescan reads the gated folders and finds it"

  # ...and from then on it is served without those folders being opened again.
  # A vendor prefix is not a family. A real miss report came back claiming
  # "MS Outlook" was found locally because "MS Reference Sans Serif" is on the
  # disk — they share nothing but the two letters, so the dialog offered a
  # meaningless consolation and the report carried found_locally: true about a
  # font that is nowhere on the machine.
  check "$($BIN explain 'MS Outlook' | grep -c '^local: *not found')" "1" \
        "a shared vendor prefix does not count as a relative"

  check "$($BIN local | grep -c 'never opened by this process')" "1" \
        "later runs serve it from the record, without opening anything gated"
  check "$($BIN local | grep -c 'served from the recorded index')" "1" \
        "and say how many files they took on trust"
  check "$(python3 -c "
import json,os
d=json.load(open(os.path.expanduser('$CACHE/local-index.json')))
print(1 if any(e['gated'] for e in d['files'].values()) else 0)" 2>/dev/null)" "1" \
        "the record marks which entries came from gated stashes"

  rm -f "$PLANTED"
  $BIN folders --rescan >/dev/null 2>&1
  check "$($BIN explain Lora-Regular | grep -c '^local: *not found')" "1" \
        "and a rescan forgets it once the file is gone"
else
  echo "  SKIP  gated-stash tests (could not download a font to plant)"
fi

# The default must reach nothing that prompts. This is the assertion that keeps
# a future stash from quietly reintroducing the interruption.
check "$($BIN folders | sed -n '/^Searched with no permission needed:/,/^$/p' \
          | grep -cE '/Users/|Group Containers|Downloads')" "0" \
      "nothing searched by default is behind a permission prompt"
check "$($BIN local --rebuild 2>/dev/null | sed -n '/^Read directly:/,/^$/p' \
          | grep -cE 'Downloads|Group Containers|CoreSync')" "0" \
      "and a default scan opens none of those directories"
check "$($BIN local --rebuild 2>/dev/null | grep -c '^Read directly:')" "1" \
      "and says which directories it did open"

# The pid file lives in the cache directory, so anything that clears the cache
# orphans it — and every CLI change needing the agent to notice then silently
# does nothing while reporting success. A `folders --rescan` recorded 581 faces
# once while the running agent went on serving 544.
$BIN run --quiet > "$CACHE/.sigtest.log" 2>&1 &
SIGPID=$!
sleep 3
rm -f "$CACHE/untofu.pid"                       # as clearing the cache would
$BIN fetch Cardo-Regular >/dev/null 2>&1
sleep 2
check "$(grep -c 'reloaded' "$CACHE/.sigtest.log")" "1" \
      "a running agent is still reachable once its pid file is gone"
kill $SIGPID 2>/dev/null; wait $SIGPID 2>/dev/null
rm -f "$CACHE/.sigtest.log"

# The index is cached against size and modification date. Reading every file
# every time was the original shape, chosen on a warm benchmark of 0.13s — the
# wrong measurement, because these stashes are 1.35 GB and the first run after a
# boot took 34 seconds, racing the user's first document.
rm -f "$CACHE/local-index.json"
first=$($BIN local 2>/dev/null | grep -c 'Read [0-9]* file')
check "$first" "1" "a fresh install reads the font files"
check "$($BIN local 2>/dev/null | grep -c 'nothing was read from disk')" "1" \
      "and the next run reads none of them"
check "$($BIN local --rebuild 2>/dev/null | grep -c 'Read [0-9]* file')" "1" \
      "--rebuild re-reads them anyway"

# Fast is worthless if it is also wrong: the cached index has to resolve exactly
# as a freshly-parsed one does.
$BIN local --rebuild 2>/dev/null | sed '/face(s) from/,$d' > "$CACHE/.idx-rebuild"
$BIN local           2>/dev/null | sed '/face(s) from/,$d' > "$CACHE/.idx-reused"
if diff -q "$CACHE/.idx-rebuild" "$CACHE/.idx-reused" >/dev/null 2>&1; then
  ok "the cached index resolves identically to a full re-read"
else
  bad "the cached index differs from a full re-read"
fi
rm -f "$CACHE/.idx-rebuild" "$CACHE/.idx-reused"

# Office ships 251 faces inside its bundles. Every one of them carries the
# family name, so a request for bare "Calibri" is satisfiable by Calibrii.ttf and
# the document silently comes out in italic — which is what the face scoring in
# LocalFonts.refresh exists to prevent.
if [ -d "/Applications/Microsoft Excel.app/Contents/Resources/DFonts" ]; then
  localfile(){ $BIN explain "$1" | sed -n 's/^local: *//p' | sed 's/.* — //'; }
  check "$(basename "$(localfile Calibri)")"        "Calibri.ttf"  "bare Calibri resolves to the regular face"
  check "$(basename "$(localfile Calibri-Italic)")" "Calibrii.ttf" "an exact face name still resolves to that face"
  check "$($BIN local | grep -c '^Microsoft Office')" "1" "reports Office as the origin of what it found"
else
  echo "  SKIP  Office bundle tests (Microsoft Excel is not installed)"
fi

echo
echo "== state watch =="
# The agent used to learn about a changed record only by being signalled, and
# twice that failed silently: the pid file was cleared along with the cache, and
# the test suite restored files with no way to say so. Both times `untofu status`
# reported the truth while the running agent served a stale index.
restore_prefs
if [ "$($BIN folders | grep -c '^Also searched')" = "1" ]; then
  cp "$CACHE/local-index.json" "$CACHE/.watch-good.json"
  $BIN run --quiet -v > "$CACHE/.watch.log" 2>&1 &
  WATCHPID=$!
  sleep 5

  # Degrade the record IN PLACE and say nothing. In place matters: a vnode watch
  # on the directory would miss this, which is why the watch polls instead.
  python3 -c "
import json
p='$CACHE/local-index.json'
d=json.load(open(p))
d['files']={k:v for k,v in d['files'].items() if not v['gated']}
json.dump(d, open(p,'w'))"
  # Wait for the count to reach N rather than sleeping a fixed time and
  # asserting. The poll runs every 2s with leeway, and a fixed sleep made this
  # flaky enough to abort a release: the suite passed standalone and failed
  # inside release.sh, on the same machine, minutes apart.
  wait_for_acts() {   # $1 = count to reach, $2 = seconds to allow
    local waited=0
    while [ "$waited" -lt "${2:-30}" ]; do
      [ "$(grep -c 'state changed on disk' "$CACHE/.watch.log")" -ge "$1" ] && return 0
      sleep 1; waited=$((waited+1))
    done
    return 1
  }

  if wait_for_acts 1 30; then
    ok "the agent notices a record changed in place, with no signal"
  else
    bad "the agent never noticed a record changed in place"
  fi

  cp "$CACHE/.watch-good.json" "$CACHE/local-index.json"
  if wait_for_acts 2 30; then
    ok "and notices it being restored"
  else
    bad "the agent never noticed the record being restored"
  fi

  # Its own writes must not wake it, or it churns forever. This one is a
  # negative, so it does have to wait out a fixed window — several poll
  # intervals, to be sure nothing was merely slow.
  BEFORE_ACTS=$(grep -c 'state changed on disk' "$CACHE/.watch.log")
  $BIN fetch Cardo-Regular >/dev/null 2>&1
  sleep 8
  check "$(grep -c 'state changed on disk' "$CACHE/.watch.log")" "$BEFORE_ACTS" \
        "and its own writes do not wake it"

  kill $WATCHPID 2>/dev/null; wait $WATCHPID 2>/dev/null
  rm -f "$CACHE/.watch.log" "$CACHE/.watch-good.json"
else
  echo "  SKIP  state-watch tests -- needs the gated stashes enabled to be meaningful"
fi

echo
echo "== preferences =="
# A settings file that cannot be decoded used to fall back to defaults in
# silence, so the file said searchPersonalFolders:true while every process read
# false. The encoder writes ISO8601 dates; a decoder without a matching strategy
# throws on the first one, which meant a single update check silently discarded
# every choice the user had made.
PREFS="$CACHE/preferences.json"
mkdir -p "$CACHE"
cat > "$PREFS" <<'JSON'
{
  "lastUpdateCheck" : "2026-08-29T17:07:38Z",
  "searchPersonalFolders" : true,
  "suppressedNames" : [ "someprivatefont-bold" ],
  "updateChecksAllowed" : true,
  "updateOfferMade" : true
}
JSON
check "$($BIN status | grep -c '^folders: *including')" "1" \
      "a settings file containing a date still decodes"
check "$($BIN status | grep -c '^updates: *allowed')" "1" \
      "and every other setting in it survives"
check "$($BIN suppressed | grep -c 'someprivatefont-bold')" "1" \
      "including the suppressed-name list"

# Round-tripping must not lose anything either: writing one setting rewrites the
# whole file, so a field that failed to decode would be silently dropped.
$BIN unsuppress someprivatefont-bold >/dev/null 2>&1
check "$($BIN status | grep -c '^folders: *including')" "1" \
      "and changing one setting does not reset the others"
rm -f "$PREFS"

echo
echo "== failure kinds =="
# A rate limit, a dropped connection and a genuine 404 used to be the same
# thing: GoogleFonts.listing returned nil for all three, so Fetcher fell through
# to markUnresolved — a six-hour suppression plus the "commercial or private
# font" dialog — for a font that is on Google Fonts and merely could not be
# looked up. UNTOFU_GITHUB_API points the client at a local server so all three
# can be exercised without waiting out a real rate limit.
FAKE_PY="$CACHE/untofu-selftest-fake.py"
mkdir -p "$CACHE"
cat > "$FAKE_PY" <<'FAKEEOF'
import sys, http.server
CODE = int(sys.argv[1]); PORT = int(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(CODE); self.send_header('Content-Type','application/json')
        self.end_headers(); self.wfile.write(b'{"message":"simulated"}')
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', PORT), H).serve_forever()
FAKEEOF
python3 "$FAKE_PY" 403 8761 >/dev/null 2>&1 & FAKE403=$!
python3 "$FAKE_PY" 404 8762 >/dev/null 2>&1 & FAKE404=$!
sleep 1

kind_probe() {   # $1 = api base -> "<exit>:<poisoned?>"
  printf '{}' > "$CACHE/negative.json"
  UNTOFU_GITHUB_API="$1" $BIN fetch Karla-Regular >/dev/null 2>&1
  local rc=$?
  local poisoned
  poisoned=$(python3 -c "
import json
try:
    d=json.load(open('$CACHE/negative.json'))
    print('poisoned' if any('karla' in k for k in d) else 'clean')
except Exception: print('clean')")
  echo "$rc:$poisoned"
}
rm -f "$CACHE/fonts/Karla"* 2>/dev/null
python3 -c "
import json
try:
    d=json.load(open('$CACHE/index.json'))
    json.dump({k:v for k,v in d.items() if 'karla' not in k}, open('$CACHE/index.json','w'))
except Exception: pass"

check "$(kind_probe http://127.0.0.1:8761)" "2:clean" \
      "a rate limit does not become 'this font does not exist'"
check "$(kind_probe http://127.0.0.1:9998)" "2:clean" \
      "nor does an unreachable network"
check "$(kind_probe http://127.0.0.1:8762)" "1:poisoned" \
      "but a real 404 still counts as a miss and is cached"

# The listing can be perfectly fine and the DOWNLOAD still fail. download() used
# to arm a pause only for 403/429 and status 0, and Fetcher recovered the reason
# by asking whether a pause was armed — so a 5xx from raw.githubusercontent.com,
# or a 200 with an empty body behind a captive portal, produced a bare nil,
# no pause, and a confident "this font does not exist".
cat > "$CACHE/untofu-selftest-fake2.py" <<'FAKE2EOF'
import sys, json, http.server
PORT = int(sys.argv[1]); DL = int(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/file'):
            self.send_response(DL); self.end_headers(); self.wfile.write(b''); return
        body = json.dumps([{ "type":"file", "name":"Karla[wght].ttf",
                             "download_url": f"http://127.0.0.1:{PORT}/file/Karla.ttf" }]).encode()
        self.send_response(200); self.send_header('Content-Type','application/json')
        self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', PORT), H).serve_forever()
FAKE2EOF
python3 "$CACHE/untofu-selftest-fake2.py" 8763 500 >/dev/null 2>&1 & FAKEDL=$!
sleep 1
check "$(kind_probe http://127.0.0.1:8763)" "2:clean" \
      "a good listing whose download 5xxs is not a miss either"
kill $FAKEDL 2>/dev/null; wait $FAKEDL 2>/dev/null
rm -f "$CACHE/untofu-selftest-fake2.py"

# And the strongest evidence gets the harshest treatment if install failure is
# mistaken for absence: by this point the file has downloaded, parsed, and
# answered to the exact name asked for.
printf '{}' > "$CACHE/negative.json"
rm -f "$CACHE"/fonts/Karla*.ttf 2>/dev/null
python3 -c "
import json
try:
    d=json.load(open('$CACHE/index.json'))
    json.dump({k:v for k,v in d.items() if 'karla' not in k}, open('$CACHE/index.json','w'))
except Exception: pass"
chmod 500 "$CACHE/fonts"
$BIN fetch Karla-Regular >/dev/null 2>&1
INSTALL_RC=$?
chmod 755 "$CACHE/fonts"
INSTALL_NEG=$(python3 -c "
import json
d=json.load(open('$CACHE/negative.json'))
print('poisoned' if any('karla' in k for k in d) else 'clean')")
check "$INSTALL_RC:$INSTALL_NEG" "2:clean" \
      "a font that downloads and verifies but cannot be installed is not a miss"

kill $FAKE403 $FAKE404 2>/dev/null; wait $FAKE403 $FAKE404 2>/dev/null
rm -f "$FAKE_PY"

echo
echo "== concurrency =="
rm -rf "$CACHE"
# Each fetch stages downloads in its own scratch directory. A shared one is a
# race: the first to finish deletes the staging area out from under the others.
for f in Karla-Regular Rubik-Regular Lora-Regular; do $BIN fetch "$f" >/dev/null 2>&1 & done
wait
check "$($BIN list | grep -cE '^  (karla|rubik|lora)-regular  ->')" "3" "three concurrent fetches all land"
check "$(ls -a "$CACHE/fonts" | grep -c incoming)" "0" "no scratch directories left behind"

# Those are three separate PROCESSES, so they are concurrent whatever the agent's
# own resolve queue does. Nothing above this line exercises Provider.queue at all
# — you could set maxConcurrentOperationCount to 1, or leave it the serial
# DispatchQueue it used to be, and every other test in this file still passes.
#
# So: drive real misses through a running agent, and use SIX DISTINCT families,
# which is the part that makes the assertion capable of failing. The obvious
# version — Raleway-Bold plus RalewayRoman-Regular — cannot fail, because both
# names come out of the same parse of the same Raleway[wght].ttf and either fetch
# alone satisfies both halves.
#
# What this catches: with the old Cache.persist (`index = mergedIndex`), a worker
# finishing while another sat inside persist had its entry dropped from memory
# and then from disk. Measured before the fix: 1 lost in 2 of 3 runs, always with
# every file present in fontsDir — the font on disk, indexed under nothing, after
# the user was told to reopen their document. After: 5 of 5 clean.
rm -rf "$CACHE"; mkdir -p "$CACHE/fonts"
CONC_FONTS="Karla-Regular Rubik-Regular Lora-Regular Cardo-Regular Arvo Inconsolata-Regular"
$BIN run --quiet > "$CACHE/.conc.log" 2>&1 &
CONC_AGENT=$!
sleep 3
CONC_PROBES=""
for f in $CONC_FONTS; do
  "$SCRATCH_PROBE" "$f" >/dev/null 2>&1 &
  CONC_PROBES="$CONC_PROBES $!"
done
# Only the probes: a bare `wait` also waits on the agent, which never exits.
for pp in $CONC_PROBES; do wait "$pp" 2>/dev/null; done

conc_present() {
  local c=0 f key
  for f in $CONC_FONTS; do
    key=$(echo "$f" | tr 'A-Z' 'a-z')
    $BIN list 2>/dev/null | grep -q "^  $key  ->" && c=$((c+1))
  done
  echo "$c"
}
# Poll on the six names asked for. Counting total index entries is useless — one
# variable font indexes dozens of siblings, so the count clears six immediately.
for _ in $(seq 1 90); do [ "$(conc_present)" -ge 6 ] && break; sleep 1; done

check "$(conc_present)" "6" "a burst of six distinct misses all reach the index"
CONC_ORPHAN=0
CONC_DETAIL=""
for f in $CONC_FONTS; do
  key=$(echo "$f" | tr 'A-Z' 'a-z')
  file=$($BIN list 2>/dev/null | awk -v k="^  $key  ->" '$0 ~ k {print $3}')
  if [ -n "$file" ] && [ ! -f "$CACHE/fonts/$file" ]; then
    CONC_ORPHAN=$((CONC_ORPHAN+1))
    CONC_DETAIL="$CONC_DETAIL
        $key -> $file (absent)"
  fi
done
check "$CONC_ORPHAN" "0" "and every one of them points at a file that exists"
if [ "$CONC_ORPHAN" != "0" ]; then
  echo "        --- orphans ---$CONC_DETAIL"
  echo "        --- fontsDir actually contains ---"
  ls -1 "$CACHE/fonts" 2>/dev/null | sed 's/^/          /'
fi
kill $CONC_AGENT 2>/dev/null; wait $CONC_AGENT 2>/dev/null

echo
echo "== browser policy =="
check "$($BIN policy $$ | grep -c 'may fetch')" "1" "an ordinary process may fetch"

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ -x "$CHROME" ]; then
  # A throwaway profile, so this never touches the user's real Chrome or its
  # tabs. A long-lived renderer caches its font lookups, so reusing the running
  # instance silently tests nothing — the first attempt at this passed for that
  # reason rather than because the policy worked.
  BWORK=$(mktemp -d)
  rm -rf "$CACHE" /tmp/ff-selftest-chrome
  cat > "$BWORK/local.html" <<'HTML'
<!doctype html><meta charset="utf-8">
<style>@font-face{font-family:"T";src:local("Manrope")}body{font-family:"T",serif}</style>
<p>local() lookup</p>
HTML
  $BIN run -q -v > "$BWORK/d.log" 2>&1 &
  BD=$!
  sleep 2
  # Headless, and the OLD --headless deliberately. This used to launch a visible
  # Chrome window and sleep 18 seconds, every run of the suite. Measured on
  # Chrome 152:
  #   --headless      --dump-dom             hook fires, 1.5s, exits by itself
  #   --headless=new  --screenshot           hook does NOT fire — silently useless
  #   --headless=new  --virtual-time-budget  hook fires but never exits
  # --dump-dom forces load and layout and then quits, so no sleep is needed at
  # all. If Chrome ever drops the old --headless this test FAILS rather than
  # passing quietly, because it asserts the hook actually fired.
  #
  # Backgrounded and polled rather than waited on. Chrome exits by itself in
  # 1.5s in isolation but took the full ceiling inside the suite, so waiting for
  # it to quit made the test SLOWER than the visible-window version it replaced.
  # What we actually care about is whether the hook fired, so watch for that and
  # stop the moment it is observed — typically a second or two. If it never
  # fires, we spend the ceiling and then fail, which is the right outcome.
  "$CHROME" --headless --disable-gpu \
        --user-data-dir=/tmp/ff-selftest-chrome --no-first-run \
        --no-default-browser-check --dump-dom "file://$BWORK/local.html" >/dev/null 2>&1 &
  CHROME_PID=$!
  for _ in $(seq 1 30); do
    grep -q 'declined, Google Chrome' "$BWORK/d.log" && break
    sleep 1
  done
  kill $CHROME_PID 2>/dev/null; wait $CHROME_PID 2>/dev/null
  check "$(grep -c 'declined, Google Chrome' "$BWORK/d.log")" "1" "a Chromium local() lookup is declined"
  check "$($BIN list | grep -ci manrope)" "0" "and the font is not downloaded"
  pkill -f 'user-data-dir=/tmp/ff-selftest-chrome' 2>/dev/null
  kill $BD 2>/dev/null; wait $BD 2>/dev/null
  sleep 2   # Chrome holds its profile open briefly; rm -rf races it otherwise
  rm -rf "$BWORK" /tmp/ff-selftest-chrome
else
  echo "  SKIP  Chrome not installed; browser policy untested"
fi

echo
echo "== document scanning =="
rm -rf "$CACHE"
SCANWORK=$(mktemp -d)
# A PDF that references a font without embedding it: FontDescriptor, no
# FontFile2. Built here rather than checked in so the test has no fixtures.
/usr/bin/python3 - "$SCANWORK/t.pdf" <<'PY'
import sys
w=" ".join(["500"]*95)
objs=[b"<< /Type /Catalog /Pages 2 0 R >>",
      b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
      ("<< /Type /Font /Subtype /TrueType /BaseFont /Karla-Regular /FirstChar 32 /LastChar 126 /Widths [%s] /FontDescriptor 6 0 R >>"%w).encode(),
      None,
      b"<< /Type /FontDescriptor /FontName /Karla-Regular /Flags 32 >>"]
s=b"BT /F1 36 Tf 72 700 Td (T) Tj ET\n"
objs[4]=b"<< /Length %d >>\nstream\n"%len(s)+s+b"endstream"
out=bytearray(b"%PDF-1.4\n"); offs=[]
for i,b in enumerate(objs,1):
    offs.append(len(out)); out+=b"%d 0 obj\n"%i+b+b"\nendobj\n"
x=len(out); out+=b"xref\n0 %d\n"%(len(objs)+1)+b"0000000000 65535 f \n"
for o in offs: out+=b"%010d 00000 n \n"%o
out+=b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n"%(len(objs)+1,x)
open(sys.argv[1],"wb").write(out)
PY
check "$($BIN scan "$SCANWORK/t.pdf" --dry-run 2>/dev/null | grep -c 'Karla-Regular.*would fetch')" "1" "finds a non-embedded font in a PDF"
$BIN scan "$SCANWORK/t.pdf" >/dev/null 2>&1
check "$($BIN list | grep -cE '^  karla-regular  ->')" "1" "scan caches what the app will actually ask for"
# The catalogue filter is what makes iWork scanning usable: without it an empty
# deck yields ~75 false positives and burns the hourly API budget.
check "$($BIN scan "$SCANWORK/t.pdf" --dry-run 2>/dev/null | grep -c 'not on Google Fonts')" "0" "precise formats report only real misses"
rm -rf "$SCANWORK"

echo
echo "== index hygiene =="
# Self-contained: the browser section above leaves the cache empty by design,
# so this has to put something in it rather than inherit from earlier tests.
$BIN fetch Cardo-Regular >/dev/null 2>&1
rm -f "$CACHE/fonts/"*.ttf

# Assert the OUTCOME, not the announcement. This test used to be
# `verify | grep -c dropped` == 1, which passed for a year while verify did
# nothing at all: it removed the keys from its own memory, then persist() merged
# its view *over* the file on disk — and a key you deleted is simply a key you do
# not have, indistinguishable from one you never knew about — so every entry came
# straight back, in memory and on disk. Running it twice printed the identical
# "dropped 62 stale entries" both times.
$BIN verify >/dev/null 2>&1
check "$($BIN verify)" "index is clean" "verify actually drops entries, and stays dropped"
check "$(python3 -c "
import json,os
try:
    d=json.load(open(os.path.expanduser('$CACHE/index.json')))
    print(1 if any('cardo' in k for k in d) else 0)
except Exception: print(0)")" "0" "and the entry is gone from index.json, not just from memory"

# A fetch stages downloads in the cache directory, and Cache.init sweeps stale
# staging — in EVERY invocation, including `untofu --version`. It used to delete
# every .incoming-* it found, so typing `untofu status` while the agent was
# downloading deleted the agent's staging out from under it: the rest of that
# fetch failed silently, fell through to markUnresolved, and told the user a
# perfectly available Google font was commercial. Then stayed quiet for 6h.
mkdir -p "$CACHE/fonts/.incoming-$$-live" \
         "$CACHE/fonts/.incoming-99999-dead" \
         "$CACHE/fonts/.incoming-oldstyle"
$BIN --version >/dev/null 2>&1
check "$([ -d "$CACHE/fonts/.incoming-$$-live" ] && echo 1 || echo 0)" "1" \
      "a live process's staging survives another invocation's sweep"
check "$([ -d "$CACHE/fonts/.incoming-99999-dead" ] && echo 1 || echo 0)" "0" \
      "and staging from a dead process is still swept"
check "$([ -d "$CACHE/fonts/.incoming-oldstyle" ] && echo 1 || echo 0)" "0" \
      "as is staging from before pids were stamped"
rm -rf "$CACHE/fonts/".incoming-* 2>/dev/null

if [ "${1:-}" = "--with-keynote" ]; then
  echo
  echo "== Keynote end-to-end =="
  SCRATCH=$(mktemp -d)
  trap 'rm -rf "$SCRATCH"; restore_prefs' EXIT
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
  trap 'kill $DAEMON 2>/dev/null; rm -rf "$SCRATCH"; restore_prefs' EXIT
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
