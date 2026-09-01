# Open questions — resolved

This records what changed from `doc/SKETCH.md` after checking the actual
upstream source (`arbadacarbaYK/gittr`, `ui/gitnostr/` bridge) instead of
guessing. Re-verify anything version-specific before trusting it blindly —
this repo is under active development (pushed daily as of 2026-09-01).

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
