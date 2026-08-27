#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_root="${1:-${repo_root}/public}"
packages_file="${PACKAGES_FILE:-${repo_root}/config/packages.txt}"
compatibility_file="${COMPATIBILITY_FILE:-${repo_root}/config/compatibility.json}"
channel="${CHANNEL:-dev}"; openwrt_version="${OPENWRT_VERSION:-24.10.4}"; package_arch="${PACKAGE_ARCH:-aarch64_cortex-a53}"
feed_base_url="${FEED_BASE_URL:-https://nik-owrt.github.io/nik-feed}"
platform_build_id="${PLATFORM_BUILD_ID:?PLATFORM_BUILD_ID is required}"; sdk_reference="${SDK_REFERENCE:?SDK_REFERENCE is required}"
signing_key_file="${SIGNING_KEY_FILE:?SIGNING_KEY_FILE is required}"; artifact_token="${NIK_ARTIFACT_READ_TOKEN:?NIK_ARTIFACT_READ_TOKEN is required}"
public_key_file="$repo_root/keys/nik-feed.pub"; org="${NIK_PACKAGE_ORG:-nik-owrt}"
[[ "$platform_build_id" =~ ^[0-9a-f]{12}$ && "$sdk_reference" =~ ^ghcr\.io/nik-owrt/openwrt-sdk@sha256:[0-9a-f]{64}$ ]]
[[ -s "$packages_file" && -s "$compatibility_file" && -s "$signing_key_file" && -s "$public_key_file" ]]
leaf="$output_root/$channel/$openwrt_version/$package_arch"; work="$(mktemp -d)"; pool="$work/pool"; meta="$work/meta"; skipped="$work/skipped.tsv"
trap 'rm -rf "$work"' EXIT; mkdir -p "$pool" "$meta" "$leaf"; : > "$skipped"; rm -rf "$leaf"/*
api_get(){ curl --fail-with-body --silent --show-error -L -H "Authorization: Bearer ${artifact_token}" -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' "$1"; }
compat_id_for_sdk(){
  local sdk="$1" tag manifest cid; tag="$(printf '%s' "$sdk" | sha256sum | cut -c1-16)"; manifest="$work/platform-manifest-$tag.json"
  if [[ ! -s "$manifest" ]]; then docker pull "$sdk" >/dev/null; cid="$(docker create "$sdk" /bin/true)"; docker cp "$cid:/usr/local/share/nik-platform/platform-manifest.json" "$manifest"; docker rm "$cid" >/dev/null; fi
  python3 - "$manifest" <<'PY'
import hashlib,json,sys
from pathlib import Path
m=json.loads(Path(sys.argv[1]).read_text()); o=m.get('openwrt',{})
i={'schema':'nik-userspace-abi-v1','openwrt_version':o.get('version',''),'openwrt_baseline':o.get('baseline_id',''),'target':m.get('target',''),'subtarget':m.get('subtarget',''),'architecture_packages':m.get('architecture_packages','')}
if not all(isinstance(v,str) and v for v in i.values()): raise SystemExit('SDK platform manifest lacks ABI identity fields')
print(hashlib.sha256(json.dumps(i,sort_keys=True,separators=(',',':')).encode()).hexdigest()[:16])
PY
}
current_compat_id="$(compat_id_for_sdk "$sdk_reference")"; [[ "$current_compat_id" =~ ^[0-9a-f]{16}$ ]]
previous_url="$feed_base_url/$channel/$openwrt_version/$package_arch"
if curl -fsSL "$previous_url/feed.json" -o "$work/previous-feed.json" && curl -fsSL "$previous_url/files.txt" -o "$work/previous-files.txt"; then
  while read -r file; do [[ -n "$file" ]] || continue; [[ "$file" == "$(basename "$file")" && "$file" == *.ipk ]]; curl -fsSL "$previous_url/$file" -o "$pool/$file"; done < "$work/previous-files.txt"
  jq -c '.packages[]?' "$work/previous-feed.json" | while read -r row; do package="$(jq -r '.package' <<<"$row")"; [[ "$package" =~ ^(br|fr)-[a-z0-9-]+$ ]] && printf '%s\n' "$row" > "$meta/$package.json" || true; done
  previous_compat_id="$(jq -r '.package_compatibility_id // empty' "$work/previous-feed.json")"
  if [[ "$previous_compat_id" != "$current_compat_id" ]]; then
    while read -r package; do mode="$(jq -r --arg p "$package" '.packages[$p] // .default' "$compatibility_file")"; if [[ "$mode" == userspace-abi-v1 ]]; then find "$pool" -maxdepth 1 -type f -name "${package}_*.ipk" -delete; rm -f "$meta/$package.json"; fi; done < <(awk '{sub(/#.*/,"");gsub(/[[:space:]]/,"");if(length)print}' "$packages_file")
  fi
