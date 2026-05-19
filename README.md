# Alona OS — Infra

Deployment and host setup for running **Alona OS** on a **Raspberry Pi** (or any Debian-based edge host).

This repo is intentionally separate from **`alona-os-core`** (application) and **`alona-os-firmware`** (ESP32 nodes). See workspace context in **`.cursor/rules/alona-os-project.mdc`** and setup in **`alona-os-setup.mdc`**:

| Repo | Role |
|------|------|
| **alona-os-core** | Elixir umbrella — Phoenix UI, Postgres data, ingest |
| **alona-os-firmware** | Sensor node firmware |
| **alona-os-infra** (this repo) | Pi OS packages, Postgres, MQTT broker, env templates, systemd examples |

## Quick start (Raspberry Pi OS / Debian)

On a fresh Pi, clone this repo (or copy `scripts/setup-pi.sh`) and run:

```bash
chmod +x scripts/setup-pi.sh
sudo ./scripts/setup-pi.sh
```

Optional environment overrides (see script header):

```bash
sudo ALONA_DB_USER=alona ALONA_DB_PASSWORD='change-me' ./scripts/setup-pi.sh
```

After host setup, deploy and run the app from **`alona-os-core`** (see [Deploy the application](#deploy-the-application)).

## What `setup-pi.sh` installs

| Component | Purpose |
|-----------|---------|
| **PostgreSQL** | `alona_os_core_prod` database for `alona_core` |
| **Mosquitto** | MQTT broker for Cerbo GX, ESP32 nodes, and `alona_ingest` |
| **Erlang/Elixir** | Runtime to build and run the umbrella (apt; version check included) |
| **Build tools** | `git`, `build-essential`, SSL/NCurses libs for native deps |

Services are enabled via `systemd` (`postgresql`, `mosquitto`).

## Configuration files

| Path | Installed to |
|------|----------------|
| `mosquitto/alona.conf` | `/etc/mosquitto/conf.d/alona.conf` |
| `env/alona.env.example` | Copy to `/etc/alona/alona.env` on the Pi (manual) |
| `systemd/alona-ui.service.example` | Reference unit for `alona-os-core` |

## Deploy the application

Host bootstrap does **not** clone or compile `alona-os-core`. On the Pi (as user `alona` or your deploy user):

```bash
# example paths — adjust to your clone location
cd ~/alona-os-core
export $(grep -v '^#' /etc/alona/alona.env | xargs)   # after you create it from env/alona.env.example
mix deps.get
MIX_ENV=prod mix compile
MIX_ENV=prod mix ecto.create
MIX_ENV=prod mix ecto.migrate
# MIX_ENV=prod mix ecto.seed   # optional demo data
MIX_ENV=prod mix phx.gen.secret   # set SECRET_KEY_BASE in /etc/alona/alona.env
```

Run under systemd using `systemd/alona-ui.service.example` as a starting point.

## Security notes

- Default Mosquitto config allows **anonymous** clients on the LAN (`listener 1883`). Harden for production: TLS, `password_file`, and firewall rules.
- Change `ALONA_DB_PASSWORD` from the script default before exposing the Pi on untrusted networks.
- Postgres is configured for **local** connections only (`localhost`).

## Verify services

```bash
sudo systemctl status postgresql mosquitto
pg_isready -h localhost
mosquitto_sub -h localhost -t '$SYS/broker/version' -C 1
```
