#!/usr/bin/env bash
# Guilty Spark — Distro detection helper
# Source this from other scripts: source "$(dirname "$0")/lib/distro.sh"
#
# Exports:
#   DISTRO_FAMILY   — "debian" or "rhel"
#   PKG_INSTALL     — install command (e.g. "apt-get install -y" or "dnf install -y")
#   PKG_REMOVE      — remove command
#   PKG_UPDATE      — update/refresh command
#   AUDIT_PKG       — package name for auditd
#   AUDIT_PLUGINS_PKG — audispd plugins package (empty if not needed)
#   AUDIT_PLUGIN_DIR  — path to audit dispatcher plugin configs
#   AUTH_LOG_PATH   — path to auth/login log file
#   LOG_GROUP       — group for log file ownership

detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian|linuxmint|pop)
                DISTRO_FAMILY="debian"
                ;;
            rhel|centos|almalinux|rocky|fedora|ol)
                DISTRO_FAMILY="rhel"
                ;;
            *)
                # Fall back to ID_LIKE
                case "$ID_LIKE" in
                    *debian*|*ubuntu*)
                        DISTRO_FAMILY="debian"
                        ;;
                    *rhel*|*fedora*|*centos*)
                        DISTRO_FAMILY="rhel"
                        ;;
                    *)
                        echo "WARNING: Unrecognized distro '$ID'. Defaulting to debian-like."
                        DISTRO_FAMILY="debian"
                        ;;
                esac
                ;;
        esac
    elif [ -f /etc/redhat-release ]; then
        DISTRO_FAMILY="rhel"
    elif [ -f /etc/debian_version ]; then
        DISTRO_FAMILY="debian"
    else
        echo "WARNING: Cannot detect distro. Defaulting to debian-like."
        DISTRO_FAMILY="debian"
    fi

    case "$DISTRO_FAMILY" in
        debian)
            PKG_UPDATE="apt-get update -qq"
            PKG_INSTALL="apt-get install -y"
            PKG_REMOVE="apt-get remove -y"
            AUDIT_PKG="auditd"
            AUDIT_PLUGINS_PKG="audispd-plugins"
            AUTH_LOG_PATH="/var/log/auth.log"
            LOG_GROUP="adm"
            ;;
        rhel)
            if command -v dnf &>/dev/null; then
                PKG_UPDATE="dnf makecache -q"
                PKG_INSTALL="dnf install -y"
                PKG_REMOVE="dnf remove -y"
            else
                PKG_UPDATE="yum makecache -q"
                PKG_INSTALL="yum install -y"
                PKG_REMOVE="yum remove -y"
            fi
            AUDIT_PKG="audit"
            AUDIT_PLUGINS_PKG=""
            AUTH_LOG_PATH="/var/log/secure"
            LOG_GROUP="root"
            ;;
    esac

    # Audit plugin directory — RHEL 8+/Ubuntu 22.04+ use /etc/audit/plugins.d,
    # older systems use /etc/audisp/plugins.d
    if [ -d /etc/audit/plugins.d ]; then
        AUDIT_PLUGIN_DIR="/etc/audit/plugins.d"
    elif [ -d /etc/audisp/plugins.d ]; then
        AUDIT_PLUGIN_DIR="/etc/audisp/plugins.d"
    else
        AUDIT_PLUGIN_DIR="/etc/audit/plugins.d"
    fi
}

detect_distro
