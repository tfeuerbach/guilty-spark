#!/usr/bin/env bash
# Set up either the central monitoring server or a remote agent.
# Usage: sudo ./scripts/setup.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib/distro.sh"

# Parse image defaults from compose files so versions aren't duplicated here
parse_image_default() {
    local var_name="$1"
    grep -oP "${var_name}:-\K[^}]+" "$REPO_ROOT/docker-compose.yml" 2>/dev/null \
        || grep -oP "${var_name}:-\K[^}]+" "$REPO_ROOT/docker-compose.agent.yml" 2>/dev/null
}

IMG_NODE_EXPORTER=$(parse_image_default NODE_EXPORTER_IMAGE)
IMG_PROMETHEUS=$(parse_image_default PROMETHEUS_IMAGE)
IMG_LOKI=$(parse_image_default LOKI_IMAGE)
IMG_ALLOY=$(parse_image_default ALLOY_IMAGE)
IMG_PROCESS_EXPORTER=$(parse_image_default PROCESS_EXPORTER_IMAGE)
IMG_CADVISOR=$(parse_image_default CADVISOR_IMAGE)
IMG_GRAFANA=$(parse_image_default GRAFANA_IMAGE)
IMG_DCGM=$(parse_image_default DCGM_IMAGE)

# "prom/node-exporter:v1.11.1" -> "node-exporter:v1.11.1"
img_short() { echo "${1##*/}"; }

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_header() {
    echo ""
    echo -e "${CYAN}${BOLD}══════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}  Guilty Spark Setup${NC}"
    echo -e "${CYAN}${BOLD}══════════════════════════════════════════${NC}"
    echo ""
}

print_step() {
    echo -e "${GREEN}==> $1${NC}"
}

print_warn() {
    echo -e "${YELLOW}    $1${NC}"
}

install_nvidia_toolkit() {
    echo ""
    echo "  Installing nvidia-container-toolkit..."
    echo ""
    case "$DISTRO_FAMILY" in
        debian)
            curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
                | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null
            curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
                | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
                > /etc/apt/sources.list.d/nvidia-container-toolkit.list
            apt-get update -qq
            apt-get install -y nvidia-container-toolkit
            ;;
        rhel)
            curl -fsSL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
                > /etc/yum.repos.d/nvidia-container-toolkit.repo
            $PKG_INSTALL nvidia-container-toolkit
            ;;
    esac

    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
    echo ""
    echo -e "  ${GREEN}nvidia-container-toolkit installed and Docker runtime configured.${NC}"
}

check_nvidia_toolkit() {
    if command -v nvidia-ctk &>/dev/null; then
        echo -e "    Container toolkit: ${GREEN}installed${NC}"
        return 0
    fi

    echo ""
    print_warn "nvidia-container-toolkit is not installed."
    echo ""
    echo "  Docker needs the NVIDIA Container Toolkit to access GPUs."
    echo "  Without it, DCGM Exporter won't start and GPU metrics won't be collected."
    echo ""

    while true; do
        read -rp "  Install nvidia-container-toolkit now? [Y/n]: " toolkit_choice
        case "$toolkit_choice" in
            [Nn]*)
                echo ""
                print_warn "Skipping toolkit install. GPU monitoring may not work."
                echo "  You can install it later: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html"
                echo ""
                return 0
                ;;
            [Yy]*|"")
                install_nvidia_toolkit
                return 0
                ;;
            *) echo "  Please enter y or n." ;;
        esac
    done
}

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Must run as root: sudo ./scripts/setup.sh${NC}"
    exit 1
