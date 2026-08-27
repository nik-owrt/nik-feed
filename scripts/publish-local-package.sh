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
lock_file="${NIK_PUBLISH_LOCK_FILE:-/tmp/nik-feed.publish.lock}"

fail() {
  echo "local feed publish: $*" >&2
  exit 1
}

[[ "$package" =~ ^(br|fr)-[a-z0-9-]+$ ]] || fail "invalid package name: $package"
[[ "$sdk_reference" =~ ^ghcr\.io/nik-owrt/openwrt-sdk@sha256:[0-9a-f]{64}$ ]] || fail "invalid immutable SDK reference"
[[ -d "$source_dir" ]] || fail "package directory does not exist: $source_dir"
[[ -s "$packages_file" ]] || fail "missing package contract: $packages_file"

for cmd in docker flock python3; do
  command -v "$cmd" >/dev/null || fail "required command is missing: $cmd"
done

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

# The Windows D: feed is mounted in WSL as /mnt/d/nik-feed. Fail here with an
# actionable error rather than later inside Docker/index generation.
mkdir -p "$feed_root" || fail "cannot create feed root: $feed_root"
probe="$feed_root/.nik-feed-write-probe.$$"
: > "$probe" || fail "feed root is not writable: $feed_root"
rm -f "$probe"

# Lock in the Linux filesystem instead of DrvFS. All package repositories on
# this self-hosted runner therefore serialize publication through one host-wide lock.
exec 9>"$lock_file"
flock 9

leaf_rel="$channel/$openwrt_version/$feed_arch"
live="$feed_root/$leaf_rel"
mkdir -p "$live"
work="$(mktemp -d "$feed_root/.publish-${package}.XXXXXX")"
cleanup() { rm -rf "$work" 2>/dev/null || true; }
trap cleanup EXIT

# Candidate snapshot = current live packages with exactly this package replaced.
find "$live" -maxdepth 1 -type f -name '*.ipk' -exec cp -f {} "$work/" \;
find "$work" -maxdepth 1 -type f -name "${package}_*.ipk" -delete
cp -f "$ipk" "$work/$(basename "$ipk")"

# The immutable SDK owns ipkg-make-index and mkhash. Host WSL does not need
# usign, jq, gzip, or an OpenWrt build tree.
docker run --rm \
  --mount "type=bind,src=$work,dst=/feed" \
  "$sdk_reference" bash -lc '
    set -euo pipefail
    cd /feed
    mkhash="$(find /opt/openwrt-sdk/staging_dir -type f -path "*/bin/mkhash" -perm -111 | head -n1)"
    [[ -x "$mkhash" ]] || { echo "SDK mkhash not found" >&2; exit 1; }
    [[ -x /opt/openwrt-sdk/scripts/ipkg-make-index.sh ]] || { echo "SDK ipkg-make-index.sh not found" >&2; exit 1; }
    MKHASH="$mkhash" /opt/openwrt-sdk/scripts/ipkg-make-index.sh . > Packages.manifest
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

# New IPKs first, index last. Thus Packages.gz never references a file that has
# not reached the HTTP directory yet.
for candidate in "$work"/*.ipk; do
  [[ -e "$candidate" ]] || continue
  base="$(basename "$candidate")"
  cp -f "$candidate" "$live/.${base}.new"
  mv -f "$live/.${base}.new" "$live/$base"
done

for meta_file in Packages.manifest Packages feed.json; do
  cp -f "$work/$meta_file" "$live/.${meta_file}.new"
  mv -f "$live/.${meta_file}.new" "$live/$meta_file"
done
cp -f "$work/Packages.gz" "$live/.Packages.gz.new"
mv -f "$live/.Packages.gz.new" "$live/Packages.gz"

# Remove obsolete IPKs only after the new index is live.
python3 - "$live" "$work/Packages" <<'PY'
import re, sys
from pathlib import Path
live = Path(sys.argv[1])
packages = Path(sys.argv[2]).read_text()
keep = set()
for line in packages.splitlines():
    if line.startswith('Filename: '):
        keep.add(line.split(': ', 1)[1].removeprefix('./'))
for ipk in live.glob('*.ipk'):
    if ipk.name not in keep:
        ipk.unlink()
PY

rm -f "$live/Packages.sig" "$live/nik-feed.pub"

read -r available expected < <(python3 - "$live/feed.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
print(m['available_packages'], m['expected_packages'])
PY
)
printf 'local feed published: %s (%s/%s packages)\n' "$live" "$available" "$expected"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'feed_path=%s\nfeed_leaf=%s\n' "$live" "$leaf_rel" >> "$GITHUB_OUTPUT"
fi
