#!/usr/bin/env bash
# =============================================================================
# hiddify-core transparent proxy installer
# Supports: Debian 12, Ubuntu 22/24, Raspberry Pi OS (arm64)
# Usage:
#   sudo ./install.sh install --subscription-url <URL> [--install-dir <DIR>]
#   sudo ./install.sh update
#   sudo ./install.sh upgrade
#   sudo ./install.sh uninstall
#   sudo ./install.sh status
#   sudo ./install.sh test
# =============================================================================
set -euo pipefail

# ─── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}=== $* ===${NC}"; }

# ─── defaults ─────────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/hiddify"
HIDDIFY_USER="hiddify-svc"
BINARY_NAME="hiddify-core"
SERVICE_NAME="hiddify"
SUBSCRIPTION_URL=""
GITHUB_REPO="hiddify/hiddify-core"
GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"

# ports (must match inbounds in generated config)
PORT_MIXED=12334
PORT_REDIR=12336
PORT_DNS=12337

# ─── helpers ──────────────────────────────────────────────────────────────────
require_root() {
  [[ $EUID -eq 0 ]] || die "Run as root: sudo $0 $*"
}

require_cmd() {
  command -v "$1" &>/dev/null || die "Required command not found: $1 — install it first"
}

install_deps() {
  local pkgs=()
  command -v curl    &>/dev/null || pkgs+=(curl)
  command -v python3 &>/dev/null || pkgs+=(python3)
  command -v iptables &>/dev/null || pkgs+=(iptables)
  command -v ip6tables &>/dev/null || pkgs+=(ip6tables)

  if [[ ${#pkgs[@]} -eq 0 ]]; then
    ok "All dependencies already installed"
    return 0
  fi

  info "Installing missing dependencies: ${pkgs[*]}"
  if command -v apt-get &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
  elif command -v yum &>/dev/null; then
    yum install -y "${pkgs[@]}"
  else
    die "Cannot install dependencies automatically — please install manually: ${pkgs[*]}"
  fi
  ok "Dependencies installed"
}

# detect real user when called via sudo
real_user() {
  echo "${SUDO_USER:-${USER:-$(whoami)}}"
}

# detect default network interface
detect_iface() {
  ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}'
}

# detect server subnet from default interface
detect_subnet() {
  local iface="$1"
  ip -4 addr show dev "$iface" 2>/dev/null \
    | awk '/inet / {print $2}' \
    | head -1 \
    | python3 -c "
import sys, ipaddress
net = ipaddress.IPv4Interface(sys.stdin.read().strip()).network
print(str(net))
" 2>/dev/null || echo ""
}

# check if public IPv6 is available
has_ipv6() {
  ip -6 addr show scope global 2>/dev/null | grep -q 'inet6' && return 0 || return 1
}

# detect arch for github release download
detect_arch() {
  local machine
  machine=$(uname -m)
  case "$machine" in
    x86_64)          echo "amd64" ;;
    aarch64|arm64)   echo "arm64" ;;
    armv7l|armv6l)   echo "arm" ;;
    i686|i386)       echo "386" ;;
    *) die "Unsupported architecture: $machine" ;;
  esac
}

# detect libc variant
detect_libc() {
  if ldd --version 2>&1 | grep -qi musl; then
    echo "musl"
  else
    echo "glibc"
  fi
}

# ─── config management ────────────────────────────────────────────────────────
data_dir()     { echo "${INSTALL_DIR}/data"; }
config_file()  { echo "${INSTALL_DIR}/data/current-config.json"; }
fixed_config() { echo "${INSTALL_DIR}/current-config.fixed.json"; }
sub_url_file() { echo "${INSTALL_DIR}/subscription.url"; }
log_file()     { echo "${INSTALL_DIR}/hiddify-core.log"; }

