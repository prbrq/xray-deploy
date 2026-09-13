#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
die(){ echo "ERROR: $*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || die "Run ./deploy.sh as root (or with sudo)."
command -v docker >/dev/null 2>&1 || die "Docker is not installed."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 plugin is not available."
command -v python3 >/dev/null 2>&1 || die "python3 is required."
[[ -f .env ]] || die ".env not found. Run ./bootstrap.sh first."
[[ -f config.json.template ]] || die "config.json.template not found."
set -a
source .env
set +a
for name in XRAY_IMAGE CLIENT_UUID REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID REALITY_TARGET REALITY_SNI SERVER_ADDRESS CLIENT_FINGERPRINT; do
  [[ -n "${!name:-}" ]] || die "$name is empty in .env"
done

echo "Rendering config.json..."
python3 - <<'PY2'
import os
from pathlib import Path
required = ["CLIENT_UUID","REALITY_PRIVATE_KEY","REALITY_SHORT_ID","REALITY_TARGET","REALITY_SNI"]
src = Path("config.json.template").read_text(encoding="utf-8")
for name in required:
    src = src.replace("${" + name + "}", os.environ[name])
if "${" in src:
    raise SystemExit("Unresolved template variable remains in config.json")
Path("config.json").write_text(src, encoding="utf-8")
PY2
XRAY_UID="$(docker image inspect --format '{{.Config.User}}' "$XRAY_IMAGE")"
[[ "$XRAY_UID" =~ ^[1-9][0-9]*$ ]] || die "Xray image must define a numeric non-root default user."
chown "$XRAY_UID:$XRAY_UID" config.json
chmod 600 config.json .env

echo "Validating Xray configuration..."
docker run --rm -v "$PWD/config.json:/etc/xray/config.json:ro" "$XRAY_IMAGE" run -test -c /etc/xray/config.json

echo "Starting Xray..."
docker compose up -d
sleep 1
if ! docker inspect -f '{{.State.Running}}' xray-reality 2>/dev/null | grep -qx true; then
  echo "Xray container failed to stay running." >&2
  docker logs --tail 100 xray-reality >&2 || true
  exit 1
fi

echo
docker compose ps
if command -v ss >/dev/null 2>&1; then
  echo
  echo "TCP/443 listeners:"
  ss -ltn 2>/dev/null | grep -E '(^|[[:space:]])[^[:space:]]*:443[[:space:]]' || echo "WARNING: ss did not show a TCP/443 listener."
fi

echo
echo "OneXray profile:"
./profile.sh
