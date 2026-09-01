# Open questions — resolved

This records what changed from `doc/SKETCH.md` after checking the actual
upstream source (`arbadacarbaYK/gittr`, `ui/gitnostr/` bridge) instead of
guessing. Re-verify anything version-specific before trusting it blindly —
this repo is under active development (pushed daily as of 2026-09-01).

## 0. Linter run (YunoHost `package_linter`)

Ran `package_linter.py` against this repo. Accepted, not fixed, on purpose:

- **`conf/sshd_config.j2:12` binding to `0.0.0.0`.** The linter's heuristic
  assumes ports are meant to sit behind nginx/SSO. `$port_git_ssh` is raw
  SSH, not HTTP — it has to be reachable directly from the internet, SSO
  can't proxy it. `ListenAddress 0.0.0.0` (IPv4-only, not the wildcard `::`)
  is deliberate.
- **Catalog checks** ("not in YunoHost's catalog", "not flagged working",
  "no category"). Expected — this targets a custom catalog
  (`imattau/nostr_catalog_ynh`), not `github.com/YunoHost/apps`.
- **README badge warning.** The linter wants either the official
  README-generator's marker text or a working `dash.yunohost.org` badge for
  a catalog-listed app id. Neither applies here for the same reason as
  above — `README.md` says so explicitly instead of faking the marker.

Everything else the linter flagged was a real issue and got fixed: helpers
2.0→2.1 declaration, missing `ask` strings, wrong `_common.sh` source path
in backup/restore, missing `LICENSE`/`README.md`/`tests.toml`, inconsistent
`yunohost service add` calls between install/upgrade/restore, and missing
systemd sandboxing directives.

One more accepted-not-fixed: the linter still reports "encouraged to harden
security" (ⓘ, non-blocking) for all three `conf/*.service` files even after
`CapabilityBoundingSet`, `Protect*`, `SystemCallFilter`, and `PrivateTmp`
were all added. Its own check
(`tests/test_configurations.py::systemd_config_harden_security`) greps for
`^\s{directive}=` — a literal single whitespace before the directive name,
missing the `*` that would make it "any amount of leading whitespace
including none". Directives at column 0 (the normal style, and what
`example_ynh`'s own reference file uses) never match. Confirmed by testing
the regex directly rather than assuming — this is a linter bug, not a real
gap; not worth reformatting the files to dodge it.

## 1. Pin a commit

Pinned to tag **`v0.2.6`** (latest as of 2026-09-01, matches `go.mod`'s
`go 1.25.0` requirement) via `manifest.toml`'s `[resources.sources.main]`
url/sha256 — not a `git clone` in the install script. Bumping the version
means editing that url/sha256 pair and re-testing the build, not editing
`scripts/_common.sh`.

## 2. Optional features default off

- **Bounties (LNbits/NWC/LNURL) and the `push_cost_sats` paywall**: these
  are configured via UI env vars (`NOSTR_NSEC`, LNbits keys, etc.) that this
  package's `conf/ui.env.j2` simply never sets. Nothing to disable — they're
  off by omission.
- **`repo_owner_pubkey`**: made optional. Left blank, `gitRepoOwners` in the
  bridge config is an empty JSON array, which upstream treats as "watch all
  authors" (their default "public GRASP" mode) rather than a filter that
  matches nothing — a single stray value would have done the latter, which
  is why `scripts/_common.sh`'s `csv_to_json_array` special-cases empty
  input instead of producing `[""]`.
- **Blossom / Pages**: not wired up at all in this package (no
  `NEXT_PUBLIC_BLOSSOM_URL` etc. set) — out of scope for a v0.1 self-hosted
  git-forge package, not something that needed defaulting off.

## 3. HTTP git vs SSH-only

**SSH-only for v0.1.** This turned out to be a bigger decision than the
sketch assumed, because two of its premises were wrong:

