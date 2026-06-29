#!/usr/bin/env bash
# =============================================================================
# hiddify-core transparent proxy installer
# Supports: Debian 12, Ubuntu 22/24, Raspberry Pi OS (arm64)
# Usage:
#   sudo ./install.sh install --subscription-url <URL> [--install-dir <DIR>]
#   sudo ./install.sh subscription <URL> | --show | --test | --list
#   sudo ./install.sh subscription --add-fallback <URL>
#   sudo ./install.sh subscription --remove-fallback <index>
#   sudo ./install.sh direct-on | direct-off
#   sudo ./install.sh health
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
LOCK_DIR="/tmp"

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

lock_file() {
  echo "${LOCK_DIR}/hcore.lock"
}

_HCORE_LOCK_FILE=""

acquire_lock() {
  mkdir -p "$LOCK_DIR"
  _HCORE_LOCK_FILE=$(lock_file)
  exec 9>"$_HCORE_LOCK_FILE"
  if ! flock -n 9; then
    local holder
    holder=$(cat "$_HCORE_LOCK_FILE" 2>/dev/null || true)
    die "Another hcore operation is already running${holder:+: $holder}"
  fi
  echo "pid=$$ cmd=${1:-unknown}" > "$_HCORE_LOCK_FILE"
  trap 'rm -f "$_HCORE_LOCK_FILE"' EXIT
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
sub_url_file()     { echo "${INSTALL_DIR}/subscription.url"; }
sub_fallback_file() { echo "${INSTALL_DIR}/subscription.fallback"; }
log_file()         { echo "${INSTALL_DIR}/hiddify-core.log"; }

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
  # fix cache.db permissions if it exists (hiddify-svc needs write access)
  [[ -f "$(data_dir)/cache.db" ]] && chown "$HIDDIFY_USER":"$HIDDIFY_USER" "$(data_dir)/cache.db"
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

  [[ -s "$src" ]] || die "Config patch source is missing or empty: $src"

  python3 - "$src" "$dst" <<'PY'
import json, sys

src, dst = sys.argv[1], sys.argv[2]

with open(src, "r", encoding="utf-8") as f:
    d = json.load(f)

if not isinstance(d, dict):
    raise SystemExit("config root must be a JSON object")

if "outbounds" not in d or not isinstance(d.get("outbounds"), list) or not d["outbounds"]:
    raise SystemExit("config must contain a non-empty outbounds array")

if "route" in d and not isinstance(d["route"], dict):
    raise SystemExit("route must be an object when present")

# 1. remove broken balance outbound (empty strategy = crash)
broken = {
    o.get("tag") for o in d.get("outbounds", [])
    if isinstance(o, dict) and o.get("type") == "balancer" and not str(o.get("strategy", "")).strip() and o.get("tag")
}

if broken:
    d["outbounds"] = [o for o in d["outbounds"] if o.get("tag") not in broken]

    # fix selector outbounds list and default
    for o in d.get("outbounds", []):
        if o.get("tag") == "select" and isinstance(o.get("outbounds", []), list):
            o["outbounds"] = [x for x in o.get("outbounds", []) if x not in broken]
            if not o.get("outbounds"):
                raise SystemExit("select outbound lost all candidates after balancer cleanup")
            if o.get("default") in broken:
                candidates = [x for x in o.get("outbounds", []) if x != "select"]
                o["default"] = candidates[0] if candidates else o["outbounds"][0]

    # fix route rules and final
    route = d.get("route") or {}
    tags = [o.get("tag") for o in d.get("outbounds", []) if o.get("tag")]
    if not tags:
        raise SystemExit("no outbound tags remain after balancer cleanup")
    if route.get("final") in broken:
        route["final"] = "lowest" if "lowest" in tags else tags[0]
    for r in route.get("rules", []):
        if isinstance(r, dict) and r.get("outbound") in broken:
            r["outbound"] = route.get("final", "direct")
    d["route"] = route

# 2. ensure all balancers have a valid strategy
for o in d.get("outbounds", []):
    if isinstance(o, dict) and o.get("type") == "balancer" and not str(o.get("strategy", "")).strip():
        o["strategy"] = "lowest-delay"

# 3. ensure required inbounds exist
existing_tags = {i.get("tag") for i in d.get("inbounds", []) if isinstance(i, dict) and i.get("tag")}

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

if not isinstance(d.get("inbounds"), list) or not d["inbounds"]:
    raise SystemExit("config must contain inbounds after patching")

with open(dst, "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)

changed = "with balancer fix" if broken else "no balancer issues found"
print(f"[patch] saved {dst} ({changed})")
PY

  [[ -s "$dst" ]] || die "Config patch output is missing or empty: $dst"
}

# ─── binary management ────────────────────────────────────────────────────────
get_latest_version() {
  curl -fsSL "$GITHUB_API" 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])" \
    || die "Failed to fetch latest version from GitHub API"
}

