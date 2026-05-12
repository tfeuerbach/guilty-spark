# Guilty Spark — GPU Server Monitoring

[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![Prometheus](https://img.shields.io/badge/Prometheus-v3.10-E6522C?logo=prometheus&logoColor=white)](https://prometheus.io)
[![Grafana](https://img.shields.io/badge/Grafana-12.3-F46800?logo=grafana&logoColor=white)](https://grafana.com)
[![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)](https://docs.docker.com/compose/)

Multi-server monitoring stack for GPU compute environments. Deploys Prometheus, Grafana, Loki, DCGM Exporter, and Node Exporter with one-command setup. Includes real-time user activity auditing with automatic UID-to-username resolution.

## Quick Start

```bash
git clone <repo> && cd guilty-spark
sudo ./scripts/setup.sh
```

The setup script handles everything interactively:
- Asks if this is the **central** server or an **agent**
- For agents: asks for the central server's IP and a name for this server
- Configures auditd (command tracking)
- Generates user metrics (UID→username mapping for dashboards)
- Installs a cron job to keep user metrics current
- Starts the correct Docker stack

Then open **Grafana** http://localhost:3000 (admin/admin), **Prometheus** http://localhost:9090.

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| Ubuntu | 20.04, 22.04, 24.04 — any LTS |
| Docker | 20.10+ (or 19.03+ with `runtime: nvidia`) |
| Docker Compose | v2 (`docker compose`) |
| NVIDIA driver | Installed and working (`nvidia-smi`) |
| nvidia-container-toolkit | For GPU access in containers |

### Install nvidia-container-toolkit (if needed)

```bash
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/libnvidia-container/gpgkey | sudo apt-key add -
curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo systemctl restart docker
```

## Scripts

| Script | Purpose |
|--------|---------|
| `setup.sh` | Universal setup — interactive, handles central or agent role |
| `setup-audit.sh` | Configures auditd (called by setup.sh, can also run standalone) |
| `teardown.sh` | Reverts everything: stops stack, removes audit config, cron, user metrics |
| `add-agent.sh` | Register a remote agent on the central node |
| `remove-agent.sh` | Remove a remote agent from the central node |
| `status` | Show stack health, endpoints, and scrape status for all agents |
| `generate-user-metrics.sh` | Regenerates UID→username mapping (runs hourly via cron) |
| `lib/distro.sh` | Distro detection helper (sourced by other scripts) |

**Teardown** — Revert all changes: `sudo ./scripts/teardown.sh`
Stops Docker stack, restores auditd.conf, removes audit rules, cron job, and user metrics. Add `--packages` to also uninstall auditd and laurel.

**User Activity dashboard** — The User filter auto-discovers usernames from system users via a Prometheus metric. A cron job keeps the mapping current. No manual updates needed.

## Multi-Server Setup

Monitor multiple GPU servers from one central dashboard. The central server runs the full stack; remote servers run lightweight agents only.

### On the central server (this machine)

Register a remote agent:

```bash
./scripts/add-agent.sh gpu01 192.168.1.11
```

Prometheus starts scraping the remote within 30 seconds. The "Server" dropdown appears in all dashboards.

To remove an agent: `./scripts/remove-agent.sh gpu01`

### On each remote server

```bash
git clone <repo> && cd guilty-spark
sudo ./scripts/setup.sh                # select "Agent", enter central IP + server name
```

The setup script generates `.env`, configures auditd, sets up user metrics, and starts the agent stack (DCGM Exporter, Node Exporter, Promtail). Metrics are scraped by central Prometheus; logs are pushed to central Loki.

### Firewall

| Server | Port | Direction | Purpose |
|--------|------|-----------|---------|
| Central | 3000 | Inbound | Grafana |
| Central | 3100 | Inbound | Loki (agent log push) |
| Central | 9090 | Inbound | Prometheus (optional) |
| Remote | 9100 | Inbound | Node Exporter (central scrape) |
| Remote | 9400 | Inbound | DCGM Exporter (central scrape) |

## Project Layout

```
guilty-spark/
├── docker-compose.yml              # Full stack (central server)
├── docker-compose.agent.yml        # Agent-only (remote servers)
├── .env.example                    # Central config template
├── .env.agent.example              # Agent config template
├── config/
│   ├── prometheus/
│   │   ├── prometheus.yml          # Scrape config (local + agents)
│   │   └── targets/                # Agent target files (auto-loaded)
│   ├── grafana/
│   │   └── provisioning/           # Datasources + dashboards
│   ├── dcgm/
│   ├── audit/                      # STIG rules
│   ├── loki/
│   └── promtail/
│       ├── promtail-config.yml     # Central node promtail
│       └── promtail-agent.yml      # Agent node promtail
└── scripts/
    ├── setup.sh                    # Interactive setup (central or agent)
    ├── setup-audit.sh              # auditd configuration
    ├── teardown.sh                 # Revert all changes
    ├── add-agent.sh                # Register agent on central
    ├── remove-agent.sh             # Remove agent from central
    ├── status                      # Stack + agent health overview
    ├── generate-user-metrics.sh    # UID→username for Prometheus
    └── lib/
        └── distro.sh               # Distro detection helper
```

## What Gets Monitored

| Source | Data |
|--------|------|
| DCGM | GPU utilization, VRAM, temperature, power draw, energy, clocks |
| Node Exporter | CPU, memory, disk, network, load |
| auditd + Laurel | Every command (execve), logins, sudo, file access |
| auth.log | Logins, SSH, sudo, failures |

## Dashboards

- **NVIDIA DCGM Exporter Dashboard**: GPU temp, power, utilization, VRAM, clocks
- **System — Node Exporter**: CPU, memory, disk, network, load
- **User Activity — Audit**: Filter by user, view every command, auth log, raw audit

## Ports

| Service | Port |
|---------|------|
| Grafana | 3000 |
| Prometheus | 9090 |
| Loki | 3100 |
| DCGM Exporter | 9400 (agents expose for central scrape) |
| Node Exporter | 9100 (agents expose for central scrape) |

## LUKS / Encrypted Storage

LUKS-encrypted LVM works without changes. Once the volume is unlocked at boot, the stack sees normal filesystem paths. Docker, auditd, Promtail, and Node Exporter all operate on decrypted data.

**Considerations:**
- Ensure `/var/log` (audit, laurel, auth) is mounted before Docker starts — this is the default boot order.
- Docker volumes (Prometheus, Grafana, Loki data) live under `/var/lib/docker`; if that’s on LUKS, data is encrypted at rest.
- Audit logs in `/var/log/audit` and `/var/log/laurel` are encrypted at rest when those paths are on LUKS.

No configuration changes are required for LUKS setups.

## Optional Overrides

Copy `.env.example` to `.env` to override defaults:

- `DCGM_IMAGE` — use a different DCGM Exporter tag (e.g. for older GPU drivers)
- `INSTANCE_NAME` — display name for this server in dashboards (defaults to `local`)
- `GF_ADMIN_USER` / `GF_ADMIN_PASSWORD` — Grafana admin credentials (defaults to `admin`/`admin`)

## Stack Status

Check health of all containers, endpoints, and agent scrape targets:

```bash
./scripts/status
```

Output includes container status, endpoint reachability, and per-agent GPU/node scrape health from Prometheus. Colors are disabled automatically when piped.

## Security

- Change Grafana admin password on first login
- For production: restrict Grafana/Prometheus to localhost or VPN
- Audit logs contain sensitive data; restrict access to `/var/log/audit` and `/var/log/laurel`
