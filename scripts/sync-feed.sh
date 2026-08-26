#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_root="${1:-${repo_root}/public}"
packages_file="${PACKAGES_FILE:-${repo_root}/config/packages.txt}"
channel="${CHANNEL:-dev}"
openwrt_version="${OPENWRT_VERSION:-24.10.4}"
package_arch="${PACKAGE_ARCH:-aarch64_cortex-a53}"
keep_versions="${KEEP_VERSIONS:-3}"
feed_base_url="${FEED_BASE_URL:-https://nik-owrt.github.io/nik-feed}"
platform_build_id="${PLATFORM_BUILD_ID:?PLATFORM_BUILD_ID is required}"
sdk_reference="${SDK_REFERENCE:?SDK_REFERENCE is required}"
signing_key_file="${SIGNING_KEY_FILE:?SIGNING_KEY_FILE is required}"

[[ "$keep_versions" =~ ^[1-9][0-9]*$ ]] || { echo "KEEP_VERSIONS must be a positive integer" >&2; exit 1; }
[[ "$platform_build_id" =~ ^[0-9a-f]{12}$ ]] || { echo "invalid PLATFORM_BUILD_ID" >&2; exit 1; }
[[ "$sdk_reference" =~ ^ghcr\.io/nik-owrt/openwrt-sdk@sha256:[0-9a-f]{64}$ ]] || { echo "SDK_REFERENCE must be immutable" >&2; exit 1; }
[[ -s "$packages_file" && -s "$signing_key_file" && -s "$repo_root/keys/nik-feed.pub" ]] || { echo "package manifest/signing keys are missing" >&2; exit 1; }

leaf="$output_root/$channel/$openwrt_version/$package_arch"
work="$(mktemp -d)"
pool="$work/pool"
trap 'rm -rf "$work"' EXIT
mkdir -p "$pool" "$leaf"
rm -rf "$leaf"/*

previous_url="$feed_base_url/$channel/$openwrt_version/$package_arch"
if curl -fsSL "$previous_url/files.txt" -o "$work/previous-files.txt"; then
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    [[ "$file" == "$(basename "$file")" && "$file" == *.ipk ]] || { echo "invalid previous feed filename: $file" >&2; exit 1; }
    curl -fsSL "$previous_url/$file" -o "$pool/$file"
  done < "$work/previous-files.txt"
else
  echo "No previous feed snapshot found; starting fresh"
fi

while IFS= read -r package; do
  package="${package%%#*}"
  package="${package//[[:space:]]/}"
  [[ -n "$package" ]] || continue
  [[ "$package" =~ ^br-[a-z0-9-]+$ ]] || { echo "invalid package name: $package" >&2; exit 1; }

  image="ghcr.io/nik-owrt/openwrt-package-${package}:latest"
  echo "Pulling $image"
  docker pull "$image" >/dev/null

  kind="$(docker image inspect --format '{{ index .Config.Labels "org.nik-link.artifact-kind" }}' "$image")"
  image_package="$(docker image inspect --format '{{ index .Config.Labels "org.nik-link.package" }}' "$image")"
  image_pbid="$(docker image inspect --format '{{ index .Config.Labels "org.nik-link.platform-build-id" }}' "$image")"
  [[ "$kind" == "openwrt-package" && "$image_package" == "$package" ]] || { echo "invalid OCI package metadata for $package" >&2; exit 1; }
  [[ "$image_pbid" == "$platform_build_id" ]] || { echo "$package was built for PBID $image_pbid, expected $platform_build_id" >&2; exit 1; }

  package_dir="$work/$package"
  mkdir -p "$package_dir"
  cid="$(docker create "$image")"
  trap 'docker rm -f "$cid" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
  docker cp "$cid:/package/." "$package_dir/"
  docker rm "$cid" >/dev/null
  trap 'rm -rf "$work"' EXIT

  [[ -s "$package_dir/package-build.json" ]] || { echo "$package is missing package-build.json" >&2; exit 1; }
  jq -e --arg package "$package" --arg pbid "$platform_build_id" \
    '.artifact_kind == "openwrt-package-build" and .package == $package and .platform_build_id == $pbid' \
    "$package_dir/package-build.json" >/dev/null

  found=0
  while IFS= read -r ipk; do
    install -m 0644 "$ipk" "$pool/$(basename "$ipk")"
    found=1
  done < <(find "$package_dir" -maxdepth 1 -type f -name '*.ipk' -print | sort)
  [[ "$found" == 1 ]] || { echo "$package OCI contains no IPK" >&2; exit 1; }
done < "$packages_file"

mapfile -t package_names < <(find "$pool" -maxdepth 1 -type f -name '*.ipk' -printf '%f\n' | sed 's/_.*$//' | sort -u)
[[ "${#package_names[@]}" -gt 0 ]] || { echo "no IPKs available for feed" >&2; exit 1; }

for package in "${package_names[@]}"; do
  mapfile -t versions < <(find "$pool" -maxdepth 1 -type f -name "${package}_*.ipk" -printf '%f\n' | sort -V)
  start=0
  if (( ${#versions[@]} > keep_versions )); then
    start=$(( ${#versions[@]} - keep_versions ))
  fi
  for ((i=start; i<${#versions[@]}; i++)); do
    install -m 0644 "$pool/${versions[$i]}" "$leaf/${versions[$i]}"
  done
done

install -m 0644 "$repo_root/keys/nik-feed.pub" "$leaf/nik-feed.pub"

docker run --rm \
  --mount "type=bind,src=$leaf,dst=/feed" \
  --mount "type=bind,src=$signing_key_file,dst=/run/nik-feed.sec,readonly" \
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
    "$usign" -V -m Packages -p nik-feed.pub -x Packages.sig
    rm -f Packages.index.log
  '

find "$leaf" -maxdepth 1 -type f -name '*.ipk' -printf '%f\n' | sort -V > "$leaf/files.txt"
package_count="$(wc -l < "$leaf/files.txt" | tr -d ' ')"
generated="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -n \
  --arg channel "$channel" \
  --arg openwrt "$openwrt_version" \
  --arg arch "$package_arch" \
  --arg pbid "$platform_build_id" \
  --arg generated "$generated" \
  --argjson keep "$keep_versions" \
  --argjson packages "$package_count" \
  '{schema_version:1,channel:$channel,openwrt_version:$openwrt,architecture:$arch,platform_build_id:$pbid,generated_at:$generated,keep_versions:$keep,ipk_count:$packages}' \
  > "$leaf/feed.json"

printf 'Published %s IPKs to %s\n' "$package_count" "$leaf"
