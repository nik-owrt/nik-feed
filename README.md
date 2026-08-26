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

## Trust model

The NIK feed public key is a firmware trust anchor. Routers must receive it from the firmware image (for example `/etc/opkg/keys/<fingerprint>`), not bootstrap trust by downloading a key from this feed.

The repository keeps `keys/nik-feed.pub` only so CI can verify the signature it just created. The Pages artifact intentionally does not publish that key.

The private signing key exists only as the `NIK_FEED_SIGNING_KEY` GitHub Actions secret and must never be committed or included in firmware.

## Publishing model

Package repositories already publish OCI images such as:

```text
ghcr.io/nik-owrt/openwrt-package-br-wifi:latest
```

The feed workflow:

1. Resolves the current immutable NIK OpenWrt SDK and platform build ID.
2. Downloads the previous public feed snapshot when one exists.
3. Pulls the latest OCI image for every active package in `config/packages.txt`.
4. Rejects packages built for a different platform build ID.
5. Merges new IPKs with the previous snapshot and keeps the latest 3 versions per package.
6. Generates `Packages`, `Packages.gz`, `Packages.manifest` and `Packages.sig` using tools from the exact NIK OpenWrt SDK.
7. Verifies the signature with repository `keys/nik-feed.pub` without publishing that key to Pages.
8. Atomically deploys the new snapshot to GitHub Pages.

The workflow also runs every 15 minutes as a fallback and accepts `repository_dispatch` event `package-published` for immediate publishing.

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
