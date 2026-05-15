#!/usr/bin/env bash
# Generates:
#   1. Prometheus textfile metric mapping UIDs to usernames
#      (Node Exporter picks this up via --collector.textfile.directory)
#   2. Promtail config with UID→username template map baked in
#      (sends SIGHUP to reload without restart if config changed)
#
# Intended to run via cron (installed by setup.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

PROM_DIR="/var/lib/guilty-spark/textfile"
PROM_FILE="$PROM_DIR/users.prom"

mkdir -p "$PROM_DIR"

# ── 1. Prometheus textfile ────────────────────────────────────────────────

{
    echo "# HELP guilty_spark_user System user UID to username mapping"
    echo "# TYPE guilty_spark_user gauge"
    while IFS=: read -r username _ uid _ _ _ _; do
        if [ "$uid" -ge 1000 ] 2>/dev/null && [ "$uid" -lt 65534 ]; then
            echo "guilty_spark_user{uid=\"$uid\",username=\"$username\"} 1"
        fi
    done < <(getent passwd)
} > "$PROM_FILE.tmp"

mv "$PROM_FILE.tmp" "$PROM_FILE"

# ── 2. Promtail config generation ────────────────────────────────────────

# Build Go template string for UID→username resolution.
# Output: {{ if eq .auid "1000" }}tfeuerbach{{ else if eq ... }}...{{ else }}{{ .auid }}{{ end }}
build_user_map() {
    local first=true
    local tmpl=""
    # Use getent to support LDAP/SSSD/AD in addition to local /etc/passwd
    while IFS=: read -r username _ uid _ _ _ _; do
        if [ "$uid" -ge 1000 ] 2>/dev/null && [ "$uid" -lt 65534 ]; then
            if [ "$first" = true ]; then
                tmpl="{{ if eq .auid \"$uid\" }}${username}"
                first=false
            else
                tmpl="${tmpl}{{ else if eq .auid \"$uid\" }}${username}"
            fi
        fi
    done < <(getent passwd)

    if [ "$first" = true ]; then
        # No users resolved
        echo ''
    else
        # Unknown UIDs get empty string
        tmpl="${tmpl}{{ end }}"
        echo "$tmpl"
    fi
}

USER_MAP=$(build_user_map)

# Determine which template to use (central has promtail-config.yml.tmpl,
# agent has promtail-agent.yml.tmpl). Generate whichever exists.
generate_config() {
    local tmpl_file="$1"
    local out_file="$2"
    local container_name="$3"

    if [ ! -f "$tmpl_file" ]; then
        return 0
    fi

    # Substitute the placeholder with the generated user map
    local new_config
    new_config=$(sed "s|@@USER_MAP@@|${USER_MAP}|g" "$tmpl_file")

    # Only write + reload if the config actually changed
    if [ -f "$out_file" ] && [ "$(echo "$new_config" | md5sum)" = "$(md5sum < "$out_file")" ]; then
        return 0
    fi

    echo "$new_config" > "$out_file"

    # Signal promtail to reload config (if running)
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container_name}$"; then
        docker kill -s HUP "$container_name" 2>/dev/null || true
    fi
}

PROMTAIL_DIR="$REPO_ROOT/config/promtail"

generate_config \
    "$PROMTAIL_DIR/promtail-config.yml.tmpl" \
    "$PROMTAIL_DIR/promtail-config.yml" \
    "guilty-spark-promtail"

generate_config \
    "$PROMTAIL_DIR/promtail-agent.yml.tmpl" \
    "$PROMTAIL_DIR/promtail-agent.yml" \
    "guilty-spark-promtail"
