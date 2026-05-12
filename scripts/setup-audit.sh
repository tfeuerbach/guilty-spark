#!/usr/bin/env bash
# Guilty Spark — Configure auditd for full command tracking
# Supports Ubuntu/Debian and RHEL/AlmaLinux/Rocky.
# Run as root. Usage: sudo ./scripts/setup-audit.sh [--stig]
#
# --stig    Apply DoD STIG audit rules and config (more verbose, disk_full_action=SINGLE)

set -e

STIG=0
for arg in "$@"; do
  [[ "$arg" == "--stig" ]] && STIG=1
done

if [[ $EUID -ne 0 ]]; then
  echo "Must run as root (sudo ./scripts/setup-audit.sh)"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RULES_SRC="$REPO_ROOT/config/audit/rules.d"

source "$SCRIPT_DIR/lib/distro.sh"

echo "==> Guilty Spark — Audit Setup"
echo "    Detected: ${DISTRO_FAMILY}"
[[ "$STIG" -eq 1 ]] && echo "    STIG mode enabled"
echo ""

# Install auditd
echo "==> Installing auditd packages..."
$PKG_UPDATE
$PKG_INSTALL $AUDIT_PKG $AUDIT_PLUGINS_PKG 2>/dev/null || $PKG_INSTALL $AUDIT_PKG || true

# Optional: Laurel for JSON output
USE_LAUREL=0
if [[ "$DISTRO_FAMILY" == "debian" ]]; then
  if apt-cache show laurel &>/dev/null; then
    echo "==> Installing Laurel (JSON audit output)..."
    $PKG_INSTALL laurel || true
    USE_LAUREL=1
  fi
elif [[ "$DISTRO_FAMILY" == "rhel" ]]; then
  if dnf info laurel &>/dev/null 2>&1 || yum info laurel &>/dev/null 2>&1; then
    echo "==> Installing Laurel (JSON audit output)..."
    $PKG_INSTALL laurel || true
    USE_LAUREL=1
  fi
fi

if [[ "$USE_LAUREL" -eq 0 ]]; then
  echo "==> Laurel not in repos; audit logs will be in native format (use ausearch)"
fi

# Backup existing configs
for f in /etc/audit/auditd.conf /etc/audit/audit.rules; do
  [[ -f "$f" ]] && cp -a "$f" "${f}.bak.$(date +%Y%m%d)" 2>/dev/null || true
done

# auditd.conf
echo "==> Configuring auditd.conf..."
if [[ "$STIG" -eq 1 ]]; then
  cat > /etc/audit/auditd.conf << AUDITDCONF
# Guilty Spark — STIG mode
log_file = /var/log/audit/audit.log
log_format = RAW
log_group = ${LOG_GROUP}
priority_boost = 4
flush = INCREMENTAL_ASYNC
freq = 50
max_log_file = 8
max_log_file_action = ROTATE
num_logs = 5
name_format = NONE
name = myhost
space_left = 75
space_left_action = SYSLOG
admin_space_left = 50
admin_space_left_action = SINGLE
disk_full_action = SINGLE
disk_error_action = SYSLOG
action_mail_acct = root
AUDITDCONF
else
  cat > /etc/audit/auditd.conf << AUDITDCONF
# Guilty Spark — default
log_file = /var/log/audit/audit.log
log_format = RAW
log_group = ${LOG_GROUP}
priority_boost = 4
flush = INCREMENTAL_ASYNC
freq = 50
max_log_file = 8
max_log_file_action = ROTATE
num_logs = 5
name_format = NONE
name = myhost
space_left = 100
space_left_action = SYSLOG
admin_space_left = 75
admin_space_left_action = SYSLOG
disk_full_action = SYSLOG
disk_error_action = SYSLOG
action_mail_acct = root
AUDITDCONF
fi

chmod 640 /etc/audit/auditd.conf
chown root:root /etc/audit/auditd.conf

mkdir -p /var/log/audit
chmod 750 /var/log/audit

# Rules
echo "==> Installing audit rules..."
mkdir -p /etc/audit/rules.d

if [[ "$STIG" -eq 1 ]] && [[ -f "$RULES_SRC/30-stig.rules" ]]; then
  cp -a "$RULES_SRC/30-stig.rules" /etc/audit/rules.d/
fi

cat > /etc/audit/rules.d/99-guilty-spark.rules << 'RULES'
# Guilty Spark — Full command tracking (every execve)

# Execve: every command executed by users (auid>=1000)
-a always,exit -F arch=b64 -S execve -F auid>=1000 -F auid!=unset -k exec
-a always,exit -F arch=b32 -S execve -F auid>=1000 -F auid!=unset -k exec

# Login/logout (watch files)
-w /var/log/tallylog -p wa -k logins
-w /var/log/faillock -p wa -k logins
-w /var/log/lastlog -p wa -k logins
-w /var/run/utmp -p wa -k session
-w /var/log/wtmp -p wa -k session
-w /var/log/btmp -p wa -k session
RULES