download_file() {
  local url="$1"
  local dst="$2"
  local part="${dst}.part"

  info "Downloading $(basename "$dst")..."

  if command -v curl >/dev/null 2>&1; then
    curl --fail --location --show-error --progress-bar \
      --connect-timeout 20 \
      --max-time 900 \
      --retry 8 \
      --retry-delay 5 \
      --retry-max-time 900 \
      --retry-all-errors \
      -C - \
      "$url" \
      -o "$part" \
      || die "Download failed: $url"
  elif command -v wget >/dev/null 2>&1; then
    wget --tries=8 \
      --timeout=30 \
      --continue \
      -O "$part" \
      "$url" \
      || die "Download failed: $url"
  else
    die "Neither curl nor wget found"
  fi

  [[ -s "$part" ]] || die "Downloaded file is empty: $part"
  mv -f "$part" "$dst"
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
  download_file "$url" "${tmp}/${asset}"

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

  # DNS redirect — bypass for hiddify-svc to prevent DNS loop
  [[ -n "$uid" ]] && \
    iptables -t nat -A OUTPUT -p udp --dport 53 -m owner --uid-owner "$uid" -j RETURN
  [[ -n "$uid" ]] && \
    iptables -t nat -A OUTPUT -p tcp --dport 53 -m owner --uid-owner "$uid" -j RETURN
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
    [[ -n "$uid" ]] && \
      ip6tables -t nat -A OUTPUT -p udp --dport 53 -m owner --uid-owner "$uid" -j RETURN
    [[ -n "$uid" ]] && \
      ip6tables -t nat -A OUTPUT -p tcp --dport 53 -m owner --uid-owner "$uid" -j RETURN
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

  while iptables -t nat -D OUTPUT -p tcp -j HIDDIFY 2>/dev/null; do :; done
  local uid
  uid=$(id -u "$HIDDIFY_USER" 2>/dev/null || echo "")
  while iptables -t nat -D OUTPUT -p udp --dport 53 -m owner --uid-owner "$uid" -j RETURN 2>/dev/null; do :; done
  while iptables -t nat -D OUTPUT -p tcp --dport 53 -m owner --uid-owner "$uid" -j RETURN 2>/dev/null; do :; done
  while iptables -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-ports "$PORT_DNS" 2>/dev/null; do :; done
  while iptables -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports "$PORT_DNS" 2>/dev/null; do :; done
  iptables -t nat -F HIDDIFY 2>/dev/null || true
  iptables -t nat -X HIDDIFY 2>/dev/null || true

  while ip6tables -t nat -D OUTPUT -p tcp -j HIDDIFY 2>/dev/null; do :; done
  while ip6tables -t nat -D OUTPUT -p udp --dport 53 -m owner --uid-owner "$uid" -j RETURN 2>/dev/null; do :; done
  while ip6tables -t nat -D OUTPUT -p tcp --dport 53 -m owner --uid-owner "$uid" -j RETURN 2>/dev/null; do :; done
  while ip6tables -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-ports "$PORT_DNS" 2>/dev/null; do :; done
  while ip6tables -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports "$PORT_DNS" 2>/dev/null; do :; done
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
  [ -n "\$uid" ] && iptables -t nat -A OUTPUT -p udp --dport 53 -m owner --uid-owner "\$uid" -j RETURN
  [ -n "\$uid" ] && iptables -t nat -A OUTPUT -p tcp --dport 53 -m owner --uid-owner "\$uid" -j RETURN
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
    [ -n "\$uid" ] && ip6tables -t nat -A OUTPUT -p udp --dport 53 -m owner --uid-owner "\$uid" -j RETURN
    [ -n "\$uid" ] && ip6tables -t nat -A OUTPUT -p tcp --dport 53 -m owner --uid-owner "\$uid" -j RETURN
    ip6tables -t nat -A OUTPUT  -p udp --dport 53 -j REDIRECT --to-ports "\$PORT_DNS"
    ip6tables -t nat -A OUTPUT  -p tcp --dport 53 -j REDIRECT --to-ports "\$PORT_DNS"
  fi
}