setup_dirs() {
  mkdir -p "${INSTALL_DIR}" "$(data_dir)"
  # hiddify-svc needs write access to data/ (writes current-config.json, db, geo files)
  chown root:"$HIDDIFY_USER" "${INSTALL_DIR}"
  chmod 750 "${INSTALL_DIR}"
  chown "$HIDDIFY_USER":"$HIDDIFY_USER" "$(data_dir)"
  chmod 770 "$(data_dir)"
  mkdir -p "${INSTALL_DIR}/data/webui"
  chown -R "$HIDDIFY_USER":"$HIDDIFY_USER" "$(data_dir)"
  chmod -R 770 "$(data_dir)"
  # log: root-owned but group-readable so both root and hiddify-svc can write
  touch "$(log_file)"
  chown root:"$HIDDIFY_USER" "$(log_file)"
  chmod 664 "$(log_file)"
}

# Generate config from subscription URL using hiddify-core run
# hiddify-core run -c URL generates current-config.json then exits/crashes —
# we catch that, then patch the generated file
generate_config() {
  local url="$1"
  local raw_config
  raw_config="$(config_file)"

  info "Generating config from subscription..."

  # hiddify-core run writes current-config.json into CWD/data/
  # so we cd into INSTALL_DIR where data/ lives
  # Run with timeout — it will generate the config then likely fail on balancer
  # We only need the file, not a successful exit
  (cd "$INSTALL_DIR" && \
    sudo -u "$HIDDIFY_USER" timeout 20 \
      "$INSTALL_DIR/$BINARY_NAME" run -c "$url" \
      >> "$(log_file)" 2>&1) || true

  if [[ ! -f "$raw_config" ]]; then
    echo ""
    warn "Last 20 lines of log:"
    tail -n 20 "$(log_file)" 2>/dev/null || true
    die "Config generation failed — no current-config.json in $(data_dir). See log above."
  fi

  info "Patching config (fixing balancer bug)..."
  patch_config "$raw_config" "$(fixed_config)"
  chown root:"$HIDDIFY_USER" "$(fixed_config)"
  chmod 640 "$(fixed_config)"
  ok "Config ready: $(fixed_config)"
}

# Patch: remove broken balance outbound, fix references in selector/route
patch_config() {
  local src="$1"
  local dst="$2"

  python3 - "$src" "$dst" <<'PY'
import json, sys

src, dst = sys.argv[1], sys.argv[2]

with open(src, "r", encoding="utf-8") as f:
    d = json.load(f)

# 1. remove broken balance outbound (empty strategy = crash)
broken = {
    o["tag"] for o in d.get("outbounds", [])
    if o.get("type") == "balancer" and not o.get("strategy", "").strip()
}

if broken:
    d["outbounds"] = [o for o in d["outbounds"] if o.get("tag") not in broken]

    # fix selector outbounds list and default
    for o in d.get("outbounds", []):
        if o.get("tag") == "select":
            o["outbounds"] = [x for x in o.get("outbounds", []) if x not in broken]
            if o.get("default") in broken:
                # pick first non-broken outbound as default
                candidates = [x for x in o.get("outbounds", []) if x != "select"]
                o["default"] = candidates[0] if candidates else o["outbounds"][0]

    # fix route rules and final
    route = d.get("route", {})
    if route.get("final") in broken:
        # fallback to "lowest" if present, else first available outbound
        tags = [o["tag"] for o in d.get("outbounds", [])]
        route["final"] = "lowest" if "lowest" in tags else tags[0]
    for r in route.get("rules", []):
        if r.get("outbound") in broken:
            r["outbound"] = route.get("final", "direct")
    d["route"] = route

# 2. ensure all balancers have a valid strategy
for o in d.get("outbounds", []):
    if o.get("type") == "balancer" and not o.get("strategy", "").strip():
        o["strategy"] = "lowest-delay"

# 3. ensure required inbounds exist
existing_types = {i.get("type") for i in d.get("inbounds", [])}
existing_tags  = {i.get("tag")  for i in d.get("inbounds", [])}

required_inbounds = [
    {
        "type": "mixed", "tag": "mixed-in127.0.0.1",
        "listen": "127.0.0.1", "listen_port": 12334
    },
    {
        "type": "mixed", "tag": "mixed-in::1",
        "listen": "::1", "listen_port": 12334
    },
    {
        "type": "redirect", "tag": "redirect-in127.0.0.1",
        "listen": "127.0.0.1", "listen_port": 12336
    },
    {
        "type": "redirect", "tag": "redirect-in::1",
        "listen": "::1", "listen_port": 12336
    },
    {
        "type": "direct", "tag": "dns-in127.0.0.1",
        "listen": "127.0.0.1", "listen_port": 12337
    },
    {
        "type": "direct", "tag": "dns-in::1",
        "listen": "::1", "listen_port": 12337
    },
]

for ib in required_inbounds:
    if ib["tag"] not in existing_tags:
        d.setdefault("inbounds", []).append(ib)

with open(dst, "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)

changed = "with balancer fix" if broken else "no balancer issues found"
print(f"[patch] saved {dst} ({changed})")
PY
}

# ─── binary management ────────────────────────────────────────────────────────
get_latest_version() {
  curl -fsSL "$GITHUB_API" 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])" \
    || die "Failed to fetch latest version from GitHub API"
}

