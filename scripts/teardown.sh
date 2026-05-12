#!/usr/bin/env bash
# Guilty Spark — Revert all changes (Docker stack + audit config + user metrics)
# Supports Ubuntu/Debian and RHEL/AlmaLinux/Rocky.
# Run as root for full teardown.
#
# Usage: sudo ./scripts/teardown.sh [--packages]
#
# --packages    Also uninstall auditd, laurel

set -e

REMOVE_PACKAGES=0
for arg in "$@"; do
  [[ "$arg" == "--packages" ]] && REMOVE_PACKAGES=1
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib/distro.sh"

echo "==> Guilty Spark — Teardown"
echo "    Detected: ${DISTRO_FAMILY}"
echo ""

# 1. Docker stack (try both compose files)
echo "==> Stopping and removing Docker stack..."
cd "$REPO_ROOT"
if docker compose ps -q 2>/dev/null | grep -q .; then
  docker compose down -v
  echo "    Central stack removed."
elif docker compose -f docker-compose.agent.yml ps -q 2>/dev/null | grep -q .; then
  docker compose -f docker-compose.agent.yml down -v
  echo "    Agent stack removed."
else
  echo "    Stack not running."
fi
echo ""

# 2. Root-only cleanup
if [[ $EUID -ne 0 ]]; then
  echo "==> Run as root to also revert audit config and cron:"
  echo "    sudo $0"
  exit 0
fi

# 3. Cron job
echo "==> Removing cron job..."
if [[ -f /etc/cron.d/guilty-spark ]]; then
  rm -f /etc/cron.d/guilty-spark
  echo "    Removed /etc/cron.d/guilty-spark"
else
  echo "    No cron job found."
fi

# 4. User metrics textfile
echo "==> Removing user metrics..."
if [[ -d /var/lib/guilty-spark ]]; then
  rm -rf /var/lib/guilty-spark
  echo "    Removed /var/lib/guilty-spark"
fi

# 5. Restore auditd.conf from backup
echo "==> Restoring auditd.conf..."
BACKUP=$(ls -t /etc/audit/auditd.conf.bak.* 2>/dev/null | head -1)
if [[ -n "$BACKUP" ]]; then
  cp -a "$BACKUP" /etc/audit/auditd.conf
  echo "    Restored from $BACKUP"
else
  echo "    No backup found; auditd.conf unchanged."
fi

# 6. Remove our rules
echo "==> Removing audit rules..."
for f in /etc/audit/rules.d/30-stig.rules /etc/audit/rules.d/99-guilty-spark.rules; do
  if [[ -f "$f" ]]; then
    rm -f "$f"
    echo "    Removed $f"
  fi
done

# 7. Laurel: restore config, disable plugin
if [[ -f /etc/laurel/config.toml.bak ]]; then
  echo "==> Restoring Laurel config..."
  mv /etc/laurel/config.toml.bak /etc/laurel/config.toml
fi
for plugin_dir in "$AUDIT_PLUGIN_DIR" /etc/audisp/plugins.d; do
  if [[ -f "$plugin_dir/laurel.conf" ]]; then
    echo "==> Disabling Laurel plugin..."
    sed -i 's/^active = yes/active = no/' "$plugin_dir/laurel.conf" 2>/dev/null || rm -f "$plugin_dir/laurel.conf"
  fi
done

# 8. Reload audit rules and restart auditd
echo "==> Reloading audit rules..."
if command -v augenrules &>/dev/null; then
  augenrules --load 2>/dev/null || true
fi
if [[ "$DISTRO_FAMILY" == "rhel" ]]; then
  service auditd restart 2>/dev/null || systemctl restart auditd 2>/dev/null || true
else
  systemctl restart auditd 2>/dev/null || true
fi

# 9. Clean up .env if it was generated
if [[ -f "$REPO_ROOT/.env" ]]; then
  rm -f "$REPO_ROOT/.env"
  echo "==> Removed .env"
fi

# 10. Optional: uninstall packages
if [[ "$REMOVE_PACKAGES" -eq 1 ]]; then
  echo "==> Uninstalling packages..."
  $PKG_REMOVE laurel 2>/dev/null || true
  $PKG_REMOVE $AUDIT_PKG $AUDIT_PLUGINS_PKG 2>/dev/null || true
  echo "    Audit packages removed."
fi

echo ""
echo "==> Teardown complete."
echo ""
echo "Note: /var/log/audit and /var/log/laurel may still contain logs."
echo "      Remove manually if desired: rm -rf /var/log/laurel"