del() {
  iptables  -t nat -D OUTPUT -p tcp -j HIDDIFY 2>/dev/null || true
  while iptables  -t nat -D OUTPUT -p udp --dport 53 -m owner --uid-owner "\$uid" -j RETURN 2>/dev/null; do :; done
  while iptables  -t nat -D OUTPUT -p tcp --dport 53 -m owner --uid-owner "\$uid" -j RETURN 2>/dev/null; do :; done
  iptables  -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-ports "\$PORT_DNS" 2>/dev/null || true
  iptables  -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports "\$PORT_DNS" 2>/dev/null || true
  iptables  -t nat -F HIDDIFY 2>/dev/null || true
  iptables  -t nat -X HIDDIFY 2>/dev/null || true
  ip6tables -t nat -D OUTPUT -p tcp -j HIDDIFY 2>/dev/null || true
  while ip6tables -t nat -D OUTPUT -p udp --dport 53 -m owner --uid-owner "\$uid" -j RETURN 2>/dev/null; do :; done
  while ip6tables -t nat -D OUTPUT -p tcp --dport 53 -m owner --uid-owner "\$uid" -j RETURN 2>/dev/null; do :; done
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

# ─── proxy state helpers ─────────────────────────────────────────────────────
proxy_env_unset() {
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
  unset all_proxy ALL_PROXY no_proxy NO_PROXY
}

proxy_direct_on() {
  section "Entering direct network mode"
  proxy_env_unset
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl stop "${SERVICE_NAME}-iptables" 2>/dev/null || true
}

proxy_direct_off() {
  section "Restarting transparent proxy"
  systemctl start "${SERVICE_NAME}-iptables" 2>/dev/null || true
  systemctl start "$SERVICE_NAME" 2>/dev/null || true
}

# ─── subscription management ────────────────────────────────────────────────
sub_backup_config() {
  local bak="$(fixed_config).bak"
  if [[ -f "$(fixed_config)" ]]; then
    cp -a "$(fixed_config)" "$bak"
    ok "Config backed up: $bak"
  fi
}

sub_restore_config() {
  local bak="$(fixed_config).bak"
  if [[ -f "$bak" ]]; then
    cp -a "$bak" "$(fixed_config)"
    ok "Config restored from backup"
    return 0
  fi
  warn "No backup config found to restore"
  return 1
}

sub_test_url() {
  local url="$1"
  curl -fsSL --max-time 15 --noproxy '*' "$url" >/dev/null 2>&1
}

sub_validate_url() {
  local url="$1"
  [[ -n "$url" ]] || die "Subscription URL cannot be empty"
  [[ "$url" =~ ^https?:// ]] || die "Invalid URL format: $url"
}

# Fallback subscriptions: one URL per line in fallback file
fallback_list() {
  [[ -f "$(sub_fallback_file)" ]] && cat "$(sub_fallback_file)" || true
}

fallback_add() {
  local url="$1"
  sub_validate_url "$url"
  local existing
  existing=$(fallback_list)
  if echo "$existing" | grep -qxF "$url"; then
    warn "URL already in fallback list"
    return 0
  fi
  echo "$url" >> "$(sub_fallback_file)"
  chown root:"$HIDDIFY_USER" "$(sub_fallback_file)"
  chmod 640 "$(sub_fallback_file)"
  ok "Fallback URL added"
}

fallback_remove() {
  local index="$1"
  [[ -f "$(sub_fallback_file)" ]] || die "No fallback URLs configured"
  local total
  total=$(wc -l < "$(sub_fallback_file)")
  [[ "$index" -ge 1 && "$index" -le "$total" ]] || die "Index $index out of range (1-$total)"
  local tmp
  tmp=$(mktemp)
  local i=0
  while IFS= read -r line; do
    i=$((i + 1))
    [[ "$i" -ne "$index" ]] && echo "$line" >> "$tmp"
  done < "$(sub_fallback_file)"
  mv "$tmp" "$(sub_fallback_file)"
  ok "Removed fallback #$index"
}

# Try primary + fallbacks, return the working URL
sub_resolve_url() {
  local primary
  primary=$(cat "$(sub_url_file)" 2>/dev/null || echo "")

  if [[ -n "$primary" ]] && sub_test_url "$primary"; then
    echo "$primary"
    return 0
  fi
  warn "Primary subscription unreachable, trying fallbacks..."

  local i=0
  while IFS= read -r fb; do
    i=$((i + 1))
    if sub_test_url "$fb"; then
      warn "Fallback #$i is reachable, switching..."
      echo "$fb"
      return 0
    fi
  done < <(fallback_list)

  # All failed — try to use last working config
  if [[ -f "$(fixed_config)" ]]; then
    warn "All subscriptions unreachable — using last known config"
    echo "__LAST_KNOWN__"
    return 0
  fi

  die "All subscriptions unreachable and no saved config"
}

cmd_subscription() {
  local action=""
  local url=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --show)
        action="show"; shift ;;
      --test)
        action="test"; shift ;;
      --list)
        action="list"; shift ;;
      --add-fallback)
        action="add-fallback"; url="$2"; shift 2 ;;
      --remove-fallback)
        action="remove-fallback"; url="$2"; shift 2 ;;
      --help|-h)
        action="help"; shift ;;
      -*)
        die "Unknown subscription option: $1" ;;
      *)
        if [[ -z "$action" ]]; then
          action="set"
          url="$1"
        else
          die "Unexpected argument: $1"
        fi
        shift ;;
    esac
  done

  case "${action:-help}" in
    help)
      cat <<SUBEOF

${BOLD}hcore subscription${NC}

Usage: sudo hcore subscription [command|URL]

Commands:
  <URL>                     Replace primary subscription
  --show                    Show current subscription and status
  --test                    Test primary + fallback subscription URLs
  --list                    List all configured subscriptions
  --add-fallback <URL>      Add a fallback subscription URL
  --remove-fallback <idx>   Remove fallback by index (1-based)

Examples:
  sudo hcore subscription "https://new-sub-url/..."
  sudo hcore subscription --show
  sudo hcore subscription --test
  sudo hcore subscription --list
  sudo hcore subscription --add-fallback "https://backup-sub/..."
  sudo hcore subscription --remove-fallback 1