download_binary() {
  local version="$1"
  local arch
  local libc
  arch=$(detect_arch)
  libc=$(detect_libc)

  local asset="hiddify-core-linux-${arch}-${libc}.tar.gz"
  local url="https://github.com/${GITHUB_REPO}/releases/download/${version}/${asset}"
  local tmp
  tmp=$(mktemp -d)

  info "Downloading ${asset} (${version})..."
  curl -fsSL --progress-bar "$url" -o "${tmp}/${asset}" \
    || die "Download failed: $url"

  info "Extracting..."
  mkdir -p "${tmp}/extracted"
  tar -xf "${tmp}/${asset}" -C "${tmp}/extracted"

  # pick the largest executable (the main binary)
  local bin
  bin=$(find "${tmp}/extracted" -type f -executable -printf "%s %p\n" \
        | sort -rn | head -1 | cut -d' ' -f2-)

  [[ -n "$bin" ]] || die "No executable found in archive"

  install -m 755 "$bin" "${INSTALL_DIR}/${BINARY_NAME}"
  rm -rf "$tmp"

  ok "Installed: ${INSTALL_DIR}/${BINARY_NAME} (${version})"
}

# ─── iptables ─────────────────────────────────────────────────────────────────
iptables_add() {
  local iface="$1"
  local subnet="$2"
  local uid
  uid=$(id -u "$HIDDIFY_USER" 2>/dev/null || echo "")

  if iptables -t nat -L HIDDIFY &>/dev/null 2>&1; then
    warn "iptables HIDDIFY chain already exists, skipping"
    return 0
  fi

  info "Adding iptables rules..."

  # ── IPv4 ──
  iptables -t nat -N HIDDIFY

  # bypass: private + server subnet
  iptables -t nat -A HIDDIFY -d 127.0.0.0/8    -j RETURN
  iptables -t nat -A HIDDIFY -d 10.0.0.0/8     -j RETURN
  iptables -t nat -A HIDDIFY -d 172.16.0.0/12  -j RETURN
  iptables -t nat -A HIDDIFY -d 192.168.0.0/16 -j RETURN
  iptables -t nat -A HIDDIFY -d 169.254.0.0/16 -j RETURN
  [[ -n "$subnet" ]] && \
    iptables -t nat -A HIDDIFY -d "$subnet" -j RETURN

  # bypass: hiddify-svc traffic (prevent routing loop)
  [[ -n "$uid" ]] && \
    iptables -t nat -A HIDDIFY -m owner --uid-owner "$uid" -j RETURN

  # redirect all tcp to hiddify redirect inbound
  iptables -t nat -A HIDDIFY -p tcp -j REDIRECT --to-ports "$PORT_REDIR"

  # apply to outgoing traffic
  iptables -t nat -A OUTPUT -p tcp -j HIDDIFY

  # DNS redirect
  iptables -t nat -A OUTPUT -p udp --dport 53 -j REDIRECT --to-ports "$PORT_DNS"
  iptables -t nat -A OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports "$PORT_DNS"

  # ── IPv6 (only if public IPv6 exists) ──
  if has_ipv6; then
    ip6tables -t nat -N HIDDIFY 2>/dev/null || true
    ip6tables -t nat -A HIDDIFY -d ::1/128  -j RETURN
    ip6tables -t nat -A HIDDIFY -d fc00::/7 -j RETURN
    ip6tables -t nat -A HIDDIFY -d fe80::/10 -j RETURN
    [[ -n "$uid" ]] && \
      ip6tables -t nat -A HIDDIFY -m owner --uid-owner "$uid" -j RETURN
    ip6tables -t nat -A HIDDIFY -p tcp -j REDIRECT --to-ports "$PORT_REDIR"
    ip6tables -t nat -A OUTPUT  -p tcp -j HIDDIFY
    ip6tables -t nat -A OUTPUT  -p udp --dport 53 -j REDIRECT --to-ports "$PORT_DNS"
    ip6tables -t nat -A OUTPUT  -p tcp --dport 53 -j REDIRECT --to-ports "$PORT_DNS"
    ok "IPv6 iptables rules added"
  else
    info "No public IPv6 detected — skipping ip6tables"
  fi

  ok "iptables rules added"
}

