#!/usr/bin/env bash
# Remove a remote agent from Prometheus target files.
#
# Usage: ./scripts/remove-agent.sh <name>
# Example: ./scripts/remove-agent.sh gpu01

set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 <name>"
    echo "  name  — the agent name to remove (e.g. gpu01)"
    exit 1
fi

NAME="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! command -v python3 &>/dev/null; then
    echo "Error: python3 is required. Install it with:"
    echo "  apt-get install -y python3    # Debian/Ubuntu"
    echo "  dnf install -y python3        # RHEL/AlmaLinux"
    exit 1
fi

for file in "$REPO_ROOT/config/prometheus/targets/gpu.json" \
            "$REPO_ROOT/config/prometheus/targets/node.json"; do
    python3 -c "
import json

with open('${file}') as f:
    targets = json.load(f)

before = len(targets)
targets = [t for t in targets if t.get('labels', {}).get('agent_name') != '${NAME}']
after = len(targets)

with open('${file}', 'w') as f:
    json.dump(targets, f, indent=2)

removed = before - after
basename = '${file}'.rsplit('/', 1)[-1]
if removed:
    print(f'Removed {removed} target(s) from {basename}')
else:
    print(f'No targets for \"${NAME}\" in {basename}')
"
done

echo ""
echo "Agent '${NAME}' removed. Prometheus will update within 30 seconds."
