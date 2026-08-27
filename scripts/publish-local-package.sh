#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package="${NIK_PUBLISH_PACKAGE:?NIK_PUBLISH_PACKAGE is required}"
source_dir="${NIK_PUBLISH_SOURCE_DIR:?NIK_PUBLISH_SOURCE_DIR is required}"
sdk_reference="${NIK_PUBLISH_SDK_REFERENCE:?NIK_PUBLISH_SDK_REFERENCE is required}"
channel="${NIK_PUBLISH_CHANNEL:-dev}"
openwrt_version="${NIK_PUBLISH_OPENWRT_VERSION:-24.10.4}"
package_arch="${NIK_PUBLISH_PACKAGE_ARCH:-aarch64_cortex-a53}"
feed_root="${NIK_PUBLISH_FEED_ROOT:-${NIK_LOCAL_FEED_ROOT:-$HOME/nik-owrt-feed}}"
signing_key_file="${NIK_PUBLISH_SIGNING_KEY_FILE:-${NIK_FEED_SIGNING_KEY_FILE:-$HOME/.config/nik-feed/nik-feed.key}}"
public_key_file="$repo_root/keys/nik-feed.pub"
packages_file="$repo_root/config/packages.txt"
compatibility_file="$repo_root/config/compatibility.json"

[[ "$package" =~ ^(br|fr)-[a-z0-9-]+$ ]] || { echo "invalid package name: $package" >&2; exit 1; }
[[ "$sdk_reference" =~ ^ghcr\.io/nik-owrt/openwrt-sdk@sha256:[0-9a-f]{64}$ ]] || { echo "invalid immutable SDK reference" >&2; exit 1; }
[[ -d "$source_dir" ]] || { echo "package directory does not exist: $source_dir" >&2; exit 1; }
[[ -s "$public_key_file" && -s "$packages_file" && -s "$compatibility_file" ]] || { echo "nik-feed contract files are incomplete" >&2; exit 1; }

for cmd in ar docker flock gzip install jq python3 sha256sum tar; do
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

