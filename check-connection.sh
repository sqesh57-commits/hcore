#!/usr/bin/env bash
# =============================================================================
# hcore connection diagnostic — find why proxy isn't working
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()    { echo -e "${RED}[FAIL]${NC}  $*"; }
section() { echo -e "\n${BOLD}=== $* ===${NC}"; }

INSTALL_DIR="/opt/hiddify"
CONFIG="${INSTALL_DIR}/data/current-config.json"
FIXED_CONFIG="${INSTALL_DIR}/current-config.fixed.json"

# --- 1. Service status ---
section "1. Service status"

systemctl is-active --quiet hiddify 2>/dev/null && ok "hiddify service active" || fail "hiddify service inactive"
systemctl is-active --quiet hiddify-iptables 2>/dev/null && ok "hiddify-iptables active" || fail "hiddify-iptables inactive"

# --- 2. Ports ---
section "2. Listening ports"

for port in 12334 12336 12337; do
  if ss -ltn 2>/dev/null | grep -q ":$port "; then
    ok "Port $port listening"
  else
    fail "Port $port NOT listening"
  fi
done

# --- 3. iptables ---
section "3. iptables rules"

if iptables -t nat -S OUTPUT 2>/dev/null | grep -q "HIDDIFY"; then
  ok "OUTPUT -> HIDDIFY rule exists"
  iptables -t nat -L HIDDIFY -n 2>/dev/null | head -15 | sed 's/^/    /'
else
  fail "No OUTPUT -> HIDDIFY rule"
fi

UID_SVC=$(id -u hiddify-svc 2>/dev/null || echo "")
if [[ -n "$UID_SVC" ]]; then
  if iptables -t nat -L HIDDIFY -n 2>/dev/null | grep -q "owner.*$UID_SVC"; then
    ok "UID $UID_SVC bypass rule exists"
  else
    fail "No UID bypass for hiddify-svc (UID $UID_SVC) — routing loop possible"
  fi
else
  fail "User hiddify-svc not found"
fi

# --- 4. Config analysis ---
section "4. Config analysis"

if [[ ! -f "$CONFIG" ]]; then
  fail "No config file: $CONFIG"
  exit 1
fi

ok "Config exists: $(wc -c < "$CONFIG") bytes"

python3 -c "
import json, sys

with open('$CONFIG') as f:
    d = json.load(f)

# Outbounds
print('  Outbounds:')
for o in d.get('outbounds', []):
    tag = o.get('tag', '?')
    otype = o.get('type', '?')
    addr = ''
    if otype in ('vmess', 'vless', 'trojan', 'shadowsocks'):
        vnext = o.get('settings', {}).get('vnext', [])
        if vnext:
            addr = vnext[0].get('address', 'N/A')
            port = vnext[0].get('port', 'N/A')
            addr = f'{addr}:{port}'
    print(f'    {tag}: {otype} {addr}')

# Route
route = d.get('route', {})
print(f'  Route final: {route.get(\"final\", \"N/A\")}')

# Inbounds
inbounds = d.get('inbounds', [])
print(f'  Inbounds: {len(inbounds)}')
for i in inbounds:
    print(f'    {i.get(\"tag\", \"?\")}: {i.get(\"type\", \"?\")} :{i.get(\"listen_port\", \"?\")}')
" 2>/dev/null || fail "Could not parse config"

# --- 5. DNS resolution ---
section "5. DNS resolution"

# Extract server address from config
SERVER_ADDR=$(python3 -c "
import json
with open('$CONFIG') as f:
    d = json.load(f)
for o in d.get('outbounds', []):
    if o.get('type') in ('vmess', 'vless', 'trojan', 'shadowsocks'):
        vnext = o.get('settings', {}).get('vnext', [{}])
        if vnext:
            print(vnext[0].get('address', ''))
            break
" 2>/dev/null || echo "")

if [[ -n "$SERVER_ADDR" ]]; then
  info "Server address: $SERVER_ADDR"

  # Try resolving
  if nslookup "$SERVER_ADDR" >/dev/null 2>&1; then
    RESOLVED_IP=$(nslookup "$SERVER_ADDR" 2>/dev/null | grep "Address:" | tail -1 | awk '{print $2}')
    ok "DNS resolves to: $RESOLVED_IP"
  elif host "$SERVER_ADDR" >/dev/null 2>&1; then
    RESOLVED_IP=$(host "$SERVER_ADDR" 2>/dev/null | head -1 | awk '{print $NF}')
    ok "DNS resolves to: $RESOLVED_IP"
  else
    fail "DNS resolution FAILED for $SERVER_ADDR"
  fi

  # Direct IP connectivity test (bypass proxy)
  info "Testing direct connectivity to server..."
  timeout 5 bash -c "echo > /dev/tcp/$SERVER_ADDR/443" 2>/dev/null && \
    ok "Direct TCP connection to $SERVER_ADDR:443 succeeded" || \
    fail "Direct TCP connection to $SERVER_ADDR:443 FAILED"
else
  fail "Could not extract server address from config"
fi

# --- 6. Proxy test ---
section "6. Proxy connectivity test"

# Test through proxy
PROXY_IP=$(curl -s --max-time 5 --noproxy '*' http://127.0.0.1:12334 https://ifconfig.me 2>/dev/null || echo "FAIL")
DIRECT_IP=$(curl -s --max-time 5 --noproxy '*' https://ifconfig.me 2>/dev/null || echo "FAIL")

info "Direct IP: $DIRECT_IP"
info "Via proxy: $PROXY_IP"

if [[ "$PROXY_IP" == "FAIL" ]]; then
  fail "Cannot connect through proxy"
elif [[ "$PROXY_IP" == "$DIRECT_IP" ]]; then
  fail "Proxy IP same as direct — proxy NOT working"
else
  ok "Proxy working! IP changed: $DIRECT_IP -> $PROXY_IP"
fi

# --- 7. Recent errors ---
section "7. Recent log errors"

if [[ -f "${INSTALL_DIR}/hiddify-core.log" ]]; then
  ERRORS=$(tail -50 "${INSTALL_DIR}/hiddify-core.log" 2>/dev/null | grep -ci "error\|fail\|dial\|connect\|refuse" || true)
  if [[ "$ERRORS" -gt 0 ]]; then
    warn "Found $ERRORS error-related lines in last 50 lines:"
    tail -50 "${INSTALL_DIR}/hiddify-core.log" 2>/dev/null | grep -i "error\|fail\|dial\|connect\|refuse" | tail -10 | sed 's/^/    /'
  else
    ok "No errors in recent log"
  fi
else
  warn "No log file found"
fi

# --- Summary ---
section "Summary"

echo "If proxy is not working, common fixes:"
echo "  1. Check DNS: nslookup <server-address>"
echo "  2. Check firewall: is port 443 open to server?"
echo "  3. Check config: do outbounds point to reachable server?"
echo "  4. Check logs: tail -f /opt/hiddify/hiddify-core.log"
echo ""
echo "Quick fixes to try:"
echo "  sudo hcore proxy-direct-on   # stop proxy temporarily"
echo "  sudo hcore proxy-direct-off  # restart proxy"
echo "  sudo hcore update            # re-fetch subscription"
echo "  sudo journalctl -u hiddify -f  # watch live logs"