fi

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
    # nvidia-smi may not be in sudo's secure_path
    for _p in /usr/lib/wsl/lib /usr/local/cuda/bin /usr/local/bin /usr/bin; do
        [[ -x "$_p/nvidia-smi" ]] && PATH="$_p:$PATH" && break
    done
    if nvidia-smi &>/dev/null; then
        HAS_GPU=1
        echo -e "    NVIDIA GPU: ${GREEN}detected${NC}"
        check_nvidia_toolkit
    else
        echo ""
        print_warn "nvidia-smi not found - no NVIDIA GPU detected."
        echo ""
        echo "  If this machine has GPUs, install drivers first and re-run setup."
        echo "  If this machine has no GPUs, GPU monitoring (DCGM) will be skipped."
        echo ""

        while true; do
            read -rp "  Continue without GPU monitoring? [y/N]: " gpu_choice
            case "$gpu_choice" in
                [Yy]*) break ;;
                [Nn]*|"") echo ""; echo "Exiting. Install GPU drivers and re-run."; exit 1 ;;
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

IS_EC2=false
if curl -sf -m 2 http://169.254.169.254/latest/meta-data/ > /dev/null 2>&1; then
    IS_EC2=true
    print_step "EC2 instance detected"
    echo ""
fi

SYSTEM_HOSTNAME=$(hostname -s 2>/dev/null || hostname)
SYSTEM_IP=$(ip -4 route get 1 2>/dev/null | awk '{print $7; exit}' || hostname -I 2>/dev/null | awk '{print $1}' || echo 'unknown')

echo -e "${BOLD}What role should this server have?${NC}"
echo ""
echo "  1) Central  - Full monitoring stack (Grafana, Prometheus, Loki + exporters)"
echo "               Run this on ONE server. All dashboards live here."
echo ""
echo "  2) Agent    - Exporters + log shipping only"
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

print_step "Server identity"
echo ""
echo "  Hostname: ${SYSTEM_HOSTNAME}"
echo "  IP:       ${SYSTEM_IP}"
echo ""

read -rp "  Name for this server in dashboards [${SYSTEM_HOSTNAME}]: " INSTANCE_NAME
INSTANCE_NAME="${INSTANCE_NAME:-$SYSTEM_HOSTNAME}"
echo ""

echo -e "${BOLD}Container image source:${NC}"
echo ""
echo "  1) Default   - upstream images from Docker Hub / GCR"
echo "  2) Iron Bank - DoD-hardened images from registry1.dso.mil (requires login)"
echo "  3) Custom    - internal registry mirror (GitLab, Harbor, Nexus, etc.)"
echo ""

IMAGE_VARS=""
while true; do
    read -rp "Select [1/2/3]: " image_choice
    case "$image_choice" in
        1) break ;;
        2)
            if ! docker pull --quiet "registry1.dso.mil/ironbank/opensource/prometheus/$(img_short "$IMG_NODE_EXPORTER")" > /dev/null 2>&1; then
                echo ""
                print_warn "Cannot pull from registry1.dso.mil. You need to log in first."
                echo "  Get your CLI secret from https://registry1.dso.mil (Profile > CLI secret)"
                echo ""
                read -rp "  Registry1 username: " r1_user
                read -rsp "  Registry1 CLI secret: " r1_pass
                echo ""
                if ! docker login -u "$r1_user" -p "$r1_pass" registry1.dso.mil 2>/dev/null; then
                    echo -e "${RED}  Login failed. Check credentials and try setup again.${NC}"
                    exit 1
                fi
                echo -e "  ${GREEN}Logged in to registry1.dso.mil${NC}"
            fi
            IMAGE_VARS="NODE_EXPORTER_IMAGE=registry1.dso.mil/ironbank/opensource/prometheus/$(img_short "$IMG_NODE_EXPORTER")