SUBEOF
      return 0
      ;;
  esac

  require_root

  case "${action}" in
    show)
      section "Current subscription"
      if [[ -f "$(sub_url_file)" ]]; then
        local sub_url sub_display
        sub_url=$(cat "$(sub_url_file)")
        sub_display=$(echo "$sub_url" | sed -E 's|(/[^/]{4})[^/]*(/\?|$)|\1****\2|; s|(\?secret=)[^&]*|\1****|')
        echo -e "  URL: ${CYAN}${sub_display}${NC}"
        if sub_test_url "$sub_url"; then
          echo -e "  Status: ${GREEN}reachable${NC}"
        else
          echo -e "  Status: ${RED}unreachable${NC}"
        fi
      else
        echo -e "  ${YELLOW}No subscription configured${NC}"
      fi
      ;;

    test)
      section "Testing subscription"
      if [[ -f "$(sub_url_file)" ]]; then
        local sub_url
        sub_url=$(cat "$(sub_url_file)")
        if sub_test_url "$sub_url"; then
          ok "Primary subscription is reachable"
        else
          warn "Primary subscription is unreachable"
        fi
      else
        warn "No subscription configured"
      fi
      local fb_count
      fb_count=$(fallback_list | grep -c . || echo 0)
      if [[ "$fb_count" -gt 0 ]]; then
        info "Testing $fb_count fallback URL(s)..."
        local i=0
        while IFS= read -r fb; do
          i=$((i + 1))
          if sub_test_url "$fb"; then
            echo -e "  Fallback #$i: ${GREEN}reachable${NC}"
          else
            echo -e "  Fallback #$i: ${RED}unreachable${NC}"
          fi
        done < <(fallback_list)
      fi
      ;;

    list)
      section "All subscriptions"
      if [[ -f "$(sub_url_file)" ]]; then
        local sub_url sub_display
        sub_url=$(cat "$(sub_url_file)")
        sub_display=$(echo "$sub_url" | sed -E 's|(/[^/]{4})[^/]*(/\?|$)|\1****\2|; s|(\?secret=)[^&]*|\1****|')
        echo -e "  ${BOLD}Primary:${NC} ${CYAN}${sub_display}${NC}"
      fi
      local fb_count
      fb_count=$(fallback_list | grep -c . || echo 0)
      if [[ "$fb_count" -gt 0 ]]; then
        local i=0
        while IFS= read -r fb; do
          i=$((i + 1))
          local fb_display
          fb_display=$(echo "$fb" | sed -E 's|(/[^/]{4})[^/]*(/\?|$)|\1****\2|; s|(\?secret=)[^&]*|\1****|')
          echo -e "  ${BOLD}Fallback #$i:${NC} ${CYAN}${fb_display}${NC}"
        done < <(fallback_list)
      else
        echo -e "  ${YELLOW}No fallback URLs configured${NC}"
      fi
      ;;

    add-fallback)
      [[ -n "$url" ]] || die "Usage: hcore subscription --add-fallback <URL>"
      sub_validate_url "$url"
      section "Adding fallback subscription"
      fallback_add "$url"
      ;;

    remove-fallback)
      [[ -n "$url" ]] || die "Usage: hcore subscription --remove-fallback <index>"
      section "Removing fallback subscription"
      fallback_remove "$url"
      ;;

    set)
      [[ -n "$url" ]] || die "Usage: hcore subscription <URL>"
      sub_validate_url "$url"

      section "Replacing subscription"

      # 1. Verify new URL is reachable
      info "Testing new subscription URL..."
      if ! sub_test_url "$url"; then
        die "New subscription URL is not reachable: $url"
      fi
      ok "New subscription URL is reachable"

      # 2. Backup current config
      sub_backup_config

      # 3. Save new URL and generate config
      info "Saving new subscription URL..."
      echo "$url" > "$(sub_url_file)"
      chown root:"$HIDDIFY_USER" "$(sub_url_file)"
      chmod 640 "$(sub_url_file)"

      proxy_direct_on

      section "Generating config from new subscription"
      rm -f "$(config_file)" 2>/dev/null || true
      if ! generate_config "$url" 2>/dev/null; then
        warn "Config generation failed — attempting rollback"
        sub_restore_config
        echo "$(cat "$(sub_url_file).bak" 2>/dev/null || echo "")" > "$(sub_url_file)"
        proxy_direct_off
        die "Subscription replacement failed — rolled back to previous config"
      fi

      # 4. Restart service
      section "Restarting service"
      proxy_direct_off
      sleep 2

      # 5. Verify connectivity
      section "Verifying connectivity"
      local proxy_ok=0
      if curl -fsSL --max-time 10 --noproxy '*' --proxy http://127.0.0.1:$PORT_REDIR https://ifconfig.me >/dev/null 2>&1; then
        proxy_ok=1
      fi

      if [[ $proxy_ok -eq 0 ]]; then
        warn "New config may not be working — rolling back..."
        sub_restore_config
        proxy_direct_on
        rm -f "$(config_file)" 2>/dev/null || true
        generate_config "$(cat "$(sub_url_file).bak" 2>/dev/null || echo "")" 2>/dev/null || true
        echo "$(cat "$(sub_url_file).bak" 2>/dev/null || echo "")" > "$(sub_url_file)"
        proxy_direct_off
        die "Subscription replacement failed connectivity check — rolled back"
      fi

      ok "Subscription replaced successfully"
      cmd_test
      ;;

    help|*)
      cat <<SUBEOF

${BOLD}hcore subscription${NC}

Usage: sudo hcore subscription [command|URL]

Commands:
  <URL>                     Replace primary subscription
  --show                    Show current subscription and status
  --test                    Test primary + fallback subscription URLs
  --list                    List all configured subscriptions
  --add-fallback <URL>      Add a fallback subscription URL
  --remove-fallback <idx>   Remove fallback by index (1-based)

Examples:
  sudo hcore subscription "https://new-sub-url/..."
  sudo hcore subscription --show
  sudo hcore subscription --test
  sudo hcore subscription --list
  sudo hcore subscription --add-fallback "https://backup-sub/..."
  sudo hcore subscription --remove-fallback 1

