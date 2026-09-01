## Services

This app runs two systemd services:

- `gittr-bridge` — the `git-nostr-bridge` Go binary. Handles SSH/HTTPS git
  access and publishes repo events to the configured Nostr relays.
- `gittr-ui` — the Next.js web UI, proxied by NGINX. Depends on
  `gittr-bridge` and won't start without it.

## SSH git access

Git-over-SSH is served directly by `git-nostr-ssh` on the port chosen at
install time (default `2225`), separate from the server's admin SSH (`22`).
Clone with:

```
git clone ssh://git@yourdomain:2225/npub1.../repo.git
```

## Configuration

- Relay list and the pubkey allowed to own/create repos are set at install
  time and written to `ui/gitnostr/config.json` from
  `conf/bridge-config.json.j2`.
- Optional paid features (bounties via LNbits/NWC/LNURL, Blossom blobs,
  `push_cost_sats` paywall) are not exposed by this package and default to
  whatever upstream's own defaults are — verify before relying on them being
  off.

## Data

- Bare repositories live under `repositories/` inside the app's install
  directory.
- The bridge's sqlite database is at `data/git-nostr-db.sqlite`.

Both are included in `ynh backup`, but can grow large on busy instances —
see the note in `scripts/backup`.
