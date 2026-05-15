#!/usr/bin/env bash
# Generate listening service/port metrics for node-exporter textfile collector.
# Enumerates all listening TCP ports, the owning process, and exports as Prometheus metrics.
# Intended to be run via cron (e.g., every 5 minutes).

set -e

TEXTFILE_DIR="/var/lib/guilty-spark/textfile"
OUTPUT_FILE="${TEXTFILE_DIR}/services.prom"
TMPFILE="${OUTPUT_FILE}.tmp"

mkdir -p "$TEXTFILE_DIR"

{
  echo "# HELP guilty_spark_listening_port TCP port currently in LISTEN state"
  echo "# TYPE guilty_spark_listening_port gauge"

  ss -tlnp 2>/dev/null | tail -n +2 | while IFS= read -r line; do
    local_addr=$(echo "$line" | awk '{print $4}')
    port=$(echo "$local_addr" | rev | cut -d: -f1 | rev)
    process=$(echo "$line" | grep -oP 'users:\(\("\K[^"]+' 2>/dev/null || echo "unknown")

    [[ -z "$port" ]] && continue
    echo "guilty_spark_listening_port{port=\"${port}\", process=\"${process}\"} 1"
  done | sort -u
} > "$TMPFILE"

mv "$TMPFILE" "$OUTPUT_FILE"
