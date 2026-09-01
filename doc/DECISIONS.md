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

- **Bounties (LNbits/NWC/LNURL) and the `push_cost_sats` paywall**:
  ~~*(superseded — see item 8, this was wrong)*~~ these turned out to need
  **no server-side config at all**. Wallet details (`lud16`, `lnurl`, NWC
  connection strings) live in each user's own browser storage or Nostr
  profile metadata (`ui/src/lib/payments/resolve-repo-wallet.ts`), and the
  server-side `/api/zap/*` / `/api/bounty/*` routes just proxy whatever
  wallet the request itself supplies — there's no platform LNbits/NWC
  secret to set. `push_cost_sats` is a per-repo Nostr event tag the repo
  owner publishes from the repo settings page; the bridge reads it off the
  event straight into its own `RepositoryPushPolicy` table
  (`ui/gitnostr/cmd/git-nostr-bridge/repo.go`), no server env var involved.
  So this feature was never "off" — it was always fully available,
  peer-to-peer, exactly as upstream intends. Nothing to package.
- **`repo_owner_pubkey`**: made optional. Left blank, `gitRepoOwners` in the
  bridge config is an empty JSON array, which upstream treats as "watch all
  authors" (their default "public GRASP" mode) rather than a filter that
  matches nothing — a single stray value would have done the latter, which
  is why `scripts/_common.sh`'s `csv_to_json_array` special-cases empty
  input instead of producing `[""]`.
- **Blossom / GitHub OAuth / publisher blocklist**: originally left
  unwired here too. That turned out to be a real gap rather than a
  deliberate cut — fixed in item 8.

## 3. HTTP git vs SSH-only

**Update: HTTPS git was added later, once SSH-only had actually been
proven working end-to-end and it became clear gittr's own UI tells users
to use HTTPS — see item 17.** The reasoning below for why it was
descoped *initially* still stands as the reasoning for that sequencing
choice.

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
`go.mod` requires `go 1.25.0`.

**Correction (item 9): this was the wrong API.** `helpers.v1.d/go` is the
legacy v1 helper set; this package declares `helpers_version = "2.1"`,
which sources `helpers.v2.1.d/go` instead — a completely different,
resource-based API. See item 9 for the real fix (this caused the first
actual install attempt to fail outright).

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

**At the time this item was written**, GitHub OAuth, Blossom URLs, and the
publisher blocklist were also left unexposed here. That was later
identified as a real gap (not a deliberate cut) and fixed — see item 8.
Bounties/`push_cost_sats` need no config at all — see the correction in
item 2.

**Still genuinely left as manual edits, deliberately, because they're
operational infrastructure rather than app config**: the leaderboard/
SEO-snapshot systemd timers (`infra/systemd/*.timer` upstream — without
them, "Most Active"/sitemap features do a live relay scan per request
instead of reading a warm cache; see item 7 for the sitemap half of this),
the CVE-alert bot, Telegram notifications, and the WoT oracle URL override.
None of these are required for the app to work, and wiring them in would be
a lot of surface for what they add — per `config_panel.toml.example`'s own
"keep things simple" framing.

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

## 8. GitHub OAuth, Blossom storage, publisher blocklist

