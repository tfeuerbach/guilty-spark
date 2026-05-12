#!/usr/bin/env bash
# Guilty Spark — Universal Setup
# Run on any server to set up either the central monitoring node or an agent.
# Handles auditd, user metrics, environment config, and starts the stack.
#
# Usage: sudo ./scripts/setup.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib/distro.sh"

# ─── Colors ───
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_header() {
    echo ""
    echo -e "${CYAN}${BOLD}══════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}  Guilty Spark — Setup${NC}"
    echo -e "${CYAN}${BOLD}══════════════════════════════════════════${NC}"
    echo ""
}

print_step() {
    echo -e "${GREEN}==> $1${NC}"
}

print_warn() {
    echo -e "${YELLOW}    $1${NC}"
}

# ─── Root check ───
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Must run as root: sudo ./scripts/setup.sh${NC}"
    exit 1
fi

# ─── Prereq checks ───
check_prereqs() {
    local missing=0
    for cmd in docker curl python3; do
        if ! command -v "$cmd" &>/dev/null; then
            echo -e "${RED}Missing required command: $cmd${NC}"
            missing=1
        fi
    done
    if ! docker compose version &>/dev/null; then
        echo -e "${RED}Docker Compose v2 required (docker compose)${NC}"
        missing=1
    fi
    [[ "$missing" -eq 1 ]] && exit 1

    HAS_GPU=0
    # nvidia-smi may not be in sudo's secure_path (especially WSL2 or custom installs)
    for _p in /usr/lib/wsl/lib /usr/local/cuda/bin /usr/local/bin /usr/bin; do
        [[ -x "$_p/nvidia-smi" ]] && PATH="$_p:$PATH" && break
    done
    if nvidia-smi &>/dev/null; then
        HAS_GPU=1
    else
        echo ""
        print_warn "nvidia-smi not found — no NVIDIA GPU detected."
        echo ""
        echo "  If this machine has GPUs, possible fixes:"
        echo "    • Install NVIDIA drivers:  sudo apt install nvidia-driver-550"
        echo "    • Install container toolkit: nvidia-ctk runtime configure"
        echo "    • Reboot after driver install"
        echo ""
        echo "  If this machine has no GPUs, GPU monitoring (DCGM) will be skipped."
        echo ""

        while true; do
            read -rp "  Continue without GPU monitoring? [y/N]: " gpu_choice
            case "$gpu_choice" in
                [Yy]*) break ;;
                [Nn]*|"") echo ""; echo "Exiting. Fix GPU drivers and re-run."; exit 1 ;;
                *) echo "  Please enter y or n." ;;
            esac
        done
        echo ""
    fi
}

print_header
echo -e "    Detected: ${BOLD}${DISTRO_FAMILY}${NC}"
echo ""
check_prereqs

# ─── Hostname and IP ───
SYSTEM_HOSTNAME=$(hostname -s 2>/dev/null || hostname)
SYSTEM_IP=$(ip -4 route get 1 2>/dev/null | awk '{print $7; exit}' || hostname -I 2>/dev/null | awk '{print $1}' || echo 'unknown')

# ─── Role selection ───
echo -e "${BOLD}What role should this server have?${NC}"
echo ""
echo "  1) Central  — Full monitoring stack (Grafana, Prometheus, Loki + exporters)"
echo "               Run this on ONE server. All dashboards live here."
echo ""
echo "  2) Agent    — Exporters + log shipping only"
echo "               Run this on every OTHER server you want to monitor."
echo ""

while true; do
    read -rp "Select [1/2]: " role_choice
    case "$role_choice" in
        1) ROLE="central"; break ;;
        2) ROLE="agent"; break ;;
        *) echo "Please enter 1 or 2." ;;
    esac
done
echo ""

# ─── Server identity ───
print_step "Server identity"
echo ""
echo "  Hostname: ${SYSTEM_HOSTNAME}"
echo "  IP:       ${SYSTEM_IP}"
echo ""

read -rp "  Name for this server in dashboards [${SYSTEM_HOSTNAME}]: " INSTANCE_NAME
INSTANCE_NAME="${INSTANCE_NAME:-$SYSTEM_HOSTNAME}"
echo ""

