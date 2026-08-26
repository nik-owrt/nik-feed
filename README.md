# nik-feed

Public signed OPKG feed for NIK OpenWrt 24.10.4 development packages.

## Feed URL

```text
https://nik-owrt.github.io/nik-feed/dev/24.10.4/aarch64_cortex-a53
```

Router configuration:

```sh
src/gz nik_dev https://nik-owrt.github.io/nik-feed/dev/24.10.4/aarch64_cortex-a53
```

The production firmware ships this URL in `/etc/opkg/customfeeds.conf` together with the NIK usign public key, so a router can update a single module independently:

```sh
opkg update
opkg upgrade fr-wifi
```

No firmware rebuild is required when only a compatible NIK package changes.

## Trust model

The NIK feed public key is a firmware trust anchor. Routers receive it from the firmware image as `/etc/opkg/keys/de2c9e01106fbc10`; the feed never bootstraps its own trust.

The repository keeps `keys/nik-feed.pub` only so CI can verify the signature it just created. The Pages artifact intentionally does not publish that key.

The private signing key exists only as the `NIK_FEED_SIGNING_KEY` GitHub Actions secret and must never be committed or included in firmware.

## Publishing model

Package repositories publish OCI images such as:

```text
ghcr.io/nik-owrt/openwrt-package-br-wifi:latest
```

The feed is a rolling snapshot, not a package archive:

1. Resolve the current immutable NIK OpenWrt SDK and platform build ID.
2. Pull `:latest` for every active package in `config/packages.txt`.
3. Require exact PBID, SDK reference and package-architecture compatibility.
4. Replace the previous version of that package in the candidate snapshot.
5. Enforce exactly one IPK per package.
6. Generate and sign `Packages`, `Packages.gz`, `Packages.manifest` and `Packages.sig` using the exact immutable NIK SDK.
7. Generate `feed.json` with OpenWrt version, architecture, PBID, immutable SDK reference, package versions, dependencies, file names, sizes and SHA-256 hashes.
8. Atomically deploy the clean snapshot to GitHub Pages.

A temporarily missing `:latest` package may reuse its last known-good package only when the previous feed belongs to the exact same PBID/SDK. The feed still contains at most one version of that package.

The workflow runs every 15 minutes as a fallback and accepts `repository_dispatch` event `package-published` for immediate publishing.

## Required secrets

Repository `nik-owrt/nik-feed` requires:

- `GHCR_USERNAME` — GitHub username that owns the GHCR read token.
- `GHCR_READ_TOKEN` — classic PAT with `read:packages`, authorized for the private NIK package images.
- `NIK_FEED_SIGNING_KEY` — private `usign` key. Never commit this value.

Commit only the matching public key as:

```text
keys/nik-feed.pub
```

## Active package set

See `config/packages.txt`. Archived or empty placeholder repositories are intentionally excluded.