Asked directly whether GitHub OAuth, Blossom storage, bounties/paywall, and
the publisher blocklist were properly accounted for. They weren't — see
item 2 for the bounties correction (no work needed there); this item
covers the three that were a real gap and are now wired up, config-panel
only (no install-time question — these are optional/advanced, and the
"keep things simple" install wizard shouldn't grow five more questions for
features most installs won't touch).

- **GitHub OAuth** (`github_client_id`, `github_client_secret`) and the
  separate, unrelated **platform token** (`github_platform_token`, raises
  GitHub API rate limits from 60/hr to 5000/hr — confirmed via
  `ui/GITHUB_PLATFORM_TOKEN_SETUP.md`, a personal access token, nothing to
  do with the OAuth App). All three are consumed via plain `process.env` in
  Next.js API routes (`ui/src/pages/api/github/auth.ts`, `callback.ts`,
  `graphql.ts`) — **server-only**, not `NEXT_PUBLIC_*`, so changing them
  needs a service restart, not a UI rebuild. Deliberately **not** put in
  `conf/systemd-ui.service` as inline `Environment=` lines even though
  that would have worked functionally: systemd unit files are
  world-readable, and `package_linter`'s own
  `systemd_config_harden_security` check explicitly greps
  `Environment=.*(pass|secret|key)` and errors on a match — `client_secret`
  and `platform_token` would both trip it. Put them in a new
  `conf/ui-runtime.env.j2` → `$install_dir/ui/.env.runtime` instead,
  `chmod 600`, loaded via `EnvironmentFile=-...` (not `Environment=`).
  `GITHUB_REDIRECT_URI` is derived (`https://$domain/api/github/callback`)
  and regenerated in `scripts/change_url` too, since a domain change means
  the OAuth callback URL registered with GitHub needs updating by hand
  regardless.
- **Blossom storage** (`blossom_url` → `NEXT_PUBLIC_BLOSSOM_URL`). This one
  *is* `NEXT_PUBLIC_*` — build-time baked, same rebuild story as
  `nostr_relays`. Defaults to upstream's own in-code default
  (`https://blossom.band`, confirmed in `ui/.env.example`) rather than an
  empty value, so the config-panel field always shows something sensible
  rather than blank-meaning-something-implicit.
- **Publisher blocklist** (`publisher_blocklist`) is really *two* upstream
  vars for one concept — confirmed in `ui/.env.example`'s own comment:
  `NEXT_PUBLIC_PUBLISHER_BLOCKLIST` (client-visible, build-time) hides
  entries from browser-rendered lists, `PUBLISHER_BLOCKLIST` (server-only,
  runtime) does the same for the API and sitemap. One config-panel
  question now feeds both — `conf/ui.env.j2` for the public one,
  `conf/ui-runtime.env.j2` for the server one — so a change always
  triggers a full rebuild (needed for the public half) even though the
  server half alone wouldn't have required one.

`scripts/config` factors the repeated "write bridge config" / "rebuild UI"
/ "write runtime env + restart" sequences into `rewrite_bridge_config`,
`rebuild_ui`, and `write_ui_runtime_config` helpers rather than repeating
them across five new setters.

Re-ran `package_linter` after adding all of this — no new findings.

## 9. Go/Node.js: fixed for real (v2.1 helpers use a resource-based API)

The first actual install attempt against a real YunoHost instance
(12.1.40.1) failed immediately:

```
+ ynh_install_go --go_version=1.25
./install: line 14: ynh_install_go: command not found
```

Root cause: `ynh_install_go`/`ynh_use_go`/`ynh_remove_go` (and the
equivalent nodejs trio) are the **v1** helper API
(`helpers/helpers.v1.d/go`), which I'd fetched and used without checking
whether the **v2.1** set — which is what this package's own
`helpers_version = "2.1"` actually sources — kept the same function names.
It doesn't. `package_linter` never caught this because it only checks that
*used* helper names are known and version-compatible, not that a
*declared* `helpers_version` and the helper calls in the scripts actually
agree on which API generation to use — a linter gap, not something to
blame on the tool.

`helpers.v2.1.d/go` and `helpers.v2.1.d/nodejs` redesigned both as
**manifest resources**, matching how `system_user`/`install_dir`/`ports`/
`apt` already work in packaging_format 2 — provisioned automatically by
the resource system, not invoked from scripts at all:

```toml
[resources.go]
version = "1.25"

[resources.nodejs]
version = "20"
```

Sourcing `/usr/share/yunohost/helpers` (already the first line of every
script) then **automatically** puts `go`/`make`/`node`/`npm` on `$PATH` —
confirmed by reading the actual source: each helper file runs
`if [ -n "${go_version:-}" ] && (manifest has resources.go); then
_ynh_load_go_in_path_and_other_tweaks; fi` as top-level code the moment
it's sourced, not inside a function you have to call. `$go_version` /
`$nodejs_version` are ambient (auto-loaded app settings, same mechanism as
`$domain`), so this fires correctly in every script once the resource has
been provisioned once at install.

Consequences, fixed across the board:

- `scripts/install`, `scripts/upgrade`, `scripts/change_url`,
  `scripts/config`: removed every `ynh_install_go`/`ynh_use_go`/
  `ynh_install_nodejs`/`ynh_use_nodejs` call. `make`/`corepack`/`yarn` are
  just called directly now.
- `scripts/restore`: removed the explicit toolchain-reinstall block
  entirely — resource reprovisioning (including `resources.go`/
  `resources.nodejs`) happens automatically before `scripts/restore` runs,
  same as `apt`/`system_user` always did. Kept regenerating the systemd
  units from templates rather than trusting a raw restored copy, since
  `$go_dir`/`$nodejs_dir` are still absolute paths that *could* differ
  after a restore onto different hardware.
- `scripts/remove`: removed `ynh_remove_nodejs`/`ynh_remove_go` (also the
  wrong v1 names, would have failed the same way on an actual removal) —
  resource deprovisioning is automatic here too.
- `conf/systemd-ui.service`: `ExecStart` used `__YNH_NODE__` (the v1
  helper's `$ynh_node` variable, which no longer exists). Replaced with
  `__NODEJS_DIR__/node` (`$nodejs_dir`), taken directly from the v2.1
  helper's own docstring example.

Lesson applied elsewhere in this file: every other "confirmed via actual
source" claim in this document (`ynh_setup_source`'s `--keep`, the ports
resource, `ynh_restore` vs `ynh_restore_file`, etc.) was checked against
`helpers.v2.1.d/*` specifically, not `v1.d`. This one slipped through
because the v1 and v2.1 function *names* looked equally plausible and I
didn't cross-check the file that actually gets sourced for this
`helpers_version`. Not proud of it, but better to record the miss
precisely than bury it.

## 10. `go build`: module cache location

Second real-install failure, one step further than item 9's fix (which
worked — `resources.go`/`resources.nodejs` provisioned Go 1.25.13 and Node
20.20.2 cleanly):

