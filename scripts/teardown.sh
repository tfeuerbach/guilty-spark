#!/usr/bin/env bash
# Revert all guilty-spark changes. Run as root for full teardown.
#
# Usage: sudo ./scripts/teardown.sh [--packages]
#
# --packages    Also uninstall auditd, laurel, snoopy

set -e

REMOVE_PACKAGES=0
for arg in "$@"; do
  [[ "$arg" == "--packages" ]] && REMOVE_PACKAGES=1
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib/distro.sh"

echo "==> Teardown"
echo "    Detected: ${DISTRO_FAMILY}"
echo ""

echo "==> Stopping Docker stack..."
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

if [[ $EUID -ne 0 ]]; then
  echo "==> Run as root to fully teardown system configs:"
  echo "    sudo $0"
  exit 0
fi

echo "==> Removing cron job..."
rm -f /etc/cron.d/guilty-spark && echo "    Removed /etc/cron.d/guilty-spark" || echo "    No cron job found."

echo "==> Removing userwatch service..."
systemctl disable --now guilty-spark-userwatch 2>/dev/null || true
rm -f /etc/systemd/system/guilty-spark-userwatch.service
rm -f /usr/local/bin/guilty-spark-userwatch
systemctl daemon-reload 2>/dev/null || true
echo "    Done."

echo "==> Removing shell logger..."
rm -f /etc/rsyslog.d/00-guilty-spark.conf
rm -f /etc/profile.d/guilty-spark-logger.sh
for rcfile in /etc/bash.bashrc /etc/zsh/zshrc /etc/zshrc; do
  if [[ -f "$rcfile" ]]; then
    sed -i '/guilty-spark.*shell command logging/d' "$rcfile" 2>/dev/null
    sed -i '/guilty-spark-logger/d' "$rcfile" 2>/dev/null
  fi
done
systemctl restart rsyslog 2>/dev/null || true
echo "    Done."

echo "==> Removing metrics data..."
rm -rf /var/lib/guilty-spark
rm -rf /opt/guilty-spark
echo "    Done."

echo "==> Removing generated alloy configs..."
rm -f "$REPO_ROOT/config/alloy/config.yml" "$REPO_ROOT/config/alloy/agent.yml"
echo "    Done."

echo "==> Restoring auditd.conf..."
BACKUP=$(ls -t /etc/audit/auditd.conf.bak.* 2>/dev/null | head -1)
if [[ -n "$BACKUP" ]]; then
  cp -a "$BACKUP" /etc/audit/auditd.conf
  echo "    Restored from $BACKUP"
else
  echo "    No backup found; auditd.conf unchanged."
fi

echo "==> Removing audit rules..."
for f in /etc/audit/rules.d/30-stig.rules /etc/audit/rules.d/99-guilty-spark.rules; do
  [[ -f "$f" ]] && rm -f "$f" && echo "    Removed $f"
done

echo "==> Restoring Laurel config..."
if [[ -f /etc/laurel/config.toml.bak ]]; then
  mv /etc/laurel/config.toml.bak /etc/laurel/config.toml
fi
for plugin_dir in "$AUDIT_PLUGIN_DIR" /etc/audisp/plugins.d; do
  if [[ -f "$plugin_dir/laurel.conf" ]]; then
    sed -i 's/^active = yes/active = no/' "$plugin_dir/laurel.conf" 2>/dev/null || rm -f "$plugin_dir/laurel.conf"
  fi
done

echo "==> Reloading audit rules..."
if command -v augenrules &>/dev/null; then
  augenrules --load 2>/dev/null || true
fi
if [[ "$DISTRO_FAMILY" == "rhel" ]]; then
  service auditd restart 2>/dev/null || systemctl restart auditd 2>/dev/null || true
else
  systemctl restart auditd 2>/dev/null || true
fi

if [[ -f "$REPO_ROOT/.env" ]]; then
  rm -f "$REPO_ROOT/.env"
  echo "==> Removed .env"
fi

if [[ "$REMOVE_PACKAGES" -eq 1 ]]; then
  echo "==> Uninstalling packages..."
  $PKG_REMOVE laurel 2>/dev/null || true
  $PKG_REMOVE snoopy 2>/dev/null || true
  $PKG_REMOVE $AUDIT_PKG $AUDIT_PLUGINS_PKG 2>/dev/null || true
  rm -f /etc/snoopy.ini 2>/dev/null
  echo "    Done."
fi

echo ""
echo "==> Teardown complete."
echo ""
echo "Logs in /var/log/audit and /var/log/laurel are preserved."
echo "Remove manually if desired: rm -rf /var/log/laurel"