fi
while read -r package; do
  package="${package%%#*}"; package="${package//[[:space:]]/}"; [[ -n "$package" ]] || continue; [[ "$package" =~ ^(br|fr)-[a-z0-9-]+$ ]]
  mode="$(jq -r --arg p "$package" '.packages[$p] // .default' "$compatibility_file")"; [[ "$mode" == architecture-all || "$mode" == userspace-abi-v1 ]]
  artifact_name="openwrt-package-$package"; list_url="https://api.github.com/repos/$org/$package/actions/artifacts?name=$artifact_name&per_page=100"
  if ! artifact_list="$(api_get "$list_url" 2>/dev/null)"; then printf '%s\t%s\n' "$package" artifact-api-unreadable >> "$skipped"; continue; fi
  artifact="$(jq -c '[.artifacts[] | select(.expired == false)] | sort_by(.created_at) | reverse | .[0] // empty' <<<"$artifact_list")"
  if [[ -z "$artifact" ]]; then printf '%s\t%s\n' "$package" missing-artifact >> "$skipped"; continue; fi
  artifact_id="$(jq -r '.id' <<<"$artifact")"; run_id="$(jq -r '.workflow_run.id // 0' <<<"$artifact")"; head_sha="$(jq -r '.workflow_run.head_sha // empty' <<<"$artifact")"; artifact_created="$(jq -r '.created_at' <<<"$artifact")"
  package_dir="$work/artifacts/$package"; mkdir -p "$package_dir"; zip="$work/$package.zip"
  if ! api_get "https://api.github.com/repos/$org/$package/actions/artifacts/$artifact_id/zip" > "$zip"; then printf '%s\t%s\n' "$package" artifact-download-failed >> "$skipped"; continue; fi
  unzip -q "$zip" -d "$package_dir"; [[ -s "$package_dir/package-build.json" ]]
  source_package="$(jq -r '.package' "$package_dir/package-build.json")"; source_pbid="$(jq -r '.platform_build_id' "$package_dir/package-build.json")"; source_sdk="$(jq -r '.sdk_reference' "$package_dir/package-build.json")"
  [[ "$source_package" == "$package" && "$source_pbid" =~ ^[0-9a-f]{12}$ && "$source_sdk" =~ ^ghcr\.io/nik-owrt/openwrt-sdk@sha256:[0-9a-f]{64}$ ]]
  mapfile -t ipks < <(find "$package_dir" -maxdepth 1 -type f -name '*.ipk' -print | sort); [[ "${#ipks[@]}" -eq 1 ]]
  expected_file="$(jq -r '.artifacts[0].file // empty' "$package_dir/package-build.json")"; expected_sha="$(jq -r '.artifacts[0].sha256 // empty' "$package_dir/package-build.json")"; actual_sha="$(sha256sum "${ipks[0]}" | awk '{print $1}')"
  [[ "$expected_file" == "$(basename "${ipks[0]}")" && "$expected_sha" == "$actual_sha" ]]
  compat=independent
  if [[ "$mode" == userspace-abi-v1 ]]; then compat="$(compat_id_for_sdk "$source_sdk")"; if [[ "$compat" != "$current_compat_id" ]]; then printf '%s\t%s\n' "$package" incompatible-userspace-abi >> "$skipped"; continue; fi; fi
  find "$pool" -maxdepth 1 -type f -name "${package}_*.ipk" -delete; install -m 0644 "${ipks[0]}" "$pool/$(basename "${ipks[0]}")"
  jq -n --arg package "$package" --arg source_pbid "$source_pbid" --arg source_sdk "$source_sdk" --arg mode "$mode" --arg compat "$compat" --argjson artifact_id "$artifact_id" --argjson run_id "$run_id" --arg head_sha "$head_sha" --arg created "$artifact_created" '{package:$package,source_platform_build_id:$source_pbid,source_sdk_reference:$source_sdk,compatibility_mode:$mode,compatibility_id:$compat,source_repository:("nik-owrt/"+$package),artifact_id:$artifact_id,workflow_run_id:$run_id,source_commit:$head_sha,artifact_created_at:$created}' > "$meta/$package.json"
