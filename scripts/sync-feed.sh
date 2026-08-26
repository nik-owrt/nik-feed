#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_root="${1:-${repo_root}/public}"
packages_file="${PACKAGES_FILE:-${repo_root}/config/packages.txt}"
compatibility_file="${COMPATIBILITY_FILE:-${repo_root}/config/compatibility.json}"
channel="${CHANNEL:-dev}"
openwrt_version="${OPENWRT_VERSION:-24.10.4}"
package_arch="${PACKAGE_ARCH:-aarch64_cortex-a53}"
keep_versions="${KEEP_VERSIONS:-1}"
feed_base_url="${FEED_BASE_URL:-https://nik-owrt.github.io/nik-feed}"
platform_build_id="${PLATFORM_BUILD_ID:?PLATFORM_BUILD_ID is required}"
sdk_reference="${SDK_REFERENCE:?SDK_REFERENCE is required}"
signing_key_file="${SIGNING_KEY_FILE:?SIGNING_KEY_FILE is required}"
public_key_file="$repo_root/keys/nik-feed.pub"

[[ "$keep_versions" == 1 ]] || { echo "NIK rolling feed must retain exactly one version per package" >&2; exit 1; }
[[ "$platform_build_id" =~ ^[0-9a-f]{12}$ ]] || { echo "invalid PLATFORM_BUILD_ID" >&2; exit 1; }
[[ "$sdk_reference" =~ ^ghcr\.io/nik-owrt/openwrt-sdk@sha256:[0-9a-f]{64}$ ]] || { echo "SDK_REFERENCE must be immutable" >&2; exit 1; }
[[ -s "$packages_file" && -s "$compatibility_file" && -s "$signing_key_file" && -s "$public_key_file" ]] || { echo "package policy/signing keys are missing" >&2; exit 1; }
jq -e '.default == "architecture-all" and ((.packages // {}) | type == "object")' "$compatibility_file" >/dev/null

leaf="$output_root/$channel/$openwrt_version/$package_arch"
work="$(mktemp -d)"
pool="$work/pool"
meta="$work/meta"
skipped="$work/skipped.tsv"
platform_manifest="$work/platform-manifest.json"
trap 'rm -rf "$work"' EXIT
mkdir -p "$pool" "$meta" "$leaf"
: > "$skipped"
rm -rf "$leaf"/*

# Derive the same userspace ABI compatibility ID used by nik-firmware/br-core.
sdk_cid="$(docker create "$sdk_reference" /bin/true)"
docker cp "$sdk_cid:/usr/local/share/nik-platform/platform-manifest.json" "$platform_manifest"
docker rm "$sdk_cid" >/dev/null
current_compat_id="$(python3 - "$platform_manifest" <<'PY'
import hashlib,json,sys
from pathlib import Path
m=json.loads(Path(sys.argv[1]).read_text())
o=m.get('openwrt',{})
identity={
  'schema':'nik-userspace-abi-v1',
  'openwrt_version':o.get('version',''),
  'openwrt_baseline':o.get('baseline_id',''),
  'target':m.get('target',''),
  'subtarget':m.get('subtarget',''),
  'architecture_packages':m.get('architecture_packages',''),
}
if not all(isinstance(v,str) and v for v in identity.values()):
    raise SystemExit('SDK platform manifest lacks ABI identity fields')
payload=json.dumps(identity,sort_keys=True,separators=(',',':')).encode()
print(hashlib.sha256(payload).hexdigest()[:16])
PY
)"
[[ "$current_compat_id" =~ ^[0-9a-f]{16}$ ]] || { echo "invalid package compatibility id" >&2; exit 1; }

# Reuse the previous one-version snapshot as a fallback. architecture-all
# packages stay independently updateable across PBIDs; ABI-sensitive packages
# are retained only when their compatibility fingerprint still matches.
previous_url="$feed_base_url/$channel/$openwrt_version/$package_arch"
if curl -fsSL "$previous_url/feed.json" -o "$work/previous-feed.json" \
   && curl -fsSL "$previous_url/files.txt" -o "$work/previous-files.txt"; then
  echo "Reusing previous feed as fallback candidates"
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    [[ "$file" == "$(basename "$file")" && "$file" == *.ipk ]] || { echo "invalid previous feed filename: $file" >&2; exit 1; }
    curl -fsSL "$previous_url/$file" -o "$pool/$file"
  done < "$work/previous-files.txt"

  if jq -e '.packages | type == "array"' "$work/previous-feed.json" >/dev/null 2>&1; then
    while IFS= read -r row; do
      package="$(jq -r '.package' <<<"$row")"
      [[ "$package" =~ ^(br|fr)-[a-z0-9-]+$ ]] || continue
      printf '%s\n' "$row" > "$meta/$package.json"
    done < <(jq -c '.packages[]' "$work/previous-feed.json")
  fi

  previous_compat_id="$(jq -r '.package_compatibility_id // empty' "$work/previous-feed.json")"
  if [[ "$previous_compat_id" != "$current_compat_id" ]]; then
    echo "Dropping previous ABI-sensitive packages: compatibility generation changed"
    while IFS= read -r package; do
      [[ -n "$package" ]] || continue
      mode="$(jq -r --arg package "$package" '.packages[$package] // .default' "$compatibility_file")"
      if [[ "$mode" == "userspace-abi-v1" ]]; then
        find "$pool" -maxdepth 1 -type f -name "${package}_*.ipk" -delete
        rm -f "$meta/$package.json"
      fi
    done < <(awk '{ sub(/#.*/, ""); gsub(/[[:space:]]/, ""); if (length) print }' "$packages_file")
  fi
