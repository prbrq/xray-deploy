#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
die(){ echo "ERROR: $*" >&2; exit 1; }
prompt(){
  local var_name="$1" message="$2" default="${3:-}" value=""
  if [[ ! -t 0 ]]; then
    [[ -n "$default" ]] || die "$var_name is required in non-interactive mode."
    printf -v "$var_name" '%s' "$default"
    return
  fi
  if [[ -n "$default" ]]; then
    read -r -p "$message [$default]: " value
    value="${value:-$default}"
  else
    read -r -p "$message: " value
  fi
  printf -v "$var_name" '%s' "$value"
}
valid_hostname(){ [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]] && [[ "$1" != .* ]] && [[ "$1" != *..* ]]; }
normalize_reality_target(){
  local value="$1"
  if [[ "$value" =~ ^[Hh][Tt][Tt][Pp][Ss]:// ]]; then
    value="${value:${#BASH_REMATCH[0]}}"
  fi
  while [[ "$value" == */ ]]; do value="${value%/}"; done
  printf '%s' "$value"
}

[[ "${EUID}" -eq 0 ]] || die "Run ./bootstrap.sh as root (or with sudo)."

echo "== xray-deploy bootstrap =="
echo "[1/5] Checking prerequisites..."

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  die "Docker Engine with Compose v2 is required. On supported Ubuntu/Debian run ./install-docker.sh as root, then rerun ./bootstrap.sh."
fi
command -v openssl >/dev/null 2>&1 || die "openssl is required. Install it with the OS package manager, then rerun ./bootstrap.sh."
command -v python3 >/dev/null 2>&1 || die "python3 is required. Install it with the OS package manager, then rerun ./bootstrap.sh."
command -v curl >/dev/null 2>&1 || die "curl is required. Install it with the OS package manager, then rerun ./bootstrap.sh."
[[ -f profiles.py ]] || die "profiles.py is missing. Restore the trusted deployment files before running bootstrap."

HAS_GIT=0
REPOSITORY="unknown"; REVISION="unknown"
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  HAS_GIT=1
  REPOSITORY="$(git config --get remote.origin.url || true)"; REPOSITORY="${REPOSITORY:-unknown}"
  REVISION="$(git rev-parse HEAD || true)"; REVISION="${REVISION:-unknown}"
fi

if [[ -f .env ]]; then
  echo "Existing .env found; existing credentials will be reused."
  set -a; source .env; set +a
else
  XRAY_IMAGE="ghcr.io/xtls/xray-core@sha256:3629bf7d825748cda29698ac354f8f2146f6b292edb9eb0c7cb7fe0583dae091"
  CLIENT_UUID=""; REALITY_PRIVATE_KEY=""; REALITY_PUBLIC_KEY=""; REALITY_SHORT_ID=""
  REALITY_TARGET=""; REALITY_SNI=""; SERVER_ADDRESS=""; CLIENT_FINGERPRINT="firefox"
fi
XRAY_IMAGE="${XRAY_IMAGE:-ghcr.io/xtls/xray-core@sha256:3629bf7d825748cda29698ac354f8f2146f6b292edb9eb0c7cb7fe0583dae091}"
CLIENT_FINGERPRINT="${CLIENT_FINGERPRINT:-firefox}"

echo "[2/5] Preparing pinned Xray image..."
if ! docker pull "$XRAY_IMAGE" >/dev/null; then
  die "Could not download the pinned Xray image. Check the Docker daemon, DNS and outbound HTTPS access, then rerun ./bootstrap.sh."
fi

if [[ -z "${CLIENT_UUID:-}" ]]; then
  echo "Preparing initial VLESS access credentials..."
  if ! CLIENT_UUID="$(docker run --rm "$XRAY_IMAGE" uuid | tail -n 1 | tr -d '\r')" || [[ -z "$CLIENT_UUID" ]]; then
    die "Could not create the initial profile UUID. Check that the pinned image runs in Docker, then rerun ./bootstrap.sh."
  fi
fi

if [[ -z "${REALITY_PRIVATE_KEY:-}" || -z "${REALITY_PUBLIC_KEY:-}" ]]; then
  echo "Preparing REALITY credentials..."
  if ! key_output="$(docker run --rm "$XRAY_IMAGE" x25519)"; then
    die "Could not generate REALITY credentials. Check that the pinned image runs in Docker, then rerun ./bootstrap.sh."
  fi
  REALITY_PRIVATE_KEY="$(printf '%s\n' "$key_output" | awk -F': ' '/^PrivateKey:/ {print $2; exit}')"
  REALITY_PUBLIC_KEY="$(printf '%s\n' "$key_output" | awk -F': ' '/^Password \(PublicKey\):/ {print $2; found=1; exit} /^Password:/ {candidate=$2} END {if (!found && candidate != "") print candidate}')"
  [[ -n "$REALITY_PRIVATE_KEY" ]] || die "Could not parse the generated REALITY private key. Verify the pinned image, then rerun ./bootstrap.sh."
  [[ -n "$REALITY_PUBLIC_KEY" ]] || die "Could not parse the generated REALITY public key. Verify the pinned image, then rerun ./bootstrap.sh."
fi

if [[ -z "${REALITY_SHORT_ID:-}" ]]; then
  echo "Preparing REALITY short ID..."
  REALITY_SHORT_ID="$(openssl rand -hex 8)"
fi

if [[ -z "${SERVER_ADDRESS:-}" ]]; then
  detected_ip="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  prompt SERVER_ADDRESS "Public server IP/hostname used by OneXray" "$detected_ip"
fi
[[ -n "$SERVER_ADDRESS" ]] || die "SERVER_ADDRESS is required."


echo "[3/5] Configuring REALITY target..."
if [[ -z "${REALITY_TARGET:-}" ]]; then
  echo
  echo "Choose a stable HTTPS REALITY target for this VPS."
  echo "Prefer a suitable host near/in the same ASN and avoid generic CDN targets."
  prompt REALITY_TARGET "REALITY target hostname or https:// URL"
fi
REALITY_TARGET="$(normalize_reality_target "$REALITY_TARGET")"
valid_hostname "$REALITY_TARGET" || die "Invalid REALITY_TARGET. Enter a hostname or an HTTPS URL without a path or port."
REALITY_SNI="${REALITY_SNI:-$REALITY_TARGET}"
valid_hostname "$REALITY_SNI" || die "Invalid REALITY_SNI hostname: $REALITY_SNI"
case "$CLIENT_FINGERPRINT" in firefox|safari|chrome|edge|ios|android|random|randomized) ;; *) die "Unsupported CLIENT_FINGERPRINT '$CLIENT_FINGERPRINT'. Set it to a supported value in .env, then rerun ./bootstrap.sh." ;; esac

