#!/usr/bin/env bash
# Generate per-user disk usage metrics for node-exporter textfile collector.
# Outputs Prometheus metrics showing how much disk each user's home directory consumes.
# Intended to be run via cron (e.g., every 15 minutes).

set -e

TEXTFILE_DIR="/var/lib/guilty-spark/textfile"
OUTPUT_FILE="${TEXTFILE_DIR}/user_disk.prom"
TMPFILE="${OUTPUT_FILE}.tmp"

mkdir -p "$TEXTFILE_DIR"

{
  echo "# HELP guilty_spark_user_disk_bytes Disk usage in bytes per user home directory"
  echo "# TYPE guilty_spark_user_disk_bytes gauge"

  if [[ -d /home ]]; then
    for dir in /home/*/; do
      [[ -d "$dir" ]] || continue
      user=$(basename "$dir")
      size_kb=$(du -s "$dir" 2>/dev/null | awk '{print $1}')
      [[ -n "$size_kb" ]] && echo "guilty_spark_user_disk_bytes{username=\"${user}\"} $((size_kb * 1024))"
    done
  fi

  if [[ -d /root ]]; then
    size_kb=$(du -s /root 2>/dev/null | awk '{print $1}')
    [[ -n "$size_kb" ]] && echo "guilty_spark_user_disk_bytes{username=\"root\"} $((size_kb * 1024))"
  fi
} > "$TMPFILE"

mv "$TMPFILE" "$OUTPUT_FILE"