else
  echo "No previous feed snapshot found; starting fresh"
fi

while IFS= read -r package; do
  package="${package%%#*}"
  package="${package//[[:space:]]/}"
  [[ -n "$package" ]] || continue
  [[ "$package" =~ ^(br|fr)-[a-z0-9-]+$ ]] || { echo "invalid package name: $package" >&2; exit 1; }

  mode="$(jq -r --arg package "$package" '.packages[$package] // .default' "$compatibility_file")"
  [[ "$mode" == "architecture-all" || "$mode" == "userspace-abi-v1" ]] || { echo "invalid compatibility mode for $package: $mode" >&2; exit 1; }

  repo="ghcr.io/nik-owrt/openwrt-package-${package}"
  if [[ "$mode" == "userspace-abi-v1" ]]; then
    image="${repo}:compat-${current_compat_id}"
  else
    image="${repo}:latest"
  fi
  echo "Pulling $image ($mode)"
  if ! docker pull "$image" >/dev/null 2>&1; then
    echo "::warning::$package has no readable compatible OCI image; keeping previous compatible version if available"
    printf '%s\t%s\n' "$package" "missing-compatible-image" >> "$skipped"
    continue
  fi

  kind="$(docker image inspect --format '{{ index .Config.Labels "org.nik-link.artifact-kind" }}' "$image")"
  image_package="$(docker image inspect --format '{{ index .Config.Labels "org.nik-link.package" }}' "$image")"
  image_pbid="$(docker image inspect --format '{{ index .Config.Labels "org.nik-link.platform-build-id" }}' "$image")"
  image_sdk="$(docker image inspect --format '{{ index .Config.Labels "org.nik-link.sdk-reference" }}' "$image")"
  image_compat="$(docker image inspect --format '{{ index .Config.Labels "org.nik-link.package-compatibility-id" }}' "$image")"
  [[ "$kind" == "openwrt-package" && "$image_package" == "$package" ]] || { echo "invalid OCI package metadata for $package" >&2; exit 1; }
  [[ "$image_pbid" =~ ^[0-9a-f]{12}$ ]] || { echo "invalid package PBID provenance for $package" >&2; exit 1; }
  [[ "$image_sdk" =~ ^ghcr\.io/nik-owrt/openwrt-sdk@sha256:[0-9a-f]{64}$ ]] || { echo "invalid package SDK provenance for $package" >&2; exit 1; }
  if [[ "$mode" == "userspace-abi-v1" ]]; then
    [[ "$image_compat" == "$current_compat_id" ]] || { echo "compatibility alias/label mismatch for $package" >&2; exit 1; }
  fi

  digest_ref="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$image" | grep -E "^ghcr\.io/nik-owrt/openwrt-package-${package}@sha256:[0-9a-f]{64}$" | head -n1)"
  [[ -n "$digest_ref" ]] || { echo "package did not resolve to immutable digest: $package" >&2; exit 1; }

  package_dir="$work/$package"
  mkdir -p "$package_dir"
  cid="$(docker create "$digest_ref" /bin/true)"
  docker cp "$cid:/package/." "$package_dir/"
  docker rm "$cid" >/dev/null

  [[ -s "$package_dir/package-build.json" ]] || { echo "$package is missing package-build.json" >&2; exit 1; }
  jq -e --arg package "$package" --arg pbid "$image_pbid" --arg sdk "$image_sdk" \
    '.artifact_kind == "openwrt-package-build" and .package == $package and .platform_build_id == $pbid and .sdk_reference == $sdk' \
    "$package_dir/package-build.json" >/dev/null

  mapfile -t new_ipks < <(find "$package_dir" -maxdepth 1 -type f -name '*.ipk' -print | sort)
  [[ "${#new_ipks[@]}" -eq 1 ]] || { echo "$package OCI must contain exactly one IPK, found ${#new_ipks[@]}" >&2; exit 1; }

  # Replace this package only. Every unrelated package remains untouched.
  find "$pool" -maxdepth 1 -type f -name "${package}_*.ipk" -delete
  install -m 0644 "${new_ipks[0]}" "$pool/$(basename "${new_ipks[0]}")"

  jq -n \
    --arg package "$package" \
    --arg source_pbid "$image_pbid" \
    --arg source_sdk "$image_sdk" \
    --arg mode "$mode" \
    --arg compat "$([[ "$mode" == userspace-abi-v1 ]] && printf '%s' "$current_compat_id" || printf 'independent')" \
    --arg oci "$digest_ref" \
    '{package:$package,source_platform_build_id:$source_pbid,source_sdk_reference:$source_sdk,compatibility_mode:$mode,compatibility_id:$compat,oci_reference:$oci}' \
    > "$meta/$package.json"