iptables_del() {
  info "Removing iptables rules..."

  iptables -t nat -D OUTPUT -p tcp -j HIDDIFY 2>/dev/null || true
  iptables -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-ports "$PORT_DNS" 2>/dev/null || true
  iptables -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports "$PORT_DNS" 2>/dev/null || true
  iptables -t nat -F HIDDIFY 2>/dev/null || true
  iptables -t nat -X HIDDIFY 2>/dev/null || true

  ip6tables -t nat -D OUTPUT -p tcp -j HIDDIFY 2>/dev/null || true
  ip6tables -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-ports "$PORT_DNS" 2>/dev/null || true
  ip6tables -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports "$PORT_DNS" 2>/dev/null || true
  ip6tables -t nat -F HIDDIFY 2>/dev/null || true
  ip6tables -t nat -X HIDDIFY 2>/dev/null || true

  ok "iptables rules removed"
}

iptables_save() {
  if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save
    ok "iptables rules saved (netfilter-persistent)"
  elif command -v iptables-save &>/dev/null; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    ok "iptables rules saved"
  else
    warn "netfilter-persistent not found — rules won't survive reboot"
    warn "Install with: apt install iptables-persistent"
  fi
}

# ─── systemd ────────────────────────────────────────────────────────────────────────────
write_service() {
  # iptables runs as root — separate oneshot service
  cat > "/etc/systemd/system/${SERVICE_NAME}-iptables.service" <<'UNIT'
[Unit]
Description=Hiddify iptables rules
Before=SVCNAME.service
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=INSTALLDIR/hcore-iptables.sh add
ExecStop=INSTALLDIR/hcore-iptables.sh del

[Install]
WantedBy=multi-user.target
UNIT
  # substitute real paths (UNIT heredoc is single-quoted so no expansion)
  sed -i "s|SVCNAME|${SERVICE_NAME}|g; s|INSTALLDIR|${INSTALL_DIR}|g" \
    "/etc/systemd/system/${SERVICE_NAME}-iptables.service"

  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<'UNIT'
[Unit]
Description=Hiddify Core Transparent Proxy
After=network-online.target SVCNAME-iptables.service
Wants=network-online.target
Requires=SVCNAME-iptables.service

[Service]
Type=simple
User=HIDDIFYUSER
WorkingDirectory=INSTALLDIR/data
ExecStart=INSTALLDIR/BINNAME srun -c INSTALLDIR/current-config.fixed.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT
  sed -i "s|SVCNAME|${SERVICE_NAME}|g; s|INSTALLDIR|${INSTALL_DIR}|g; s|HIDDIFYUSER|${HIDDIFY_USER}|g; s|BINNAME|${BINARY_NAME}|g" \
    "/etc/systemd/system/${SERVICE_NAME}.service"

  ok "systemd units written"
}

