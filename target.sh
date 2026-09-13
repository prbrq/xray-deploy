#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

die(){ echo "ERROR: $*" >&2; exit 1; }

PINNED_XRAY_IMAGE="ghcr.io/xtls/xray-core@sha256:3629bf7d825748cda29698ac354f8f2146f6b292edb9eb0c7cb7fe0583dae091"
XRAY_IMAGE="${XRAY_IMAGE:-$PINNED_XRAY_IMAGE}"

normalize_target() {
  local value="$1"
  if [[ "$value" =~ ^[Hh][Tt][Tt][Pp][Ss]:// ]]; then
    value="${value:${#BASH_REMATCH[0]}}"
  fi
  while [[ "$value" == */ ]]; do value="${value%/}"; done
  printf '%s' "$value"
}

valid_hostname() {
  local value="$1"
  [[ ${#value} -le 253 ]] || return 1
  [[ "$value" != *..* && "$value" != .* && "$value" != *. ]] || return 1
  [[ ! "$value" =~ ^[0-9.]+$ ]] || return 1
  [[ "$value" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

require_checker() {
  [[ "${EUID}" -eq 0 ]] || die "Run ./target.sh as root (or with sudo)."
  command -v docker >/dev/null 2>&1 || die "Docker Engine is required. On a supported VPS run ./install-docker.sh as root, then retry."
  command -v python3 >/dev/null 2>&1 || die "python3 is required. Install it with the OS package manager, then retry."
  command -v getent >/dev/null 2>&1 || die "The getent command is required for a DNS check. Install the libc utilities for this VPS, then retry."
  docker info >/dev/null 2>&1 || die "Docker daemon is unavailable. Start Docker or repair its installation, then retry."

  if ! docker image inspect "$XRAY_IMAGE" >/dev/null 2>&1; then
    echo "Preparing the pinned Xray image for the TLS check..." >&2
    docker pull "$XRAY_IMAGE" >/dev/null || die "Could not download the pinned Xray image. Check Docker, DNS and outbound HTTPS access, then retry."
  fi
}

show_guidance() {
  cat >&2 <<'EOF'
== REALITY target assistant ==

The target is your decision. This assistant does not search for or recommend hostnames;
it only explains the criteria and tests a hostname that you explicitly provide.

Choose a stable public HTTPS hostname that:
  - accepts TLS on TCP/443 and is reachable from this VPS;
  - has a certificate and SNI that complete a normal TLS handshake;
  - is suitable for the VPS network and expected to remain stable;
  - is chosen deliberately, rather than copied from a generic CDN list.

How to search:
  1. Start with the network context of your VPS: provider, region and ASN.
  2. Independently research stable HTTPS services relevant to that context.
  3. Submit one candidate at a time; a passing check only means that it works from
     this VPS now, not that it is the best choice or guaranteed to stay available.

Enter only a hostname or https://hostname/. Paths, query parameters and ports are not supported.
Keep the target/SNI private: do not put it into Git, tickets, chats or logs.
EOF
}

prompt_candidate() {
  [[ -t 0 ]] || die "An interactive terminal is required to enter a REALITY target."
  local value
  printf '\nREALITY target hostname or https:// URL: ' >&2
  IFS= read -r value || die "Could not read the REALITY target."
  CANDIDATE="$value"
}

check_dns() {
  getent ahosts "$1" >/dev/null 2>&1
}

check_tcp() {
  REALITY_TARGET="$1" python3 - <<'PY'
import os
import socket
import sys
import time

host = os.environ["REALITY_TARGET"]
deadline = time.monotonic() + 10
try:
    addresses = socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)
except OSError:
    sys.exit(1)

for family, socktype, protocol, _, sockaddr in addresses:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        break
    try:
        with socket.socket(family, socktype, protocol) as connection:
            connection.settimeout(min(remaining, 5))
            connection.connect(sockaddr)
        sys.exit(0)
    except OSError:
        pass
sys.exit(1)
PY
}

check_tls() {
  local candidate="$1" output
  output="$(mktemp)"
  if ! docker run --rm "$XRAY_IMAGE" tls ping "$candidate" >"$output" 2>&1; then
    rm -f -- "$output"
    return 1
  fi
  if awk '/Pinging with SNI/ {in_sni=1; next} in_sni && /Handshake succeeded/ {ok=1} END {exit(ok ? 0 : 1)}' "$output"; then
    rm -f -- "$output"
    return 0
  fi
  rm -f -- "$output"
  return 1
}

check_candidate() {
  local candidate
  candidate="$(normalize_target "$1")"
  if ! valid_hostname "$candidate"; then
    echo "CHECK: The supplied value is not a supported public hostname. Use a hostname or an HTTPS URL without a path or port." >&2
    return 1
  fi

  echo "Checking DNS resolution..." >&2
  if ! check_dns "$candidate"; then
    echo "CHECK: The supplied hostname does not resolve from this VPS. Check DNS or try another candidate." >&2
    return 1
  fi

  echo "Checking outbound TCP/443..." >&2
  if ! check_tcp "$candidate"; then
    echo "CHECK: This VPS could not reach the candidate on TCP/443. Check outbound connectivity or try another candidate." >&2
    return 1
  fi

  echo "Checking the TLS handshake with Xray..." >&2
  if ! check_tls "$candidate"; then
    echo "CHECK: The candidate did not complete the required TLS handshake with its SNI. Try another stable HTTPS hostname." >&2
    return 1
  fi

  VERIFIED_TARGET="$candidate"
  echo "OK: The candidate passed the current DNS, TCP/443 and Xray TLS checks." >&2
}

choose() {
  show_guidance
  require_checker
  while true; do
    prompt_candidate
    if check_candidate "$CANDIDATE"; then
      echo "This command did not change the deployment. Run ./bootstrap.sh when you are ready to use a target." >&2
      return 0
    fi
    printf 'Try another candidate? [Y/n]: ' >&2
    local answer
    IFS= read -r answer || return 1
    case "$answer" in
      n|N|no|NO|No) return 1 ;;
    esac
  done
}

check_once() {
  require_checker
  prompt_candidate
  check_candidate "$CANDIDATE"
}

select_for_bootstrap() {
  show_guidance
  require_checker
  while true; do
    prompt_candidate
    if check_candidate "$CANDIDATE"; then
      printf 'Use this verified target for the deployment? [y/N]: ' >&2
      local answer
      IFS= read -r answer || return 1
      case "$answer" in
        y|Y|yes|YES|Yes)
          printf '%s\n' "$VERIFIED_TARGET"
          return 0
          ;;
      esac
    fi
    printf 'Try another candidate? [Y/n]: ' >&2
    local retry
    IFS= read -r retry || return 1
    case "$retry" in
      n|N|no|NO|No) return 1 ;;
    esac
  done
}

check_from_environment() {
  require_checker
  [[ -n "${REALITY_TARGET:-}" ]] || die "No configured REALITY target is available for checking."
  check_candidate "$REALITY_TARGET"
}

usage() {
  cat >&2 <<'EOF'
Usage:
  ./target.sh choose
  ./target.sh check
EOF
  exit 1
}

case "${1:-choose}" in
  choose)
    [[ "$#" -eq 1 || "$#" -eq 0 ]] || usage
    choose
    ;;
  check)
    [[ "$#" -eq 1 ]] || usage
    check_once
    ;;
  --select-for-bootstrap)
    [[ "$#" -eq 1 ]] || usage
    select_for_bootstrap
    ;;
  --check-from-environment)
    [[ "$#" -eq 1 ]] || usage
    check_from_environment
    ;;
  *)
    usage
    ;;
esac
