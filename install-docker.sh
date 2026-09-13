#!/usr/bin/env bash
set -Eeuo pipefail

die(){ echo "ERROR: $*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Run ./install-docker.sh as root."
command -v apt-get >/dev/null 2>&1 || die "Only Ubuntu and Debian with apt are supported."
command -v dpkg >/dev/null 2>&1 || die "dpkg is required."
command -v systemctl >/dev/null 2>&1 || die "A systemd-based host is required."
[[ -r /etc/os-release ]] || die "/etc/os-release is required."

# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
  ubuntu)
    CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    REPOSITORY_DISTRO="ubuntu"
    case "$CODENAME" in jammy|noble|resolute) ;; *) die "Unsupported Ubuntu release: ${VERSION:-unknown}." ;; esac
    ;;
  debian)
    CODENAME="${VERSION_CODENAME:-}"
    REPOSITORY_DISTRO="debian"
    case "$CODENAME" in bookworm|trixie) ;; *) die "Unsupported Debian release: ${VERSION:-unknown}." ;; esac
    ;;
  *)
    die "Unsupported distribution '${ID:-unknown}'. Supported: Ubuntu 22.04/24.04/26.04 and Debian 12/13."
    ;;
esac

ARCHITECTURE="$(dpkg --print-architecture)"
case "$ARCHITECTURE" in amd64|arm64) ;; *) die "Unsupported architecture '$ARCHITECTURE'. Supported: amd64 and arm64." ;; esac

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  systemctl enable --now docker
  docker info >/dev/null || die "Docker is installed but the daemon is unavailable."
  echo "Docker Engine and Compose v2 are already available."
  exit 0
fi

conflicts=()
for package in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
  if dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -qx installed; then
    conflicts+=("$package")
  fi
done
((${#conflicts[@]} == 0)) || die "Conflicting packages found: ${conflicts[*]}. Remove them manually before installing Docker Engine."

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl openssl python3
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://download.docker.com/linux/$REPOSITORY_DISTRO/gpg" -o /etc/apt/keyrings/docker.asc
chmod 0644 /etc/apt/keyrings/docker.asc
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/$REPOSITORY_DISTRO
Suites: $CODENAME
Components: stable
Architectures: $ARCHITECTURE
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
docker info >/dev/null || die "Docker daemon did not become available."
docker --version
docker compose version
echo "Docker Engine and Compose v2 are ready."
