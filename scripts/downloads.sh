#!/usr/bin/env bash
# How many times has the release tarball been downloaded?
#
#   ./scripts/downloads.sh
#
# This is the only real install signal untofu has, and it works only because
# release.sh uploads a tarball as a release *asset*. GitHub reports
# `download_count` for uploaded assets; the auto-generated
# archive/refs/tags tarballs carry no counter at all.
#
# Homebrew itself tells you nothing here: the install analytics behind
# formulae.brew.sh cover homebrew-core only, and a third-party tap is invisible
# to them. Nothing phones home.
#
# Read it with two caveats. It counts fetches, not people — Homebrew caches
# downloads, so a reinstall on the same machine may not re-fetch — and it counts
# only from the moment a release started carrying an asset.
set -euo pipefail
REPO="${REPO:-taggie313/untofu}"

command -v gh >/dev/null || { echo "needs the gh CLI"; exit 1; }

gh api "repos/$REPO/releases" --paginate 2>/dev/null | /usr/bin/python3 -c "
import json, sys
rels = json.load(sys.stdin)
if not rels:
    print('  no releases yet — run scripts/release.sh')
    raise SystemExit(0)
total = 0
print('  %-10s %-34s %8s  %s' % ('TAG', 'ASSET', 'DOWNLOADS', 'PUBLISHED'))
for r in rels:
    if not r['assets']:
        print('  %-10s %-34s %8s  %s' % (r['tag_name'], '(no uploaded asset)', '-', r['published_at'][:10]))
        continue
    for a in r['assets']:
        total += a['download_count']
        print('  %-10s %-34s %8d  %s' % (r['tag_name'], a['name'][:34], a['download_count'], r['published_at'][:10]))
print('  %-10s %-34s %8d' % ('TOTAL', '', total))
"

echo
echo "  Tap installs are approximated by clones of the tap repo, since"
echo "  \`brew tap\` is a git clone (brew update also fetches, so this drifts high):"
gh api repos/taggie313/homebrew-tap/traffic/clones 2>/dev/null | /usr/bin/python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print('    (traffic API unavailable — needs push access, and 503s transiently)')
    raise SystemExit(0)
print('    %d clones, %d unique, last 14 days' % (d['count'], d['uniques']))
" 2>/dev/null || echo "    (traffic API unavailable)"