done < "$packages_file"

mapfile -t package_names < <(find "$pool" -maxdepth 1 -type f -name '*.ipk' -printf '%f\n' | sed 's/_.*$//' | sort -u)
[[ "${#package_names[@]}" -gt 0 ]] || { echo "no compatible IPKs available for feed" >&2; exit 1; }
for package in "${package_names[@]}"; do
  count="$(find "$pool" -maxdepth 1 -type f -name "${package}_*.ipk" | wc -l | tr -d ' ')"
  [[ "$count" == 1 ]] || { echo "feed invariant violated: $package has $count versions" >&2; exit 1; }
done
find "$pool" -maxdepth 1 -type f -name '*.ipk' -exec install -m 0644 {} "$leaf/" \;

docker run --rm \
  --mount "type=bind,src=$leaf,dst=/feed" \
  --mount "type=bind,src=$signing_key_file,dst=/run/nik-feed.sec,readonly" \
  --mount "type=bind,src=$public_key_file,dst=/run/nik-feed.pub,readonly" \
  "$sdk_reference" bash -lc '
    set -euo pipefail
    cd /feed
    mkhash="$(find /opt/openwrt-sdk/staging_dir -type f -path "*/bin/mkhash" -perm -111 | head -n1)"
    usign="$(find /opt/openwrt-sdk/staging_dir -type f -path "*/bin/usign" -perm -111 | head -n1)"
    [[ -x "$mkhash" && -x "$usign" ]]
    MKHASH="$mkhash" /opt/openwrt-sdk/scripts/ipkg-make-index.sh . 2>Packages.index.log > Packages.manifest
    grep -vE "^(Maintainer|LicenseFiles|Source|SourceName|Require|SourceDateEpoch)" Packages.manifest > Packages
    case "$(((64 + $(stat -L -c%s Packages)) % 128))" in
      110|111) { echo ""; echo ""; } >> Packages ;;
    esac
    gzip -9nc Packages > Packages.gz
    "$usign" -S -m Packages -s /run/nik-feed.sec -x Packages.sig
    "$usign" -V -m Packages -p /run/nik-feed.pub -x Packages.sig
    rm -f Packages.index.log
  '

