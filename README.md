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
  -> replace one package in the live feed
  -> regenerate and sign the local OPKG index
  -> LAN HTTP server
  -> OpenWrt opkg
```

The public GitHub Pages deployment is only a package-free tombstone. It must never contain `*.ipk`, `Packages`, `Packages.gz`, `Packages.manifest`, or `Packages.sig`.

## Local storage

Default persistent roots on the self-hosted WSL runner:

```text
/mnt/d/nik-feed/
└── served/
    └── dev/24.10.4/aarch64_cortex-a53/
        ├── br-*.ipk
        ├── fr-*.ipk
        ├── .meta/
        ├── Packages.manifest
        ├── Packages
        ├── Packages.gz
        ├── Packages.sig
        ├── feed.json
        └── nik-feed.pub

/mnt/d/nik-feed-state/
├── keys/nik-feed.key
├── locks/publish.lock
└── transactions/
```

`served/` is the only tree the LAN HTTP server exposes. The architecture directory is a real persistent directory, not a per-deployment symlink. Every successful package deployment replaces only that package and then regenerates the feed indexes in place.

The retired `releases/<timestamp-run-package-pid>/` snapshot layout is migrated automatically on the next successful publication and removed after the new live feed has been validated.

Override these roots with `NIK_LOCAL_FEED_ROOT` and `NIK_LOCAL_FEED_STATE_ROOT` when required.

## Publication contract

The reusable composite action is:

```text
nik-owrt/nik-feed/.github/actions/publish-local@<immutable-commit-sha>
```

Each package workflow passes its validated `.artifacts/packages` directory and the exact immutable SDK reference used for the build.

`scripts/publish-local-package.sh`:

1. requires exactly one `<package>_*.ipk` plus `package-build.json`;
2. verifies package name, immutable SDK reference, platform build ID, filename and SHA-256;
3. preserves the package's existing OPKG version without generating or changing it;
4. takes a host-wide `flock` from `/mnt/d/nik-feed-state/locks` so package workflows from different GitHub repositories cannot race;
5. migrates the old release-snapshot symlink layout to a real live directory when encountered;
6. backs up only the package being replaced, its provenance metadata, and the small current index files;
7. atomically copies the new IPK into the live directory and removes only older IPKs for that same package;
8. regenerates `Packages.manifest`, `Packages`, `Packages.gz` under hidden temporary names with OpenWrt tools from the immutable SDK;
9. signs and immediately verifies the next `Packages.sig` with `usign`;
10. generates the next `feed.json` with provenance and missing-package state;
11. atomically renames the completed index files into their live names;
12. rolls the package and index files back if generation/signing fails;
13. removes the retired release snapshot tree after a successful migration.

Routine package publication never duplicates the complete feed and never creates a new release directory. The served feed contains at most one current version of every package.

## Compatibility

The publisher verifies that `package-build.json` names the same immutable SDK and platform build ID exposed by the SDK image. It records that provenance per package but does not generate versions or rewrite package metadata.

The active package set is `config/packages.txt` and currently contains 23 packages.

## Signing key

The firmware public key remains the trust anchor. The matching public key is committed as:

```text
keys/nik-feed.pub
```

The private key is never committed and is never served over HTTP.

One-time bootstrap copies the existing `NIK_FEED_SIGNING_KEY` repository secret onto the trusted self-hosted runner only after a sign+verify check against `keys/nik-feed.pub`:

```text
/mnt/d/nik-feed-state/keys/nik-feed.key
```

Override that path with `NIK_FEED_SIGNING_KEY_FILE` if required. Package repositories do not need to own the signing secret once the local runner has been bootstrapped.

During migration, the publisher copies an already-installed legacy key from `$HOME/.config/nik-feed/nik-feed.key` into the canonical state directory when the canonical file is absent. It never generates a replacement key and fails closed when neither file exists.

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