# separate script for iptables called from systemd ExecStartPost/ExecStop
write_iptables_helper() {
  local iface="$1"
  local subnet="$2"

  cat > "${INSTALL_DIR}/hcore-iptables.sh" <<EOF
#!/usr/bin/env bash
# Auto-generated by install.sh — do not edit manually
HIDDIFY_USER="${HIDDIFY_USER}"
PORT_REDIR="${PORT_REDIR}"
PORT_DNS="${PORT_DNS}"
SERVER_SUBNET="${subnet}"
IFACE="${iface}"

uid=\$(id -u "\$HIDDIFY_USER" 2>/dev/null || echo "")

add() {
  iptables -t nat -L HIDDIFY &>/dev/null && return 0

  iptables -t nat -N HIDDIFY
  iptables -t nat -A HIDDIFY -d 127.0.0.0/8    -j RETURN
  iptables -t nat -A HIDDIFY -d 10.0.0.0/8     -j RETURN
  iptables -t nat -A HIDDIFY -d 172.16.0.0/12  -j RETURN
  iptables -t nat -A HIDDIFY -d 192.168.0.0/16 -j RETURN
  iptables -t nat -A HIDDIFY -d 169.254.0.0/16 -j RETURN
  [ -n "\$SERVER_SUBNET" ] && iptables -t nat -A HIDDIFY -d "\$SERVER_SUBNET" -j RETURN
  [ -n "\$uid" ] && iptables -t nat -A HIDDIFY -m owner --uid-owner "\$uid" -j RETURN
  iptables -t nat -A HIDDIFY -p tcp -j REDIRECT --to-ports "\$PORT_REDIR"
  iptables -t nat -A OUTPUT  -p tcp -j HIDDIFY
  iptables -t nat -A OUTPUT  -p udp --dport 53 -j REDIRECT --to-ports "\$PORT_DNS"
  iptables -t nat -A OUTPUT  -p tcp --dport 53 -j REDIRECT --to-ports "\$PORT_DNS"

  # IPv6
  if ip -6 addr show scope global &>/dev/null | grep -q inet6; then
    ip6tables -t nat -N HIDDIFY 2>/dev/null || true
    ip6tables -t nat -A HIDDIFY -d ::1/128   -j RETURN
    ip6tables -t nat -A HIDDIFY -d fc00::/7  -j RETURN
    ip6tables -t nat -A HIDDIFY -d fe80::/10 -j RETURN
    [ -n "\$uid" ] && ip6tables -t nat -A HIDDIFY -m owner --uid-owner "\$uid" -j RETURN
    ip6tables -t nat -A HIDDIFY -p tcp -j REDIRECT --to-ports "\$PORT_REDIR"
    ip6tables -t nat -A OUTPUT  -p tcp -j HIDDIFY
    ip6tables -t nat -A OUTPUT  -p udp --dport 53 -j REDIRECT --to-ports "\$PORT_DNS"
    ip6tables -t nat -A OUTPUT  -p tcp --dport 53 -j REDIRECT --to-ports "\$PORT_DNS"
  fi
}

del() {
  iptables  -t nat -D OUTPUT -p tcp -j HIDDIFY 2>/dev/null || true
  iptables  -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-ports "\$PORT_DNS" 2>/dev/null || true
  iptables  -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports "\$PORT_DNS" 2>/dev/null || true
  iptables  -t nat -F HIDDIFY 2>/dev/null || true
  iptables  -t nat -X HIDDIFY 2>/dev/null || true
  ip6tables -t nat -D OUTPUT -p tcp -j HIDDIFY 2>/dev/null || true
  ip6tables -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-ports "\$PORT_DNS" 2>/dev/null || true
  ip6tables -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports "\$PORT_DNS" 2>/dev/null || true
  ip6tables -t nat -F HIDDIFY 2>/dev/null || true
  ip6tables -t nat -X HIDDIFY 2>/dev/null || true
}

case "\${1:-}" in
  add) add ;;
  del) del ;;
  *) echo "Usage: \$0 {add|del}"; exit 1 ;;
