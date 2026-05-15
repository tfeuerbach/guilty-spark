#!/usr/bin/env bash
# Generate EC2 cost-per-hour metrics from Prometheus instance data + pricing files.
# Runs on central server via cron. Output: /var/lib/guilty-spark/textfile/ec2_costs.prom

set -euo pipefail

PRICING_DIR="/opt/guilty-spark/ec2-pricing"
TEXTFILE_DIR="/var/lib/guilty-spark/textfile"
PROM_URL="${PROMETHEUS_URL:-http://localhost:9090}"

mkdir -p "$TEXTFILE_DIR"

# Get active EC2 instances from Prometheus
RESPONSE=$(curl -sf "$PROM_URL/api/v1/query?query=guilty_spark_ec2_info" 2>/dev/null || echo "")

if [[ -z "$RESPONSE" ]] || ! echo "$RESPONSE" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
  exit 0
fi

# Join instance metadata with pricing data and write .prom file
python3 -c "
import json, sys, os

pricing_dir = '${PRICING_DIR}'
textfile = '${TEXTFILE_DIR}/ec2_costs.prom'

# Parse Prometheus response
try:
    response = json.loads('''$(echo "$RESPONSE")''')
    results = response.get('data', {}).get('result', [])
except (json.JSONDecodeError, KeyError):
    sys.exit(0)

if not results:
    # No EC2 instances, write empty file to clear stale metrics
    with open(textfile, 'w') as f:
        f.write('# HELP guilty_spark_ec2_cost_per_hour On-demand cost per hour in USD\n')
        f.write('# TYPE guilty_spark_ec2_cost_per_hour gauge\n')
    sys.exit(0)

# Load pricing files as needed (cache by region)
pricing_cache = {}

def get_price(region, instance_type):
    if region not in pricing_cache:
        price_file = os.path.join(pricing_dir, f'{region}.json')
        if os.path.exists(price_file):
            with open(price_file) as f:
                pricing_cache[region] = json.load(f)
        else:
            pricing_cache[region] = {}
    return pricing_cache[region].get(instance_type, 0)

# Generate metrics
lines = [
    '# HELP guilty_spark_ec2_cost_per_hour On-demand cost per hour in USD',
    '# TYPE guilty_spark_ec2_cost_per_hour gauge',
]

for result in results:
    metric = result.get('metric', {})
    instance = metric.get('instance', '')
    instance_type = metric.get('instance_type', '')
    region = metric.get('region', '')
    lifecycle = metric.get('lifecycle', 'on-demand')

    if not instance_type or not region:
        continue

    price = get_price(region, instance_type)
    lines.append(
        f'guilty_spark_ec2_cost_per_hour{{instance=\"{instance}\",instance_type=\"{instance_type}\",region=\"{region}\",lifecycle=\"{lifecycle}\"}} {price}'
    )

with open(textfile, 'w') as f:
    f.write('\n'.join(lines) + '\n')
" 2>/dev/null || true
