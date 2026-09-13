#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
die(){ echo "ERROR: $*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || die "Run ./profile.sh as root (or with sudo)."
[[ -f .env ]] || die ".env not found. Restore it from a protected backup or run ./bootstrap.sh first."
[[ -f profiles.py ]] || die "profiles.py is missing. Restore the trusted deployment files before managing profiles."
command -v python3 >/dev/null 2>&1 || die "python3 is required. Install it with the OS package manager, then rerun ./profile.sh."
set -a
source .env
set +a
for name in XRAY_IMAGE SERVER_ADDRESS CLIENT_UUID REALITY_SNI REALITY_PUBLIC_KEY REALITY_SHORT_ID CLIENT_FINGERPRINT; do
  [[ -n "${!name:-}" ]] || die "$name is empty in .env. Restore the protected credentials backup or correct the local file; do not publish its contents."
done
python3 ./profiles.py ensure "$CLIENT_UUID"
chmod 600 .env profiles.json

print_uri() {
  local profile_name="$1"
  local profile_uuid
  profile_uuid="$(python3 ./profiles.py get "$profile_name")"
  PROFILE_NAME="$profile_name" PROFILE_UUID="$profile_uuid" python3 - <<'PY2'
import os
from urllib.parse import urlencode, quote
params = {
    "encryption": "none",
    "flow": "xtls-rprx-vision",
    "security": "reality",
    "sni": os.environ["REALITY_SNI"],
    "fp": os.environ["CLIENT_FINGERPRINT"],
    "pbk": os.environ["REALITY_PUBLIC_KEY"],
    "sid": os.environ["REALITY_SHORT_ID"],
    "type": "tcp",
}
address = os.environ["SERVER_ADDRESS"]
uuid = os.environ["PROFILE_UUID"]
name = os.environ["PROFILE_NAME"]
label = quote(f"Xray-REALITY-{name}-{address}")
print(f"vless://{uuid}@{address}:443?{urlencode(params)}#{label}")
PY2
}

apply_candidate() {
  local candidate="$1"
  if ! PROFILES_FILE="$candidate" ./deploy.sh; then
    echo "The profile registry was not changed; restoring the current rendered configuration..." >&2
    ./deploy.sh || echo "WARNING: Could not restore the current configuration automatically. Run ./deploy.sh after fixing the deployment error." >&2
    die "Profile change was not applied."
  fi
  mv -f -- "$candidate" profiles.json
}

usage() {
  cat >&2 <<'EOF'
Usage:
  ./profile.sh [show [NAME]]
  ./profile.sh list
  ./profile.sh add NAME
  ./profile.sh revoke NAME
EOF
  exit 1
}

command="${1:-show}"
case "$command" in
  show)
    [[ "$#" -le 2 ]] || usage
    print_uri "${2:-default}"
    ;;
  list)
    [[ "$#" -eq 1 ]] || usage
    echo "Profiles:"
    python3 ./profiles.py list | sed 's/^/  - /'
    ;;
  add)
    [[ "$#" -eq 2 ]] || usage
    command -v docker >/dev/null 2>&1 || die "Docker is not available. On a supported VPS run ./install-docker.sh as root, then retry adding the profile."
    candidate="$(mktemp .profiles.json.XXXXXX)"
    trap 'rm -f -- "$candidate"' EXIT
    chmod 600 "$candidate"
    cp --preserve=mode profiles.json "$candidate"
    if ! profile_uuid="$(docker run --rm "$XRAY_IMAGE" uuid | tail -n 1 | tr -d '\r')" || [[ -z "$profile_uuid" ]]; then
      die "Could not create a profile UUID. Check that the pinned image runs in Docker, then retry adding the profile."
    fi
    python3 ./profiles.py --file "$candidate" add "$2" "$profile_uuid"
    apply_candidate "$candidate"
    trap - EXIT
    echo "Profile '$2' added and applied. Print its URI only in a private terminal: ./profile.sh show '$2'"
    ;;
  revoke)
    [[ "$#" -eq 2 ]] || usage
    candidate="$(mktemp .profiles.json.XXXXXX)"
    trap 'rm -f -- "$candidate"' EXIT
    chmod 600 "$candidate"
    cp --preserve=mode profiles.json "$candidate"
    python3 ./profiles.py --file "$candidate" remove "$2"
    apply_candidate "$candidate"
    trap - EXIT
    echo "Profile '$2' revoked and applied. Other profiles and REALITY credentials were not changed."
    ;;
  *)
    usage
    ;;
esac