chmod 640 /etc/audit/rules.d/*.rules 2>/dev/null || true

# Laurel config (if installed)
if [[ "$USE_LAUREL" -eq 1 ]] && command -v laurel &>/dev/null; then
  echo "==> Configuring Laurel..."
  mkdir -p /var/log/laurel
  chmod 750 /var/log/laurel
  chown root:${LOG_GROUP} /var/log/laurel 2>/dev/null || true

  if [[ -f /etc/laurel/config.toml ]]; then
    cp -a /etc/laurel/config.toml /etc/laurel/config.toml.bak 2>/dev/null || true
  fi
  mkdir -p /etc/laurel
  cat > /etc/laurel/config.toml << 'LAURELCONF'
# Guilty Spark — Laurel config for Loki
[output]
  [output.file]
  path = "/var/log/laurel/audit.json"
  mode = 0o640
LAURELCONF
  chmod 640 /etc/laurel/config.toml 2>/dev/null || true

  mkdir -p "$AUDIT_PLUGIN_DIR"
  cat > "$AUDIT_PLUGIN_DIR/laurel.conf" << 'LAURELPLUGIN'
active = yes
direction = out
path = /usr/sbin/laurel
type = always
args = 
format = string
LAURELPLUGIN
  chmod 640 "$AUDIT_PLUGIN_DIR/laurel.conf" 2>/dev/null || true
fi

# Load rules
echo "==> Loading audit rules..."
if command -v augenrules &>/dev/null; then
  if ! augenrules --load 2>/dev/null; then
    echo "    WARNING: augenrules --load failed (audit subsystem may not be available)"
    echo "    This is expected on WSL2 or containers. Rules are installed for native boot."
  fi
else
  auditctl -R /etc/audit/audit.rules 2>/dev/null || true
fi

# Enable and start auditd
# RHEL: auditd doesn't support restart via systemctl, use 'service auditd restart'
systemctl enable auditd 2>/dev/null || true
if [[ "$DISTRO_FAMILY" == "rhel" ]]; then
  service auditd restart 2>/dev/null || systemctl restart auditd 2>/dev/null || true
else
  systemctl restart auditd 2>/dev/null || true
fi

# ─── Snoopy Logger (full execve capture with args) ───
USE_SNOOPY=0
echo "==> Installing Snoopy Logger (execve interception)..."
if [[ "$DISTRO_FAMILY" == "debian" ]]; then
  if apt-cache show snoopy &>/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive $PKG_INSTALL snoopy 2>/dev/null && USE_SNOOPY=1
  fi
elif [[ "$DISTRO_FAMILY" == "rhel" ]]; then
  if dnf info snoopy &>/dev/null 2>&1 || yum info snoopy &>/dev/null 2>&1; then
    $PKG_INSTALL snoopy 2>/dev/null && USE_SNOOPY=1
  fi
fi

if [[ "$USE_SNOOPY" -eq 1 ]]; then
  if command -v snoopyctl &>/dev/null; then
    snoopyctl enable 2>/dev/null || true
  elif ! grep -q 'libsnoopy' /etc/ld.so.preload 2>/dev/null; then
    SNOOPY_LIB=$(find /usr/lib* /lib* -name 'libsnoopy.so' 2>/dev/null | head -1)
    if [[ -n "$SNOOPY_LIB" ]]; then
      echo "$SNOOPY_LIB" >> /etc/ld.so.preload
    fi
  fi

  # Configure snoopy to log to its own file via syslog
  mkdir -p /etc/snoopy.d 2>/dev/null || true
  if [[ -f /etc/snoopy.ini ]]; then
    if ! grep -q 'output.*syslog' /etc/snoopy.ini 2>/dev/null; then
      cat >> /etc/snoopy.ini << 'SNOOPYCONF'

[snoopy]
output = syslog
syslog_facility = LOG_AUTH
syslog_level = LOG_INFO
SNOOPYCONF
    fi
  fi

  echo "    Snoopy installed and enabled (logging all execve calls)"
else
  echo "    Snoopy not available in repos — skipping (auditd still captures execve)"
fi

echo ""
echo "==> Done. Audit is configured."
echo ""
echo "Audit logs: /var/log/audit/audit.log"
echo "  Query: ausearch -k exec"
echo "  Report: aureport -x"
if [[ "$USE_LAUREL" -eq 1 ]]; then
  echo ""
  echo "Laurel JSON: /var/log/laurel/audit.json"
  echo "  (Used by Promtail for Loki/Grafana)"
fi
if [[ "$USE_SNOOPY" -eq 1 ]]; then
  echo ""
  echo "Snoopy: /var/log/snoopy.log (or /var/log/auth.log)"
  echo "  (Full execve capture with arguments)"
fi
echo ""