find "$leaf" -maxdepth 1 -type f -name '*.ipk' -printf '%f\n' | sort -V > "$leaf/files.txt"
ipk_count="$(wc -l < "$leaf/files.txt" | tr -d ' ')"
available_count="$(sed 's/_.*$//' "$leaf/files.txt" | sort -u | grep -c . || true)"
expected_count="$(awk '{ sub(/#.*/, ""); gsub(/[[:space:]]/, ""); if (length) n++ } END { print n+0 }' "$packages_file")"
skipped_json="$(jq -Rn '[inputs | select(length > 0) | split("\t") | {package:.[0], reason:.[1]}]' < "$skipped")"
generated="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

packages_json="$(python3 - "$leaf/Packages" "$leaf" "$meta" "$compatibility_file" "$package_arch" <<'PY'
import hashlib,json,sys
from pathlib import Path
packages_path,leaf_path,meta_path,compat_path,platform_arch=map(Path,sys.argv[1:5]) if False else (Path(sys.argv[1]),Path(sys.argv[2]),Path(sys.argv[3]),Path(sys.argv[4]),sys.argv[5])
policy=json.loads(compat_path.read_text())
text=packages_path.read_text()
items=[]
for stanza in text.strip().split("\n\n"):
    fields={}
    for line in stanza.splitlines():
        if not line or line[0].isspace() or ": " not in line:
            continue
        key,value=line.split(": ",1)
        fields[key]=value
    package=fields.get("Package")
    if not package:
        continue
    mode=policy.get("packages",{}).get(package,policy["default"])
    architecture=fields.get("Architecture","")
    if mode == "architecture-all" and architecture != "all":
        raise SystemExit(f"{package} must be Architecture: all, got {architecture}")
    if mode == "userspace-abi-v1" and architecture != platform_arch:
        raise SystemExit(f"{package} architecture mismatch: {architecture} != {platform_arch}")
    filename=fields.get("Filename","")
    if filename.startswith("./"):
        filename=filename[2:]
    file_path=leaf_path/filename
    if not file_path.is_file():
        raise SystemExit(f"indexed package file missing: {filename}")
    sha=hashlib.sha256(file_path.read_bytes()).hexdigest()
    indexed_sha=fields.get("SHA256sum","")
    if indexed_sha and indexed_sha != sha:
        raise SystemExit(f"SHA256 mismatch for {package}")
    item={
        "package":package,
        "version":fields.get("Version",""),
        "architecture":architecture,
        "filename":filename,
        "size":file_path.stat().st_size,
        "sha256":sha,
        "depends":fields.get("Depends",""),
        "compatibility_mode":mode,
    }
    mp=meta_path/f"{package}.json"
    if mp.is_file():
        item.update(json.loads(mp.read_text()))
    items.append(item)
items.sort(key=lambda x:x["package"])
print(json.dumps(items,separators=(",",":")))
PY
)"

jq -n \
  --arg channel "$channel" \
  --arg openwrt "$openwrt_version" \
  --arg arch "$package_arch" \
  --arg pbid "$platform_build_id" \
  --arg sdk "$sdk_reference" \
  --arg compat "$current_compat_id" \
  --arg generated "$generated" \
  --argjson keep "$keep_versions" \
  --argjson ipks "$ipk_count" \
  --argjson expected "$expected_count" \
  --argjson available "$available_count" \
  --argjson skipped "$skipped_json" \
  --argjson packages "$packages_json" \
  '{schema_version:2,channel:$channel,openwrt_version:$openwrt,architecture:$arch,platform_build_id:$pbid,sdk_reference:$sdk,package_compatibility_id:$compat,generated_at:$generated,keep_versions:$keep,ipk_count:$ipks,expected_packages:$expected,available_packages:$available,skipped_packages:$skipped,packages:$packages}' \
  > "$leaf/feed.json"

printf 'Published %s IPKs for %s/%s packages to %s (one version per package)\n' "$ipk_count" "$available_count" "$expected_count" "$leaf"
if [[ -s "$skipped" ]]; then
  echo "Skipped package candidates:"
  cat "$skipped"
fi
