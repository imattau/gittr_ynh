## Services

This app runs three systemd services:

- `gittr-bridge` — the `git-nostr-bridge` Go binary. Watches the configured
  Nostr relays, mirrors repo metadata to a local sqlite db, and rewrites
  `$install_dir/.ssh/authorized_keys` from published SSH-key (kind 52)
  events. Also always listens on `0.0.0.0:8080` for an internal
  `/api/event` fast-lane — not exposed through the firewall by default, see
  doc/DECISIONS.md item 3.
- `gittr-ui` — the Next.js web UI, proxied by NGINX. Depends on
  `gittr-bridge` and won't start without it.
- `gittr-ssh` — a **second, dedicated sshd instance** (separate from the
  server's admin SSH on port 22) that exists only to run `git-nostr-ssh` as
  a forced command per authorized key. It listens on the port shown by
  `yunohost app show gittr` (defaults to `2225` if free). See
  doc/DECISIONS.md item 3 for why this isn't a single binary listening
  directly.

## SSH git access

```
git clone ssh://gittr@yourdomain:<port>/<owner-pubkey-or-npub>/<repo>.git
```

(The SSH login user is `gittr` — the dedicated `gittr-ssh` instance's
`AllowUsers` is the app's own system user, not upstream's conventional
`git-nostr`/`git` usernames, since this package doesn't create a separate
`git-nostr` account.)

Find `<port>` with `yunohost app show gittr` (config `port_git_ssh`).
**The clone URL shown inside the gittr UI itself will be missing this
port** — upstream's `NEXT_PUBLIC_GIT_SSH_BASE` env var only carries a
hostname, with no way to add a port, because upstream's own deployment
dedicates a whole subdomain to port 22 for this. Tell your users to either
add `-p <port>` / use the `ssh://host:port/...` form, or add a `Host` entry
to their `~/.ssh/config`:

```
Host yourdomain-git
    HostName yourdomain
    Port <port>
    User gittr
```

SSH keys are published as Nostr kind-52 events — via the gittr UI
(Settings → SSH Keys), the `gn` CLI (`gn ssh-key add ~/.ssh/id_ed25519.pub`,
built separately, see `ui/gitnostr/Makefile`'s `git-nostr-cli` target), or
any Nostr client. The bridge picks them up from the relays and rewrites
`authorized_keys` automatically — no restart needed.

## Configuration

- Relay list and the pubkey allowed to own/create repos are set at install
  time and written to `.config/git-nostr/git-nostr-bridge.json` (bridge)
  and `ui/.env.production.local` (UI, baked into the built JS bundle — see
  below) from `conf/bridge-config.json.j2` and `conf/ui.env.j2`.
- Leaving the owner pubkey blank switches the bridge to upstream's default
  "watch all authors" mode rather than filtering to nobody — see
  doc/DECISIONS.md item 2.
- Optional paid features (bounties via LNbits/NWC/LNURL, Blossom blobs,
  `push_cost_sats` paywall) are configured via UI env vars this package
  never sets, so they're off by default, not merely hidden.
- **Changing the domain requires a UI rebuild**, not just a config reload —
  `NEXT_PUBLIC_*` vars are inlined into the client bundle at `next build`
  time. `scripts/change_url` handles this; a manual edit of
  `ui/.env.production.local` alone will not take effect until `yarn build`
  reruns.

## Data

- Bare repositories live under `repositories/` inside the app's install
  directory.
- The bridge's sqlite database is at `data/git-nostr-db.sqlite`.
- The dedicated sshd's host key and config live under `ssh/`.

All of the above are included in `ynh backup` (see `scripts/backup`), but
`repositories/` and the sqlite db can grow large on busy instances — no
exclusion is implemented yet.

## HTTPS git access

Not implemented in this package — see doc/DECISIONS.md item 3 for why (it
needs `git-http-backend` + `fcgiwrap` + an nginx `auth_request` ACL stack
that's a meaningfully larger surface than v0.1 takes on). SSH is the only
supported transport for now.