```
go build -tags netgo -ldflags="-s -w" -trimpath -o ./bin/git-nostr-bridge ./cmd/git-nostr-bridge
go: module cache not found: neither GOMODCACHE nor GOPATH is set
make: *** [Makefile:5: git-nostr-bridge] Error 1
```

`$HOME` isn't set in the environment `scripts/install`/`scripts/upgrade`
run in, and Go derives its default `GOPATH` (and from that, `GOMODCACHE`)
from `$HOME` — with neither set, `go build` has nowhere to put downloaded
module sources and refuses to proceed. Fixed by exporting `GOPATH`
(and `GOCACHE`, for the build cache) explicitly, at a path outside
`$install_dir` so it doesn't get swept up in `_ynh_apply_default_permissions`
or complicate `--keep` on upgrade:

```bash
export GOPATH="/var/cache/yunohost/gittr-go-build"
export GOCACHE="$GOPATH/build-cache"
mkdir -p "$GOPATH"
```

`/var/cache/yunohost/` is YunoHost's own convention for this kind of
scratch state (already used for the source tarball download cache, visible
in the same install log). Left in place across upgrades deliberately — it
speeds up `go build` by reusing the module cache — but cleaned up in
`scripts/remove`, since it isn't tracked by any resource and would
otherwise be orphaned after the app is removed.

Not needed in `scripts/restore`: restore doesn't rebuild the bridge, it
restores the already-built binary from the backup archive.

## 11. The v1-vs-v2.1 rename goes much further than Go/Node

Prompted by the user asking "was also getting warnings about
`ynh_secure_remove`?" after the item 10 fix — checking that one
(`ynh_secure_remove --file=X` → `ynh_safe_rm X`, positional, no
backward-compat alias, same pattern as item 9) turned up the fact that
item 9 was not an isolated incident: v2.1 renamed a **whole family** of
config/service helpers under a `ynh_config_*` prefix, plus a couple of
others. Rather than wait for each one to surface as its own runtime
failure, audited every `ynh_*` call in every script against the actual
downloaded `helpers.v2.1.d/*.sh` source (not GitHub code search, which
returned false negatives more than once in this session — read the files
directly). Full rename table:

