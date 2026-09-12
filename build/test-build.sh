#!/bin/bash
# Regression tests for build.sh's artifact acceptance and signing gates.
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SOURCE_DIR")"
HARNESS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lumacontrol-build-test.XXXXXX")"
trap 'rm -rf "$HARNESS_DIR"' EXIT
mkdir -p "$HARNESS_DIR/project/build" "$HARNESS_DIR/bin"
cp "$ROOT_DIR/build/build.sh" "$HARNESS_DIR/project/build/build.sh"
chmod +x "$HARNESS_DIR/project/build/build.sh"
touch "$HARNESS_DIR/project/MonitorControl.xcodeproj"

cat > "$HARNESS_DIR/bin/security" <<'STUB'
#!/bin/bash
if [ "${BUILD_TEST_IDENTITY:-}" = valid ]; then
  echo "  1) ABCDEF \"Test Identity\""
  echo "     1 valid identities found"
fi
STUB
cat > "$HARNESS_DIR/bin/xcodebuild" <<'STUB'
#!/bin/bash
set -u
derived=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [ "${args[$i]}" = -derivedDataPath ]; then derived="${args[$((i+1))]}"; fi
done
case "${BUILD_TEST_SCENARIO:-}" in
  partial)
    mkdir -p "$derived/Build/Products/Release/LumaControl.app"
    exit 7
    ;;
  fallback)
    call_file="${BUILD_TEST_CALL_FILE:?}"
    call=0
    if [ -f "$call_file" ]; then call=$(cat "$call_file"); fi
    call=$((call + 1))
    printf "%s" "$call" > "$call_file"
    if [ "$call" -eq 1 ]; then
      mkdir -p "$derived/Build/Products/Release/LumaControl.app"
      exit 9
    fi
    mkdir -p "$derived/Build/Products/Release/LumaControl.app"
    exit 0
    ;;
  success|signfail)
    mkdir -p "$derived/Build/Products/Release/LumaControl.app"
    exit 0
    ;;
  missing)
    exit 0
    ;;
  *) exit 99 ;;
esac
STUB
cat > "$HARNESS_DIR/bin/ditto" <<'STUB'
#!/bin/bash
if [ "$1" = --norsrc ]; then shift; fi
cp -R "$1" "$2"
STUB
cat > "$HARNESS_DIR/bin/xattr" <<'STUB'
#!/bin/bash
exit 0
STUB
cat > "$HARNESS_DIR/bin/codesign" <<'STUB'
#!/bin/bash
if [ "${BUILD_TEST_SCENARIO:-}" = signfail ] && [ "${1:-}" = --verify ]; then exit 1; fi
exit 0
STUB
chmod +x "$HARNESS_DIR/bin"/*

run_case() {
  local scenario="$1" expected="$2" identity="${3:-}" status
  rm -rf "$HARNESS_DIR/project/build/DerivedData" "$HARNESS_DIR/project/build/LumaControl.app"
  if BUILD_TEST_SCENARIO="$scenario" BUILD_TEST_IDENTITY="$identity" BUILD_TEST_CALL_FILE="$HARNESS_DIR/$scenario.calls" PATH="$HARNESS_DIR/bin:$PATH" CODESIGN_BIN="$HARNESS_DIR/bin/codesign" \
      "$HARNESS_DIR/project/build/build.sh" >"$HARNESS_DIR/$scenario.log" 2>&1; then
    status=0
  else
    status=$?
  fi
  if [ "$status" -ne "$expected" ]; then
    echo "FAIL $scenario: expected exit $expected, got $status" >&2
    cat "$HARNESS_DIR/$scenario.log" >&2
    exit 1
  fi
  if [ "$scenario" = partial ] && [ -e "$HARNESS_DIR/project/build/LumaControl.app" ]; then
    echo "FAIL $scenario: copied an app after failure" >&2
    exit 1
  fi
  if [ "$expected" -eq 0 ] && ! grep -q 'Done: ' "$HARNESS_DIR/$scenario.log"; then
    echo "FAIL $scenario: missing success marker" >&2
    exit 1
  fi
  if [ "$expected" -ne 0 ] && grep -q 'Done: ' "$HARNESS_DIR/$scenario.log"; then
    echo "FAIL $scenario: reported success" >&2
    exit 1
  fi
  echo "PASS $scenario (exit $status)"
}

run_case partial 7
run_case success 0 valid
run_case fallback 0 valid
run_case missing 1
run_case signfail 1 valid