# ─── Agent-specific config ───
if [[ "$ROLE" == "agent" ]]; then
    print_step "Agent configuration"
    echo ""

    read -rp "  Central server IP or hostname: " CENTRAL_IP
    while [[ -z "$CENTRAL_IP" ]]; do
        echo "  IP cannot be empty."
        read -rp "  Central server IP or hostname: " CENTRAL_IP
    done

    echo ""
    print_step "Writing .env"
    {
        echo "CENTRAL_IP=${CENTRAL_IP}"
        echo "INSTANCE_NAME=${INSTANCE_NAME}"
        if [[ "$HAS_GPU" -eq 1 ]]; then echo "COMPOSE_PROFILES=gpu"; fi
    } > "$REPO_ROOT/.env"
    echo "    CENTRAL_IP=${CENTRAL_IP}"
    echo "    INSTANCE_NAME=${INSTANCE_NAME}"
    if [[ "$HAS_GPU" -eq 1 ]]; then echo "    COMPOSE_PROFILES=gpu"; fi
    if [[ "$HAS_GPU" -eq 0 ]]; then echo "    GPU monitoring: disabled (no nvidia-smi)"; fi
    echo ""
else
    print_step "Writing .env"
    {
        echo "INSTANCE_NAME=${INSTANCE_NAME}"
        if [[ "$HAS_GPU" -eq 1 ]]; then echo "COMPOSE_PROFILES=gpu"; fi
    } > "$REPO_ROOT/.env"
    echo "    INSTANCE_NAME=${INSTANCE_NAME}"
    if [[ "$HAS_GPU" -eq 1 ]]; then echo "    COMPOSE_PROFILES=gpu"; fi
    if [[ "$HAS_GPU" -eq 0 ]]; then echo "    GPU monitoring: disabled (no nvidia-smi)"; fi
    echo ""
fi

# ─── STIG option ───
read -rp "Include DoD STIG audit rules? [y/N]: " stig_choice
STIG_FLAG=""
[[ "$stig_choice" =~ ^[Yy] ]] && STIG_FLAG="--stig"
echo ""

# ─── Step 1: auditd ───
print_step "Configuring auditd (command tracking)..."
"$SCRIPT_DIR/setup-audit.sh" $STIG_FLAG
echo ""

# ─── Step 2: Shell command logger (bash + zsh) ───
print_step "Installing shell command logger..."

# rsyslog is required for shell-history.log, auth.log, snoopy.log
if ! command -v rsyslogd &>/dev/null; then
    print_warn "rsyslog not found — installing (required for log routing)..."
    $PKG_INSTALL rsyslog
    systemctl enable rsyslog 2>/dev/null || true
    systemctl start rsyslog 2>/dev/null || true
    echo "    Installed rsyslog"
fi

# Install rsyslog config — 00- prefix ensures it loads before defaults
install -m 644 "$REPO_ROOT/config/rsyslog/guilty-spark-shell.conf" /etc/rsyslog.d/00-guilty-spark.conf
# Remove old filename if present
rm -f /etc/rsyslog.d/guilty-spark-shell.conf 2>/dev/null
systemctl restart rsyslog 2>/dev/null || service rsyslog restart 2>/dev/null || true
echo "    Installed /etc/rsyslog.d/00-guilty-spark.conf"

# Install shell hook to /etc/profile.d/ (login shells)
install -m 644 "$REPO_ROOT/config/shell/guilty-spark-logger.sh" /etc/profile.d/guilty-spark-logger.sh
echo "    Installed /etc/profile.d/guilty-spark-logger.sh"

# Also source from bash.bashrc and zshrc for non-login interactive shells
for rcfile in /etc/bash.bashrc /etc/zsh/zshrc /etc/zshrc; do
    if [[ -f "$rcfile" ]] && ! grep -q 'guilty-spark-logger' "$rcfile" 2>/dev/null; then
        echo "" >> "$rcfile"
        echo "# Guilty Spark — shell command logging" >> "$rcfile"
        echo '[ -f /etc/profile.d/guilty-spark-logger.sh ] && . /etc/profile.d/guilty-spark-logger.sh' >> "$rcfile"
    fi
done
echo "    Hooked into bash.bashrc / zshrc for non-login shells"
echo ""

# ─── Step 3: User metrics + promtail config ───
print_step "Generating user metrics and promtail config..."
"$SCRIPT_DIR/generate-user-metrics.sh"

user_count=$(grep -c 'guilty_spark_user' /var/lib/guilty-spark/textfile/users.prom 2>/dev/null || echo 0)
echo "    Found ${user_count} system users"
echo "    Promtail config generated with UID→username map"
echo ""

# ─── Step 4: User change watcher + cron fallback ───
print_step "Installing user change watcher..."

# Install inotify-tools if not present
if ! command -v inotifywait &>/dev/null; then
    apt-get install -y inotify-tools -qq 2>/dev/null \
        || yum install -y inotify-tools -q 2>/dev/null \
        || echo "    WARNING: inotify-tools not available — falling back to cron only"
