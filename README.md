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
ghcr.io/nik-owrt/openwrt-package-fr-wifi:latest
```

The feed is a rolling snapshot, not a package archive:

1. Resolve the current NIK SDK/platform generation used to sign and index the feed.
2. Read package compatibility policy from `config/compatibility.json`.
3. Resolve `architecture-all` modules from their independent `:latest` aliases.
4. Resolve ABI-sensitive packages such as `br-core` from `compat-<userspace-abi-id>`.
5. Replace only the package that has a newer compatible artifact; unrelated packages remain untouched.
6. Enforce exactly one IPK per package.
7. Validate real IPK architecture (`all` for independent modules; platform arch for ABI-sensitive modules).
8. Generate and sign `Packages`, `Packages.gz`, `Packages.manifest` and `Packages.sig` with the current immutable NIK SDK.
9. Generate `feed.json` containing feed-generation PBID/SDK plus per-package version, dependencies, SHA-256, source PBID, source SDK, compatibility mode and immutable OCI digest.
10. Atomically deploy the clean snapshot to GitHub Pages.

This means a new `fr-wifi` can be built and published later and become immediately available through `opkg upgrade fr-wifi` without rebuilding firmware. PBID and SDK remain provenance; only packages whose compatibility mode requires platform ABI matching are locked to a compatibility generation.

If a compatible package publication is temporarily unavailable, the feed may retain its previous compatible package. It still retains at most one version of that package.

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
