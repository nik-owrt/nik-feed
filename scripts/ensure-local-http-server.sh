#!/usr/bin/env bash
set -euo pipefail

feed_root="${NIK_LOCAL_FEED_ROOT:-$HOME/nik-owrt-feed}"
bind="${NIK_LOCAL_FEED_BIND:-0.0.0.0:8080}"
container="${NIK_LOCAL_FEED_CONTAINER:-nik-local-feed}"
image="${NIK_LOCAL_FEED_HTTP_IMAGE:-nginx:1.29-alpine}"
served="$feed_root/served"

command -v docker >/dev/null || { echo 'docker is required' >&2; exit 1; }
[[ "$bind" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$ ]] || {
  echo "NIK_LOCAL_FEED_BIND must be IPv4:port, got: $bind" >&2
  exit 1
}
mkdir -p "$served"
served="$(readlink -f "$served")"

docker image inspect "$image" >/dev/null 2>&1 || docker pull "$image" >/dev/null

if docker container inspect "$container" >/dev/null 2>&1; then
  current_image="$(docker container inspect --format '{{.Config.Image}}' "$container")"
  current_bind="$(docker container inspect --format '{{with (index .HostConfig.PortBindings "80/tcp")}}{{(index . 0).HostIp}}:{{(index . 0).HostPort}}{{end}}' "$container")"
  current_mount="$(docker container inspect --format '{{range .Mounts}}{{if eq .Destination "/usr/share/nginx/html"}}{{.Source}}{{end}}{{end}}' "$container")"
  [[ "$current_bind" == ":${bind##*:}" ]] && current_bind="0.0.0.0:${bind##*:}"
  if [[ "$current_image" == "$image" && "$current_bind" == "$bind" && "$current_mount" == "$served" ]]; then
    docker update --restart unless-stopped "$container" >/dev/null
    [[ "$(docker container inspect --format '{{.State.Running}}' "$container")" == true ]] || docker start "$container" >/dev/null
    printf 'local feed HTTP server already configured: http://%s/\n' "$bind"
    exit 0
  fi
  docker rm -f "$container" >/dev/null
fi

docker run -d \
  --name "$container" \
  --restart unless-stopped \
  --label org.nik-link.role=local-opkg-feed \
  -p "$bind:80" \
  --mount "type=bind,src=$served,dst=/usr/share/nginx/html,readonly" \
  "$image" >/dev/null

printf 'local feed HTTP server ready: http://%s/\n' "$bind"
printf 'served root: %s\n' "$served"
printf 'configure Windows/LAN firewall to allow this port only from the trusted LAN.\n'
