## Services

This app runs four systemd services:

- `gittr-bridge` — the `git-nostr-bridge` Go binary. Watches the configured
  Nostr relays, mirrors repo metadata to a local sqlite db, and rewrites
  `$install_dir/.ssh/authorized_keys` from published SSH-key (kind 52)
  events. Also always listens on `$port_bridge_http` (defaults to 8080,
  auto-shifted if that's taken — check `yunohost app show gittr`) for an
  internal `/api/event` fast-lane — not exposed through the firewall by
  default, see doc/DECISIONS.md items 3 and 13.
- `gittr-ui` — the Next.js web UI, proxied by NGINX. Depends on
  `gittr-bridge` and won't start without it.
- `gittr-ssh` — a **second, dedicated sshd instance** (separate from the
  server's admin SSH on port 22) that exists only to run `git-nostr-ssh` as
  a forced command per authorized key. It listens on the port shown by
  `yunohost app show gittr` (defaults to `2225` if free). See
  doc/DECISIONS.md item 3 for why this isn't a single binary listening
  directly.
- `gittr-fcgiwrap` — a **second, dedicated `fcgiwrap` instance** (socket-
  activated, `gittr-fcgiwrap.socket`), separate from the shared system
  `fcgiwrap` some other apps may use. Runs `git-http-backend` (wrapped to
  quiet its stderr) as the CGI handler for HTTPS git. See doc/DECISIONS.md
  item 17.

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
- **Lightning bounties, zaps, and the `push_cost_sats` push paywall need no
  server-side config and are already fully available** — every user brings
  their own wallet (Lightning address / LNURL / NWC connection string,
  entered in their own Settings or read from their Nostr profile), and
  `push_cost_sats` is a per-repo setting the repo owner publishes from
  their own repo settings page. There is nothing to enable here.
- **Changing the domain requires a UI rebuild**, not just a config reload —
  `NEXT_PUBLIC_*` vars are inlined into the client bundle at `next build`
  time. `scripts/change_url` handles this; a manual edit of
  `ui/.env.production.local` alone will not take effect until `yarn build`
  reruns.

## Upgrading from a pre-v0.1.5 install

If gittr was installed before v0.1.5, it predates this package declaring
`[resources.permissions]` / `[install.init_main_permission]` — its `main`
permission was created with nobody allowed and no tile. Upgrading fixes
the tile automatically, but **not** who's allowed to access it (that group
is only set once, when the permission is first created — an upgrade
deliberately doesn't touch it afterward). Run this once by hand:

```
yunohost user permission update gittr.main --add visitors
```

(or `--add all_users` instead, to gate it to logged-in YunoHost users). A
fresh install doesn't need this — `init_main_permission` handles it
automatically at install time.

## Changing config after install

All of the below can be changed via `yunohost app config get/set gittr` or
the webadmin's Apps → gittr → Config Panel:

```
yunohost app config get gittr
yunohost app config set gittr nostr_relays -v "wss://relay1,wss://relay2"
yunohost app config set gittr repo_owner_pubkey -v "<64-char hex pubkey>"
yunohost app config set gittr blossom_url -v "https://your-blossom-host"
yunohost app config set gittr publisher_blocklist -v "<pubkey1>,<pubkey2>"
yunohost app config set gittr github_client_id -v "<client id>"
yunohost app config set gittr github_client_secret -v "<client secret>"
yunohost app config set gittr github_platform_token -v "<personal access token>"
```

**`nostr_relays`, `blossom_url`, and `publisher_blocklist` all trigger a
full UI rebuild** (can take a minute or two) — they're `NEXT_PUBLIC_*`
vars, baked into the client bundle at build time, not read at runtime.
`repo_owner_pubkey` and the three GitHub settings only restart a service
and are fast. See doc/DECISIONS.md items 6 and 8.

### GitHub integration

Two independent things, both optional:

- **OAuth login** (`github_client_id` + `github_client_secret`) — create an
  OAuth App at <https://github.com/settings/developers> with callback URL
  `https://yourdomain/api/github/callback`, then set both values. Missing
  either one leaves GitHub login disabled with a clear in-app error;
  nothing else breaks.
- **Platform token** (`github_platform_token`) — a personal access token
  from <https://github.com/settings/tokens> (scope: `public_repo`), unrelated
  to the OAuth App above. Raises GitHub API rate limits from 60/hr to
  5000/hr for import/mirroring features. Skip it if you don't need that.

### Blossom storage

`blossom_url` defaults to upstream's own public `https://blossom.band` —
this package doesn't self-host Blossom. Point it at your own Blossom
server if you have one and want Pages/media uploads to land there instead.

### Publisher blocklist

`publisher_blocklist` hides listed pubkeys (hex or `npub1…`, comma or
space separated) from explore/home/repos listings, `/apps`, `/pages`, and
the sitemap — both the browser-rendered and server/API views (this one
setting feeds both of upstream's `NEXT_PUBLIC_PUBLISHER_BLOCKLIST` and
`PUBLISHER_BLOCKLIST`).

### Still genuinely left as manual edits

The leaderboard/SEO-snapshot systemd timers, the CVE-alert bot, Telegram
notifications, and the WoT oracle URL override aren't exposed anywhere —
they're operational infrastructure (extra timers/processes) rather than
app config, and none are required for the app to work. See
doc/DECISIONS.md item 6 if you want to wire one up by hand.

By default `/sitemap.xml` skips live Nostr relay scans
(`SITEMAP_SKIP_NOSTR=1` in `conf/systemd-ui.service`) since this package
doesn't install the SEO-snapshot timer that would otherwise back it —
see doc/DECISIONS.md item 7 if you want full SEO coverage instead.

## Data

- Bare repositories live under `repositories/` inside the app's install
  directory.
- The bridge's sqlite database is at `data/git-nostr-db.sqlite`.
- The dedicated sshd's host key and config live under `ssh/`.

All of the above are included in `ynh backup` (see `scripts/backup`), but
`repositories/` and the sqlite db can grow large on busy instances — no
exclusion is implemented yet.

## HTTPS git access

```
git clone https://yourdomain/<owner-pubkey-or-npub>/<repo>.git
```

Same URL format as SSH, just `https://` instead of `ssh://`. Served by
`git-http-backend` behind a dedicated `fcgiwrap` instance (its own
socket-activated systemd unit — `gittr-fcgiwrap.socket` /
`gittr-fcgiwrap.service` — not the shared system `fcgiwrap`, so this
doesn't touch any other app's setup). Private repos are gated by an nginx
`auth_request` to the UI's own `/api/git/http-auth` endpoint, mirroring
the same owner/permission ACL SSH already enforces — authorized users pass
a signed Nostr event the same way as any bridge API push
(`git -c http.extraHeader="X-Nostr-Auth-Event: ..."`).

Originally descoped for v0.1 (see doc/DECISIONS.md item 3) as more surface
than seemed worth it before SSH-only had even been proven working — added
once that held up and it became clear it's what gittr's own UI actually
tells users to run. Full design notes in doc/DECISIONS.md item 17,
including what was deliberately left out (CORS support for in-browser git
clients like gitworkshop.dev, and non-root-path installs).
