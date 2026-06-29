#!/usr/bin/env bash
# =============================================================================
# hcore install.sh function unit tests
# Tests individual functions without requiring root or systemd
# Usage: bash tests/test_install_functions.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SH="$REPO_DIR/install.sh"

# Source only the functions we need (avoid main())
source_functions() {
  local tmp
  tmp=$(mktemp)
  # Remove set -euo pipefail, remove main call
  sed -e 's/^set -euo pipefail$/set +e/' \
      -e 's/^main "$@"$/# skipped/' \
      "$INSTALL_SH" > "$tmp"
  source "$tmp"
  rm -f "$tmp"
  # Override functions after sourcing
  acquire_lock() { :; }
  require_root() { :; }
}

source_functions

PASS=0
FAIL=0
TOTAL=0
TMPDIR_TEST=$(mktemp -d)

pass() { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); echo -e "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); echo -e "  ✗ $1 — $2"; }
section() { echo -e "\n=== $1 ==="; }

cleanup() { rm -rf "$TMPDIR_TEST"; }
trap cleanup EXIT

# ─── sub_validate_url ──────────────────────────────────────────────────────
section "sub_validate_url"

# Valid URLs should not die
if sub_validate_url "https://example.com/sub" 2>/dev/null; then
  pass "valid https URL accepted"
else
  fail "valid https URL rejected" ""
fi

if sub_validate_url "http://example.com/sub" 2>/dev/null; then
  pass "valid http URL accepted"
else
  fail "valid http URL rejected" ""
fi

# Invalid URLs should die (run in subshell to catch exit)
if ( sub_validate_url "" 2>/dev/null ); then
  fail "empty URL accepted" "should have failed"
else
  pass "empty URL rejected"
fi

if ( sub_validate_url "ftp://example.com" 2>/dev/null ); then
  fail "ftp URL accepted" "should have failed"
else
  pass "ftp URL rejected"
fi

if ( sub_validate_url "not-a-url" 2>/dev/null ); then
  fail "plain text accepted as URL" "should have failed"
else
  pass "plain text rejected as URL"
fi

# ─── sub_test_url ──────────────────────────────────────────────────────────
section "sub_test_url"

# Test with a known reachable URL (if network available)
if sub_test_url "https://ifconfig.me" 2>/dev/null; then
  pass "ifconfig.me is reachable"
else
  # May be network issue, not a test failure
  echo "  ⚠ ifconfig.me unreachable (network issue, not a test failure)"
fi

# Test with definitely unreachable URL
if sub_test_url "https://definitely-not-a-valid-domain-12345.example" 2>/dev/null; then
  fail "invalid domain reachable" "should have been unreachable"
else
  pass "invalid domain correctly unreachable"
fi

# ─── fallback_list ─────────────────────────────────────────────────────────
section "fallback_list"

# With no fallback file
export INSTALL_DIR="$TMPDIR_TEST/hcore-test"
mkdir -p "$INSTALL_DIR"

result=$(fallback_list)
if [[ -z "$result" ]]; then
  pass "empty fallback list when no file exists"
else
  fail "expected empty list" "got: $result"
fi

# With fallback file
echo "https://backup1.example.com/sub" > "$INSTALL_DIR/subscription.fallback"
echo "https://backup2.example.com/sub" >> "$INSTALL_DIR/subscription.fallback"

result=$(fallback_list)
line_count=$(echo "$result" | grep -c . || echo 0)
if [[ "$line_count" -eq 2 ]]; then
  pass "fallback_list returns 2 URLs"
else
  fail "expected 2 URLs" "got $line_count"
fi

# ─── fallback_add ──────────────────────────────────────────────────────────
section "fallback_add"

# Clear fallback file
rm -f "$INSTALL_DIR/subscription.fallback"

fallback_add "https://new-fallback.example.com/sub" 2>/dev/null
if [[ -f "$INSTALL_DIR/subscription.fallback" ]]; then
  content=$(cat "$INSTALL_DIR/subscription.fallback")
  if [[ "$content" == "https://new-fallback.example.com/sub" ]]; then
    pass "fallback_add creates file with URL"
  else
    fail "fallback_add wrong content" "got: $content"
  fi
