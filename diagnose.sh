#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

die(){ echo "ERROR: $*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || die "Run ./diagnose.sh as root (or with sudo)."

problems=0
ok() { echo "OK: $*"; }
problem() { echo "CHECK: $*"; problems=$((problems + 1)); }

echo "Xray local diagnostic report (no credentials are displayed)"

if [[ ! -f docker-compose.yml || -L docker-compose.yml ]]; then
  die "docker-compose.yml must be a regular file. Restore trusted deployment files before diagnosing the service."
fi

if ! command -v docker >/dev/null 2>&1; then
  problem "Docker command is unavailable. On a supported VPS run ./install-docker.sh as root, then rerun ./diagnose.sh."
elif ! docker info >/dev/null 2>&1; then
  problem "Docker daemon is unavailable. Start Docker or repair its installation, then rerun ./diagnose.sh."
else
  if docker compose version >/dev/null 2>&1; then
    ok "Docker Compose is available."
  else
    problem "Docker Compose plugin is unavailable. Repair the Docker installation, then rerun ./diagnose.sh."
  fi

  if docker compose config -q >/dev/null 2>&1; then
    ok "Compose definition resolves."
  else
    problem "Compose definition does not resolve. Check local deployment files and run ./status.sh for safe configuration checks."
  fi

  service_state="$(docker inspect --format '{{.State.Status}}' xray-reality 2>/dev/null || true)"
  if [[ -z "$service_state" ]]; then
    problem "Container xray-reality is absent. Run ./deploy.sh to create and start it."
  else
    restart_count="$(docker inspect --format '{{.RestartCount}}' xray-reality 2>/dev/null || true)"
    if [[ "$service_state" == "running" ]]; then
      ok "Container xray-reality is running (restart count: ${restart_count:-unknown})."
    else
      problem "Container xray-reality state is '$service_state' (restart count: ${restart_count:-unknown}). Inspect its logs locally: docker logs --tail 100 xray-reality"
    fi

    published_port="$(docker inspect --format '{{range $port, $bindings := .HostConfig.PortBindings}}{{if eq $port "443/tcp"}}{{range $bindings}}{{if eq .HostPort "443"}}published{{end}}{{end}}{{end}}{{end}}' xray-reality 2>/dev/null || true)"
    if [[ "$published_port" == "published" ]]; then
      ok "Container publishes TCP/443."
    else
      problem "Container does not publish TCP/443. Restore docker-compose.yml and run ./deploy.sh."
    fi
  fi
fi

if command -v ss >/dev/null 2>&1; then
  listeners="$(ss -ltnH 'sport = :443' 2>/dev/null || true)"
  if [[ -n "$listeners" ]]; then
    ok "A local TCP/443 listener is present."
  else
    problem "No local TCP/443 listener is present. Check the container state, then inspect its logs locally."
  fi
else
  problem "The 'ss' command is unavailable. Install the iproute2 package to check the local TCP/443 listener."
fi

if (( problems > 0 )); then
  echo "Result: $problems local check(s) need attention. No credentials or logs were displayed." >&2
  exit 1
fi

echo "Result: Compose, container, published TCP/443 and local listener are OK."
echo "If clients still cannot connect, verify inbound TCP/443 in both the VPS firewall and the provider firewall."