PROMETHEUS_IMAGE=registry1.dso.mil/ironbank/opensource/prometheus/$(img_short "$IMG_PROMETHEUS")
LOKI_IMAGE=registry1.dso.mil/ironbank/opensource/grafana/$(img_short "$IMG_LOKI")
ALLOY_IMAGE=registry1.dso.mil/ironbank/opensource/grafana/$(img_short "$IMG_ALLOY")
GRAFANA_IMAGE=registry1.dso.mil/ironbank/opensource/grafana/$(img_short "$IMG_GRAFANA")"
            echo ""
            echo -e "  ${GREEN}Using Iron Bank images${NC}"
            break
            ;;
        3)
            echo ""
            echo "  Enter your registry base URL. Images will be pulled as:"
            echo "    <base-url>/$(img_short "$IMG_NODE_EXPORTER")"
            echo "    <base-url>/$(img_short "$IMG_GRAFANA")"
            echo "    etc."
            echo ""
            read -rp "  Registry base URL (e.g. registry-gitlab/github.internal.com:5000/mirrors): " custom_registry
            while [[ -z "$custom_registry" ]]; do
                echo "  URL cannot be empty."
                read -rp "  Registry base URL: " custom_registry
            done
            custom_registry="${custom_registry%/}"

            IMAGE_VARS="NODE_EXPORTER_IMAGE=${custom_registry}/$(img_short "$IMG_NODE_EXPORTER")
PROMETHEUS_IMAGE=${custom_registry}/$(img_short "$IMG_PROMETHEUS")
LOKI_IMAGE=${custom_registry}/$(img_short "$IMG_LOKI")
ALLOY_IMAGE=${custom_registry}/$(img_short "$IMG_ALLOY")
PROCESS_EXPORTER_IMAGE=${custom_registry}/$(img_short "$IMG_PROCESS_EXPORTER")
CADVISOR_IMAGE=${custom_registry}/$(img_short "$IMG_CADVISOR")
GRAFANA_IMAGE=${custom_registry}/$(img_short "$IMG_GRAFANA")
DCGM_IMAGE=${custom_registry}/$(img_short "$IMG_DCGM")"

            echo ""
            echo "  If this registry requires authentication, run:"
            echo "    docker login ${custom_registry%%/*}"
            echo ""
            echo "  Images that must be mirrored into your registry:"
            echo "    ${IMG_NODE_EXPORTER}"
            echo "    ${IMG_PROMETHEUS}"
            echo "    ${IMG_LOKI}"
            echo "    ${IMG_ALLOY}"
            echo "    ${IMG_PROCESS_EXPORTER}"
            echo "    ${IMG_CADVISOR}"
            echo "    ${IMG_GRAFANA}"
            echo "    ${IMG_DCGM}"
            echo ""
            echo -e "  ${GREEN}Using custom registry: ${custom_registry}${NC}"
            break
            ;;
        *) echo "Please enter 1, 2, or 3." ;;
    esac
done
echo ""

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
        if [[ -n "$IMAGE_VARS" ]]; then echo ""; echo "$IMAGE_VARS"; fi
    } > "$REPO_ROOT/.env"
    echo "    CENTRAL_IP=${CENTRAL_IP}"
    echo "    INSTANCE_NAME=${INSTANCE_NAME}"
    if [[ "$HAS_GPU" -eq 1 ]]; then echo "    COMPOSE_PROFILES=gpu"; fi
    if [[ "$HAS_GPU" -eq 0 ]]; then echo "    GPU monitoring: disabled (no nvidia-smi)"; fi
    if [[ -n "$IMAGE_VARS" ]]; then echo "    Image overrides written to .env"; fi
    echo ""
else
    print_step "Writing .env"
    {
        echo "INSTANCE_NAME=${INSTANCE_NAME}"
        if [[ "$HAS_GPU" -eq 1 ]]; then echo "COMPOSE_PROFILES=gpu"; fi
        if [[ -n "$IMAGE_VARS" ]]; then echo ""; echo "$IMAGE_VARS"; fi
    } > "$REPO_ROOT/.env"
    echo "    INSTANCE_NAME=${INSTANCE_NAME}"
    if [[ "$HAS_GPU" -eq 1 ]]; then echo "    COMPOSE_PROFILES=gpu"; fi
    if [[ "$HAS_GPU" -eq 0 ]]; then echo "    GPU monitoring: disabled (no nvidia-smi)"; fi
    if [[ -n "$IMAGE_VARS" ]]; then echo "    Image overrides written to .env"; fi
    echo ""
