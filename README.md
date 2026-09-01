# gittr for YunoHost

[![Integration level](https://dash.yunohost.org/integration/gittr.svg)](https://dash.yunohost.org/appci/app/gittr)

> This is a custom package, not part of YunoHost's official app catalog —
> see `imattau/nostr_catalog_ynh`. This README is maintained by hand, not by
> the [official README generator](https://github.com/YunoHost/apps_tools/tree/main/readme_generator),
> since this app isn't catalog-listed.

## Overview

[gittr](https://gittr.space) is a self-hosted git forge built on Nostr
(NIP-34): repositories, issues, and pull requests are signed Nostr events
published to relays, instead of living in a proprietary central database.
This package builds and runs both halves of the stack from source:

- the **Next.js web UI** (`ui/`)
- the **gitnostr bridge** (`ui/gitnostr/`), which mirrors bare git repos to
  disk and manages SSH key access

**Shipped version:** `v0.2.6`

## Requirements

- YunoHost `>= 11.2`
- A domain (or subdomain) for the web UI
- A free TCP port for dedicated SSH git access, separate from the server's
  admin SSH (defaults to `2225`, auto-picked if taken — see
  `yunohost app show gittr`)

## What this package does — and deliberately doesn't

Read `doc/DECISIONS.md` before touching `scripts/install` or the
`conf/*.j2` templates — it records why several things aren't the "obvious"
implementation:

- **Git access is SSH and HTTPS.** `git-nostr-ssh` has no listener of its
  own — it's a forced-command binary that a real `sshd` invokes. This
  package runs a second, dedicated `sshd` instance for that, rather than
  touching the server's admin SSH config. HTTPS smart-git uses
  `git-http-backend` behind a dedicated `fcgiwrap` instance (its own
  socket-activated systemd unit, not the shared system one), with nginx
  `auth_request` gating private repos via the UI's own ACL endpoint.
- **Go and Node.js are declared as manifest resources** (`resources.go`,
  `resources.nodejs`) and provisioned by YunoHost's own resource system,
  not hand-vendored or scripted via helper calls.
- **The UI is rebuilt whenever the domain changes** (`scripts/change_url`),
  because Next.js inlines `NEXT_PUBLIC_*` env vars into the client bundle
  at build time, not at process start.
- Optional upstream features (Lightning bounties, push paywall, Blossom
  Pages) are off by omission — this package never sets the env vars that
  enable them.

## Documentation

- `doc/DESCRIPTION.md` — what the app is, for the install screen
- `doc/ADMIN.md` — post-install admin notes (SSH access, config, data
  layout, backup contents)
- `doc/DECISIONS.md` — the packaging decisions above, with the upstream
  source evidence behind each one
- `doc/SKETCH.md` — the original planning skeleton this package was built
  from (kept for history; superseded by DECISIONS.md where they disagree)

## Links

- Report a package bug: this repository's issue tracker
- Upstream code: <https://github.com/arbadacarbaYK/gittr>
- Upstream bridge: `ui/gitnostr/` in the same repo
