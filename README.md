<p align="center">
  <img src="assets/guilty-spark-light.png" alt="Guilty Spark" width="400">
</p>

<p align="center">
  <a href="https://www.gnu.org/licenses/agpl-3.0"><img src="https://img.shields.io/badge/License-AGPL--3.0-blue.svg" alt="License: AGPL-3.0"></a>
  <a href="https://prometheus.io"><img src="https://img.shields.io/badge/Prometheus-v3.11-E6522C?logo=prometheus&logoColor=white" alt="Prometheus"></a>
  <a href="https://grafana.com"><img src="https://img.shields.io/badge/Grafana-12.3-F46800?logo=grafana&logoColor=white" alt="Grafana"></a>
  <a href="https://docs.docker.com/compose/"><img src="https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white" alt="Docker"></a>
</p>

Multi-server monitoring stack for GPU compute environments. Deploys Prometheus, Grafana, Loki, and a suite of exporters with one command. Includes user activity auditing, cost tracking, and EC2 auto-detection.

## Quick Start

### Central server

```bash
git clone <repo> && cd guilty-spark
sudo ./scripts/setup.sh    # select "Central"
```

Open **Grafana** at `http://<server-ip>:3000` (default login: admin / admin).

### Remote agents

```bash
git clone <repo> && cd guilty-spark
sudo ./scripts/setup.sh    # select "Agent", enter central server IP
```

### Register agents on central

```bash
sudo ./scripts/add-agent.sh gpu01 192.168.1.11
sudo ./scripts/add-agent.sh minecraft-box 192.168.1.151 --no-gpu
```

Prometheus picks up new targets within 30 seconds.

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| Ubuntu / Debian / RHEL / AlmaLinux | Tested on Ubuntu 20.04-24.04, RHEL 8-9 |
| Docker 20.10+ | With Compose v2 (`docker compose`) |
| NVIDIA driver | Only needed on GPU servers (setup installs the container toolkit automatically) |

## What Gets Monitored

| Source | Data |
|--------|------|
| DCGM Exporter | GPU utilization, VRAM, temperature, power, clocks |
| Node Exporter | CPU, memory, disk, network, load, filesystem mounts |
| cAdvisor | Per-container CPU, memory, network, disk I/O |
| Process Exporter | Per-process resource usage |
| Snoopy Logger | Every command executed (execve-level capture) |
| auditd + Laurel | Command history, logins, sudo, file access |
| auth.log / secure | SSH sessions, failed logins, authentication events |
| EC2 IMDS v2 | Instance type, region, AZ, lifecycle (auto-detected) |

## Dashboards

| Dashboard | Description |
|-----------|-------------|
| Home | Cluster health overview with quick nav |
| System | CPU, memory, disk, network per server |
| GPUs | DCGM metrics: temp, power, utilization, VRAM, clocks |
| GPU Allocation | Who is using which GPU and how efficiently |
| Containers | Per-container resource usage from cAdvisor |
| Network | Deep-dive into network traffic and interfaces |
| Services & Storage | Listening ports, per-user disk, filesystem mounts, I/O |
| Audit | User commands, sudo activity, shell history |
| Security | Failed logins, firewall events, auth anomalies |
| Cost Estimation | Cost estimation for on-prem and EC2 infrastructure |

## Scripts

| Script | Purpose |
|--------|---------|
| `setup.sh` | Interactive setup for central or agent role |
| `setup-audit.sh` | Configure auditd (called by setup.sh, or standalone) |
| `teardown.sh` | Revert all changes: stop stack, remove configs |
| `add-agent.sh` | Register a remote agent on the central server |
| `remove-agent.sh` | Remove a remote agent |
| `status` | Show stack health, endpoints, agent scrape status |
| `fetch-ec2-pricing.sh` | Download EC2 on-demand pricing from AWS public API |
| `generate-user-metrics.sh` | UID-to-username mapping for Prometheus |
| `generate-disk-metrics.sh` | Per-user disk usage metrics |
| `generate-service-metrics.sh` | Listening port/service inventory |
| `ec2-metadata.sh` | Export EC2 instance metadata via IMDSv2 |
| `generate-ec2-cost-metrics.sh` | Calculate EC2 cost-per-hour from pricing data |

## EC2 Integration

EC2 instances are auto-detected during setup (no IAM credentials needed). On EC2 agents, `ec2-metadata.sh` queries IMDSv2 for instance type, region, and lifecycle. On the central server, `generate-ec2-cost-metrics.sh` joins that metadata with pricing data to calculate hourly costs.