- **`git-nostr-ssh` has no listener of its own.** It's a forced-command
  binary: the bridge process itself rewrites `~/.ssh/authorized_keys` with
  `command="git-nostr-ssh <pubkey>" ssh-ed25519 ...` entries
  (`ui/gitnostr/cmd/git-nostr-bridge/sshkey.go`), and relies on a real
  OpenSSH `sshd` to invoke it per-connection via `SSH_ORIGINAL_COMMAND`.
  Upstream's own deployment docs point this at the *system* sshd via a
  `Match User` block in `/etc/ssh/sshd_config` — not something a YunoHost
  package should be touching (shared, security-sensitive, affects the
  admin's own SSH access). Instead, this package runs a **second, dedicated
  sshd instance** (`conf/systemd-ssh.service` + `conf/sshd_config.j2`),
  bound only to `$port_git_ssh`, running as the unprivileged `__APP__` user,
  with its own host key under `$install_dir/ssh/`, and
  `AuthorizedKeysFile $install_dir/.ssh/authorized_keys` — the same file the
  bridge already manages. It never needs root/setuid because it only ever
  authenticates as the one user it already runs as.
- **The bridge's HTTP port (default `:8080`) is not git-over-HTTPS.** It's
  an internal, weakly-authenticated `/api/event` fast-lane for submitting
  signed Nostr events directly instead of waiting on relay propagation. Real
  HTTPS smart-git (`git clone https://...`) needs a separate stack:
  `git-http-backend` behind `fcgiwrap`, an nginx `auth_request` to the
  Next.js app's `/api/git/http-auth` endpoint for private-repo ACLs, a
  quieted `git-http-backend` wrapper (raw stderr output corrupts the smart
  HTTP protocol), and specific `git config` flags per bare repo
  (`uploadpack.allowFilter`, etc.) for browser clients. That's a
  meaningfully larger, more fragile surface than this package takes on for
  v0.1 — descoped, not forgotten. A future version could add it as an
  opt-in config-panel toggle.
- The bridge's HTTP listener still binds `0.0.0.0:8080` unconditionally
  (there's no way to turn it off in the binary) but is deliberately **not**
  declared as a `resources.ports` entry, so it stays closed on the
  YunoHost/nftables firewall by default. If a firewall is later disabled by
  hand, that endpoint is reachable — worth a callout in `doc/ADMIN.md`.

**Known limitation this creates**: the UI's displayed `git clone` command is
built from `NEXT_PUBLIC_GIT_SSH_BASE` (just a hostname — upstream has no
"port" variant of that env var), so it will show the clone URL without the
non-standard port this package uses. Users need `-p $port_git_ssh` or an
`~/.ssh/config` `Host` entry. Flagged in `doc/ADMIN.md`; not something this
package can silently fix without patching the UI's clone-URL builder.

## 4. Go/Node version pinning strategy

Confirmed `ynh_install_go` / `ynh_use_go` / `ynh_remove_go` exist as real
YunoHost core helpers (`helpers/helpers.v1.d/go`), goenv-based, same pattern
as `ynh_install_nodejs`. Used those instead of hand-vendoring a Go tarball.
`go.mod` requires `go 1.25.0`; `GO_VERSION="1.25"` in `_common.sh` resolves
to the latest 1.25.x patch via goenv's `xxenv-latest` plugin.

Also corrected: the Makefile's `git-nostr-bridge` target builds **both**
`bin/git-nostr-bridge` and `bin/git-nostr-ssh` — there's no separate
`git-nostr-ssh` target, so the sketch's `make git-nostr-bridge git-nostr-ssh
git-nostr-cli` would have failed with "No rule to make target
'git-nostr-ssh'". `git-nostr-cli` (`gn`) is optional tooling, not built by
this package.

The UI is a `yarn`-only project (`ui/yarn.lock` is canonical, no
`package-lock.json` — `npm ci` would fail outright). Switched to
`corepack prepare yarn@stable --activate` + `yarn install --frozen-lockfile`
+ `yarn build`.

One more thing the sketch missed entirely: `NEXT_PUBLIC_*` env vars are
inlined into the client JS bundle at `next build` time, not read at
runtime. `conf/ui.env.j2` writes `ui/.env.production.local` *before*
`yarn build` runs in both `scripts/install` and `scripts/upgrade`, and
`scripts/change_url` now does a full UI rebuild (not just a systemd
restart + env swap) since the domain is baked into the bundle.

## 5. Backup/restore scripts

Sketched now (`scripts/backup`, `scripts/restore`) covering: the bridge
config (`.config/git-nostr/git-nostr-bridge.json`), the sqlite db and
`repositories/` bare-repo tree (both under `$install_dir`, so covered by the
main `ynh_backup --src_path="$install_dir"` call), the dedicated sshd's host
key + config under `$install_dir/ssh/`, and the bridge-managed
`$install_dir/.ssh/authorized_keys`. `scripts/restore` re-provisions the Go
and Node.js toolchains explicitly, since `goenv`/`n` install shared
toolchains outside `$install_dir` and aren't part of the app's own backup
archive.

Still true from the original sketch: for busy instances, `repositories/`
and the sqlite db could get large. No exclusion is implemented — if this
becomes a real problem, exclude `repositories/` from the main backup and
document a separate git-mirroring strategy instead.

## 6. Ongoing (post-install) configuration

Until this item, `nostr_relays` and `repo_owner_pubkey` were install-time
questions only — there was no supported way to change either afterward
short of hand-editing `settings.yml` and re-running `ynh_add_config`
manually. Added `config_panel.toml` + `scripts/config` so both are editable
from `yunohost app config` / the webadmin Config Panel, matching the
question IDs already established at install time (required so the config
panel mechanism and `ynh_add_config` don't drift out of sync — see the
comments in `config_panel.toml.example` upstream).

Both use `bind = "null"` with custom `get__`/`set__` functions rather than
the default file-binding, because:

- `repo_owner_pubkey` needs to become part of a JSON array
  (`gitRepoOwners`), not a raw key=value line — same `csv_to_json_array`
  logic as install/upgrade.
- `nostr_relays` additionally needs a **full UI rebuild**, not just a config
  file edit — see item 4. `set__nostr_relays` in `scripts/config` runs
  `yarn build` before restarting the UI service, so this one config-panel
  save can take a minute or two; documented in the panel's `help` text so
  it doesn't look hung.

Confirmed via YunoHost core (`helpers/helpers.v2.1.d/config`,
`_ynh_app_config_validate`) that `$nostr_relays` / `$repo_owner_pubkey` are
ambient bash variables inside both setters regardless of which one actually
changed (the framework pre-populates unchanged questions with their current
value) — so both setters can reference both variables directly without an
extra `ynh_app_setting_get` round-trip.

**Still not exposed anywhere (install or config panel), left as manual
`.env.production.local` / `git-nostr-bridge.json` edits + rebuild for an
admin who wants them**: GitHub OAuth (import/rate-limit token), Blossom
URLs (Pages/media storage — defaults to upstream's public `blossom.band`
if a self-hoster ever touches Pages), Lightning bounties / `push_cost_sats`
paywall (LNbits/NWC/LNURL keys, a whole payment-integration surface), the
leaderboard/SEO-snapshot systemd timers (`infra/systemd/*.timer` upstream —
without them, "Most Active"/sitemap features do a live relay scan per
request instead of reading a warm cache), the CVE-alert bot, Telegram
notifications, the publisher blocklist, and the WOT oracle URL override.
None of these are required for the app to work; wiring all of them into the
config panel would be a lot of surface for a v0.1 package per
`doc/DECISIONS.md`'s own "keep things simple" framing from
`config_panel.toml.example`.

## 7. Sitemap default for a single-tenant instance

`conf/systemd-ui.service` sets `SITEMAP_SKIP_NOSTR=1`. This is a
server-only var (read at request time, not baked into the client bundle
like `NEXT_PUBLIC_*`), so it's safe to change without a rebuild — unlike
items 4/6 above. Set by default because this package doesn't install
upstream's optional SEO-snapshot timer (see item 6); without either the
timer's warm cache or this flag, every visitor's `/sitemap.xml` request
would trigger a live, uncached multi-relay scan. For a single-owner
self-hosted instance, a leaner static sitemap is the better trade-off than
a slow one. An admin who wants full SEO coverage can unset this and
manually install upstream's `scripts/install-gittr-seo-repo-index-timer.sh`
— out of scope for this package (it assumes an `/opt/ngit`-shaped
deployment, not `$install_dir`).