fi

echo "DoD STIG audit rules add verbose logging for file access, privilege"
echo "escalation, time changes, and identity modifications. Recommended for"
echo "compliance environments; increases audit log volume. See README for details."
read -rp "Include DoD STIG audit rules? [y/N]: " stig_choice
STIG_FLAG=""
[[ "$stig_choice" =~ ^[Yy] ]] && STIG_FLAG="--stig"
echo ""

print_step "Configuring auditd (command tracking)..."
"$SCRIPT_DIR/setup-audit.sh" $STIG_FLAG
echo ""

print_step "Installing shell command logger..."

if ! command -v rsyslogd &>/dev/null; then
    print_warn "rsyslog not found - installing..."
    $PKG_INSTALL rsyslog
    systemctl enable rsyslog 2>/dev/null || true
    systemctl start rsyslog 2>/dev/null || true
    echo "    Installed rsyslog"
fi

install -m 644 "$REPO_ROOT/config/rsyslog/guilty-spark-shell.conf" /etc/rsyslog.d/00-guilty-spark.conf
rm -f /etc/rsyslog.d/guilty-spark-shell.conf 2>/dev/null
systemctl restart rsyslog 2>/dev/null || service rsyslog restart 2>/dev/null || true
echo "    Installed /etc/rsyslog.d/00-guilty-spark.conf"

install -m 644 "$REPO_ROOT/config/shell/guilty-spark-logger.sh" /etc/profile.d/guilty-spark-logger.sh
echo "    Installed /etc/profile.d/guilty-spark-logger.sh"

for rcfile in /etc/bash.bashrc /etc/zsh/zshrc /etc/zshrc; do
    if [[ -f "$rcfile" ]] && ! grep -q 'guilty-spark-logger' "$rcfile" 2>/dev/null; then
        echo "" >> "$rcfile"
        echo "# guilty-spark shell command logging" >> "$rcfile"
        echo '[ -f /etc/profile.d/guilty-spark-logger.sh ] && . /etc/profile.d/guilty-spark-logger.sh' >> "$rcfile"
    fi
done
echo "    Hooked into bash.bashrc / zshrc for non-login shells"
echo ""

print_step "Generating user metrics and alloy config..."
"$SCRIPT_DIR/generate-user-metrics.sh"

user_count=$(grep -c 'guilty_spark_user' /var/lib/guilty-spark/textfile/users.prom 2>/dev/null || echo 0)
echo "    Found ${user_count} system users"
echo "    Alloy config generated with UID->username map"
echo ""

print_step "Installing user change watcher..."

if ! command -v inotifywait &>/dev/null; then
    apt-get install -y inotify-tools -qq 2>/dev/null \
        || yum install -y inotify-tools -q 2>/dev/null \
        || echo "    WARNING: inotify-tools not available - falling back to cron only"
fi

install -m 755 "$SCRIPT_DIR/userwatch" /usr/local/bin/guilty-spark-userwatch
cp "$REPO_ROOT/config/systemd/guilty-spark-userwatch.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now guilty-spark-userwatch 2>/dev/null || true
echo "    Enabled guilty-spark-userwatch.service (real-time user detection)"

# cron fallback in case inotify misses NSS changes
cat > /etc/cron.d/guilty-spark << CRONEOF
# User metrics (backup for inotify)
*/5 * * * * root ${REPO_ROOT}/scripts/generate-user-metrics.sh
# Per-user disk usage
*/15 * * * * root ${REPO_ROOT}/scripts/generate-disk-metrics.sh
# Listening services inventory
*/5 * * * * root ${REPO_ROOT}/scripts/generate-service-metrics.sh
CRONEOF
chmod 644 /etc/cron.d/guilty-spark
echo "    Installed /etc/cron.d/guilty-spark (user metrics + disk + services)"
echo ""