echo
echo "[4/5] Verifying the REALITY target TLS handshake..."
tls_output="$(mktemp)"; trap 'rm -f "$tls_output"' EXIT
if ! docker run --rm "$XRAY_IMAGE" tls ping "$REALITY_TARGET" | tee "$tls_output"; then
  die "REALITY target check could not start. Check DNS and outbound HTTPS access, then rerun ./bootstrap.sh."
fi
if ! awk '/Pinging with SNI/ {in_sni=1; next} in_sni && /Handshake succeeded/ {ok=1} END {exit(ok ? 0 : 1)}' "$tls_output"; then
  die "REALITY target did not complete a TLS handshake with its SNI. Choose another stable HTTPS host and rerun ./bootstrap.sh."
fi

cat > .env <<EOF
XRAY_IMAGE=$XRAY_IMAGE
CLIENT_UUID=$CLIENT_UUID
REALITY_PRIVATE_KEY=$REALITY_PRIVATE_KEY
REALITY_PUBLIC_KEY=$REALITY_PUBLIC_KEY
REALITY_SHORT_ID=$REALITY_SHORT_ID
REALITY_TARGET=$REALITY_TARGET
REALITY_SNI=$REALITY_SNI
SERVER_ADDRESS=$SERVER_ADDRESS
CLIENT_FINGERPRINT=$CLIENT_FINGERPRINT
EOF
chmod 600 .env
python3 ./profiles.py ensure "$CLIENT_UUID"
chmod 600 profiles.json

echo
echo "[5/5] Deploying Xray..."
if ! ./deploy.sh; then
  die "Deployment did not complete. Correct the error above, then rerun ./bootstrap.sh; existing credentials in .env will be reused."
fi

if [[ "$HAS_GIT" -eq 1 || ! -f DEPLOYED_FROM ]]; then
  deployed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  cat > DEPLOYED_FROM <<EOF
repository: $REPOSITORY
revision: $REVISION
deployed_at_utc: $deployed_at
hostname: $(hostname)
xray_image: $XRAY_IMAGE
stack: VLESS + RAW + xtls-rprx-vision + REALITY
client_fingerprint: $CLIENT_FINGERPRINT
EOF
fi

if [[ -d .git ]]; then
  echo
  echo "Deployment succeeded. Detaching this VPS from the template repository..."
  rm -rf .git
  echo ".git removed."
fi

echo
echo "Bootstrap complete."
echo "Deployment provenance: $PWD/DEPLOYED_FROM"
echo "Secrets/config:       $PWD/.env and $PWD/config.json (0600)"
echo
echo "Next steps:"
echo "  Check the container:     docker compose ps"
echo "  Get the profile safely:  ./profile.sh"
echo "  View service logs:       docker logs -f xray-reality"
echo "  Apply local changes:     ./deploy.sh"
