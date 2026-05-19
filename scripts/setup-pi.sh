#!/usr/bin/env bash
#
# Bootstrap a Raspberry Pi (or Debian/Ubuntu host) for Alona OS:
#   PostgreSQL, Mosquitto MQTT, Erlang/Elixir build/runtime deps.
#
# Usage:
#   chmod +x scripts/setup-pi.sh
#   sudo ./scripts/setup-pi.sh
#
# Environment (optional):
#   ALONA_DB_USER          default: alona
#   ALONA_DB_PASSWORD      default: alona  (change in production)
#   ALONA_DB_NAME          default: alona_os_core_prod
#   ALONA_SKIP_APT=1       skip apt install (re-run DB/MQTT config only)
#   ALONA_SKIP_ELIXIR=1    skip Erlang/Elixir apt packages
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ALONA_DB_USER="${ALONA_DB_USER:-alona}"
ALONA_DB_PASSWORD="${ALONA_DB_PASSWORD:-alona}"
ALONA_DB_NAME="${ALONA_DB_NAME:-alona_os_core_prod}"

log() { printf '==> %s\n' "$*"; }
warn() { printf '==> WARNING: %s\n' "$*" >&2; }
die() { printf '==> ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run as root: sudo $0"
  fi
}

detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    log "OS: ${PRETTY_NAME:-unknown}"
  else
    warn "Cannot read /etc/os-release; continuing anyway."
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    die "This script targets Debian/Ubuntu (apt). Raspberry Pi OS is supported."
  fi
}

apt_install() {
  if [[ "${ALONA_SKIP_APT:-}" == "1" ]]; then
    log "ALONA_SKIP_APT=1 — skipping apt packages"
    return
  fi

  log "Updating apt indexes"
  apt-get update -qq

  local packages=(
    ca-certificates
    curl
    git
    gnupg
    build-essential
    openssl
    libssl-dev
    libncurses-dev
    postgresql
    postgresql-contrib
    mosquitto
    mosquitto-clients
  )

  if [[ "${ALONA_SKIP_ELIXIR:-}" != "1" ]]; then
    packages+=(erlang elixir)
  fi

  log "Installing packages: ${packages[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
}

check_elixir_version() {
  if [[ "${ALONA_SKIP_ELIXIR:-}" == "1" ]]; then
    return
  fi

  if ! command -v elixir >/dev/null 2>&1; then
    warn "elixir not in PATH after install"
    return
  fi

  local version
  version="$(elixir --short-version 2>/dev/null || true)"

  if [[ -z "$version" ]]; then
    warn "Could not read elixir version"
    return
  fi

  log "Elixir version: $version"

  local major minor
  major="${version%%.*}"
  rest="${version#*.}"
  minor="${rest%%.*}"

  if [[ "$major" -lt 1 ]] || { [[ "$major" -eq 1 ]] && [[ "$minor" -lt 15 ]]; }; then
    warn "alona-os-core requires Elixir ~> 1.15; apt may ship an older release."
    warn "Install a newer OTP/Elixir via asdf or https://elixir-lang.org/install.html"
  fi
}

ensure_postgresql_running() {
  systemctl enable postgresql
  systemctl start postgresql
}

setup_postgresql() {
  ensure_postgresql_running

  log "Configuring PostgreSQL role and database: ${ALONA_DB_USER} / ${ALONA_DB_NAME}"

  # idempotent role + database
  sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${ALONA_DB_USER}') THEN
    CREATE ROLE ${ALONA_DB_USER} LOGIN PASSWORD '${ALONA_DB_PASSWORD}';
  ELSE
    ALTER ROLE ${ALONA_DB_USER} WITH PASSWORD '${ALONA_DB_PASSWORD}';
  END IF;
END
\$\$;

SELECT 'CREATE DATABASE ${ALONA_DB_NAME} OWNER ${ALONA_DB_USER}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${ALONA_DB_NAME}')
\\gexec