Pricing data is bundled in `config/ec2-pricing/` (33 regions) and can be refreshed:

```bash
./scripts/fetch-ec2-pricing.sh           # all regions
./scripts/fetch-ec2-pricing.sh --region us-east-1  # single region
```

A [GitHub Actions workflow](.github/workflows/update-ec2-pricing.yml) auto-updates pricing weekly.

The Cost Estimation dashboard separates on-prem and EC2 costs automatically.

## Firewall

| Server | Port | Direction | Purpose |
|--------|------|-----------|---------|
| Central | 3000 | Inbound | Grafana |
| Central | 3100 | Inbound | Loki (agent log push) |
| Central | 9090 | Inbound | Prometheus (optional, for external access) |
| Remote | 9100 | Inbound | Node Exporter |
| Remote | 9400 | Inbound | DCGM Exporter (GPU servers only) |
| Remote | 8080 | Inbound | cAdvisor |
| Remote | 9256 | Inbound | Process Exporter |

## Project Layout

```
guilty-spark/
├── docker-compose.yml            # Full stack (central server)
├── docker-compose.agent.yml      # Agent-only (remote servers)
├── .env.example                  # Central config template
├── .env.agent.example            # Agent config template
├── config/
│   ├── prometheus/
│   │   ├── prometheus.yml        # Scrape config
│   │   └── targets/              # Auto-loaded agent targets
│   ├── grafana/
│   │   └── provisioning/
│   │       ├── dashboards/
│   │       ├── datasources/
│   │       └── alerting/         # Alert rules
│   ├── ec2-pricing/              # Bundled per-region pricing JSON
│   ├── dcgm/                     # DCGM metrics config
│   ├── loki/
│   ├── alloy/                    # Grafana Alloy log shipping configs
│   ├── process-exporter/
│   ├── audit/rules.d/            # STIG audit rules
│   ├── rsyslog/                  # Log routing config
│   ├── shell/                    # Shell command logger (bash + zsh)
│   └── systemd/                  # Userwatch service
├── scripts/                      # Setup, teardown, agent management, metrics
└── .github/workflows/            # EC2 pricing auto-update, CVE scans
```

## Configuration

Copy `.env.example` to `.env` to override defaults:

| Variable | Default | Purpose |
|----------|---------|---------|
| `INSTANCE_NAME` | hostname | Display name in dashboards |
| `GF_ADMIN_USER` | `admin` | Grafana admin username |
| `GF_ADMIN_PASSWORD` | `admin` | Grafana admin password |
| `DCGM_IMAGE` | `nvidia/dcgm-exporter:4.5.2-4.8.1-ubuntu22.04` | DCGM image tag |

## Stack Status

```bash
./scripts/status
```

Shows container health, endpoint reachability, and per-agent scrape status from Prometheus.

## Teardown

```bash
sudo ./scripts/teardown.sh              # stop stack, remove configs
sudo ./scripts/teardown.sh --packages   # also uninstall auditd, laurel, snoopy
```

## Security Notes

- Change the Grafana admin password on first login
- Restrict Grafana/Prometheus ports to localhost or VPN in production
- Audit logs contain sensitive data; restrict access to `/var/log/audit` and `/var/log/laurel`
- A weekly [Trivy CVE scan](.github/workflows/cve-scan.yml) checks all container images for CRITICAL/HIGH vulnerabilities and opens a GitHub issue if any are found

## DoD STIG Audit Rules

During setup you're asked whether to enable STIG audit rules. These are a
subset of the [linux-audit/audit-userspace](https://github.com/linux-audit/audit-userspace)
`30-stig.rules` and add monitoring for:

- System time changes
- Identity file modifications (`/etc/passwd`, `/etc/shadow`, `/etc/group`)
- Privilege escalation and `sudo` usage
- Kernel module loading
- Unauthorized file access attempts (`EACCES`, `EPERM`)
- Login/logout and session events

Enabling STIG mode also sets `disk_full_action=SINGLE` in `auditd.conf` (single-user
mode if audit disk fills), which is required for compliance but aggressive for
general use. If you don't have a compliance requirement, the default audit rules
(execve tracking via Snoopy + guilty-spark's own rules) are sufficient.

## LUKS / Encrypted Storage

Works without changes. Once volumes are unlocked at boot, the stack sees normal filesystem paths. Docker volumes (Prometheus, Grafana, Loki data) under `/var/lib/docker` are encrypted at rest when on LUKS.