SUBEOF
      ;;
  esac
}

# ─── direct-on / direct-off ────────────────────────────────────────────────
cmd_direct_on() {
  require_root
  section "Entering direct network mode (proxy disabled)"
  proxy_direct_on
  ok "Proxy disabled — traffic going direct"
  echo -e "  To re-enable: ${CYAN}sudo hcore direct-off${NC}"
}

cmd_direct_off() {
  require_root
  section "Re-enabling transparent proxy"
  proxy_direct_off
  sleep 2
  systemctl is-active --quiet "$SERVICE_NAME" \
    && ok "Proxy re-enabled" \
    || warn "Service may not be running — check: journalctl -u ${SERVICE_NAME} -n 30"
}

# ─── health check ──────────────────────────────────────────────────────────
cmd_health() {
  section "Health check"

  local score=0 total=0
  local pass="pass" fail="fail"

  check() {
    total=$((total + 1))
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
      echo -e "  ${GREEN}✓${NC}  $label"
      score=$((score + 1))
    else
      echo -e "  ${RED}✗${NC}  $label"
    fi
  }

  check "Service running" systemctl is-active --quiet "$SERVICE_NAME"
  check "iptables service running" systemctl is-active --quiet "${SERVICE_NAME}-iptables"
  check "Redirect port $PORT_REDIR listening" ss -ltn | grep -q ":$PORT_REDIR "
  check "DNS port $PORT_DNS listening" ss -ltn | grep -q ":$PORT_DNS "
  check "OUTPUT -> HIDDIFY rule exists" iptables -t nat -S OUTPUT 2>/dev/null | grep -q -- "-A OUTPUT -p tcp -j HIDDIFY"
  check "Config file exists" test -s "$(fixed_config)"
  check "Subscription URL configured" test -f "$(sub_url_file)"

  # Proxy IP != direct IP
  local proxy_ip direct_ip
  proxy_ip=$(curl -s --max-time 5 --proxy http://127.0.0.1:$PORT_REDIR https://ifconfig.me 2>/dev/null || echo "FAIL")
  direct_ip=$(curl -s --max-time 5 --noproxy '*' https://ifconfig.me 2>/dev/null || echo "FAIL")
  total=$((total + 1))
  if [[ "$proxy_ip" != "FAIL" && "$proxy_ip" != "$direct_ip" && "$direct_ip" != "FAIL" ]]; then
    echo -e "  ${GREEN}✓${NC}  Proxy IP differs from direct ($proxy_ip vs $direct_ip)"
    score=$((score + 1))
  else
    echo -e "  ${RED}✗${NC}  Proxy IP check failed (proxy=$proxy_ip direct=$direct_ip)"
  fi

  # No recent errors
  total=$((total + 1))
  if [[ -f "$(log_file)" ]]; then
    local recent_errors
    recent_errors=$(tail -50 "$(log_file)" 2>/dev/null | grep -ci "error\|fail\|panic" || true)
    if [[ "$recent_errors" -eq 0 ]]; then
      echo -e "  ${GREEN}✓${NC}  No recent errors in log"
      score=$((score + 1))
    else
      echo -e "  ${RED}✗${NC}  $recent_errors recent error(s) in log"
    fi
  else
    echo -e "  ${YELLOW}?${NC}  Log file not found"
  fi

  echo ""
  if [[ "$score" -eq "$total" ]]; then
    ok "All $total checks passed — proxy is healthy"
  else
    warn "$score/$total checks passed"
  fi
}

# ─── rollback on failure ─────────────────────────────────────────────────────
rollback_install() {
  local exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    return 0
  fi

  warn "Installation failed (exit code: $exit_code) — rolling back..."

  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl stop "${SERVICE_NAME}-iptables" 2>/dev/null || true
  iptables_del 2>/dev/null || true
  iptables_save 2>/dev/null || true
  rm -rf "$INSTALL_DIR" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}-iptables.service" 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  userdel "$HIDDIFY_USER" 2>/dev/null || true
  rm -f /usr/local/sbin/hcore 2>/dev/null || true
  rm -f /etc/profile.d/hiddify-proxy.sh 2>/dev/null || true

  die "Installation rolled back — server connectivity preserved"
}

# ─── CLI install helpers ─────────────────────────────────────────────────────
install_cli() {
  local source_script wrapper_path
  source_script=$(readlink -f "$0" 2>/dev/null || echo "$0")
  wrapper_path="/usr/local/sbin/hcore"

  install -d /usr/local/sbin
  install -m 755 "$source_script" "${INSTALL_DIR}/hcore"

  cat > "$wrapper_path" <<EOF
#!/usr/bin/env bash
exec "${INSTALL_DIR}/hcore" "\$@"
EOF
  chmod 755 "$wrapper_path"
}

# ─── commands ─────────────────────────────────────────────────────────────────
cmd_install() {
  require_root
  trap rollback_install ERR

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

  section "Network validation"
  info "Testing DNS resolution..."
  if nslookup google.com >/dev/null 2>&1 || host google.com >/dev/null 2>&1; then
    ok "DNS resolution OK"
  else
    die "DNS resolution failed — cannot proceed without working DNS"
  fi

  info "Testing internet connectivity..."
  if curl -fsSL --max-time 10 --noproxy '*' https://ifconfig.me >/dev/null 2>&1; then
    ok "Internet connectivity OK"
  else
    die "No internet connectivity — cannot proceed"
  fi

  info "Testing subscription URL..."
  if curl -fsSL --max-time 15 --noproxy '*' "$SUBSCRIPTION_URL" >/dev/null 2>&1; then
    ok "Subscription URL reachable"
  else
    die "Subscription URL not reachable: $SUBSCRIPTION_URL"
  fi

  local upstream_host
  upstream_host=$(curl -fsSL --max-time 15 --noproxy '*' "$SUBSCRIPTION_URL" 2>/dev/null \
    | base64 -d 2>/dev/null \
    | grep -oP '(?<=@)[^:]+(?=:)' | head -1 || echo "")
  if [[ -n "$upstream_host" ]]; then
    info "Upstream server: $upstream_host"
    if nslookup "$upstream_host" >/dev/null 2>&1 || host "$upstream_host" >/dev/null 2>&1; then
      ok "Upstream server reachable"
    else
      die "Cannot resolve upstream server: $upstream_host"
    fi
  else
    warn "Could not extract upstream host from subscription — skipping check"
  fi

  section "Pre-install recovery"
  if systemctl is-active --quiet "${SERVICE_NAME}-iptables" && ! systemctl is-active --quiet "$SERVICE_NAME"; then
    warn "Detected partial install state: iptables active while service inactive"
    warn "Cleaning stale transparent proxy state before reinstall"
    systemctl stop "${SERVICE_NAME}-iptables" 2>/dev/null || true
    iptables_del
    iptables_save
  fi
  systemctl daemon-reload 2>/dev/null || true

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

  section "Cleaning stale proxy state"
  # Kill any running hiddify-core processes (may be from previous install)
  pkill -f "hiddify-core" 2>/dev/null || true

  # Remove HIDDIFY chain regardless of which service created it
  while iptables -t nat -D OUTPUT -p tcp -j HIDDIFY 2>/dev/null; do :; done
  while iptables -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-ports "$PORT_DNS" 2>/dev/null; do :; done
  while iptables -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports "$PORT_DNS" 2>/dev/null; do :; done
  iptables -t nat -F HIDDIFY 2>/dev/null || true
  iptables -t nat -X HIDDIFY 2>/dev/null || true

  # Same for IPv6
  while ip6tables -t nat -D OUTPUT -p tcp -j HIDDIFY 2>/dev/null; do :; done
  while ip6tables -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-ports "$PORT_DNS" 2>/dev/null; do :; done
  while ip6tables -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports "$PORT_DNS" 2>/dev/null; do :; done
  ip6tables -t nat -F HIDDIFY 2>/dev/null || true
  ip6tables -t nat -X HIDDIFY 2>/dev/null || true

  # Stop any existing hcore/hiddify services
  systemctl stop hcore 2>/dev/null || true
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl stop "${SERVICE_NAME}-iptables" 2>/dev/null || true

  # Unset proxy env to ensure direct connection for config generation
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY 2>/dev/null || true

  ok "Stale proxy state cleaned"

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

  section "Installing CLI"
  install_cli

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

  section "Post-install connectivity check"
  local proxy_ok=0
  if curl -fsSL --max-time 10 --noproxy '*' --proxy http://127.0.0.1:12334 https://ifconfig.me >/dev/null 2>&1; then
    proxy_ok=1
    ok "Proxy connectivity verified"
  fi

  if [[ $proxy_ok -eq 0 ]]; then
    warn "Proxy may not be working — checking direct connection..."
    if curl -fsSL --max-time 10 --noproxy '*' https://ifconfig.me >/dev/null 2>&1; then
      ok "Direct connection still works — proxy may need manual configuration"
    else
      warn "Direct connection also failed — check network or run: journalctl -u ${SERVICE_NAME} -n 30"
    fi
  fi

  section "Verification"
  cmd_test

  echo ""
  ok "Installation complete!"
  echo -e "  Install dir : ${CYAN}${INSTALL_DIR}${NC}"
  echo -e "  Service     : ${CYAN}systemctl status ${SERVICE_NAME}${NC}"
  echo -e "  Logs        : ${CYAN}journalctl -u ${SERVICE_NAME} -f${NC}"
  echo -e "  CLI         : ${CYAN}sudo hcore status${NC}"
  echo -e "  Update sub  : ${CYAN}sudo hcore update${NC}"
  echo -e "  Upgrade bin : ${CYAN}sudo hcore upgrade${NC}"
}

cmd_update() {
  require_root
  [[ -f "$(sub_url_file)" ]] || die "No subscription URL found. Run install first."

  local url
  url=$(cat "$(sub_url_file)")
  info "Subscription URL: $url"

  proxy_direct_on

  section "Re-generating config"
  rm -f "$(config_file)" 2>/dev/null || true
  generate_config "$url"

  proxy_direct_off
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

  proxy_direct_on
  latest=$(get_latest_version)

  if [[ "$current" == "$latest" ]]; then
    ok "Already on latest version: $current"
    proxy_direct_off
    return 0
  fi

  info "Upgrading: $current → $latest"

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
  proxy_direct_off
  sleep 2
  systemctl is-active --quiet "$SERVICE_NAME" && ok "Service restarted" \
    || warn "Service may not be running"

  cmd_test
}

cmd_uninstall() {
  require_root
  proxy_env_unset
  warn "This will remove hiddify-core, its config, service, and iptables rules."
  warn "System will be restored to default settings (no proxy)."
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

  section "Removing proxy environment"
  rm -f /etc/profile.d/hiddify-proxy.sh

  section "Removing iptables rules"
  iptables_del
  iptables_save

  section "Removing files"
  rm -f /usr/local/sbin/hcore
  rm -f "${INSTALL_DIR}/hcore-iptables.sh"
  rm -f "${INSTALL_DIR}/hcore"
  rm -f "${INSTALL_DIR}/subscription.url"
  rm -f "${INSTALL_DIR}/subscription.fallback"
  rm -f "$(fixed_config).bak"
  rm -rf "$INSTALL_DIR"
  rm -f "$(lock_file)"

  section "Removing user"
  userdel "$HIDDIFY_USER" 2>/dev/null || true

  section "Verification"
  local issues=0
  [[ -f /etc/profile.d/hiddify-proxy.sh ]] && { warn "Profile.d file still exists"; issues=1; }
  [[ -d "$INSTALL_DIR" ]] && { warn "Install directory still exists"; issues=1; }
  id "$HIDDIFY_USER" &>/dev/null && { warn "User $HIDDIFY_USER still exists"; issues=1; }
  iptables -t nat -L HIDDIFY &>/dev/null 2>&1 && { warn "iptables HIDDIFY chain still exists"; issues=1; }

  if [[ $issues -eq 0 ]]; then
    ok "Uninstall complete — system restored to default (no proxy)"
  else
    warn "Uninstall finished with warnings — check above"
  fi
}

cmd_status() {
  require_root
  section "Summary"

  local service_state ipt_state config_state profile_state cli_state
  service_state=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo inactive)
  ipt_state=$(systemctl is-active "${SERVICE_NAME}-iptables" 2>/dev/null || echo inactive)
  [[ -s "$(fixed_config)" ]] && config_state=present || config_state=missing
  [[ -f /etc/profile.d/hiddify-proxy.sh ]] && profile_state=present || profile_state=missing
  [[ -x /usr/local/sbin/hcore ]] && cli_state=present || cli_state=missing

  echo "service=$service_state iptables=$ipt_state fixed_config=$config_state profile=$profile_state cli=$cli_state"

  if [[ "$service_state" != "active" ]]; then
    warn "Service is not active"
  fi
  if [[ "$ipt_state" != "active" ]]; then
    warn "iptables helper service is not active"
  fi
  if [[ "$config_state" != "present" ]]; then
    warn "Patched config is missing or empty: $(fixed_config)"
  fi

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

  section "Subscription"
  if [[ -f "$(sub_url_file)" ]]; then
    local sub_url sub_display
    sub_url=$(cat "$(sub_url_file)")
    # Mask the secret part of URL for security
    sub_display=$(echo "$sub_url" | sed -E 's|(/[^/]{4})[^/]*(/\?|$)|\1****\2|; s|(\?secret=)[^&]*|\1****|')
    echo -e "  URL: ${CYAN}${sub_display}${NC}"
    # Check if config is fresh (modified within last 24h)
    if [[ -f "$(config_file)" ]]; then
      local config_age
      config_age=$(( ($(date +%s) - $(stat -c %Y "$(config_file)" 2>/dev/null || echo 0)) / 3600 ))
      if [[ "$config_age" -lt 24 ]]; then
        echo -e "  Config age: ${GREEN}${config_age}h${NC} (fresh)"
      elif [[ "$config_age" -lt 168 ]]; then
        echo -e "  Config age: ${YELLOW}${config_age}h${NC} (may need update)"
      else
        echo -e "  Config age: ${RED}${config_age}h${NC} (stale — run 'hcore update')"
      fi
    fi
  else
    echo -e "  ${YELLOW}No subscription configured${NC}"
  fi
  local fb_count
  fb_count=$(fallback_list | grep -c . || echo 0)
  if [[ "$fb_count" -gt 0 ]]; then
    echo -e "  Fallback URLs: ${CYAN}${fb_count}${NC}"
  fi

  section "External IP"
  curl -s --max-time 5 --noproxy '*' -4 https://ifconfig.me 2>/dev/null \
    && echo " (IPv4)" || echo "IPv4: timeout"

  section "Connection check"

  if ss -ltn 2>/dev/null | grep -q ":$PORT_REDIR "; then
    echo -e "  ${GREEN}✓${NC}  Redirect port $PORT_REDIR accepting connections"
  else
    echo -e "  ${RED}✗${NC}  Redirect port $PORT_REDIR not listening"
  fi

  local proxy_ip direct_ip
  proxy_ip=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null || echo "FAIL")
  direct_ip=$(curl -s --max-time 5 --noproxy '*' https://ifconfig.me 2>/dev/null || echo "FAIL")

  if [[ "$proxy_ip" == "FAIL" ]]; then
    echo -e "  ${RED}✗${NC}  Proxy connection: ${RED}FAILED${NC}"
  elif [[ "$proxy_ip" == "$direct_ip" ]]; then
    echo -e "  ${YELLOW}?${NC}  Proxy IP same as direct ($proxy_ip) — proxy may not be working"
  else
    echo -e "  ${GREEN}✓${NC}  Proxy IP: $proxy_ip (direct: $direct_ip)"
  fi

  if [[ -f "$(log_file)" ]]; then
    local recent_errors
    recent_errors=$(tail -20 "$(log_file)" 2>/dev/null | grep -ci "error\|fail\|panic" || true)
    if [[ "$recent_errors" -gt 0 ]]; then
      echo -e "  ${YELLOW}?${NC}  Recent errors in log: $recent_errors"
      tail -5 "$(log_file)" 2>/dev/null | sed 's/^/    /'
    else
      echo -e "  ${GREEN}✓${NC}  No recent errors in log"
    fi
  else
    echo -e "  ${YELLOW}?${NC}  Log file not found"
  fi
}