esac
EOF
  chmod +x "${INSTALL_DIR}/hcore-iptables.sh"
  ok "iptables helper written: ${INSTALL_DIR}/hcore-iptables.sh"
}

# ─── env proxy setup ──────────────────────────────────────────────────────────
write_env_profile() {
  local profile_file="/etc/profile.d/hiddify-proxy.sh"
  cat > "$profile_file" <<EOF
# hiddify transparent proxy — HTTP proxy env for apps that respect it
export http_proxy="http://127.0.0.1:${PORT_MIXED}/"
export https_proxy="http://127.0.0.1:${PORT_MIXED}/"
export HTTP_PROXY="http://127.0.0.1:${PORT_MIXED}/"
export HTTPS_PROXY="http://127.0.0.1:${PORT_MIXED}/"
export no_proxy="127.0.0.1,localhost,::1"
export NO_PROXY="127.0.0.1,localhost,::1"
EOF
  ok "Proxy env written: $profile_file (takes effect on next login)"
}

# ─── commands ─────────────────────────────────────────────────────────────────
cmd_install() {
  require_root

  # parse args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --subscription-url) SUBSCRIPTION_URL="$2"; shift 2 ;;
      --install-dir)      INSTALL_DIR="$2";       shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  [[ -n "$SUBSCRIPTION_URL" ]] || die "Required: --subscription-url <URL>"

  section "Installing dependencies"
  install_deps

  section "Pre-flight checks"
  require_cmd curl
  require_cmd python3
  require_cmd ip
  require_cmd iptables

  local iface subnet
  iface=$(detect_iface)
  [[ -n "$iface" ]] || die "Could not detect default network interface"
  subnet=$(detect_subnet "$iface")

  info "Interface : $iface"
  info "Subnet    : ${subnet:-unknown}"
  info "IPv6      : $(has_ipv6 && echo yes || echo no)"
  info "Arch      : $(detect_arch) / libc: $(detect_libc)"
  info "Install   : $INSTALL_DIR"

  section "Creating directories and user"
  if ! id "$HIDDIFY_USER" &>/dev/null; then
    useradd -r -s /usr/sbin/nologin -M -d "$INSTALL_DIR" "$HIDDIFY_USER"
    ok "User created: $HIDDIFY_USER"
  else
    ok "User already exists: $HIDDIFY_USER"
  fi
  setup_dirs

  section "Downloading hiddify-core"
  local version
  version=$(get_latest_version)
  info "Latest version: $version"
  download_binary "$version"
  echo "$version" > "${INSTALL_DIR}/version.txt"

  # allow hiddify-svc to bind low ports if needed (cap)
  setcap 'cap_net_bind_service=+ep' "${INSTALL_DIR}/${BINARY_NAME}" 2>/dev/null || true

  section "Generating and patching config"
  echo "$SUBSCRIPTION_URL" > "$(sub_url_file)"
  chown root:"$HIDDIFY_USER" "$(sub_url_file)"
  chmod 640 "$(sub_url_file)"
  generate_config "$SUBSCRIPTION_URL"

  section "Installing iptables-persistent"
  if ! command -v netfilter-persistent &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent 2>/dev/null \
      || warn "Could not install iptables-persistent — rules won't survive reboot"
  fi

  section "Writing systemd service"
  write_iptables_helper "$iface" "$subnet"
  write_service
  write_env_profile

  section "Starting service"
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}-iptables"
  systemctl enable "$SERVICE_NAME"
  systemctl restart "${SERVICE_NAME}-iptables"
  systemctl restart "$SERVICE_NAME"
  sleep 2
  systemctl is-active --quiet "$SERVICE_NAME" \
    && ok "Service is running" \
    || { warn "Service may not be running — check: journalctl -u ${SERVICE_NAME} -n 30"; }

  section "Saving iptables rules"
  # give hiddify a moment to bind ports before iptables ExecStartPost fires
  sleep 1
  iptables_save

  section "Verification"
  cmd_test

  echo ""
  ok "Installation complete!"
  echo -e "  Install dir : ${CYAN}${INSTALL_DIR}${NC}"
  echo -e "  Service     : ${CYAN}systemctl status ${SERVICE_NAME}${NC}"
  echo -e "  Logs        : ${CYAN}journalctl -u ${SERVICE_NAME} -f${NC}"
  echo -e "  Update sub  : ${CYAN}sudo $0 update${NC}"
  echo -e "  Upgrade bin : ${CYAN}sudo $0 upgrade${NC}"
}