done < "$packages_file"
mapfile -t package_names < <(find "$pool" -maxdepth 1 -type f -name '*.ipk' -printf '%f\n' | sed 's/_.*$//' | sort -u); [[ "${#package_names[@]}" -gt 0 ]]
for package in "${package_names[@]}"; do [[ "$(find "$pool" -maxdepth 1 -type f -name "${package}_*.ipk" | wc -l | tr -d ' ')" == 1 ]]; done
find "$pool" -maxdepth 1 -type f -name '*.ipk' -exec install -m 0644 {} "$leaf/" \;
docker run --rm --mount "type=bind,src=$leaf,dst=/feed" --mount "type=bind,src=$signing_key_file,dst=/run/nik-feed.sec,readonly" --mount "type=bind,src=$public_key_file,dst=/run/nik-feed.pub,readonly" "$sdk_reference" bash -lc 'set -euo pipefail; cd /feed; usign="$(find /opt/openwrt-sdk/staging_dir -type f -path "*/bin/usign" -perm -111 | head -n1)"; mkhash="$(find /opt/openwrt-sdk/staging_dir -type f -path "*/bin/mkhash" -perm -111 | head -n1)"; MKHASH="$mkhash" /opt/openwrt-sdk/scripts/ipkg-make-index.sh . 2>/dev/null > Packages.manifest; grep -vE "^(Maintainer|LicenseFiles|Source|SourceName|Require|SourceDateEpoch)" Packages.manifest > Packages; gzip -9nc Packages > Packages.gz; "$usign" -S -m Packages -s /run/nik-feed.sec -x Packages.sig; "$usign" -V -m Packages -p /run/nik-feed.pub -x Packages.sig'
find "$leaf" -maxdepth 1 -type f -name '*.ipk' -printf '%f\n' | sort -V > "$leaf/files.txt"
expected_count="$(awk '{sub(/#.*/,"");gsub(/[[:space:]]/,"");if(length)n++}END{print n+0}' "$packages_file")"; available_count="$(sed 's/_.*$//' "$leaf/files.txt" | sort -u | grep -c . || true)"; skipped_json="$(jq -Rn '[inputs|select(length>0)|split("\t")|{package:.[0],reason:.[1]}]' < "$skipped")"
packages_json="$(python3 - "$leaf/Packages" "$leaf" "$meta" <<'PY'
import hashlib,json,sys
from pathlib import Path
packages,leaf,meta=Path(sys.argv[1]),Path(sys.argv[2]),Path(sys.argv[3]); items=[]
for stanza in packages.read_text().strip().split('\n\n'):
 f={}
 for line in stanza.splitlines():
  if ': ' in line and not line[:1].isspace(): k,v=line.split(': ',1); f[k]=v
 name=f.get('Package')
 if not name: continue
 fn=f.get('Filename','').removeprefix('./'); p=leaf/fn; src={}; mf=meta/f'{name}.json'
 if mf.exists(): src=json.loads(mf.read_text())
 items.append({**src,'package':name,'version':f.get('Version',''),'architecture':f.get('Architecture',''),'depends':f.get('Depends',''),'filename':fn,'size':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
print(json.dumps(sorted(items,key=lambda x:x['package']),separators=(',',':')))
PY
)"
generated="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -n --arg channel "$channel" --arg openwrt "$openwrt_version" --arg arch "$package_arch" --arg pbid "$platform_build_id" --arg sdk "$sdk_reference" --arg compat "$current_compat_id" --arg generated "$generated" --argjson expected "$expected_count" --argjson available "$available_count" --argjson skipped "$skipped_json" --argjson packages "$packages_json" '{schema_version:2,storage:"github-actions-artifacts",channel:$channel,openwrt_version:$openwrt,architecture:$arch,platform_build_id:$pbid,sdk_reference:$sdk,package_compatibility_id:$compat,generated_at:$generated,retention_versions_per_package:1,expected_packages:$expected,available_packages:$available,skipped_packages:$skipped,packages:$packages}' > "$leaf/feed.json"
install -m 0644 "$public_key_file" "$leaf/nik-feed.pub"
echo "Feed ready: $available_count/$expected_count packages, one version each"