work="$(mktemp -d)"
temporary_key=""
staging=""
tmp_link=""
cleanup() {
  [[ -z "$tmp_link" ]] || rm -f "$tmp_link" 2>/dev/null || true
  [[ -z "$staging" ]] || rm -rf "$staging" 2>/dev/null || true
  [[ -z "$temporary_key" ]] || rm -f "$temporary_key" 2>/dev/null || true
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT

if [[ ! -s "$signing_key_file" ]]; then
  if [[ -n "${NIK_FEED_SIGNING_KEY:-}" ]]; then
    temporary_key="$work/nik-feed.key"
    printf '%s\n' "$NIK_FEED_SIGNING_KEY" > "$temporary_key"
    chmod 600 "$temporary_key"
    signing_key_file="$temporary_key"
  else
    echo "local feed signing key is missing: $signing_key_file" >&2
    echo "set NIK_FEED_SIGNING_KEY_FILE or install the existing nik-feed key on the self-hosted runner" >&2
    exit 1
  fi
fi

compat_id_for_sdk() {
  local sdk="$1" manifest="$work/platform-manifest.json" cid
  cid="$(docker create "$sdk" /bin/true)"
  docker cp "$cid:/usr/local/share/nik-platform/platform-manifest.json" "$manifest" >/dev/null
  docker rm "$cid" >/dev/null
  python3 - "$manifest" <<'PY'
import hashlib, json, sys
from pathlib import Path
m = json.loads(Path(sys.argv[1]).read_text())
o = m.get("openwrt", {})
i = {
    "schema": "nik-userspace-abi-v1",
    "openwrt_version": o.get("version", ""),
    "openwrt_baseline": o.get("baseline_id", ""),
    "target": m.get("target", ""),
    "subtarget": m.get("subtarget", ""),
    "architecture_packages": m.get("architecture_packages", ""),
}
if not all(isinstance(v, str) and v for v in i.values()):
    raise SystemExit("SDK platform manifest lacks ABI identity fields")
print(hashlib.sha256(json.dumps(i, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:16])
PY
}

current_compat_id="$(compat_id_for_sdk "$sdk_reference")"
[[ "$current_compat_id" =~ ^[0-9a-f]{16}$ ]] || { echo "invalid userspace compatibility id" >&2; exit 1; }
compat_mode="$(jq -r --arg p "$package" '.packages[$p] // .default' "$compatibility_file")"
[[ "$compat_mode" == architecture-all || "$compat_mode" == userspace-abi-v1 ]] || { echo "invalid compatibility mode for $package" >&2; exit 1; }
package_compat_id="independent"
[[ "$compat_mode" != userspace-abi-v1 ]] || package_compat_id="$current_compat_id"

mkdir -p "$feed_root"
exec 9>"$feed_root/.publish.lock"
flock 9

leaf_rel="$channel/$openwrt_version/$package_arch"
release_parent="$feed_root/releases/$leaf_rel"
served_parent="$feed_root/served/$channel/$openwrt_version"
current_link="$served_parent/$package_arch"
mkdir -p "$release_parent" "$served_parent"

if [[ -e "$current_link" && ! -L "$current_link" ]]; then
  echo "refusing to replace non-symlink feed path: $current_link" >&2
  exit 1
fi

staging="$release_parent/.staging-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}-${package}-$$"
mkdir -p "$staging/.meta"
if [[ -L "$current_link" ]]; then
  current_target="$(readlink -f "$current_link")"
  [[ -d "$current_target" ]] || { echo "current feed symlink is broken: $current_link" >&2; exit 1; }
  cp -a "$current_target/." "$staging/"
  mkdir -p "$staging/.meta"
fi

previous_compat_id="$(jq -r '.package_compatibility_id // empty' "$staging/feed.json" 2>/dev/null || true)"
if [[ -n "$previous_compat_id" && "$previous_compat_id" != "$current_compat_id" ]]; then
  while read -r abi_package; do
    [[ -n "$abi_package" ]] || continue
    find "$staging" -maxdepth 1 -type f -name "${abi_package}_*.ipk" -delete
    rm -f "$staging/.meta/${abi_package}.json"
  done < <(jq -r '.packages | to_entries[] | select(.value == "userspace-abi-v1") | .key' "$compatibility_file")
fi

find "$staging" -maxdepth 1 -type f -name "${package}_*.ipk" -delete
rm -f "$staging/.meta/${package}.json"
install -m 0644 "$ipk" "$staging/$(basename "$ipk")"

jq -n \
  --arg package "$package" \
  --arg repository "${GITHUB_REPOSITORY:-nik-owrt/$package}" \
  --arg commit "${GITHUB_SHA:-local}" \
  --arg run_id "${GITHUB_RUN_ID:-0}" \
  --arg run_attempt "${GITHUB_RUN_ATTEMPT:-0}" \
  --arg sdk "$sdk_reference" \
  --arg pbid "$meta_pbid" \
  --arg mode "$compat_mode" \
  --arg compat "$package_compat_id" \
  --arg sha256 "$actual_sha" \
  --arg file "$(basename "$ipk")" \
  '{package:$package,source_repository:$repository,source_commit:$commit,workflow_run_id:$run_id,workflow_run_attempt:$run_attempt,source_sdk_reference:$sdk,source_platform_build_id:$pbid,compatibility_mode:$mode,compatibility_id:$compat,filename:$file,sha256:$sha256}' \
  > "$staging/.meta/${package}.json"

# The immutable SDK owns OpenWrt-native index/signing tools, so host package versions cannot skew feed output.
docker run --rm \
  --mount "type=bind,src=$staging,dst=/feed" \
  --mount "type=bind,src=$signing_key_file,dst=/run/nik-feed.sec,readonly" \
  --mount "type=bind,src=$public_key_file,dst=/run/nik-feed.pub,readonly" \
  "$sdk_reference" bash -lc '
    set -euo pipefail
    cd /feed
    usign="$(find /opt/openwrt-sdk/staging_dir -type f -path "*/bin/usign" -perm -111 | head -n1)"
    mkhash="$(find /opt/openwrt-sdk/staging_dir -type f -path "*/bin/mkhash" -perm -111 | head -n1)"
    [[ -x "$usign" && -x "$mkhash" ]]
    MKHASH="$mkhash" /opt/openwrt-sdk/scripts/ipkg-make-index.sh . 2>/dev/null > Packages.manifest
    grep -vE "^(Maintainer|LicenseFiles|Source|SourceName|Require|SourceDateEpoch)" Packages.manifest > Packages
    gzip -9nc Packages > Packages.gz
    "$usign" -S -m Packages -s /run/nik-feed.sec -x Packages.sig
    "$usign" -V -m Packages -p /run/nik-feed.pub -x Packages.sig
  '

find "$staging" -maxdepth 1 -type f -name '*.ipk' -printf '%f\n' | LC_ALL=C sort -V > "$staging/files.txt"

python3 - "$staging" "$packages_file" "$current_compat_id" "$channel" "$openwrt_version" "$package_arch" "$meta_pbid" "$sdk_reference" <<'PY'
import hashlib, json, sys
from datetime import datetime, timezone
from pathlib import Path
leaf = Path(sys.argv[1])
packages_file = Path(sys.argv[2])
compat_id, channel, openwrt, arch, pbid, sdk = sys.argv[3:]
expected = []
for raw in packages_file.read_text().splitlines():
    name = raw.split('#', 1)[0].strip()
    if name:
        expected.append(name)
items = []
packages_text = (leaf / 'Packages').read_text()
for stanza in packages_text.strip().split('\n\n') if packages_text.strip() else []:
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
    meta_file = leaf / '.meta' / f'{name}.json'
    meta = json.loads(meta_file.read_text()) if meta_file.exists() else {}
    items.append({
        **meta,
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
    'package_compatibility_id': compat_id,
    'generated_at': datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z'),
    'retention_versions_per_package': 1,
    'expected_packages': len(expected),
    'available_packages': len(items),
    'missing_packages': missing,
    'packages': items,
}
(leaf / 'feed.json').write_text(json.dumps(feed, indent=2) + '\n')
PY

install -m 0644 "$public_key_file" "$staging/nik-feed.pub"
release_id="$(date -u +%Y%m%dT%H%M%SZ)-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}-${package}"
final_release="$release_parent/$release_id"
[[ ! -e "$final_release" ]] || { echo "release already exists: $final_release" >&2; exit 1; }
mv "$staging" "$final_release"
staging=""

tmp_link="$served_parent/.${package_arch}.next-$$"
ln -s "$final_release" "$tmp_link"
mv -Tf "$tmp_link" "$current_link"
tmp_link=""

# Keep two hidden rollback snapshots plus the live snapshot. Only the live symlink is served.
mapfile -t releases < <(find "$release_parent" -mindepth 1 -maxdepth 1 -type d ! -name '.staging-*' -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2-)
if (( ${#releases[@]} > 3 )); then
  for old in "${releases[@]:3}"; do rm -rf "$old"; done
fi

available="$(jq -r '.available_packages' "$final_release/feed.json")"
expected="$(jq -r '.expected_packages' "$final_release/feed.json")"
printf 'local feed published: %s (%s/%s packages)\n' "$current_link" "$available" "$expected"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'feed_path=%s\nfeed_leaf=%s\n' "$current_link" "$leaf_rel" >> "$GITHUB_OUTPUT"
fi
