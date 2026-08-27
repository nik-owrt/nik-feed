#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package="${NIK_PUBLISH_PACKAGE:?NIK_PUBLISH_PACKAGE is required}"
source_dir="${NIK_PUBLISH_SOURCE_DIR:?NIK_PUBLISH_SOURCE_DIR is required}"
sdk_reference="${NIK_PUBLISH_SDK_REFERENCE:?NIK_PUBLISH_SDK_REFERENCE is required}"
channel="${NIK_PUBLISH_CHANNEL:-dev}"
openwrt_version="${NIK_PUBLISH_OPENWRT_VERSION:-24.10.4}"
feed_arch="${NIK_PUBLISH_PACKAGE_ARCH:-aarch64_cortex-a53}"
feed_root="${NIK_PUBLISH_FEED_ROOT:-${NIK_LOCAL_FEED_ROOT:-/mnt/d/nik-feed}}"
state_root="${NIK_PUBLISH_STATE_ROOT:-${NIK_LOCAL_FEED_STATE_ROOT:-/mnt/d/nik-feed-state}}"
signing_key_file="${NIK_PUBLISH_SIGNING_KEY_FILE:-${NIK_FEED_SIGNING_KEY_FILE:-$state_root/keys/nik-feed.key}}"
legacy_signing_key_file="${NIK_PUBLISH_LEGACY_SIGNING_KEY_FILE:-$HOME/.config/nik-feed/nik-feed.key}"
public_key_file="$repo_root/keys/nik-feed.pub"
packages_file="$repo_root/config/packages.txt"
lock_file="${NIK_PUBLISH_LOCK_FILE:-$state_root/locks/publish.lock}"

fail() {
  echo "local feed publish: $*" >&2
  exit 1
}

[[ "$package" =~ ^(br|fr)-[a-z0-9-]+$ ]] || fail "invalid package name: $package"
[[ "$sdk_reference" =~ ^ghcr\.io/nik-owrt/openwrt-sdk@sha256:[0-9a-f]{64}$ ]] || fail "invalid immutable SDK reference"
[[ -d "$source_dir" ]] || fail "package directory does not exist: $source_dir"
[[ -s "$packages_file" ]] || fail "missing package contract: $packages_file"
[[ -s "$public_key_file" ]] || fail "missing feed public key: $public_key_file"

for cmd in docker flock install python3; do
  command -v "$cmd" >/dev/null || fail "required command is missing: $cmd"
done

if [[ ! -s "$signing_key_file" ]]; then
  [[ -s "$legacy_signing_key_file" ]] || fail "missing feed signing key: $signing_key_file"
  mkdir -p "$(dirname "$signing_key_file")" || fail "cannot create signing key directory"
  umask 077
  install -m 0600 "$legacy_signing_key_file" "$signing_key_file"
fi

mapfile -t ipks < <(find "$source_dir" -maxdepth 1 -type f -name "${package}_*.ipk" -print | LC_ALL=C sort)
[[ "${#ipks[@]}" -eq 1 ]] || fail "expected exactly one ${package} IPK in ${source_dir}, found ${#ipks[@]}"
ipk="${ipks[0]}"
build_meta="$source_dir/package-build.json"
[[ -s "$build_meta" ]] || fail "missing package-build.json in $source_dir"

mapfile -t meta < <(python3 - "$build_meta" "$ipk" <<'PY'
import hashlib, json, sys
from pathlib import Path
meta_path = Path(sys.argv[1])
ipk = Path(sys.argv[2])
m = json.loads(meta_path.read_text())
artifacts = m.get("artifacts") or []
a = artifacts[0] if len(artifacts) == 1 else {}
print(m.get("package", ""))
print(m.get("sdk_reference", ""))
print(m.get("platform_build_id", ""))
print(a.get("file", ""))
print(a.get("sha256", ""))
print(hashlib.sha256(ipk.read_bytes()).hexdigest())
PY
)
[[ "${#meta[@]}" -eq 6 ]] || fail "cannot parse package-build.json"
meta_package="${meta[0]}"
meta_sdk="${meta[1]}"
meta_pbid="${meta[2]}"
meta_file="${meta[3]}"
meta_sha="${meta[4]}"
actual_sha="${meta[5]}"

[[ "$meta_package" == "$package" ]] || fail "package-build package mismatch"
[[ "$meta_sdk" == "$sdk_reference" ]] || fail "package-build SDK mismatch"
[[ "$meta_pbid" =~ ^[0-9a-f]{12}$ ]] || fail "package-build platform build id is invalid"
[[ "$meta_file" == "$(basename "$ipk")" && "$meta_sha" == "$actual_sha" ]] || fail "package-build artifact metadata mismatch"