else
  fail "fallback_add didn't create file" ""
fi

# Add duplicate
fallback_add "https://new-fallback.example.com/sub" 2>/dev/null
line_count=$(grep -c . "$INSTALL_DIR/subscription.fallback" || echo 0)
if [[ "$line_count" -eq 1 ]]; then
  pass "fallback_add deduplicates"
else
  fail "fallback_add added duplicate" "lines: $line_count"
fi

# Add second URL
fallback_add "https://another-fallback.example.com/sub" 2>/dev/null
line_count=$(grep -c . "$INSTALL_DIR/subscription.fallback" || echo 0)
if [[ "$line_count" -eq 2 ]]; then
  pass "fallback_add adds second URL"
else
  fail "expected 2 lines" "got $line_count"
fi

# ─── fallback_remove ───────────────────────────────────────────────────────
section "fallback_remove"

# Setup: 3 fallbacks
rm -f "$INSTALL_DIR/subscription.fallback"
echo "https://backup-a.example.com" > "$INSTALL_DIR/subscription.fallback"
echo "https://backup-b.example.com" >> "$INSTALL_DIR/subscription.fallback"
echo "https://backup-c.example.com" >> "$INSTALL_DIR/subscription.fallback"

# Remove middle one
fallback_remove 2 2>/dev/null
content=$(cat "$INSTALL_DIR/subscription.fallback")
if echo "$content" | grep -q "backup-a" && echo "$content" | grep -q "backup-c" && ! echo "$content" | grep -q "backup-b"; then
  pass "fallback_remove removes correct index"
else
  fail "fallback_remove wrong result" "got: $content"
fi

# Remove first
fallback_remove 1 2>/dev/null
content=$(cat "$INSTALL_DIR/subscription.fallback")
if [[ "$content" == "https://backup-c.example.com" ]]; then
  pass "fallback_remove first item works"
else
  fail "fallback_remove first item wrong" "got: $content"
fi

# Remove last remaining
fallback_remove 1 2>/dev/null
if [[ ! -f "$INSTALL_DIR/subscription.fallback" ]] || [[ ! -s "$INSTALL_DIR/subscription.fallback" ]]; then
  pass "fallback_remove last item clears file"
else
  content=$(cat "$INSTALL_DIR/subscription.fallback")
  fail "fallback_remove last item didn't clear" "got: $content"
fi

# Out of range
echo "https://only.example.com" > "$INSTALL_DIR/subscription.fallback"
if ( fallback_remove 5 2>/dev/null ); then
  fail "fallback_remove out of range accepted" "should have failed"
else
  pass "fallback_remove out of range rejected"
fi

# ─── sub_backup_config / sub_restore_config ────────────────────────────────
section "config backup and restore"

# Setup: create a fake fixed config
mkdir -p "$INSTALL_DIR/data"
echo '{"test": "original"}' > "$INSTALL_DIR/current-config.fixed.json"

# Backup
sub_backup_config 2>/dev/null
if [[ -f "$INSTALL_DIR/current-config.fixed.json.bak" ]]; then
  pass "sub_backup_config creates .bak file"
  bak_content=$(cat "$INSTALL_DIR/current-config.fixed.json.bak")
  if [[ "$bak_content" == '{"test": "original"}' ]]; then
    pass "backup content matches original"
  else
    fail "backup content mismatch" "got: $bak_content"
  fi
else
  fail "sub_backup_config didn't create .bak" ""
fi

# Modify the config
echo '{"test": "modified"}' > "$INSTALL_DIR/current-config.fixed.json"

# Restore
sub_restore_config 2>/dev/null
restored=$(cat "$INSTALL_DIR/current-config.fixed.json")
if [[ "$restored" == '{"test": "original"}' ]]; then
  pass "sub_restore_config restores original"
else
  fail "sub_restore_config wrong content" "got: $restored"
fi

# ─── patch_config ──────────────────────────────────────────────────────────
section "patch_config"

# Test: balancer fix
cat > "$TMPDIR_TEST/test_config.json" <<'CFG'
{
  "outbounds": [
    {"tag": "direct", "type": "direct"},
    {"tag": "select", "type": "selector", "outbounds": ["direct", "broken-bal"], "default": "direct"},
    {"tag": "broken-bal", "type": "balancer", "strategy": ""}
  ],
  "route": {
    "final": "direct",
    "rules": []
  },
  "inbounds": []
}
CFG