| v1 (what this package had) | v2.1 (correct) | Note |
|---|---|---|
| `ynh_add_config --template= --destination=` | `ynh_config_add` (same args) | |
| `ynh_add_nginx_config` | `ynh_config_add_nginx` (no args) | |
| `ynh_remove_nginx_config` | `ynh_config_remove_nginx` (no args) | |
| `ynh_change_url_nginx_config` | `ynh_config_change_url_nginx` (no args) | |
| `ynh_add_systemd_config --service= --template=` | `ynh_config_add_systemd` (same args) | |
| `ynh_remove_systemd_config --service=X` | `ynh_config_remove_systemd X` | **positional now**, no `--service=` |
| `ynh_systemd_action --service_name=X --action=Y --log_path=Z` | `ynh_systemctl --service=X --action=Y --log_path=Z` | arg renamed `service_name`→`service` |
| `ynh_exec_warn_less CMD` | `ynh_exec_and_print_stderr_only_if_error CMD` | |
| `ynh_secure_remove --file=X` | `ynh_safe_rm X` | **positional now**, no `--file=` |
| `ynh_backup --src_path=X` | `ynh_backup X` | **positional now**, no `--src_path=` — see below |

The `ynh_backup` one is the nastiest of the batch: unlike the others, it
does **not** fail loudly. `ynh_backup()`'s v2.1 body is
`local target="$1"` with no getopts parsing at all, so
`ynh_backup --src_path="$install_dir"` would have set `target` to the
literal string `--src_path=/var/www/gittr`, hit
`[ ! -e "$target" ]`, printed `ynh_print_warn "File or folder
'--src_path=/var/www/gittr' to be backed up does not exist"`, and
`return 1` — no crash, no abort, just a backup archive **silently missing
everything**. Would only have been discovered the day someone actually
needed to restore from a backup. Confirmed by reading `ynh_backup`'s and
`ynh_restore`'s bodies directly in `helpers.v2.1.d/backup.sh` rather than
assuming symmetry between the two.

`ynh_restore` itself turned out to already be correct — it was already
positional (`ynh_restore "$install_dir"`) from when it was first written,
so no change needed there. `ynh_app_setting_get`/`_set` (`--app=` `--key=`
`--value=`) and `ynh_setup_source` (`--dest_dir=` `--source_id=`
`--keep=`) were also double-checked against the v2.1 source directly and
found to already be correct as originally written.

Applied via `sed` across `scripts/install`, `upgrade`, `restore`,
`remove`, `change_url`, `config`, `backup` for the mechanical renames, then
hand-fixed the two argument-shape changes (`ynh_config_remove_systemd`,
`ynh_systemctl`) and `ynh_backup` separately since a blind rename would
have been wrong for those. Re-verified afterward by grepping every
`ynh_*` call actually used across the whole package and confirming each
one's function definition exists, by name, in the actual downloaded
`helpers.v2.1.d/*.sh` files — not by re-reading my own conclusions.

`package_linter` was re-run after this fix too, same as after items 9 and
10: still clean, still only the three items in item 0. It has no way to
catch any of this — it doesn't cross-reference helper calls against the
declared `helpers_version` at all. Worth being explicit about since it
means passing the linter here proves nothing about this whole class of
bug; only reading the actual v2.1 source (as done now, comprehensively)
or an actual install/backup/restore run against a real instance can.

## 12. `corepack prepare yarn@stable` resolves to the wrong Yarn entirely

Third real-install failure, one step past item 11's fix (Go built cleanly
this time — both `git-nostr-bridge` and `git-nostr-ssh` — and every
`ynh_config_*`/`ynh_systemctl` call worked):

```
➤ YN0087: Migrated your project to the latest Yarn version 🚀
➤ YN0000: · Yarn 4.18.0
...
➤ YN0028: │ The lockfile would have been modified by this install, which is explicitly forbidden.
➤ YN0000: · Failed with errors in 11s 722ms
```

`ui/yarn.lock` starts `# yarn lockfile v1` — **Yarn Classic (1.x)**, not
Berry, and there's no `.yarnrc.yml` or `packageManager` field in
`package.json` to pin it automatically (checked both directly). But
`corepack prepare yarn@stable --activate` resolved to **Yarn 4.18.0**
(Berry) — a different, incompatible tool with its own lockfile format.
Berry's `yarn install` saw the v1 lockfile, silently rewrote it to Berry's
format ("Migrated your project..."), and then refused to proceed anyway
because `--frozen-lockfile` forbids exactly that kind of implicit
modification.

Fixed by pinning Yarn Classic explicitly rather than trusting `@stable`:
`YARN_VERSION="1.22.22"` in `_common.sh` (the current `latest` dist-tag
for the classic `yarn` npm package, confirmed via the registry rather than
assumed), used as `corepack prepare yarn@$YARN_VERSION --activate` in both
`scripts/install` and `scripts/upgrade`. `--frozen-lockfile` itself was
already correct — it's the native Classic flag; the `YN0050 deprecated`
warning seen in earlier reasoning about this only fires under Berry, which
is precisely the tool we shouldn't have been running in the first place.

