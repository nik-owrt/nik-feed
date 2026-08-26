#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_root="${1:-${repo_root}/public}"
packages_file="${PACKAGES_FILE:-${repo_root}/config/packages.txt}"
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
[[ -s "$packages_file" && -s "$signing_key_file" && -s "$public_key_file" ]] || { echo "package manifest/signing keys are missing" >&2; exit 1; }

leaf="$output_root/$channel/$openwrt_version/$package_arch"
work="$(mktemp -d)"
pool="$work/pool"
skipped="$work/skipped.tsv"
trap 'rm -rf "$work"' EXIT
mkdir -p "$pool" "$leaf"
: > "$skipped"
rm -rf "$leaf"/*

# Reuse the previous snapshot only when it belongs to the same immutable
# platform generation. This lets a missing package publication keep its last
# known-good version without ever accumulating a second version in the feed.
previous_url="$feed_base_url/$channel/$openwrt_version/$package_arch"
if curl -fsSL "$previous_url/feed.json" -o "$work/previous-feed.json"; then
  previous_pbid="$(jq -r '.platform_build_id // empty' "$work/previous-feed.json")"
  previous_sdk="$(jq -r '.sdk_reference // empty' "$work/previous-feed.json")"
  if [[ "$previous_pbid" == "$platform_build_id" && ( -z "$previous_sdk" || "$previous_sdk" == "$sdk_reference" ) ]] \
     && curl -fsSL "$previous_url/files.txt" -o "$work/previous-files.txt"; then
    echo "Reusing previous compatible feed snapshot for PBID $platform_build_id"
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      [[ "$file" == "$(basename "$file")" && "$file" == *.ipk ]] || { echo "invalid previous feed filename: $file" >&2; exit 1; }
      curl -fsSL "$previous_url/$file" -o "$pool/$file"
    done < "$work/previous-files.txt"
  else
    echo "Previous feed is not compatible with PBID/SDK; starting fresh"
  fi
else
  echo "No previous feed snapshot found; starting fresh"
fi

while IFS= read -r package; do
  package="${package%%#*}"
  package="${package//[[:space:]]/}"
  [[ -n "$package" ]] || continue
  [[ "$package" =~ ^(br|fr)-[a-z0-9-]+$ ]] || { echo "invalid package name: $package" >&2; exit 1; }

  image="ghcr.io/nik-owrt/openwrt-package-${package}:latest"
  echo "Pulling $image"
  if ! docker pull "$image" >/dev/null 2>&1; then
    echo "::warning::$package has no readable :latest OCI image; keeping previous compatible version if available"
    printf '%s\t%s\n' "$package" "missing-latest" >> "$skipped"
    continue
  fi

  kind="$(docker image inspect --format '{{ index .Config.Labels "org.nik-link.artifact-kind" }}' "$image")"
  image_package="$(docker image inspect --format '{{ index .Config.Labels "org.nik-link.package" }}' "$image")"
  image_pbid="$(docker image inspect --format '{{ index .Config.Labels "org.nik-link.platform-build-id" }}' "$image")"
  image_sdk="$(docker image inspect --format '{{ index .Config.Labels "org.nik-link.sdk-reference" }}' "$image")"
  [[ "$kind" == "openwrt-package" && "$image_package" == "$package" ]] || { echo "invalid OCI package metadata for $package" >&2; exit 1; }

  if [[ "$image_pbid" != "$platform_build_id" ]]; then
    echo "::warning::$package latest PBID $image_pbid is incompatible with current $platform_build_id; keeping previous compatible version if available"
    printf '%s\t%s\n' "$package" "incompatible-pbid:$image_pbid" >> "$skipped"
    continue
  fi
  if [[ "$image_sdk" != "$sdk_reference" ]]; then
    echo "::warning::$package latest SDK does not match current immutable SDK; keeping previous compatible version if available"
    printf '%s\t%s\n' "$package" "incompatible-sdk" >> "$skipped"
    continue
  fi

  package_dir="$work/$package"
  mkdir -p "$package_dir"
  cid="$(docker create "$image" /bin/true)"
  docker cp "$cid:/package/." "$package_dir/"
  docker rm "$cid" >/dev/null

  [[ -s "$package_dir/package-build.json" ]] || { echo "$package is missing package-build.json" >&2; exit 1; }
  jq -e --arg package "$package" --arg pbid "$platform_build_id" --arg sdk "$sdk_reference" --arg arch "$package_arch" \
    '.artifact_kind == "openwrt-package-build" and .package == $package and .platform_build_id == $pbid and .sdk_reference == $sdk and .package_architecture == $arch' \
    "$package_dir/package-build.json" >/dev/null

  mapfile -t new_ipks < <(find "$package_dir" -maxdepth 1 -type f -name '*.ipk' -print | sort)
  [[ "${#new_ipks[@]}" -eq 1 ]] || { echo "$package OCI must contain exactly one IPK, found ${#new_ipks[@]}" >&2; exit 1; }

  # Atomic per-package replacement in the candidate pool: once a valid latest
  # package exists, remove every prior version of that package before copying it.
  find "$pool" -maxdepth 1 -type f -name "${package}_*.ipk" -delete
  install -m 0644 "${new_ipks[0]}" "$pool/$(basename "${new_ipks[0]}")"
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

packages_json="$(python3 - "$leaf/Packages" <<'PY'
import json
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
items = []
for stanza in text.strip().split("\n\n"):
    fields = {}
    for line in stanza.splitlines():
        if not line or line[0].isspace() or ": " not in line:
            continue
        key, value = line.split(": ", 1)
        fields[key] = value
    if not fields.get("Package"):
        continue
    filename = fields.get("Filename", "")
    if filename.startswith("./"):
        filename = filename[2:]
    item = {
        "package": fields["Package"],
        "version": fields.get("Version", ""),
        "architecture": fields.get("Architecture", ""),
        "filename": filename,
        "size": int(fields.get("Size", "0") or 0),
        "sha256": fields.get("SHA256sum", ""),
        "depends": fields.get("Depends", ""),
    }
    items.append(item)
items.sort(key=lambda x: x["package"])
print(json.dumps(items, separators=(",", ":")))
PY
)"

jq -n \
  --arg channel "$channel" \
  --arg openwrt "$openwrt_version" \
  --arg arch "$package_arch" \
  --arg pbid "$platform_build_id" \
  --arg sdk "$sdk_reference" \
  --arg generated "$generated" \
  --argjson keep "$keep_versions" \
  --argjson ipks "$ipk_count" \
  --argjson expected "$expected_count" \
  --argjson available "$available_count" \
  --argjson skipped "$skipped_json" \
  --argjson packages "$packages_json" \
  '{schema_version:2,channel:$channel,openwrt_version:$openwrt,architecture:$arch,platform_build_id:$pbid,sdk_reference:$sdk,generated_at:$generated,keep_versions:$keep,ipk_count:$ipks,expected_packages:$expected,available_packages:$available,skipped_packages:$skipped,packages:$packages}' \
  > "$leaf/feed.json"

printf 'Published %s IPKs for %s/%s packages to %s (one version per package)\n' "$ipk_count" "$available_count" "$expected_count" "$leaf"
if [[ -s "$skipped" ]]; then
  echo "Skipped package candidates:"
  cat "$skipped"
fi
