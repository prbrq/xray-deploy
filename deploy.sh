#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
die(){ echo "ERROR: $*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || die "Run ./deploy.sh as root (or with sudo)."
command -v docker >/dev/null 2>&1 || die "Docker Engine is not available. On a supported VPS run ./install-docker.sh as root, then rerun ./deploy.sh."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 plugin is not available. On a supported VPS run ./install-docker.sh as root, then rerun ./deploy.sh."
command -v python3 >/dev/null 2>&1 || die "python3 is required. Install it with the OS package manager, then rerun ./deploy.sh."
[[ -f .env ]] || die ".env not found. Restore it from a protected backup or run ./bootstrap.sh before deploying."
[[ -f config.json.template ]] || die "config.json.template is missing. Restore the trusted deployment files before deploying."
[[ -f profiles.py ]] || die "profiles.py is missing. Restore the trusted deployment files before deploying."
set -a
source .env
set +a
for name in XRAY_IMAGE CLIENT_UUID REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID REALITY_TARGET REALITY_SNI SERVER_ADDRESS CLIENT_FINGERPRINT; do
  [[ -n "${!name:-}" ]] || die "$name is empty in .env. Restore the protected credentials backup or correct the local file; do not publish its contents."
done
PROFILES_FILE="${PROFILES_FILE:-profiles.json}"
[[ "$PROFILES_FILE" != */* && "$PROFILES_FILE" != "." && "$PROFILES_FILE" != ".." ]] || die "PROFILES_FILE must name a file in the deployment directory."
python3 ./profiles.py --file "$PROFILES_FILE" ensure "$CLIENT_UUID"
CLIENTS_JSON="$(python3 ./profiles.py --file "$PROFILES_FILE" clients)"
export CLIENTS_JSON

echo "Rendering config.json..."
python3 - <<'PY2'
import json
import os
from pathlib import Path
required = ["CLIENTS_JSON", "REALITY_PRIVATE_KEY", "REALITY_SHORT_ID", "REALITY_TARGET", "REALITY_SNI"]
src = Path("config.json.template").read_text(encoding="utf-8")
for name in required:
    src = src.replace("${" + name.removesuffix("_JSON") + "}", os.environ[name])
if "${" in src:
    raise SystemExit("Unresolved template variable remains in config.json")
try:
    json.loads(src)
except json.JSONDecodeError as exc:
    raise SystemExit(f"Rendered config.json is invalid JSON: {exc}") from exc
Path("config.json").write_text(src, encoding="utf-8")
PY2
XRAY_UID="$(docker image inspect --format '{{.Config.User}}' "$XRAY_IMAGE")"
[[ "$XRAY_UID" =~ ^[1-9][0-9]*$ ]] || die "Xray image must define a numeric non-root default user."
chown "$XRAY_UID:$XRAY_UID" config.json
chmod 600 config.json .env "$PROFILES_FILE"

echo "Validating Xray configuration..."
if ! docker run --rm -v "$PWD/config.json:/etc/xray/config.json:ro" "$XRAY_IMAGE" run -test -c /etc/xray/config.json >/dev/null; then
  die "Xray rejected the rendered configuration. Restore the trusted template or profile registry, then rerun ./deploy.sh; do not publish config.json."
fi

echo "Starting Xray..."
if ! docker compose up -d --force-recreate; then
  die "Docker Compose could not start Xray. Check that TCP/443 is free and the Docker daemon is running, then rerun ./deploy.sh."
fi
sleep 1
if ! docker inspect -f '{{.State.Running}}' xray-reality 2>/dev/null | grep -qx true; then
  die "Xray container did not stay running. Inspect its logs locally with 'docker logs --tail 100 xray-reality', correct the issue, then rerun ./deploy.sh. Do not publish the logs."
fi

echo
docker compose ps
if command -v ss >/dev/null 2>&1; then
  echo
  echo "TCP/443 listeners:"
  ss -ltn 2>/dev/null | grep -E '(^|[[:space:]])[^[:space:]]*:443[[:space:]]' || echo "WARNING: ss did not show a TCP/443 listener. Check 'docker compose ps' and whether another service owns TCP/443."
fi

echo
echo "Xray is running. To print the OneXray profile in a private terminal, run: ./profile.sh"
