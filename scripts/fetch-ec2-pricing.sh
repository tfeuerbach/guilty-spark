#!/usr/bin/env bash
# Fetch EC2 on-demand pricing from the AWS public bulk API (no credentials needed).
#
# Usage:
#   ./scripts/fetch-ec2-pricing.sh                     # all regions
#   ./scripts/fetch-ec2-pricing.sh --region us-east-1   # single region
#
# Output: config/ec2-pricing/{region}.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PRICING_DIR="$REPO_ROOT/config/ec2-pricing"
mkdir -p "$PRICING_DIR"

PRICING_BASE_URL="https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/current"

ALL_REGIONS=(
  # US
  us-east-1 us-east-2 us-west-1 us-west-2
  # US GovCloud
  us-gov-east-1 us-gov-west-1
  # Europe
  eu-west-1 eu-west-2 eu-west-3 eu-central-1 eu-central-2
  eu-north-1 eu-south-1 eu-south-2
  # Asia Pacific
  ap-east-1 ap-southeast-1 ap-southeast-2 ap-southeast-3 ap-southeast-4 ap-southeast-5
  ap-northeast-1 ap-northeast-2 ap-northeast-3
  ap-south-1 ap-south-2
  # Canada
  ca-central-1 ca-west-1
  # Middle East & Africa
  me-south-1 me-central-1 af-south-1
  # South America
  sa-east-1
  # Israel
  il-central-1
  # Mexico
  mx-central-1
)

fetch_region() {
  local region="$1"
  local output_file="$PRICING_DIR/${region}.json"
  local csv_url="${PRICING_BASE_URL}/${region}/index.csv"

  echo -n "  Fetching $region... "

  # Download CSV and extract header to find column indices
  local tmpfile
  tmpfile=$(mktemp)

  if ! curl -sf --max-time 120 "$csv_url" -o "$tmpfile" 2>/dev/null; then
    echo "FAILED (network error or timeout)"
    return 1
  fi

  # CSV has metadata rows before the actual header (starts with "SKU")
  local header_line
  header_line=$(grep -n '^"SKU"' "$tmpfile" | head -1 | cut -d: -f1)
  if [[ -z "$header_line" ]]; then
    # Try without quotes
    header_line=$(grep -n '^SKU,' "$tmpfile" | head -1 | cut -d: -f1)
  fi
  if [[ -z "$header_line" ]]; then
    echo "FAILED (could not find header row)"
    rm -f "$tmpfile"
    return 1
  fi

  # Python for CSV parsing (quoted fields, commas in values)
  python3 -c "
import csv, json, sys

header_line = int(sys.argv[1]) - 1  # 0-indexed
region = sys.argv[2]
output = sys.argv[3]

prices = {}

with open(sys.argv[4], 'r', encoding='utf-8', errors='replace') as f:
    # Skip metadata rows
    for _ in range(header_line):
        next(f)

    reader = csv.DictReader(f)

    for row in reader:
        if row.get('Product Family', '') != 'Compute Instance':
            continue
        if row.get('Tenancy', '') != 'Shared':
            continue
        if row.get('Operating System', '') != 'Linux':
            continue
        if row.get('Pre Installed S/W', '') != 'NA':
            continue
        if row.get('CapacityStatus', '') != 'Used':
            continue
        if row.get('License Model', '') == 'Bring your own license':
            continue

        instance_type = row.get('Instance Type', '')
        price_str = row.get('PricePerUnit', '') or row.get('pricePerUnit', '0')

        if not instance_type or not price_str:
            continue

        try:
            price = float(price_str)
        except (ValueError, TypeError):
            continue

        if price <= 0:
            continue

        # Keep the lowest price for each instance type (some duplicates exist)
        if instance_type not in prices or price < prices[instance_type]:
            prices[instance_type] = price

# Sort by instance type for readability
sorted_prices = dict(sorted(prices.items()))

with open(output, 'w') as f:
    json.dump(sorted_prices, f, indent=2)

print(f'{len(sorted_prices)} instance types')
" "$header_line" "$region" "$output_file" "$tmpfile"

  rm -f "$tmpfile"
}

# Parse args
REGIONS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)
      REGIONS+=("$2")
      shift 2
      ;;
    --all)
      REGIONS=("${ALL_REGIONS[@]}")
      shift
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 [--region REGION] [--all]"
      exit 1
      ;;
  esac
done

# Default: all common regions
if [[ ${#REGIONS[@]} -eq 0 ]]; then
  REGIONS=("${ALL_REGIONS[@]}")
fi

echo "Fetching EC2 pricing data..."
echo "  Output: $PRICING_DIR/"
echo ""

SUCCESS=0
FAILED=0

for region in "${REGIONS[@]}"; do
  if fetch_region "$region"; then
    SUCCESS=$((SUCCESS + 1))
  else
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "Done: $SUCCESS regions fetched, $FAILED failed"

if [[ $FAILED -gt 0 && $SUCCESS -eq 0 ]]; then
  echo ""
  echo "ERROR: Could not reach AWS pricing API."
  echo "  If this machine has no internet access, use pre-bundled pricing files."
  echo "  Run this script on a machine with connectivity and copy config/ec2-pricing/ over."
  exit 1
fi
