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