docker image inspect "$sdk_reference" >/dev/null 2>&1 || docker pull "$sdk_reference" >/dev/null
sdk_pbid="$(docker image inspect --format '{{ index .Config.Labels "org.nik-link.platform-build-id" }}' "$sdk_reference")"
[[ "$sdk_pbid" == "$meta_pbid" ]] || fail "SDK/platform build id mismatch"

# The Windows D: feed and its private state are persistent WSL mounts.
mkdir -p "$feed_root" "$state_root/locks" || fail "cannot create feed/state directories"
probe="$feed_root/.nik-feed-write-probe.$$"
: > "$probe" || fail "feed root is not writable: $feed_root"
rm -f "$probe"

exec 9>"$lock_file"
flock 9

leaf_rel="$channel/$openwrt_version/$feed_arch"
release_parent="$feed_root/releases/$leaf_rel"
served_parent="$feed_root/served/$channel/$openwrt_version"
live="$served_parent/$feed_arch"
legacy_live="$feed_root/$leaf_rel"
mkdir -p "$release_parent" "$served_parent"
[[ ! -e "$live" || -L "$live" ]] || fail "live feed path is not a symlink: $live"

work="$(mktemp -d "$release_parent/.staging-${package}.XXXXXX")"
next_link=""
cleanup() {
  [[ -z "$next_link" ]] || rm -f "$next_link" 2>/dev/null || true
  [[ -z "$work" ]] || rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT

# Candidate snapshot = current live packages with exactly this package replaced.
if [[ -L "$live" ]]; then
  current_target="$(readlink -f "$live")"
  [[ -d "$current_target" ]] || fail "live feed symlink is broken: $live"
  cp -a "$current_target/." "$work/"
elif [[ -d "$legacy_live" ]]; then
  cp -a "$legacy_live/." "$work/"
fi
mkdir -p "$work/.meta"
find "$work" -maxdepth 1 -type f -name "${package}_*.ipk" -delete
rm -f "$work/.meta/${package}.json"
cp -f "$ipk" "$work/$(basename "$ipk")"

python3 - "$work/.meta/${package}.json" "$package" "$sdk_reference" "$meta_pbid" "$actual_sha" "$(basename "$ipk")" <<'PY'
import json, os, sys
from pathlib import Path

path = Path(sys.argv[1])
package, sdk, pbid, sha256, filename = sys.argv[2:]
path.write_text(json.dumps({
    'package': package,
    'source_repository': os.environ.get('GITHUB_REPOSITORY', f'nik-owrt/{package}'),
    'source_commit': os.environ.get('GITHUB_SHA', 'local'),
    'workflow_run_id': os.environ.get('GITHUB_RUN_ID', '0'),
    'workflow_run_attempt': os.environ.get('GITHUB_RUN_ATTEMPT', '0'),
    'source_sdk_reference': sdk,
    'source_platform_build_id': pbid,
    'filename': filename,
    'sha256': sha256,
}, indent=2) + '\n')
PY

# The immutable SDK owns ipkg-make-index and mkhash. Host WSL does not need
# usign, jq, gzip, or an OpenWrt build tree.
docker run --rm \
  --mount "type=bind,src=$work,dst=/feed" \
  --mount "type=bind,src=$signing_key_file,dst=/run/nik-feed.sec,readonly" \
  --mount "type=bind,src=$public_key_file,dst=/run/nik-feed.pub,readonly" \
  "$sdk_reference" bash -lc '
    set -euo pipefail
    cd /feed
    mkhash="$(find /opt/openwrt-sdk/staging_dir -type f -path "*/bin/mkhash" -perm -111 | head -n1)"
    usign="$(find /opt/openwrt-sdk/staging_dir -type f -path "*/bin/usign" -perm -111 | head -n1)"
    [[ -x "$mkhash" ]] || { echo "SDK mkhash not found" >&2; exit 1; }
    [[ -x "$usign" ]] || { echo "SDK usign not found" >&2; exit 1; }
    [[ -x /opt/openwrt-sdk/scripts/ipkg-make-index.sh ]] || { echo "SDK ipkg-make-index.sh not found" >&2; exit 1; }
    MKHASH="$mkhash" /opt/openwrt-sdk/scripts/ipkg-make-index.sh . > Packages.manifest
    grep -vE "^(Maintainer|LicenseFiles|Source|SourceName|Require|SourceDateEpoch)" Packages.manifest > Packages
    gzip -9nc Packages > Packages.gz
    "$usign" -S -m Packages -s /run/nik-feed.sec -x Packages.sig
    "$usign" -V -m Packages -p /run/nik-feed.pub -x Packages.sig
  '

python3 - "$work" "$packages_file" "$channel" "$openwrt_version" "$feed_arch" "$meta_pbid" "$sdk_reference" <<'PY'
import hashlib, json, sys
from datetime import datetime, timezone
from pathlib import Path

leaf = Path(sys.argv[1])
packages_file = Path(sys.argv[2])
channel, openwrt, arch, pbid, sdk = sys.argv[3:]
expected = []
for raw in packages_file.read_text().splitlines():
    name = raw.split('#', 1)[0].strip()
    if name:
        expected.append(name)

items = []
text = (leaf / 'Packages').read_text()
for stanza in text.strip().split('\n\n') if text.strip() else []:
    fields = {}
    current = None
    for line in stanza.splitlines():
        if line[:1].isspace() and current:
            fields[current] += ' ' + line.strip()
            continue
        if ': ' not in line:
            current = None
            continue
        current, value = line.split(': ', 1)
        fields[current] = value
    name = fields.get('Package')
    filename = fields.get('Filename', '').removeprefix('./')
    if not name or not filename:
        continue
    ipk = leaf / filename
    if not ipk.is_file():
        raise SystemExit(f'index references missing IPK: {filename}')
    metadata_path = leaf / '.meta' / f'{name}.json'
    metadata = json.loads(metadata_path.read_text()) if metadata_path.is_file() else {}
    items.append({
        **metadata,
        'package': name,
        'version': fields.get('Version', ''),
        'architecture': fields.get('Architecture', ''),
        'depends': fields.get('Depends', ''),
        'filename': filename,
        'size': ipk.stat().st_size,
        'sha256': hashlib.sha256(ipk.read_bytes()).hexdigest(),
    })

items.sort(key=lambda x: x['package'])
seen = [x['package'] for x in items]
if len(seen) != len(set(seen)):
    raise SystemExit('feed contains more than one version of a package')
missing = [p for p in expected if p not in set(seen)]
feed = {
    'schema_version': 3,
    'storage': 'local-self-hosted',
    'channel': channel,
    'openwrt_version': openwrt,
    'architecture': arch,
    'platform_build_id': pbid,
    'sdk_reference': sdk,
    'generated_at': datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z'),
    'retention_versions_per_package': 1,
    'expected_packages': len(expected),
    'available_packages': len(items),
    'missing_packages': missing,
    'packages': items,
}
(leaf / 'feed.json').write_text(json.dumps(feed, indent=2) + '\n')
PY

[[ -s "$work/Packages" && -s "$work/Packages.gz" && -s "$work/Packages.sig" ]] || fail "signed feed index is incomplete"
cp -f "$public_key_file" "$work/nik-feed.pub"

release_id="$(date -u +%Y%m%dT%H%M%SZ)-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}-${package}-$$"
final_release="$release_parent/$release_id"
mv "$work" "$final_release"
work=""

relative_target="$(python3 - "$served_parent" "$final_release" <<'PY'
import os, sys
print(os.path.relpath(sys.argv[2], sys.argv[1]))
PY
)"
next_link="$served_parent/.${feed_arch}.next-$$"
ln -s "$relative_target" "$next_link"
mv -Tf "$next_link" "$live"
next_link=""

# Keep the live snapshot and two rollback snapshots. Version values are never
# generated or modified here; the ready-built IPK remains the source of truth.
mapfile -t releases < <(find "$release_parent" -mindepth 1 -maxdepth 1 -type d ! -name '.staging-*' -printf '%T@ %p\n' | LC_ALL=C sort -nr | cut -d' ' -f2-)
if (( ${#releases[@]} > 3 )); then
  for old in "${releases[@]:3}"; do rm -rf "$old"; done
fi

read -r available expected < <(python3 - "$final_release/feed.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
print(m['available_packages'], m['expected_packages'])
PY
)
printf 'local feed published: %s -> %s (%s/%s packages)\n' "$live" "$relative_target" "$available" "$expected"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'feed_path=%s\nfeed_leaf=%s\n' "$live" "$leaf_rel" >> "$GITHUB_OUTPUT"
fi