## 13. First full install succeeded; two runtime failures on first boot

Install completed end-to-end for the first time — source, Go build, UI
build, config, systemd, nginx all worked. Both new failures are the
services actually starting on a real box, caught from `journalctl`:

**`gittr-bridge` — `bind: address already in use` on :8080, looping every
5s.** The bridge's HTTP listener has no way to disable itself (see item
3) and defaults to port 8080 if `BRIDGE_HTTP_PORT` isn't set — which this
package never set, so it collided with something else already using 8080
on the test box. Not hypothetical once a package actually shares a real
server. Fixed by adding a `resources.ports.bridge_http` entry (default
8080, same as before, but YunoHost will now shift it to a free port if
that one's taken, same as `git_ssh` already does) and setting
`Environment=BRIDGE_HTTP_PORT=__PORT_BRIDGE_HTTP__` in
`conf/systemd-bridge.service`. Still not `exposed = "TCP"` — it's not
meant to be reachable from outside regardless of which port it lands on.

**`gittr-ssh` — killed by signal 31 (SIGSYS) immediately on every start,
restart-looping.** SIGSYS on process start is the specific, recognizable
signature of a systemd `SystemCallFilter=` seccomp denial (default action
for a filtered-out syscall is to kill with SIGSYS unless
`SystemCallErrorNumber=` is set). `conf/systemd-ssh.service`'s hardening
included `SystemCallFilter=~@clock @debug @module @mount @obsolete
@reboot @swap @cpu-emulation @privileged` — item in the original hardening
pass (before any real sshd ran under it) already excluded `@setuid` on the
theory that sshd's self-referential session setup needs it even
authenticating as itself, but evidently something else sshd calls falls
under `@privileged` too (a broad systemd syscall group — capset, chroot,
setgroups, and others). Rather than guess again which single syscall to
carve out of that list and risk being wrong a second time, removed
`SystemCallFilter=` from this unit entirely — the rest of the hardening
(`NoNewPrivileges`, `ProtectSystem=full`, `RestrictNamespaces`, etc.)
stays, since nothing points to those being the problem. `bridge`/`ui`'s
own `SystemCallFilter=` (identical list) are untouched — the bridge
process actually ran under it without incident (it failed on the port
bind, not a syscall kill), so there's no evidence they need the same fix,
and changing them without evidence would just be trading one guess for
another.

Both fixes are consistent with the running theme of this document: guess
at your own risk, but the real signal is what a live instance's logs
actually say.

## 14. No portal tile, and the domain fell through to the SSO login page

All three services stayed up this time (items 9–13's fixes held) — this
one surfaced by the user just visiting the site: the app's domain
(`gittr.$domain`) redirected to `https://$maindomain/yunohost/sso/`
instead of showing gittr, and that portal had no tile for the app at all.

Root cause: **`manifest.toml` never declared `[resources.permissions]` or
`[install.init_main_permission]`, at all.** I'd assumed — wrongly, and
without checking — that a usable default permission gets auto-created the
same way `system_user`/`install_dir` do. It partly does: `PermissionsResource.__init__`
in YunoHost core does inject a `main` entry if the whole block is missing
(`if "main" not in properties: properties["main"] = copy.copy(self.default_perm_properties)`).
But that default has `url = None` and `allowed = None`. Two consequences,
both observed:

- `show_tile` defaults to `bool(properties[perm]["url"])` — with `url`
  unset, that's `False`. No tile, exactly as reported.
- With `allowed = None` (nobody) and no `url` to anchor a real SSOwat rule
  at `$domain/$path`, there's no permission entry mapping the app's
  domain/path to anything — so nginx/SSOwat's fallback for an unmatched
  request is the portal login page. Matches "goes to
  `.../yunohost/sso/`" exactly.

Fixed by adding, matching the exact pattern in `YunoHost/example_ynh`'s
own manifest (checked directly rather than assumed, given how many
"obvious" assumptions in this document have turned out wrong):

```toml
[install.init_main_permission]
type = "group"
default = "visitors"

[resources.permissions]
main.url = "/"
```

`init_main_permission` is a **generic, reserved** install question name —
YunoHost's core handles its `ask` string and its public/private semantics
itself (`visitors` = public, `all_users` = any logged-in YunoHost user);
it is *not* saved as a regular app setting, it seeds the `main`
permission's initially-allowed group directly. Defaulted to `visitors`
(public): gittr has its own Nostr-based login (NIP-07 / pubkey), not a
YunoHost-account gate, consistent with `sso = false` / `ldap = false`
already declared in `[integration]` — and a self-hosted git forge nobody
can browse or clone from without first having a YunoHost account on that
specific server isn't very useful. An admin who wants it gated to logged-in
YunoHost users instead can flip this after install via `yunohost user
permission update gittr.main --add all_users --remove visitors` or the
webadmin's Permissions panel.

This is a good one to flag as a category, not just an instance: it's the
second time in this document (`[resources.database]` in the original
sketch being the first) that "this whole resource block can just be
omitted, defaults are fine" turned out to be true for the *provisioning*
half of a resource but silently wrong for making the app *actually usable*
once provisioned. Worth treating any manifest resource's documented
defaults with the same "did I check what happens when I omit this
entirely" skepticism as a helper call, not just the ones that fail loudly
at install time.

One operational note from diagnosing this live: `init_main_permission` is
consulted **only** at the moment a permission is first created
(`PermissionsResource.provision_or_update`, `if perm not in existing_perms:`
gates the `allowed=` assignment). An `allowed` group, once set, is
deliberately left alone on every later `provision_or_update` — an upgrade
does not retroactively grant `visitors` to a permission that was created
under an older manifest without it. `show_tile` *does* get recalculated
unconditionally on every provision (it's outside that `if` block), so an
upgrade should fix a missing tile even on an old install, but not a wrong
`allowed` group — that needs `yunohost user permission update gittr.main
--add visitors` by hand, or a fresh install, once.

## 15. `gittr-ui` crash-looping: `AF_NETLINK` needed for `os.networkInterfaces()`

Found by the user directly asking "should gittr-ui even be running?" —
it wasn't, while bridge and ssh were both up. `journalctl -u gittr-ui`:

```
NodeError [SystemError]: A system error occurred: uv_interface_addresses
returned Unknown system error 97 (Unknown system error 97)
    at Object.networkInterfaces (node:os:223:16)
    at getNetworkHosts (.../next/dist/lib/get-network-host.js:18:36)
```

errno 97 is `EAFNOSUPPORT`. Next.js's `next start` calls
`os.networkInterfaces()` at boot to print the "available on your network"
banner — on Linux that's `getifaddrs()`, which needs an `AF_NETLINK`
socket. `conf/systemd-ui.service`'s `RestrictAddressFamilies=AF_UNIX
AF_INET AF_INET6` doesn't include it, so the kernel refuses the socket and
Next.js dies on every single start — the same category of self-inflicted
hardening bug as item 13's SSH SIGSYS, just a blocked address family
instead of a blocked syscall.

Rather than widen the sandbox (add `AF_NETLINK`), found a tighter fix by
reading Next.js's own source
(`packages/next/src/server/lib/start-server.ts`): the network-host lookup
is `hostname ?? getNetworkHost(...)` — it only runs when `next start` is
given **no** explicit `-H`/`--hostname`. `conf/nginx.conf` already proxies
to `127.0.0.1:$port` specifically (not `0.0.0.0`/`localhost`), so the UI
never needed to listen on all interfaces in the first place. Added
`-H 127.0.0.1` to `ExecStart` in `conf/systemd-ui.service` — this skips
the network-host lookup entirely (no `AF_NETLINK` needed, sandbox stays as
tight as before) and narrows the actual listen scope to match what nginx
was already assuming, which is strictly better than just permitting the
wider socket family.

## 16. Config panel crashed entirely: `str` has no `.get()`

App up, tile showing, then the user hit "Unexpected server error" just
opening the config panel — before changing anything. Got the real
traceback via `yunohost app config get gittr --full --debug`:

```
File ".../yunohost/utils/configpanel.py", line 157, in __init__
    options = self.options_dict_to_list(kwargs, optional=optional)
File ".../yunohost/utils/form.py", line 1953, in options_dict_to_list
    "id": data.get("id", id_),
AttributeError: 'str' object has no attribute 'get'
```

Traced it through `configpanel.py` (`ConfigPanel.get` →
`_get_config_panel` → `ConfigPanelModel(**raw_config)`, where `raw_config`
is `_get_raw_config()` — i.e. this app's `config_panel.toml`, read as-is,
no bash-side `__VAR__` templating applied to it at all, confirmed by
reading the loading code directly) down through `PanelModel.__init__`
(sections = `[data | {"id": name} for name, data in kwargs.items()]`) into
`SectionModel.__init__` → `OptionsModel.options_dict_to_list`, which
iterates a section's leftover kwargs expecting every value to be a dict
(an option's own sub-table) and calls `.get()` on it. Confirmed by
hand-tracing that every value in `config_panel.toml`, parsed with Python's
builtin `tomllib`, is correctly typed — no plain strings where dicts
belong.

The catch: **YunoHost's core doesn't use `tomllib`.**
`src/utils/file_utils.py`'s `read_toml()` does `import toml; toml.loads(...)`
— the older third-party `toml` PyPI package. Reparsing the exact same file
with that library (installed and run directly, not assumed) reproduced the
crash precisely: a dotted key whose value is a **multi-line triple-quoted
string** —

```toml
help.en = """\
some text \
"""
```

— gets mis-parsed. Instead of nesting correctly, it produces an *empty*
`help = {}` and leaks the actual text up as a **sibling key literally
named `en`**, at whatever level the dotted key was written. For options
(`[main.nostr.nostr_relays]`'s `help.en`) that's mostly harmless — an
extra unexpected attribute on that option. For **sections**
(`[main.github]`'s `help.en`, at section level) it's fatal: that stray
`en: "<long string>"` becomes a phantom "option" entry when
`options_dict_to_list` iterates the section's kwargs, and `data` for it is
the plain string — exactly the crash. Single-line dotted keys
(`ask.en = "one line"`, `name.en = "..."`) parse correctly with the same
library — confirmed by testing that specific case directly too. It's
specifically the multi-line + dotted-key combination this library gets
wrong.

Fixed by flattening every `help.en = """multi-line"""` block in
`config_panel.toml` to a single line. Checked `manifest.toml` for the same
pattern — it never used multi-line strings for `ask`/`help`, so it was
never affected; confirmed by parsing it with the actual `toml` library
too, not assumed clean by analogy.

Given how much time hand-tracing pydantic internals cost before actually
reproducing this with the real library, the lesson for next time: when a
TOML file is involved and the failure is downstream of parsing it, install
and run the *exact* parsing library in question against the *exact* file
before doing anything else — `tomllib` (or any other spec-compliant
parser) passing doesn't mean the actual consumer's parser agrees.

## 17. HTTPS git, added

User pushed back on item 3's original descoping: gittr's own website tells
users to `git clone https://...`, so SSH-only isn't actually meeting the
app where its own UI points people. Fair — and by this point SSH-only had
been proven working end-to-end on a real instance (items 9–16), so the
"prove the simple path works first" reasoning behind the original descope
had done its job. Built it properly rather than as an afterthought,
starting from upstream's actual production config
(`nginx.gittr.conf.example` at the repo root, pinned tag) rather than
reconstructing from the docs summary alone.

**What upstream's reference config does, and what this package keeps vs.
drops:**

- `git-http-backend` behind `fcgiwrap`, private repos gated by nginx
  `auth_request` to the UI's own `/api/git/http-auth` — kept, this is the
  actual mechanism, no simpler alternative exists.
- A `git-http-backend-quiet` wrapper (redirects stderr) — kept.
  `git-http-backend` writes progress to stderr; through fcgiwrap that can
  corrupt the FastCGI response for smart-HTTP clients.
- `uploadpack.allowFilter=true` etc. per bare repo, for browser git
  clients (gitworkshop.dev) — **not needed**, the bridge already applies
  this automatically on repo creation (`ensureUploadPackBrowserCaps`,
  confirmed in `docs/GIT_NOSTR_BRIDGE_SETUP.md`), nothing for the package
  to do.
- CORS headers, the `gitworkshop.dev` `Referer`-sniffing redirect, and the
  NIP-05-identifier URL resolver (`/api/git/nip05-resolve`) — **dropped**.
  These exist specifically for in-browser git clients and human-readable
  identifiers in clone URLs; upstream's own docs are explicit that plain
  CLI `git clone`/`ls-remote` works without any of it ("CLI `git ls-remote`
  working is not enough. Browser clients also need: ..."). Out of scope
  for what was actually asked (`git clone` working over HTTPS).
  `NEXT_PUBLIC_GIT_SERVER_URL` isn't overridden by this package, so clone
  URLs the UI shows already default to `https://$domain` — nothing extra
  needed for that either.
- `listen 443 ssl;` without `http2` (large packs reportedly failing
  mid-stream over HTTP/2 for some clients) — **not applicable**: that's a
  `listen`/server-block-level directive, controlled by YunoHost's own
  domain-level nginx config, not something an app-level `conf/nginx.conf`
  snippet can set.
- A dedicated `git.subdomain` — **not used**. Upstream dedicates a whole
  subdomain (and thus a whole separate `listen 443` server block) to git
  traffic; this package has one domain, so the git-http `location` block
  is added to the *same* server block as everything else, matching how
  `NEXT_PUBLIC_GIT_SERVER_URL` already defaults to the main domain when
  unset. Only supports a root-path install (`path = "/"`, this package's
  default) — a non-root install would need `PATH_INFO` to have the path
  prefix stripped before reaching `git-http-backend`, which this doesn't
  attempt.

**fcgiwrap runs as a second, dedicated instance, not the shared system
one** — same reasoning as the dedicated `sshd` in item 3: fcgiwrap
normally runs as `www-data` (the Debian package's own `fcgiwrap.socket`/
`.service`, left alone — other apps may depend on it), and upstream's own
setup notes the friction this causes directly: *"fcgiwrap runs as www-data
(must be in group git-nostr). Owner hex dirs under GIT_PROJECT_ROOT need
mode 0750; 0700 causes 404 here while SSH still works."* That's exactly
the kind of shared-system-identity coupling this package has avoided
everywhere else. A dedicated instance running as `__APP__` sidesteps it
entirely — no group-membership changes, no repo directory permission
downgrade, `$install_dir/repositories` stays owned and permissioned
exactly as SSH already needs it.

**Verified `fcgiwrap`'s actual CLI flags from its own source**
(`gnosek/fcgiwrap` on GitHub) rather than trusting the sketch/memory,
given this document's track record on exactly that kind of assumption:
`-c <n>` is the prefork worker count (used, `-c 4` — upstream's own docs
call out that Ubuntu's single-worker default serializes every clone/fetch
under concurrent load). `-f` is **not** "run in foreground" as the flag
letter suggests — it means *"send the CGI's stderr over FastCGI"*,
confirmed directly in `fcgiwrap.c`'s own `-h` text. That's the literal
opposite of what `git-http-backend-quiet` exists to prevent, so it's
deliberately never passed. No `-s` (socket) flag either: fcgiwrap
natively supports systemd socket activation
(`sd_listen_fds`, compiled in on Debian/Ubuntu builds) — confirmed in the
source, not assumed — so `conf/systemd-fcgiwrap.socket` creates and owns
the listening socket via `SocketUser=`/`SocketGroup=www-data`/
`SocketMode=0660` (nginx connects as `www-data` via the group bit), and
`fcgiwrap.service` just picks up the inherited file descriptor with no
explicit socket flag at all.

**`ynh_config_add_systemd` and `ynh_config_remove_systemd` only know
`.service`/`.mount`** (confirmed by reading their source, in
`helpers.v2.1.d/systemd`) — there's no built-in helper for `.socket`
units. `scripts/install`/`upgrade`/`restore` write the `.socket` file via
a plain `ynh_config_add` call and `systemctl enable`/`daemon-reload`
by hand; `scripts/remove` stops/disables/removes it the same way.

**Systemd hardening kept deliberately lighter** on the new
`gittr-fcgiwrap.service` than the other three units: no
`SystemCallFilter=`, no `RestrictAddressFamilies=`. Both of those exact
directives already crash-looped a real service in this package twice
(items 13 and 15) from blocking something the process legitimately
needed, and `fcgiwrap` forking into `git-http-backend` forking into `git
upload-pack`/`receive-pack` per request is a wider, less-familiar syscall
and socket surface than either of those prior cases — guessing a filter
here without a live box to verify against risks the same failure a third
time for no verified benefit.

Not yet confirmed on a live instance — next thing to watch for.
