#!/usr/bin/env bash
# =============================================================================
# hcore diagnostic script — safe subscription testing without proxy setup
# Usage: sudo bash diagnose.sh --url <subscription-url>
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}=== $* ===${NC}"; }

INSTALL_DIR="/opt/hiddify"
BINARY_NAME="hiddify-core"
HIDDIFY_USER="hiddify-svc"
SUB_URL=""

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) SUB_URL="$2"; shift 2 ;;
    *) die "Unknown option: $1. Usage: sudo bash $0 --url <subscription-url>" ;;
  esac
done

# Fallback to saved URL
if [[ -z "$SUB_URL" && -f "${INSTALL_DIR}/subscription.url" ]]; then
  SUB_URL=$(cat "${INSTALL_DIR}/subscription.url")
  info "Using saved subscription URL"
fi

[[ -n "$SUB_URL" ]] || die "No URL provided. Usage: sudo bash $0 --url <subscription-url>"

# --- Ensure directories exist ---
mkdir -p "${INSTALL_DIR}/data" 2>/dev/null || true
chown -R "$HIDDIFY_USER":"$HIDDIFY_USER" "${INSTALL_DIR}" 2>/dev/null || true

# --- Step 1: Check current state ---
section "1. Current state"

if [[ -f "${INSTALL_DIR}/hiddify-core.log" ]]; then
  info "Last 10 lines of log:"
  tail -10 "${INSTALL_DIR}/hiddify-core.log" | sed 's/^/    /'
else
  warn "No log file found"
fi

if [[ -f "${INSTALL_DIR}/data/current-config.json" ]]; then
  info "Current config exists: $(wc -c < "${INSTALL_DIR}/data/current-config.json") bytes"
else
  warn "No current-config.json found"
fi

if [[ -f "${INSTALL_DIR}/current-config.fixed.json" ]]; then
  info "Fixed config exists: $(wc -c < "${INSTALL_DIR}/current-config.fixed.json") bytes"
else
  warn "No fixed config found"
fi

# --- Step 2: Test subscription URL ---
section "2. Subscription URL test"

info "Testing URL: ${SUB_URL:0:60}..."

# Extract host from URL and resolve it
SUB_HOST=$(echo "$SUB_URL" | sed -E 's|https?://([^/:]+).*|\1|')
SUB_IP=$(nslookup "$SUB_HOST" 2>/dev/null | grep "Address:" | tail -1 | awk '{print $2}' || echo "")

# Add iptables bypass if proxy is active and subscription is on same server
if [[ -n "$SUB_IP" ]] && systemctl is-active --quiet hiddify 2>/dev/null; then
  info "Adding temporary iptables bypass for $SUB_IP..."
  sudo iptables -t nat -I OUTPUT -d "$SUB_IP" -j RETURN 2>/dev/null || true
  BYPASS_ADDED=1
fi

# Test URL
if curl -fsSL --max-time 10 --noproxy '*' "$SUB_URL" >/dev/null 2>&1; then
  ok "URL is reachable"
else
  # Try via proxy as fallback
  if curl -fsSL --max-time 10 --proxy http://127.0.0.1:12334 "$SUB_URL" >/dev/null 2>&1; then
    ok "URL is reachable (via proxy)"
  else
    fail "URL is not reachable: $SUB_URL"
  fi
fi

# Remove bypass if we added it
if [[ "${BYPASS_ADDED:-0}" == "1" ]]; then
  sudo iptables -t nat -D OUTPUT -d "$SUB_IP" -j RETURN 2>/dev/null || true
fi

CONTENT_TYPE=$(curl -fsSI --max-time 10 "$SUB_URL" 2>/dev/null | grep -i content-type | head -1 || true)
info "Content-Type: ${CONTENT_TYPE:-unknown}"

# Show first 200 chars of response to verify it's valid config
RESPONSE=$(curl -fsSL --max-time 10 "$SUB_URL" 2>/dev/null | head -c 500 || true)
if echo "$RESPONSE" | grep -q '{'; then
  ok "Response looks like JSON config"
else
  warn "Response doesn't look like JSON — first 200 chars:"
  echo "$RESPONSE" | head -c 200 | sed 's/^/    /'
fi

# --- Step 3: Check binary ---
section "3. Binary check"

if [[ -x "${INSTALL_DIR}/${BINARY_NAME}" ]]; then
  ok "Binary found: ${INSTALL_DIR}/${BINARY_NAME}"
  "${INSTALL_DIR}/${BINARY_NAME}" version 2>/dev/null | sed 's/^/    /' || true
else
  die "Binary not found: ${INSTALL_DIR}/${BINARY_NAME}

  Install hcore first:
    sudo ./install.sh install --subscription-url \"$SUB_URL\""
fi

# --- Step 4: Generate config manually ---
section "4. Manual config generation"

BACKUP_DIR="${INSTALL_DIR}/backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
[[ -f "${INSTALL_DIR}/data/current-config.json" ]] && \
  cp "${INSTALL_DIR}/data/current-config.json" "$BACKUP_DIR/"
[[ -f "${INSTALL_DIR}/current-config.fixed.json" ]] && \
  cp "${INSTALL_DIR}/current-config.fixed.json" "$BACKUP_DIR/"
info "Backup saved to: $BACKUP_DIR"

rm -f "${INSTALL_DIR}/data/current-config.json" 2>/dev/null || true