fi

# Install the watcher script and systemd service
install -m 755 "$SCRIPT_DIR/userwatch" /usr/local/bin/guilty-spark-userwatch
cp "$REPO_ROOT/config/systemd/guilty-spark-userwatch.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now guilty-spark-userwatch 2>/dev/null || true
echo "    Enabled guilty-spark-userwatch.service (real-time user detection)"

# Cron as backup (every 5 minutes) in case inotify misses NSS changes
cat > /etc/cron.d/guilty-spark << CRONEOF
# Guilty Spark — regenerate user metrics (backup for inotify)
*/5 * * * * root ${REPO_ROOT}/scripts/generate-user-metrics.sh
CRONEOF
chmod 644 /etc/cron.d/guilty-spark
echo "    Installed /etc/cron.d/guilty-spark (every 5 min fallback)"
echo ""

# ─── Step 5: Prometheus targets (central only) ───
if [[ "$ROLE" == "central" ]]; then
    print_step "Configuring Prometheus targets..."
    TARGETS_DIR="$REPO_ROOT/config/prometheus/targets"
    mkdir -p "$TARGETS_DIR"

    # Generate local target entries with hostname + IP
    python3 -c "
import json, os

targets_dir = '${TARGETS_DIR}'
name = '${INSTANCE_NAME}'
ip = '${SYSTEM_IP}'
has_gpu = ${HAS_GPU}

entries = [('node.json', '9100', 'node-exporter')]
if has_gpu:
    entries.append(('gpu.json', '9400', 'dcgm-exporter'))

for fname, port, container in entries:
    path = os.path.join(targets_dir, fname)
    existing = []
    if os.path.exists(path):
        with open(path) as f:
            try:
                existing = json.load(f)
            except json.JSONDecodeError:
                existing = []
    # Remove any previous local entry (target contains container name)
    existing = [t for t in existing if not any('exporter:' in addr for addr in t.get('targets', []))]
    local_entry = {
        'targets': [f'{container}:{port}'],
        'labels': {'agent_name': name, 'agent_ip': ip}
    }
    targets = [local_entry] + existing
    with open(path, 'w') as f:
        json.dump(targets, f, indent=2)
    print(f'    {fname}: {name} ({ip}) + {len(existing)} agent(s)')

# Ensure gpu.json exists even without local GPU (remote agents may have GPUs)
gpu_path = os.path.join(targets_dir, 'gpu.json')
if not os.path.exists(gpu_path):
    with open(gpu_path, 'w') as f:
        json.dump([], f)
    print(f'    gpu.json: created (empty — no local GPU)')
"
    echo ""
fi

# ─── Step 6: Start the stack ───
if [[ "$ROLE" == "central" ]]; then
    print_step "Starting central monitoring stack..."
    cd "$REPO_ROOT"
    docker compose up -d

    echo ""
    print_step "Done!"
    echo ""
    echo -e "  ${BOLD}Server:${NC}      ${INSTANCE_NAME} (${SYSTEM_IP})"
    echo -e "  ${BOLD}Grafana:${NC}     http://${SYSTEM_IP}:3000  (admin / admin)"
    echo -e "  ${BOLD}Prometheus:${NC}  http://${SYSTEM_IP}:9090"
    echo ""
    echo -e "  ${BOLD}To monitor additional servers, run this ON THIS MACHINE:${NC}"
    echo "    ./scripts/add-agent.sh <name> <remote-ip>"
    echo "    ./scripts/add-agent.sh <name> <remote-ip> --no-gpu"
    echo ""
    echo "  Then run setup.sh on each remote server (select Agent, enter ${SYSTEM_IP})."
    echo ""
else
    print_step "Starting agent stack..."
    cd "$REPO_ROOT"
    docker compose -f docker-compose.agent.yml up -d

    echo ""
    print_step "Done!"
    echo ""
    echo "  This server is reporting as '${INSTANCE_NAME}' (${SYSTEM_IP}) to ${CENTRAL_IP}."
    echo ""
    echo -e "  ${BOLD}On the central server, run:${NC}"
    if [[ "$HAS_GPU" -eq 1 ]]; then
        echo "    ./scripts/add-agent.sh ${INSTANCE_NAME} ${SYSTEM_IP}"
    else
        echo "    ./scripts/add-agent.sh ${INSTANCE_NAME} ${SYSTEM_IP} --no-gpu"
    fi
    echo ""
fi