if patch_config "$TMPDIR_TEST/test_config.json" "$TMPDIR_TEST/test_config.patched" 2>/dev/null; then
  pass "patch_config runs without error"

  # Check broken balancer was removed
  if python3 -c "
import json
with open('$TMPDIR_TEST/test_config.patched') as f:
    d = json.load(f)
tags = [o['tag'] for o in d['outbounds']]
assert 'broken-bal' not in tags, 'broken balancer still present'
print('OK')
" 2>/dev/null; then
    pass "patch_config removes broken balancer"
  else
    fail "patch_config didn't remove broken balancer" ""
  fi

  # Check required inbounds were added
  if python3 -c "
import json
with open('$TMPDIR_TEST/test_config.patched') as f:
    d = json.load(f)
tags = [i['tag'] for i in d.get('inbounds', [])]
assert len(d.get('inbounds', [])) >= 6, f'expected 6+ inbounds, got {len(d.get(\"inbounds\", []))}'
print('OK')
" 2>/dev/null; then
    pass "patch_config adds required inbounds"
  else
    fail "patch_config missing inbounds" ""
  fi
else
  fail "patch_config failed" ""
fi

# Test: config with no balancer issues
cat > "$TMPDIR_TEST/test_config_clean.json" <<'CFG'
{
  "outbounds": [
    {"tag": "direct", "type": "direct"}
  ],
  "route": {"final": "direct"},
  "inbounds": []
}
CFG

if patch_config "$TMPDIR_TEST/test_config_clean.json" "$TMPDIR_TEST/test_config_clean.patched" 2>/dev/null; then
  pass "patch_config handles clean config"
else
  fail "patch_config failed on clean config" ""
fi

# Test: empty config should fail
echo '{}' > "$TMPDIR_TEST/test_config_empty.json"
if ( patch_config "$TMPDIR_TEST/test_config_empty.json" "$TMPDIR_TEST/test_config_empty.patched" 2>/dev/null ); then
  fail "patch_config accepted empty config" "should have failed"
else
  pass "patch_config rejects empty config"
fi

# ─── detect_arch ───────────────────────────────────────────────────────────
section "detect_arch"

arch=$(detect_arch)
case "$arch" in
  amd64|arm64|arm|386) pass "detect_arch returned valid arch: $arch" ;;
  *) fail "detect_arch returned unknown" "$arch" ;;
esac

# ─── detect_iface ──────────────────────────────────────────────────────────
section "detect_iface"

iface=$(detect_iface)
if [[ -n "$iface" ]]; then
  pass "detect_iface returned: $iface"
else
  echo "  ⚠ detect_iface returned empty (may be container/CI)"
fi

# ─── real_user ─────────────────────────────────────────────────────────────
section "real_user"

user=$(real_user)
if [[ -n "$user" ]]; then
  pass "real_user returned: $user"
else
  fail "real_user returned empty" ""
fi

# ─── proxy_env_unset ──────────────────────────────────────────────────────
section "proxy_env_unset"

export http_proxy="http://test:8080"
export https_proxy="http://test:8080"
export HTTP_PROXY="http://test:8080"
export HTTPS_PROXY="http://test:8080"

proxy_env_unset 2>/dev/null || true

if [[ -z "${http_proxy:-}" ]] && [[ -z "${HTTP_PROXY:-}" ]]; then
  pass "proxy_env_unset clears proxy vars"
else
  fail "proxy_env_unset didn't clear vars" "http_proxy=${http_proxy:-set}"
fi

# ─── summary ────────────────────────────────────────────────────────────────
echo ""
echo "=== Results ==="
echo "  Total: $TOTAL"
echo -e "  Pass:  \033[0;32m$PASS\033[0m"
if [[ $FAIL -gt 0 ]]; then
  echo -e "  Fail:  \033[0;31m$FAIL\033[0m"
  exit 1
else
  echo -e "  Fail:  \033[0;32m0\033[0m"
  echo -e "\n\033[0;32mAll tests passed!\033[0m"
  exit 0
fi
