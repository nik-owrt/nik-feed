#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

sdk_reference="ghcr.io/nik-owrt/openwrt-sdk@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
platform_build_id="bbbbbbbbbbbb"
feed_root="$tmp/feed"
state_root="$tmp/state"
source_dir="$tmp/source"
fake_bin="$tmp/bin"
mkdir -p "$feed_root" "$state_root/keys" "$source_dir" "$fake_bin"
printf 'private test key\n' > "$state_root/keys/nik-feed.key"

cat > "$fake_bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  image)
    if [[ "${2:-}" == inspect && " $* " == *" --format "* ]]; then
      printf '%s\n' "${NIK_TEST_PLATFORM_BUILD_ID:?}"
    fi
    ;;
  pull)
    ;;
  run)
    [[ "${NIK_TEST_DOCKER_FAIL:-0}" != 1 ]] || exit 42
    feed=""; key=""; public_key=""
    for arg in "$@"; do
      case "$arg" in
        type=bind,src=*,dst=/feed) feed="${arg#type=bind,src=}"; feed="${feed%,dst=/feed}" ;;
        type=bind,src=*,dst=/run/nik-feed.sec,readonly) key="${arg#type=bind,src=}"; key="${key%,dst=/run/nik-feed.sec,readonly}" ;;
        type=bind,src=*,dst=/run/nik-feed.pub,readonly) public_key="${arg#type=bind,src=}"; public_key="${public_key%,dst=/run/nik-feed.pub,readonly}" ;;
      esac
    done
    [[ -d "$feed" && -s "$key" && -s "$public_key" ]]
    : > "$feed/Packages.manifest"
    for ipk in "$feed"/*.ipk; do
      [[ -e "$ipk" ]] || continue
      base="$(basename "$ipk")"
      IFS=_ read -r package version architecture <<< "${base%.ipk}"
      size="$(wc -c < "$ipk" | tr -d ' ')"
      sha="$(sha256sum "$ipk" | awk '{print $1}')"
      printf 'Package: %s\nVersion: %s\nArchitecture: %s\nFilename: ./%s\nSize: %s\nSHA256sum: %s\n\n' \
        "$package" "$version" "$architecture" "$base" "$size" "$sha" >> "$feed/Packages.manifest"
    done
    cp "$feed/Packages.manifest" "$feed/Packages"
    gzip -9nc "$feed/Packages" > "$feed/Packages.gz"
    printf 'fake verified signature\n' > "$feed/Packages.sig"
    ;;
  *)
    printf 'unexpected docker invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
SH
chmod +x "$fake_bin/docker"

make_package() {
  local version="$1" payload="$2" ipk sha
  rm -rf "$source_dir"
  mkdir -p "$source_dir"
  ipk="$source_dir/br-core_${version}_aarch64_cortex-a53.ipk"
  printf '%s\n' "$payload" > "$ipk"
  sha="$(sha256sum "$ipk" | awk '{print $1}')"
  printf '{"package":"br-core","sdk_reference":"%s","platform_build_id":"%s","artifacts":[{"file":"%s","sha256":"%s"}]}\n' \
    "$sdk_reference" "$platform_build_id" "$(basename "$ipk")" "$sha" > "$source_dir/package-build.json"
}

publish() {
  PATH="$fake_bin:$PATH" \
  NIK_TEST_PLATFORM_BUILD_ID="$platform_build_id" \
  NIK_PUBLISH_PACKAGE=br-core \
  NIK_PUBLISH_SOURCE_DIR="$source_dir" \
  NIK_PUBLISH_SDK_REFERENCE="$sdk_reference" \
  NIK_PUBLISH_FEED_ROOT="$feed_root" \
  NIK_PUBLISH_STATE_ROOT="$state_root" \
  NIK_PUBLISH_SIGNING_KEY_FILE="$state_root/keys/nik-feed.key" \
  NIK_PUBLISH_CHANNEL=dev \
  NIK_PUBLISH_OPENWRT_VERSION=24.10.4 \
  NIK_PUBLISH_PACKAGE_ARCH=aarch64_cortex-a53 \
    bash "$repo_root/scripts/publish-local-package.sh"
}

live="$feed_root/served/dev/24.10.4/aarch64_cortex-a53"

make_package 1.0.0-1 first
publish
[[ -L "$live" ]]
[[ -s "$live/Packages.sig" ]]
[[ -s "$live/nik-feed.pub" ]]
[[ -f "$live/br-core_1.0.0-1_aarch64_cortex-a53.ipk" ]]
first_target="$(readlink -f "$live")"

make_package 1.1.0-1 second
publish
second_target="$(readlink -f "$live")"
[[ "$first_target" != "$second_target" ]]
[[ -d "$first_target" ]]
[[ -f "$live/br-core_1.1.0-1_aarch64_cortex-a53.ipk" ]]
[[ ! -e "$live/br-core_1.0.0-1_aarch64_cortex-a53.ipk" ]]
[[ "$(find -L "$live" -maxdepth 1 -type f -name 'br-core_*.ipk' | wc -l)" -eq 1 ]]

make_package 1.2.0-1 third
if NIK_TEST_DOCKER_FAIL=1 publish; then
  echo 'publisher unexpectedly succeeded after index/sign failure' >&2
  exit 1
fi
[[ "$(readlink -f "$live")" == "$second_target" ]]
[[ -f "$live/br-core_1.1.0-1_aarch64_cortex-a53.ipk" ]]
[[ ! -e "$live/br-core_1.2.0-1_aarch64_cortex-a53.ipk" ]]

python3 - "$live/feed.json" <<'PY'
import json, sys
from pathlib import Path
m = json.loads(Path(sys.argv[1]).read_text())
assert m['storage'] == 'local-self-hosted'
assert m['retention_versions_per_package'] == 1
assert [p['version'] for p in m['packages'] if p['package'] == 'br-core'] == ['1.1.0-1']
PY

echo 'local publisher regression test: PASS'