cmd_update() {
  require_root
  [[ -f "$(sub_url_file)" ]] || die "No subscription URL found. Run install first."

  local url
  url=$(cat "$(sub_url_file)")
  info "Subscription URL: $url"

  section "Stopping service"
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true

  section "Re-generating config"
  rm -f "$(config_file)" 2>/dev/null || true
  generate_config "$url"

  section "Restarting service"
  systemctl start "$SERVICE_NAME"
  sleep 2
  systemctl is-active --quiet "$SERVICE_NAME" && ok "Service restarted" \
    || warn "Service may not be running"

  cmd_test
}

cmd_upgrade() {
  require_root
  [[ -f "${INSTALL_DIR}/version.txt" ]] || die "Not installed. Run install first."

  local current latest
  current=$(cat "${INSTALL_DIR}/version.txt")
  latest=$(get_latest_version)

  if [[ "$current" == "$latest" ]]; then
    ok "Already on latest version: $current"
    return 0
  fi

  info "Upgrading: $current → $latest"

  section "Stopping service"
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true

  section "Downloading new binary"
  download_binary "$latest"
  echo "$latest" > "${INSTALL_DIR}/version.txt"
  setcap 'cap_net_bind_service=+ep' "${INSTALL_DIR}/${BINARY_NAME}" 2>/dev/null || true

  section "Re-patching config (API may have changed)"
  if [[ -f "$(config_file)" ]]; then
    patch_config "$(config_file)" "$(fixed_config)"
    chown root:"$HIDDIFY_USER" "$(fixed_config)"
    chmod 640 "$(fixed_config)"
  fi

  section "Restarting service"
  systemctl daemon-reload
  systemctl start "$SERVICE_NAME"
  sleep 2
  systemctl is-active --quiet "$SERVICE_NAME" && ok "Service restarted" \
    || warn "Service may not be running"

  cmd_test
}

cmd_uninstall() {
  require_root
  warn "This will remove hiddify-core, its config, service, and iptables rules."
  read -rp "Continue? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }

  section "Stopping and disabling service"
  systemctl stop "$SERVICE_NAME"               2>/dev/null || true
  systemctl stop "${SERVICE_NAME}-iptables"    2>/dev/null || true
  systemctl disable "$SERVICE_NAME"            2>/dev/null || true
  systemctl disable "${SERVICE_NAME}-iptables" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  rm -f "/etc/systemd/system/${SERVICE_NAME}-iptables.service"
  systemctl daemon-reload

  section "Removing iptables rules"
  iptables_del
  iptables_save

  section "Removing files"
  rm -rf "$INSTALL_DIR"
  rm -f /etc/profile.d/hiddify-proxy.sh

  section "Removing user"
  userdel "$HIDDIFY_USER" 2>/dev/null || true

  ok "Uninstall complete"
}

