#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ "${EUID}" -eq 0 ]] || { echo "ERROR: Run ./profile.sh as root (or with sudo)." >&2; exit 1; }
[[ -f .env ]] || { echo "ERROR: .env not found. Run ./bootstrap.sh first." >&2; exit 1; }
set -a
source .env
set +a
for name in SERVER_ADDRESS CLIENT_UUID REALITY_SNI REALITY_PUBLIC_KEY REALITY_SHORT_ID CLIENT_FINGERPRINT; do
  [[ -n "${!name:-}" ]] || { echo "ERROR: $name is empty in .env" >&2; exit 1; }
done
python3 - <<'PY2'
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
uuid = os.environ["CLIENT_UUID"]
label = quote(f"Xray-REALITY-{address}")
print(f"vless://{uuid}@{address}:443?{urlencode(params)}#{label}")
PY2