if [[ "$IS_EC2" == true ]]; then
    print_step "Configuring EC2 cost integration..."
    mkdir -p /opt/guilty-spark
    install -m 755 "$SCRIPT_DIR/ec2-metadata.sh" /opt/guilty-spark/ec2-metadata.sh
    /opt/guilty-spark/ec2-metadata.sh || true
    echo "    Installed EC2 metadata exporter"

    cat >> /etc/cron.d/guilty-spark <<'CRONEOF'
# EC2 instance metadata
*/5 * * * * root /opt/guilty-spark/ec2-metadata.sh
CRONEOF
    echo "    Added ec2-metadata.sh to cron (*/5 min)"
    echo ""
fi

if [[ "$ROLE" == "central" ]]; then
    print_step "Setting up EC2 pricing data..."
    mkdir -p /opt/guilty-spark/ec2-pricing

    if [[ -d "$REPO_ROOT/config/ec2-pricing" ]] && ls "$REPO_ROOT/config/ec2-pricing/"*.json &>/dev/null; then
        cp "$REPO_ROOT/config/ec2-pricing/"*.json /opt/guilty-spark/ec2-pricing/
        local_count=$(ls /opt/guilty-spark/ec2-pricing/*.json 2>/dev/null | wc -l)
        echo "    Copied ${local_count} bundled region pricing files"
    fi

    install -m 755 "$SCRIPT_DIR/fetch-ec2-pricing.sh" /opt/guilty-spark/fetch-ec2-pricing.sh
    if curl -sf -m 5 "https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/index.json" > /dev/null 2>&1; then
        echo "    AWS pricing API reachable - will fetch fresh data weekly"
    else
        echo -e "    ${YELLOW}AWS pricing API not reachable - using bundled pricing data${NC}"
        echo "    To update: run ./scripts/fetch-ec2-pricing.sh on a machine with internet"
    fi

    install -m 755 "$SCRIPT_DIR/generate-ec2-cost-metrics.sh" /opt/guilty-spark/generate-ec2-cost-metrics.sh

    cat >> /etc/cron.d/guilty-spark <<'CRONEOF'
# EC2 cost calculation
*/5 * * * * root /opt/guilty-spark/generate-ec2-cost-metrics.sh
# Refresh EC2 pricing from AWS (weekly)
0 3 * * 0 root /opt/guilty-spark/fetch-ec2-pricing.sh --all 2>/dev/null || true
CRONEOF
    echo "    Added EC2 cost crons (metrics */5m, pricing weekly)"
    echo ""
fi

if [[ "$ROLE" == "central" ]]; then
    print_step "Configuring Prometheus targets..."
    TARGETS_DIR="$REPO_ROOT/config/prometheus/targets"
    mkdir -p "$TARGETS_DIR"
    python3 -c "
import json, os

targets_dir = '${TARGETS_DIR}'
name = '${INSTANCE_NAME}'
ip = '${SYSTEM_IP}'
has_gpu = ${HAS_GPU}

entries = [('node.json', '9100', 'node-exporter'), ('cadvisor.json', '8080', 'cadvisor'), ('process.json', '9256', 'process-exporter')]
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
    # remove stale local entries before re-adding
    existing = [t for t in existing if not any(container in addr or 'localhost' in addr for addr in t.get('targets', []))]
    local_entry = {
        'targets': [f'{container}:{port}'],
        'labels': {'agent_name': name, 'agent_ip': ip}
    }
    targets = [local_entry] + existing
    with open(path, 'w') as f:
        json.dump(targets, f, indent=2)
    print(f'    {fname}: {name} ({ip}) + {len(existing)} agent(s)')

# remote agents may still have GPUs, so create an empty file
gpu_path = os.path.join(targets_dir, 'gpu.json')
if not os.path.exists(gpu_path):
    with open(gpu_path, 'w') as f:
        json.dump([], f)
    print(f'    gpu.json: created (empty, no local GPU)')
"
    echo ""
fi

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
