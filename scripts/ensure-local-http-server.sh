#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
feed_root="${NIK_LOCAL_FEED_ROOT:-/mnt/d/nik-feed}"
bind="${NIK_LOCAL_FEED_BIND:-0.0.0.0:8080}"
container="${NIK_LOCAL_FEED_CONTAINER:-nik-local-feed}"
image="${NIK_LOCAL_FEED_HTTP_IMAGE:-nginx:1.29-alpine}"
served="$feed_root/served"
nginx_config="$repo_root/config/nginx-local-feed.conf"

command -v docker >/dev/null || { echo 'docker is required' >&2; exit 1; }
[[ "$bind" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$ ]] || {
  echo "NIK_LOCAL_FEED_BIND must be IPv4:port, got: $bind" >&2
  exit 1
}
mkdir -p "$served"
feed_root="$(readlink -f "$feed_root")"
[[ -s "$nginx_config" ]] || { echo "nginx feed config is missing: $nginx_config" >&2; exit 1; }

docker image inspect "$image" >/dev/null 2>&1 || docker pull "$image" >/dev/null

if docker container inspect "$container" >/dev/null 2>&1; then
  current_image="$(docker container inspect --format '{{.Config.Image}}' "$container")"
  current_bind="$(docker container inspect --format '{{with (index .HostConfig.PortBindings "80/tcp")}}{{(index . 0).HostIp}}:{{(index . 0).HostPort}}{{end}}' "$container")"
  current_mount="$(docker container inspect --format '{{range .Mounts}}{{if eq .Destination "/srv/nik-feed"}}{{.Source}}{{end}}{{end}}' "$container")"
  current_config="$(docker container inspect --format '{{range .Mounts}}{{if eq .Destination "/etc/nginx/conf.d/default.conf"}}{{.Source}}{{end}}{{end}}' "$container")"
  [[ "$current_bind" == ":${bind##*:}" ]] && current_bind="0.0.0.0:${bind##*:}"
  if [[ "$current_image" == "$image" && "$current_bind" == "$bind" && "$current_mount" == "$feed_root" && "$current_config" == "$nginx_config" ]]; then
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
  --mount "type=bind,src=$feed_root,dst=/srv/nik-feed,readonly" \
  --mount "type=bind,src=$nginx_config,dst=/etc/nginx/conf.d/default.conf,readonly" \
  "$image" >/dev/null

printf 'local feed HTTP server ready: http://%s/\n' "$bind"
printf 'served root: %s\n' "$served"
printf 'configure Windows/LAN firewall to allow this port only from the trusted LAN.\n'