GRANT ALL PRIVILEGES ON DATABASE ${ALONA_DB_NAME} TO ${ALONA_DB_USER};
SQL

  # schema privileges for ecto migrations
  sudo -u postgres psql -v ON_ERROR_STOP=1 -d "${ALONA_DB_NAME}" <<SQL
GRANT ALL ON SCHEMA public TO ${ALONA_DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${ALONA_DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${ALONA_DB_USER};
SQL
}

install_mosquitto_config() {
  local src="${ROOT}/mosquitto/alona.conf"
  local dest="/etc/mosquitto/conf.d/alona.conf"

  [[ -f "$src" ]] || die "Missing ${src}"

  log "Installing Mosquitto config → ${dest}"
  install -m 0644 "$src" "$dest"
}

ensure_mosquitto_running() {
  install_mosquitto_config
  systemctl enable mosquitto
  systemctl restart mosquitto
}

install_env_template() {
  local src="${ROOT}/env/alona.env.example"
  local dest_dir="/etc/alona"
  local dest="${dest_dir}/alona.env.example"

  [[ -f "$src" ]] || return

  mkdir -p "$dest_dir"
  install -m 0644 "$src" "$dest"

  if [[ ! -f "${dest_dir}/alona.env" ]]; then
    local db_url="ecto://${ALONA_DB_USER}:${ALONA_DB_PASSWORD}@localhost/${ALONA_DB_NAME}"
    sed "s|^export DATABASE_URL=.*|export DATABASE_URL=${db_url}|" "$src" > "${dest_dir}/alona.env"
    chmod 600 "${dest_dir}/alona.env"
    log "Created ${dest_dir}/alona.env (edit SECRET_KEY_BASE before prod)"
  else
    log "Keeping existing ${dest_dir}/alona.env"
  fi
}

maybe_create_deploy_user() {
  if id alona >/dev/null 2>&1; then
    log "User 'alona' already exists"
    return
  fi

  log "Creating deploy user 'alona' (home /home/alona) for app + systemd unit"
  useradd --create-home --shell /bin/bash alona
}

verify_services() {
  log "Verifying PostgreSQL"
  if command -v pg_isready >/dev/null 2>&1; then
    pg_isready -h localhost -q
  fi

  log "Verifying Mosquitto (MQTT)"
  if command -v mosquitto_sub >/dev/null 2>&1; then
    timeout 5 mosquitto_sub -h localhost -p 1883 -t '$SYS/broker/version' -C 1 >/dev/null \
      || warn "mosquitto_sub test failed — check: journalctl -u mosquitto"
  fi
}

print_summary() {
  local db_url="ecto://${ALONA_DB_USER}:${ALONA_DB_PASSWORD}@localhost/${ALONA_DB_NAME}"

  cat <<EOF

Alona OS Pi host setup complete.

Services:
  postgresql   systemctl status postgresql
  mosquitto    systemctl status mosquitto   (MQTT port 1883)

Database:
  DATABASE_URL=${db_url}

MQTT (local broker):
  ALONA_MQTT_HOST=localhost
  ALONA_MQTT_PORT=1883

Env file:
  /etc/alona/alona.env

Next steps:
  1. Clone alona-os-core onto the Pi (e.g. /home/alona/alona-os-core).
  2. Set SECRET_KEY_BASE in /etc/alona/alona.env (mix phx.gen.secret).
  3. From alona-os-core: MIX_ENV=prod mix deps.get && mix compile && mix ecto.create && mix ecto.migrate
  4. Optional: copy systemd/alona-ui.service.example → /etc/systemd/system/alona-ui.service

Repo layout: host setup lives in alona-os-infra; application code in alona-os-core.

EOF
}

main() {
  require_root
  detect_os
  apt_install
  check_elixir_version
  setup_postgresql
  ensure_mosquitto_running
  maybe_create_deploy_user
  install_env_template
  verify_services
  print_summary
}

main "$@"
