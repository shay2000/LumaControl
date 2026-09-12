#!/bin/bash
#
# Installs the freshly built LumaControl into /Applications.
#
# Safe by design:
#   - Aborts without changing anything if the app is still running.
#   - Never deletes the existing app: it is moved aside (an atomic rename),
#     so it can be put back by hand if anything goes wrong.
#   - Keeps the code signature Xcode produced. The only fixup needed is
#     clearing stray extended attributes (a com.apple.FinderInfo xattr on
#     Sparkle's Updater.app otherwise makes codesign refuse to validate).
#
set -euo pipefail

REPO="/Users/shayprasad/Documents/Side Projects and Hobbies/Coding/LumaControl"
# Source bundle. Pass a path as $1 to install a build from a different derived-data folder
# (each build should use a fresh one, so this is the normal case rather than the exception).
SRC="${1:-$REPO/build/DerivedDataRelease/Build/Products/Release/LumaControl.app}"
DST="/Applications/LumaControl.app"
BACKUP="/Applications/LumaControl.app.backup-20260912"
PROC_PATTERN="LumaControl.app/Contents/MacOS/LumaControl"

echo "=== 1. checking the app is not running ==="
if pgrep -f "$PROC_PATTERN" >/dev/null 2>&1; then
  echo "STILL RUNNING - aborting. Quit LumaControl from its menu bar icon first."
  exit 1
fi
echo "not running - ok"

echo "=== 2. checking the new build is present ==="
[ -d "$SRC" ] || { echo "missing build: $SRC"; exit 1; }
echo "found: $SRC"

echo "=== 3. moving the current app aside ==="
if [ -d "$DST" ]; then
  ASIDE="/Applications/LumaControl.app.replaced-$(date +%Y%m%d-%H%M%S)"
  mv "$DST" "$ASIDE"
  echo "moved to $ASIDE"
else
  echo "no existing app found (nothing to move aside)"
fi

echo "=== 4. installing the new build ==="
xattr -cr "$SRC"
ditto --norsrc "$SRC" "$DST"
echo "copied into place"

echo "=== 5. clearing extended attributes on the installed copy ==="
xattr -cr "$DST"

echo "=== 6. verifying the signature ==="
codesign --verify --deep --strict --verbose=2 "$DST"
echo "signature ok"
echo
codesign -dv "$DST" 2>&1 | grep -E "Identifier|Format|Signature|TeamIdentifier" || true

echo "=== 7. pruning older copies ==="
# Each install parks the previous app in /Applications as .replaced-<timestamp>. Without
# pruning they pile up one per build, so keep only the most recent one as a fallback and
# move the rest to the Trash (never `rm` - these are real apps the user may want back).
cd /Applications
OLD_COPIES=$(ls -1dt LumaControl.app.backup-* LumaControl.app.replaced-* 2>/dev/null | tail -n +2 || true)
if [ -n "$OLD_COPIES" ]; then
  while IFS= read -r old; do
    [ -n "$old" ] || continue
    osascript -e "tell application \"Finder\" to delete POSIX file \"/Applications/$old\"" >/dev/null 2>&1 \
      && echo "trashed: $old" \
      || echo "could not trash: $old (left in place)"
  done <<< "$OLD_COPIES"
else
  echo "nothing to prune"
fi
ls -1d LumaControl.app* 2>/dev/null | sed 's/^/kept: /' || true

echo
echo "=== installed ==="
/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$DST/Contents/Info.plist" 2>/dev/null | sed 's/^/build number: /'
/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$DST/Contents/Info.plist" 2>/dev/null | sed 's/^/min macOS: /'
