#!/usr/bin/env bash
# Export EC2 instance metadata as Prometheus textfile metrics via IMDSv2.
# Runs on EC2 agents via cron. Output: /var/lib/guilty-spark/textfile/ec2.prom

set -euo pipefail

TEXTFILE_DIR="/var/lib/guilty-spark/textfile"
mkdir -p "$TEXTFILE_DIR"

# IMDSv2 token
TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60") || exit 0

imds_get() {
  curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
    "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null || echo ""
}

INSTANCE_TYPE=$(imds_get "instance-type")
INSTANCE_ID=$(imds_get "instance-id")
AZ=$(imds_get "placement/availability-zone")
REGION=$(imds_get "placement/region")
LIFECYCLE=$(imds_get "instance-life-cycle")
LIFECYCLE=${LIFECYCLE:-on-demand}

# Bail if IMDS didn't respond
[[ -z "$INSTANCE_TYPE" ]] && exit 0

cat > "$TEXTFILE_DIR/ec2.prom" <<EOF
# HELP guilty_spark_ec2_info EC2 instance metadata labels
# TYPE guilty_spark_ec2_info gauge
guilty_spark_ec2_info{instance_id="${INSTANCE_ID}",instance_type="${INSTANCE_TYPE}",region="${REGION}",az="${AZ}",lifecycle="${LIFECYCLE}"} 1
EOF
