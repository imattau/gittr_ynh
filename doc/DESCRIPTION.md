gittr is a self-hosted git forge built on Nostr (NIP-34), pairing a Next.js
web UI with the `gitnostr` bridge for SSH git access. Repositories and their
events are published to Nostr relays instead of a proprietary central
database.

This package builds both pieces from source (Go bridge, Node/Next.js UI) and
runs them as three systemd services behind NGINX: the bridge, the UI, and a
dedicated sshd instance (separate from the server's admin SSH) that runs
`git-nostr-ssh` as a forced command for git clone/push/pull. HTTPS git
access is not implemented in this package — see doc/DECISIONS.md item 3.
