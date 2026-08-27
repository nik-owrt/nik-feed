#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$repo_root/scripts/ensure-local-http-server.sh"
config="$repo_root/config/nginx-local-feed.conf"

[[ -f "$config" ]]
grep -Fq 'root /srv/nik-feed/served;' "$config"
grep -Fq 'dst=/srv/nik-feed,readonly' "$helper"
grep -Fq 'dst=/etc/nginx/conf.d/default.conf,readonly' "$helper"
! grep -Fq 'dst=/usr/share/nginx/html,readonly' "$helper"

echo 'local HTTP contract test: PASS'