info "Running: hiddify-core run -c <URL>"
cd "$INSTALL_DIR"
timeout 20 sudo -u "$HIDDIFY_USER" \
  "${INSTALL_DIR}/${BINARY_NAME}" run -c "$SUB_URL" \
  >> "${INSTALL_DIR}/hiddify-core.log" 2>&1 || true

if [[ -f "${INSTALL_DIR}/data/current-config.json" ]]; then
  CONFIG_SIZE=$(wc -c < "${INSTALL_DIR}/data/current-config.json")
  ok "Config generated: $CONFIG_SIZE bytes"

  python3 -c "
import json, sys
with open('${INSTALL_DIR}/data/current-config.json') as f:
    d = json.load(f)
print('  inbounds:', len(d.get('inbounds', [])))
print('  outbounds:', len(d.get('outbounds', [])))
print('  route rules:', len(d.get('route', {}).get('rules', [])))
print('  route final:', d.get('route', {}).get('final', 'N/A'))
types = {}
for o in d.get('outbounds', []):
    t = o.get('type', 'unknown')
    types[t] = types.get(t, 0) + 1
print('  outbound types:', dict(types))
" 2>/dev/null || warn "Could not parse config"
else
  section "Config generation FAILED — last 20 lines of log"
  tail -20 "${INSTALL_DIR}/hiddify-core.log" 2>/dev/null | sed 's/^/    /'
  die "No current-config.json generated"
fi

# --- Step 5: Patch config ---
section "5. Patch config"

PATCH_SCRIPT=$(mktemp)
cat > "$PATCH_SCRIPT" << 'PYEOF'
import json, sys

src, dst = sys.argv[1], sys.argv[2]

with open(src, "r", encoding="utf-8") as f:
    d = json.load(f)

if not isinstance(d, dict):
    raise SystemExit("config root must be a JSON object")

if "outbounds" not in d or not isinstance(d.get("outbounds"), list) or not d["outbounds"]:
    raise SystemExit("config must contain a non-empty outbounds array")

broken = {
    o.get("tag") for o in d.get("outbounds", [])
    if isinstance(o, dict) and o.get("type") == "balancer" and not str(o.get("strategy", "")).strip() and o.get("tag")
}

if broken:
    print(f"  Removing {len(broken)} broken balancer(s): {broken}")
    d["outbounds"] = [o for o in d["outbounds"] if o.get("tag") not in broken]
    for o in d.get("outbounds", []):
        if o.get("tag") == "select" and isinstance(o.get("outbounds", []), list):
            o["outbounds"] = [x for x in o.get("outbounds", []) if x not in broken]
            if not o.get("outbounds"):
                raise SystemExit("select outbound lost all candidates after balancer cleanup")
else:
    print("  No broken balancers found")

for o in d.get("outbounds", []):
    if isinstance(o, dict) and o.get("type") == "balancer" and not str(o.get("strategy", "")).strip():
        o["strategy"] = "lowest-delay"
        print(f"  Fixed balancer strategy for: {o.get('tag')}")

existing_tags = {i.get("tag") for i in d.get("inbounds", []) if isinstance(i, dict) and i.get("tag")}
required_inbounds = [
    {"type": "mixed", "tag": "mixed-in127.0.0.1", "listen": "127.0.0.1", "listen_port": 12334},
    {"type": "mixed", "tag": "mixed-in::1", "listen": "::1", "listen_port": 12334},
    {"type": "redirect", "tag": "redirect-in127.0.0.1", "listen": "127.0.0.1", "listen_port": 12336},
    {"type": "redirect", "tag": "redirect-in::1", "listen": "::1", "listen_port": 12336},
    {"type": "direct", "tag": "dns-in127.0.0.1", "listen": "127.0.0.1", "listen_port": 12337},
    {"type": "direct", "tag": "dns-in::1", "listen": "::1", "listen_port": 12337},
]

added = []
for ib in required_inbounds:
    if ib["tag"] not in existing_tags:
        d.setdefault("inbounds", []).append(ib)
        added.append(ib["tag"])

if added:
    print(f"  Added inbounds: {added}")

with open(dst, "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)

print(f"  Patched config saved to: {dst}")
PYEOF

FIXED_CONFIG="${INSTALL_DIR}/current-config.fixed.json"
python3 "$PATCH_SCRIPT" "${INSTALL_DIR}/data/current-config.json" "$FIXED_CONFIG"
rm -f "$PATCH_SCRIPT"

if [[ -s "$FIXED_CONFIG" ]]; then
  ok "Fixed config ready"
else
  die "Failed to create fixed config"
fi

# --- Step 6: Test config ---
section "6. Test config (dry run)"

info "Running: hiddify-core srun -c fixed-config (will timeout after 5s)"
timeout 5 sudo -u "$HIDDIFY_USER" \
  "${INSTALL_DIR}/${BINARY_NAME}" srun -c "$FIXED_CONFIG" \
  2>&1 | head -20 | sed 's/^/    /' || true

section "Summary"
ok "Diagnostics complete"
info "Backup: $BACKUP_DIR"
info "Generated config: ${INSTALL_DIR}/data/current-config.json"
info "Fixed config: $FIXED_CONFIG"
info "Log: ${INSTALL_DIR}/hiddify-core.log"

echo ""
echo "To restore previous config:"
echo "  cp $BACKUP_DIR/*.json ${INSTALL_DIR}/data/"
echo "  cp $BACKUP_DIR/*.json ${INSTALL_DIR}/"
