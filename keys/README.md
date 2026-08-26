# Feed signing key

Only the public `usign` key belongs in this directory:

- `keys/nik-feed.pub` — committed public key used by routers to verify the OPKG feed.
- private key — never commit it; store it only as the `NIK_FEED_SIGNING_KEY` GitHub Actions secret.

The publish workflow intentionally fails if `keys/nik-feed.pub` or the private-key secret is missing.