cmd_test() {
  section "Proxy test"

  local via_env direct_ipv4 as_nobody server_ip leak=0
  via_env=$(curl -s --max-time 8 https://ifconfig.me 2>/dev/null || echo "FAIL")
  direct_ipv4=$(curl -s --max-time 8 --noproxy '*' -4 https://ifconfig.me 2>/dev/null || echo "FAIL")
  as_nobody=$(sudo -u nobody curl -s --max-time 8 https://ifconfig.me 2>/dev/null || echo "FAIL")
  server_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{print $7}' | head -1)

  result_line() {
    local label="$1" val="$2"
    if [[ "$val" == "FAIL" ]]; then
      echo -e "  ${YELLOW}?${NC}  $label : ${YELLOW}FAIL${NC}"
      leak=1
    elif [[ -n "$server_ip" && "$val" == "$server_ip" ]]; then
      echo -e "  ${RED}✗${NC}  $label : ${RED}$val${NC} (direct, NOT proxied)"
      leak=1
    else
      echo -e "  ${GREEN}✓${NC}  $label : ${GREEN}$val${NC} (proxied)"
    fi
  }

  echo ""
  result_line "Via http_proxy env " "$via_env"
  result_line "Direct IPv4 (iptables)" "$direct_ipv4"
  result_line "As nobody (no env)  " "$as_nobody"
  echo ""

  section "Sanity checks"
  systemctl is-active --quiet "$SERVICE_NAME" \
    && echo -e "  ${GREEN}✓${NC}  Service active" \
    || { echo -e "  ${RED}✗${NC}  Service inactive"; leak=1; }

  systemctl is-active --quiet "${SERVICE_NAME}-iptables" \
    && echo -e "  ${GREEN}✓${NC}  iptables service active" \
    || { echo -e "  ${RED}✗${NC}  iptables service inactive"; leak=1; }

  ss -ltn 2>/dev/null | grep -q ":$PORT_REDIR " \
    && echo -e "  ${GREEN}✓${NC}  Redirect port $PORT_REDIR listening" \
    || { echo -e "  ${RED}✗${NC}  Redirect port $PORT_REDIR not listening"; leak=1; }

  iptables -t nat -S OUTPUT 2>/dev/null | grep -q -- "-A OUTPUT -p tcp -j HIDDIFY" \
    && echo -e "  ${GREEN}✓${NC}  OUTPUT jumps to HIDDIFY" \
    || { echo -e "  ${RED}✗${NC}  Missing OUTPUT -> HIDDIFY rule"; leak=1; }

  if [[ $leak -eq 0 ]]; then
    ok "All traffic is going through proxy"
  else
    warn "Proxy sanity checks found problems"
    return 1
  fi
}

# ─── entrypoint ───────────────────────────────────────────────────────────────
usage() {
  cat <<EOF

${BOLD}hiddify-core transparent proxy installer${NC}

Usage: sudo $0 <command> [options]

After install, operational commands are also available via: sudo hcore <command>

Commands:
  install --subscription-url <URL> [--install-dir <DIR>]
                    Full install: download binary, generate config,
                    setup iptables, systemd service
  subscription <URL>             Replace subscription (with backup/rollback)
  subscription --show            Show current subscription status
  subscription --test            Test subscription URL accessibility
  subscription --list            List primary + fallback subscriptions
  subscription --add-fallback <URL>     Add a fallback subscription
  subscription --remove-fallback <idx>  Remove fallback by index
  direct-on         Stop proxy, remove iptables, direct access
  direct-off        Start proxy, restore iptables rules
  health            Run health checks on proxy components
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
  sudo hcore subscription "https://new-sub-url/..."
  sudo hcore subscription --show
  sudo hcore subscription --test
  sudo hcore subscription --add-fallback "https://backup-sub/..."
  sudo hcore direct-on
  sudo hcore direct-off
  sudo hcore health
  sudo hcore update
  sudo hcore upgrade
  sudo hcore status
  sudo hcore test
  sudo hcore uninstall

EOF
}

main() {
  local cmd="${1:-}"
  shift || true

  [[ -n "$cmd" && "$cmd" != "--help" && "$cmd" != "-h" ]] && acquire_lock "$cmd"

  case "$cmd" in
    install)      cmd_install "$@" ;;
    subscription) cmd_subscription "$@" ;;
    direct-on)    cmd_direct_on ;;
    direct-off)   cmd_direct_off ;;
    health)       cmd_health ;;
    update)       cmd_update ;;
    upgrade)      cmd_upgrade ;;
    uninstall)    cmd_uninstall ;;
    status)       cmd_status ;;
    test)         cmd_test ;;
    ""|--help|-h) usage; exit 0 ;;
    *) die "Unknown command: $cmd. Run '$0 --help' for usage." ;;
  esac
}

main "$@"
