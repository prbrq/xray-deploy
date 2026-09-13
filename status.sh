#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

die(){ echo "ERROR: $*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || die "Run ./status.sh as root (or with sudo)."

problems=0
ok() { echo "OK: $*"; }
problem() { echo "CHECK: $*"; problems=$((problems + 1)); }

check_private_regular_file() {
  local file="$1"
  local mode

  if [[ -L "$file" || ! -f "$file" ]]; then
    problem "$file must be a regular file. Restore it from a protected backup or run ./bootstrap.sh if this is a new deployment."
    return
  fi

  mode="$(stat -c '%a' -- "$file")"
  if [[ "$mode" == "600" ]]; then
    ok "$file is a regular file with permissions 0600."
  else
    problem "$file permissions are $mode, expected 0600. Restrict access with: chmod 600 $file"
  fi
}

config_clients=""
check_rendered_config() {
  local result

  if [[ -L config.json || ! -f config.json ]]; then
    problem "config.json must be a regular file. Run ./deploy.sh to render the configuration."
    return
  fi

  if ! result="$(python3 - <<'PY' 2>/dev/null
import json

with open("config.json", encoding="utf-8") as handle:
    config = json.load(handle)

inbounds = config.get("inbounds")
if not isinstance(inbounds, list):
    raise ValueError("inbounds is missing")

vless = next((item for item in inbounds if item.get("protocol") == "vless"), None)
if not isinstance(vless, dict) or vless.get("port") != 443:
    raise ValueError("VLESS inbound on TCP/443 is missing")

settings = vless.get("settings")
stream = vless.get("streamSettings")
clients = settings.get("clients") if isinstance(settings, dict) else None
if settings.get("decryption") != "none" or not isinstance(clients, list) or not clients:
    raise ValueError("VLESS client settings are invalid")
if not isinstance(stream, dict) or stream.get("method") != "raw" or stream.get("security") != "reality":
    raise ValueError("RAW/TCP + REALITY stream settings are invalid")
if not isinstance(stream.get("realitySettings"), dict):
    raise ValueError("REALITY settings are missing")
if any(client.get("flow") != "xtls-rprx-vision" for client in clients if isinstance(client, dict)):
    raise ValueError("a client flow is invalid")
if any(not isinstance(client, dict) for client in clients):
    raise ValueError("a client entry is invalid")

print(len(clients))
PY
)"; then
    problem "config.json is not a valid rendered VLESS + RAW/TCP + REALITY configuration. Run ./deploy.sh after correcting local deployment files."
    return
  fi

  config_clients="$result"
  ok "config.json has the expected VLESS + RAW/TCP + REALITY structure on TCP/443."
}

echo "Configuration status (no credentials are displayed)"

command -v python3 >/dev/null 2>&1 || die "python3 is required. Install it with the OS package manager, then rerun ./status.sh."
[[ -f profiles.py ]] || die "profiles.py is missing. Restore trusted deployment files before checking status."

check_private_regular_file .env
check_private_regular_file config.json
check_private_regular_file profiles.json

profile_count=""
if [[ -f profiles.json && ! -L profiles.json ]] && profile_count="$(python3 ./profiles.py list 2>/dev/null | wc -l)"; then
  ok "Profile registry is valid: $profile_count active profile(s)."
else
  problem "profiles.json is invalid or cannot be read safely. Restore a protected backup; do not weaken its permissions."
fi

check_rendered_config
if [[ -n "$profile_count" && -n "$config_clients" ]]; then
  if [[ "$profile_count" == "$config_clients" ]]; then
    ok "Rendered configuration and profile registry contain the same number of profiles."
  else
    problem "Rendered configuration and profile registry differ. Run ./deploy.sh to apply the current registry."
  fi
fi

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if docker compose config -q >/dev/null 2>&1; then
    ok "Compose definition resolves without displaying configuration values."
  else
    problem "Compose definition does not resolve. Check local deployment files, then run ./deploy.sh after correcting them."
  fi

  service_state="$(docker inspect --format '{{.State.Status}}' xray-reality 2>/dev/null || true)"
  if [[ "$service_state" == "running" ]]; then
    ok "Xray service is running."
  elif [[ -n "$service_state" ]]; then
    problem "Xray service state is '$service_state'. Run ./diagnose.sh for local checks, then inspect logs locally if needed."
  else
    problem "Xray container is not present. Run ./deploy.sh to create and start it."
  fi
else
  problem "Docker daemon is unavailable. Start Docker or repair its installation, then rerun ./status.sh."
fi

if (( problems > 0 )); then
  echo "Result: $problems item(s) need attention. No credentials were displayed." >&2
  exit 1
fi

echo "Result: local configuration and service status are OK. No credentials were displayed."