cmd_status() {
  section "Service"
  systemctl status "$SERVICE_NAME" --no-pager 2>/dev/null || echo "Service not found"

  section "Process"
  pgrep -af "$BINARY_NAME" || echo "Not running"

  section "Ports"
  ss -tulnp | grep -E ":($PORT_MIXED|$PORT_REDIR|$PORT_DNS)" || echo "No ports listening"

  section "iptables IPv4"
  iptables -t nat -L HIDDIFY -n --line-numbers 2>/dev/null || echo "No HIDDIFY chain"

  section "iptables IPv6"
  ip6tables -t nat -L HIDDIFY -n --line-numbers 2>/dev/null || echo "No HIDDIFY chain (IPv6)"

  section "Version"
  [[ -f "${INSTALL_DIR}/version.txt" ]] \
    && cat "${INSTALL_DIR}/version.txt" || echo "Unknown"
  "${INSTALL_DIR}/${BINARY_NAME}" version 2>/dev/null || true

  section "External IP"
  curl -s --max-time 5 --noproxy '*' -4 https://ifconfig.me 2>/dev/null \
    && echo " (IPv4)" || echo "IPv4: timeout"
}

cmd_test() {
  section "Proxy test"

  local via_env direct_ipv4 as_nobody
  via_env=$(curl -s --max-time 8 https://ifconfig.me 2>/dev/null || echo "FAIL")
  direct_ipv4=$(curl -s --max-time 8 --noproxy '*' -4 https://ifconfig.me 2>/dev/null || echo "FAIL")
  as_nobody=$(sudo -u nobody curl -s --max-time 8 https://ifconfig.me 2>/dev/null || echo "FAIL")

  local server_ip
  server_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{print $7}' | head -1)

  result_line() {
    local label="$1" val="$2"
    if [[ "$val" == "FAIL" ]]; then
      echo -e "  ${YELLOW}?${NC}  $label : ${YELLOW}FAIL${NC}"
    elif [[ "$val" == "$server_ip" ]]; then
      echo -e "  ${RED}✗${NC}  $label : ${RED}$val${NC} (direct — NOT proxied)"
    else
      echo -e "  ${GREEN}✓${NC}  $label : ${GREEN}$val${NC} (proxied)"
    fi
  }

  echo ""
  result_line "Via http_proxy env " "$via_env"
  result_line "Direct IPv4 (iptables)" "$direct_ipv4"
  result_line "As nobody (no env)  " "$as_nobody"
  echo ""

  if [[ "$direct_ipv4" != "$server_ip" && "$as_nobody" != "$server_ip" ]]; then
    ok "All traffic is going through proxy"
  else
    warn "Some traffic may be leaking — check iptables rules"
  fi
}

# ─── entrypoint ───────────────────────────────────────────────────────────────
usage() {
  cat <<EOF

${BOLD}hiddify-core transparent proxy installer${NC}

Usage: sudo $0 <command> [options]

Commands:
  install --subscription-url <URL> [--install-dir <DIR>]
                    Full install: download binary, generate config,
                    setup iptables, systemd service
  update            Re-fetch subscription, re-patch config, restart
  upgrade           Download latest binary from GitHub, restart
  uninstall         Remove everything (service, rules, files, user)
  status            Show service status, ports, iptables, external IP
  test              Verify traffic is going through proxy

Options:
  --subscription-url   Hiddify/sing-box subscription URL (required for install)
  --install-dir        Installation directory (default: /opt/hiddify)

Examples:
  sudo $0 install --subscription-url "https://sub.example.com/..."
  sudo $0 update
  sudo $0 upgrade
  sudo $0 status

EOF
}

main() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    install)   cmd_install "$@" ;;
    update)    cmd_update ;;
    upgrade)   cmd_upgrade ;;
    uninstall) cmd_uninstall ;;
    status)    cmd_status ;;
    test)      cmd_test ;;
    ""|--help|-h) usage; exit 0 ;;
    *) die "Unknown command: $cmd. Run '$0 --help' for usage." ;;
  esac
}

main "$@"
