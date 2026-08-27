# nik-feed

Local-only signed OPKG feed for NIK OpenWrt 24.10.4 development packages.

Runtime `br-*` / `fr-*` IPKs are intentionally not published to GHCR, GitHub Actions artifacts, releases, or GitHub Pages. GitHub remains source control and CI orchestration; the self-hosted build machine is the package publisher and storage host.

## Data flow

```text
package repository
  -> self-hosted GitHub Actions runner
  -> validate
  -> build one IPK
  -> validate final IPK/payload
  -> local nik-feed publisher
  -> signed local OPKG index
  -> LAN HTTP server
  -> OpenWrt opkg
```

The public GitHub Pages deployment is only a package-free tombstone. It must never contain `*.ipk`, `Packages`, `Packages.gz`, `Packages.manifest`, or `Packages.sig`.

## Local storage

Default persistent root on the self-hosted Linux runner:

```text
$HOME/nik-owrt-feed/
├── .publish.lock
├── releases/
│   └── dev/24.10.4/aarch64_cortex-a53/<immutable-release>/
└── served/
    └── dev/24.10.4/aarch64_cortex-a53 -> <immutable-release>
```

`served/` is the only tree the LAN HTTP server exposes. The live architecture directory is an atomic symlink to an immutable release snapshot, so `opkg` cannot observe a half-updated package index.

Override the root with repository/organization Actions variable `NIK_LOCAL_FEED_ROOT` when required.

## Publication contract

The reusable composite action is:

```text
nik-owrt/nik-feed/.github/actions/publish-local@<immutable-commit-sha>
```

Each package workflow passes its validated `.artifacts/packages` directory and the exact immutable SDK reference used for the build.

`scripts/publish-local-package.sh`:

1. requires exactly one `<package>_*.ipk` plus `package-build.json`;
2. verifies package name, immutable SDK reference, platform build ID, filename and SHA-256;
3. derives the userspace compatibility ID from the immutable SDK platform manifest;
4. takes a host-wide `flock` so package workflows from different GitHub repositories cannot race;
5. copies the previous live snapshot into a staging release;
6. removes the previous version of only the package being replaced;
7. invalidates ABI-sensitive packages if the userspace compatibility generation changed;
8. regenerates `Packages.manifest`, `Packages`, `Packages.gz` with OpenWrt tools from the immutable SDK;
9. signs and immediately verifies `Packages.sig` with `usign`;
10. generates `feed.json` with provenance and missing-package state;
11. atomically switches the live symlink to the complete immutable release;
12. keeps the live snapshot plus two non-served rollback snapshots.

The served feed therefore contains at most one current version of every package.

## Compatibility

`config/compatibility.json` defines the policy. The default is `architecture-all`; currently `br-core` uses `userspace-abi-v1` and is invalidated automatically when the SDK userspace ABI identity changes.

The active package set is `config/packages.txt` and currently contains 23 packages.

## Signing key

The firmware public key remains the trust anchor. The matching public key is committed as:

```text
keys/nik-feed.pub
```

The private key is never committed and is never served over HTTP.

One-time bootstrap copies the existing `NIK_FEED_SIGNING_KEY` repository secret onto the trusted self-hosted runner only after a sign+verify check against `keys/nik-feed.pub`:

```text
$HOME/.config/nik-feed/nik-feed.key
```

Override that path with `NIK_FEED_SIGNING_KEY_FILE` if required. Package repositories do not need to own the signing secret once the local runner has been bootstrapped.

## LAN HTTP server

The helper below keeps an nginx container running locally and exposes only the `served/` tree:

```sh
bash scripts/ensure-local-http-server.sh
```

Defaults:

```text
bind:      0.0.0.0:8080
container: nik-local-feed
root:      $HOME/nik-owrt-feed/served
```

To bind to one LAN address instead:

```sh
NIK_LOCAL_FEED_BIND=192.168.1.100:8080 bash scripts/ensure-local-http-server.sh
```

The PC does not need a public IP, inbound NAT/port-forwarding, or VPN. Restrict the selected TCP port to the trusted LAN in the host firewall.

If the Linux runner is inside a VM/WSL/container network, verify that the LAN can reach the published host port; the OPKG URL must use an address routable from the router.

## Router configuration

If the build host is reachable as `192.168.1.100:8080`, the feed leaf is:

```text
http://192.168.1.100:8080/dev/24.10.4/aarch64_cortex-a53
```

OpenWrt `/etc/opkg/customfeeds.conf`:

```sh
src/gz nik_dev http://192.168.1.100:8080/dev/24.10.4/aarch64_cortex-a53
```

Then individual modules can be updated without rebuilding firmware:

```sh
opkg update
opkg list-upgradable
opkg upgrade fr-wifi
```

When the build PC is offline, the local feed is simply unavailable; already installed packages and the firmware continue to operate.
