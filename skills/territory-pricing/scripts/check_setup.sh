#!/usr/bin/env bash
# territory-pricing setup check. One PASS/WARN/FAIL line per prerequisite and
# a fix hint for anything missing. Never prints key material.
# Exit code 0 only when the App Store Connect key works end to end.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="$HOME/.appstoreconnect"
FAILS=0

pass() { echo "  PASS  $1"; }
warn() { echo "  WARN  $1"; }
fail() { echo "  FAIL  $1"; FAILS=$((FAILS+1)); }

perms() { stat -f "%Lp" "$1" 2>/dev/null || stat -c "%a" "$1" 2>/dev/null; }

check_perms() { # $1 path, $2 expected mode, $3 label
  local p; p=$(perms "$1")
  if [ "$p" = "$2" ]; then pass "$3 permissions $2"; else warn "$3 permissions are $p, run: chmod $2 $1"; fi
}

echo "territory-pricing setup check"
echo

if command -v ruby >/dev/null; then
  pass "ruby $(ruby -e 'print RUBY_VERSION')"
else
  fail "ruby missing (ships with macOS; needed for the App Store Connect client)"
  echo; echo "1 check(s) failed - fix the FAIL lines above before pricing anything"; exit 1
fi

# key, key id, issuer id: resolved by the same code the pricing scripts use
out=$(ruby "$DIR/asc.rb" --credentials 2>&1); rc=$?
if [ $rc -ne 0 ]; then
  fail "${out#ERROR: }"
  cat <<HINT

  How to fix:
   1. App Store Connect -> Users and Access -> Integrations -> App Store Connect API
      -> Team Keys -> Generate API Key, access: App Manager (or Admin).
   2. Download AuthKey_<KEY_ID>.p8 (downloadable once) and save it as
        $HOME_DIR/private_keys/AuthKey_<KEY_ID>.p8
   3. Save the Issuer ID (UUID at the top of the Team Keys page):
        echo '{"issuer_id": "<ISSUER_ID>"}' > $HOME_DIR/config.json
   4. chmod 700 $HOME_DIR $HOME_DIR/private_keys && chmod 600 $HOME_DIR/config.json $HOME_DIR/private_keys/*.p8
HINT
  echo; echo "$FAILS check(s) failed - fix the FAIL lines above before pricing anything"; exit 1
fi

KEY_ID=$(echo "$out" | sed -n 's/^key_id=//p')
ISSUER=$(echo "$out" | sed -n 's/^issuer_id=//p')
P8=$(echo "$out" | sed -n 's/^p8_path=//p')
CFG=$(echo "$out" | sed -n 's/^config_path=//p')

pass "private key found and parses as EC P-256 (key id $KEY_ID)"
pass "issuer id set (${ISSUER:0:8}...)"

# permissions
[ -d "$HOME_DIR" ] && check_perms "$HOME_DIR" 700 "key folder"
check_perms "$P8" 600 "private key"
[ -f "$CFG" ] && check_perms "$CFG" 600 "config"
case "$P8" in
  "$HOME"/*) ;;
  *) warn "key is outside your home folder: $P8" ;;
esac
if git -C "$(dirname "$P8")" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  warn "key sits inside a git work tree - move it out so it cannot be committed"
fi

# live round trip
res=$(ruby "$DIR/asc.rb" GET '/v1/apps?limit=1' 2>&1); code=$(echo "$res" | head -1)
case "$code" in
  "HTTP 200") pass "App Store Connect API round trip (HTTP 200)" ;;
  "HTTP 401") fail "API rejected the key (HTTP 401): key id, issuer id and .p8 do not belong together" ;;
  "HTTP 403") fail "API forbids the request (HTTP 403): the key role is too low, needs App Manager or Admin" ;;
  *)          fail "API round trip failed: $(echo "$res" | head -2 | tr '\n' ' ')" ;;
esac

echo
if [ "$FAILS" -eq 0 ]; then
  echo "setup OK"
else
  echo "$FAILS check(s) failed - fix the FAIL lines above before pricing anything"
  exit 1
fi
