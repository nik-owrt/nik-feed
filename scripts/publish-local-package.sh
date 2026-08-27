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
packages_file="$repo_root/config/packages.txt"

[[ "$package" =~ ^(br|fr)-[a-z0-9-]+$ ]] || { echo "invalid package name: $package" >&2; exit 1; }
[[ "$sdk_reference" =~ ^ghcr\.io/nik-owrt/openwrt-sdk@sha256:[0-9a-f]{64}$ ]] || { echo "invalid immutable SDK reference" >&2; exit 1; }
[[ -d "$source_dir" ]] || { echo "package directory does not exist: $source_dir" >&2; exit 1; }
[[ -s "$packages_file" ]] || { echo "missing package contract: $packages_file" >&2; exit 1; }

for cmd in docker flock gzip install jq python3 sha256sum; do
  command -v "$cmd" >/dev/null || { echo "required command is missing: $cmd" >&2; exit 1; }
done

mapfile -t ipks < <(find "$source_dir" -maxdepth 1 -type f -name "${package}_*.ipk" -print | LC_ALL=C sort)
[[ "${#ipks[@]}" -eq 1 ]] || {
  printf 'expected exactly one %s IPK in %s, found %s\n' "$package" "$source_dir" "${#ipks[@]}" >&2
  exit 1
}
ipk="${ipks[0]}"
build_meta="$source_dir/package-build.json"
[[ -s "$build_meta" ]] || { echo "missing package-build.json in $source_dir" >&2; exit 1; }

meta_package="$(jq -r '.package // empty' "$build_meta")"
meta_sdk="$(jq -r '.sdk_reference // empty' "$build_meta")"
meta_pbid="$(jq -r '.platform_build_id // empty' "$build_meta")"
meta_file="$(jq -r '.artifacts[0].file // empty' "$build_meta")"
meta_sha="$(jq -r '.artifacts[0].sha256 // empty' "$build_meta")"
actual_sha="$(sha256sum "$ipk" | awk '{print $1}')"
[[ "$meta_package" == "$package" ]] || { echo "package-build package mismatch" >&2; exit 1; }
[[ "$meta_sdk" == "$sdk_reference" ]] || { echo "package-build SDK mismatch" >&2; exit 1; }
[[ "$meta_pbid" =~ ^[0-9a-f]{12}$ ]] || { echo "package-build platform build id is invalid" >&2; exit 1; }
[[ "$meta_file" == "$(basename "$ipk")" && "$meta_sha" == "$actual_sha" ]] || { echo "package-build artifact metadata mismatch" >&2; exit 1; }

docker image inspect "$sdk_reference" >/dev/null 2>&1 || docker pull "$sdk_reference" >/dev/null
sdk_pbid="$(docker image inspect --format '{{ index .Config.Labels "org.nik-link.platform-build-id" }}' "$sdk_reference")"
[[ "$sdk_pbid" == "$meta_pbid" ]] || { echo "SDK/platform build id mismatch" >&2; exit 1; }

leaf_rel="$channel/$openwrt_version/$feed_arch"
live="$feed_root/$leaf_rel"
mkdir -p "$feed_root" "$live"
exec 9>"$feed_root/.publish.lock"
flock 9

work="$(mktemp -d "$feed_root/.publish-${package}.XXXXXX")"
cleanup() { rm -rf "$work" 2>/dev/null || true; }
trap cleanup EXIT

# Build a complete candidate snapshot from the currently served IPKs.
find "$live" -maxdepth 1 -type f -name '*.ipk' -exec cp -f {} "$work/" \;
find "$work" -maxdepth 1 -type f -name "${package}_*.ipk" -delete
install -m 0644 "$ipk" "$work/$(basename "$ipk")"

# Generate OpenWrt-native package metadata inside the immutable SDK. No host usign/tools are required.
docker run --rm \
  --mount "type=bind,src=$work,dst=/feed" \
  "$sdk_reference" bash -lc '
    set -euo pipefail
    cd /feed
    mkhash="$(find /opt/openwrt-sdk/staging_dir -type f -path "*/bin/mkhash" -perm -111 | head -n1)"
    [[ -x "$mkhash" ]]
    MKHASH="$mkhash" /opt/openwrt-sdk/scripts/ipkg-make-index.sh . 2>/dev/null > Packages.manifest
    grep -vE "^(Maintainer|LicenseFiles|Source|SourceName|Require|SourceDateEpoch)" Packages.manifest > Packages
    gzip -9nc Packages > Packages.gz
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
    for line in stanza.splitlines():
        if ': ' in line and not line[:1].isspace():
            k, v = line.split(': ', 1)
            fields[k] = v
    name = fields.get('Package')
    filename = fields.get('Filename', '').removeprefix('./')
    if not name or not filename:
        continue
    ipk = leaf / filename
    items.append({
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
    'storage': 'windows-local-unsigned',
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

# Publish safely: new IPKs first, Packages.gz last. A reader can therefore never receive
# an index that references an IPK which has not reached the live directory yet.
for candidate in "$work"/*.ipk; do
  [[ -e "$candidate" ]] || continue
  base="$(basename "$candidate")"
  install -m 0644 "$candidate" "$live/.${base}.new"
  mv -f "$live/.${base}.new" "$live/$base"
done

for meta in Packages.manifest Packages feed.json; do
  install -m 0644 "$work/$meta" "$live/.${meta}.new"
  mv -f "$live/.${meta}.new" "$live/$meta"
done
install -m 0644 "$work/Packages.gz" "$live/.Packages.gz.new"
mv -f "$live/.Packages.gz.new" "$live/Packages.gz"

# Only after the new index is live, remove package files no longer referenced by it.
declare -A keep=()
while IFS= read -r filename; do
  [[ -n "$filename" ]] && keep["$filename"]=1
done < <(awk -F': ' '$1=="Filename" {sub(/^\.\//,"",$2); print $2}' "$work/Packages")
while IFS= read -r -d '' old; do
  base="$(basename "$old")"
  [[ -n "${keep[$base]:-}" ]] || rm -f "$old"
done < <(find "$live" -maxdepth 1 -type f -name '*.ipk' -print0)

# Explicitly remove legacy signing files: this LAN dev feed is intentionally unsigned.
rm -f "$live/Packages.sig" "$live/nik-feed.pub"

available="$(jq -r '.available_packages' "$live/feed.json")"
expected="$(jq -r '.expected_packages' "$live/feed.json")"
printf 'local feed published: %s (%s/%s packages)\n' "$live" "$available" "$expected"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'feed_path=%s\nfeed_leaf=%s\n' "$live" "$leaf_rel" >> "$GITHUB_OUTPUT"
fi
