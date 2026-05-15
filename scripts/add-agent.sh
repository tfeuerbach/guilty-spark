#!/usr/bin/env bash
# Register a remote agent on the central monitoring node.
# Adds the agent's IP to Prometheus target files so it gets scraped.
#
# Usage: ./scripts/add-agent.sh <name> <ip> [--no-gpu]
# Example: ./scripts/add-agent.sh gpu01 192.168.1.11
#         ./scripts/add-agent.sh webserver 192.168.1.20 --no-gpu
#
# Prometheus picks up changes automatically (file_sd refresh every 30s).

set -e

NO_GPU=0
ARGS=()
for arg in "$@"; do
    if [[ "$arg" == "--no-gpu" ]]; then
        NO_GPU=1
    else
        ARGS+=("$arg")
    fi
done

if [ ${#ARGS[@]} -lt 2 ]; then
    echo "Usage: $0 <name> <ip> [--no-gpu]"
    echo "  name     - hostname or friendly name (e.g. gpu01)"
    echo "  ip       - IP address of the remote server"
    echo "  --no-gpu - skip GPU (DCGM) target for machines without NVIDIA GPUs"
    echo ""
    echo "Example: $0 gpu01 192.168.1.11"
    echo "         $0 webserver 192.168.1.20 --no-gpu"
    exit 1
fi

NAME="${ARGS[0]}"
IP="${ARGS[1]}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! command -v python3 &>/dev/null; then
    echo "Error: python3 is required. Install it with:"
    echo "  apt-get install -y python3    # Debian/Ubuntu"
    echo "  dnf install -y python3        # RHEL/AlmaLinux"
    exit 1
fi

GPU_TARGETS="$REPO_ROOT/config/prometheus/targets/gpu.json"
NODE_TARGETS="$REPO_ROOT/config/prometheus/targets/node.json"
CADVISOR_TARGETS="$REPO_ROOT/config/prometheus/targets/cadvisor.json"
PROCESS_TARGETS="$REPO_ROOT/config/prometheus/targets/process.json"

add_target() {
    local file="$1" port="$2"
    local target="${IP}:${port}"

    python3 -c "
import json, sys

with open('${file}') as f:
    targets = json.load(f)

for entry in targets:
    if '${target}' in entry.get('targets', []):
        print(f'Already registered: ${target}')
        sys.exit(0)

targets.append({
    'targets': ['${target}'],
    'labels': {'agent_name': '${NAME}', 'agent_ip': '${IP}'}
})

with open('${file}', 'w') as f:
    json.dump(targets, f, indent=2)

print(f'Added ${NAME} (${target})')
"
}

if [[ "$NO_GPU" -eq 0 ]]; then
    add_target "$GPU_TARGETS" 9400
else
    echo "Skipping GPU target (--no-gpu)"
fi
add_target "$NODE_TARGETS" 9100
add_target "$CADVISOR_TARGETS" 8080
add_target "$PROCESS_TARGETS" 9256

echo ""
echo "Agent '${NAME}' registered at ${IP}"
[[ "$NO_GPU" -eq 1 ]] && echo "  (node metrics only, no GPU)"
echo "Prometheus will pick up the new targets within 30 seconds."
echo ""
echo "NOTE: This command must be run on the CENTRAL server (where Prometheus lives)."
echo ""
echo "If '${NAME}' isn't set up yet, run on that remote machine (${IP}):"
echo "  git clone <repo> && cd guilty-spark"
echo "  sudo ./scripts/setup.sh    # select Agent, enter this server's IP"
