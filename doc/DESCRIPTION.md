gittr is a self-hosted git forge built on Nostr (NIP-34), pairing a Next.js
web UI with the `gitnostr` bridge for SSH and HTTPS git access. Repositories
and their events are published to Nostr relays instead of a proprietary
central database.

This package builds both pieces from source (Go bridge, Node/Next.js UI) and
runs them as two systemd services behind NGINX, with SSH git access served
directly by `git-nostr-ssh` on a dedicated port.
