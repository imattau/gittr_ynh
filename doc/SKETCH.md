# gittr_ynh — package sketch

Target: `imattau/nostr_catalog_ynh` (custom catalog, not the official YunoHost app store).
Upstream: `github.com/arbadacarbaYK/gittr` (monorepo: Next.js UI + `ui/gitnostr/` bridge).

This is a starting skeleton, not a finished package. Treat every value below as
something to verify against current upstream before it runs anywhere real.

---

## 1. Repo layout

```
gittr_ynh/
├── manifest.toml
├── conf/
│   ├── nginx.conf
│   ├── systemd-ui.service
│   ├── systemd-bridge.service
│   └── bridge-config.json.j2
├── scripts/
│   ├── install
│   ├── remove
│   ├── upgrade
│   ├── backup
│   ├── restore
│   ├── change_url
│   └── _common.sh
└── doc/
    ├── DESCRIPTION.md
    └── ADMIN.md
```

---

## 2. manifest.toml (skeleton)

```toml
packaging_format = 2

id = "gittr"
name = "gittr"
description.en = "Self-hosted git forge on Nostr (NIP-34), with the gitnostr bridge for SSH/HTTPS git access"

version = "0.1~ynh1"

maintainers = ["imattau"]

[upstream]
license = "AGPL-3.0"
website = "https://gittr.space"
code = "https://github.com/arbadacarbaYK/gittr"

[integration]
yunohost = ">= 11.2"
architectures = "all"
multi_instance = false
ldap = false
sso = false
disk = "1G"
ram.build = "2G"
ram.runtime = "512M"

[install]
    [install.domain]
    type = "domain"

    [install.path]
    type = "path"
    default = "/"

    [install.admin]
    type = "user"

    [install.git_ssh_port]
    type = "number"
    default = 2225
    help.en = "Port for git-nostr-ssh, kept separate from the server's admin SSH (22)."

    [install.nostr_relays]
    type = "string"
    default = "wss://relay.damus.io,wss://nos.lol"
    help.en = "Comma-separated relay list the bridge and UI will use."

    [install.repo_owner_pubkey]
    type = "string"
    help.en = "Hex nostr pubkey allowed to own/create repos on this bridge."

[resources]
    [resources.system_user]

    [resources.install_dir]

    [resources.ports]
        [resources.ports.git_ssh]
        default = 2225

    [resources.apt]
        packages = "git, build-essential, sqlite3"

    [resources.database]
        # not used — bridge uses sqlite on disk, no MySQL/Postgres needed
```

Notes:
- `system_user` resource gives you the dedicated non-login-shell user the
  bridge docs insist on (never run it as your own account — it rewrites
  `authorized_keys`).
- Go and Node aren't in `apt` packages above on purpose — safer to vendor a
  pinned Go toolchain and Node version in `scripts/install` (via nvm-style
  local install to the app's install_dir) rather than depend on whatever
  Debian ships, since both upstream pieces are version-sensitive.

---

## 3. scripts/install (skeleton, abbreviated)

```bash
#!/bin/bash
source _common.sh
source /usr/share/yunohost/helpers

ynh_script_progression "Validating installation parameters"
# domain, path, admin, git_ssh_port, nostr_relays, repo_owner_pubkey
# all already resolved into env vars by the resource system

ynh_script_progression "Setting up source files"
ynh_setup_source --dest_dir="$install_dir"

ynh_script_progression "Installing Go toolchain (pinned)"
GO_VERSION="1.21.6"
ynh_setup_source --source_id="go" --dest_dir="$install_dir/.go"

ynh_script_progression "Building git-nostr-bridge"
pushd "$install_dir/ui/gitnostr"
  PATH="$install_dir/.go/bin:$PATH" make git-nostr-bridge git-nostr-ssh git-nostr-cli
popd

ynh_script_progression "Installing Node and building the UI"
ynh_exec_warn_less ynh_install_nodejs --nodejs_version=20
pushd "$install_dir/ui"
  ynh_use_nodejs
  ynh_exec_warn_less npm ci
  ynh_exec_warn_less npm run build
popd

ynh_script_progression "Writing bridge config"
ynh_add_config --template="bridge-config.json.j2" \
  --destination="$install_dir/ui/gitnostr/config.json"

ynh_script_progression "Configuring systemd services"
ynh_add_systemd_config --service="$app-ui" --template="systemd-ui.service"
ynh_add_systemd_config --service="$app-bridge" --template="systemd-bridge.service"

ynh_script_progression "Configuring NGINX"
ynh_add_nginx_config

ynh_script_progression "Setting permissions"
chown -R "$app:$app" "$install_dir"
# lock down authorized_keys handling per upstream warning
chmod 700 "/home/$app/.ssh" 2>/dev/null || true

ynh_script_progression "Enabling and starting services"
yunohost service add "$app-bridge" --description="gitnostr bridge (git SSH/HTTPS)" --log="/var/log/$app/bridge.log"
ynh_systemd_action --service_name="$app-bridge" --action="start" --log_path="systemd"
ynh_systemd_action --service_name="$app-ui" --action="start" --log_path="systemd"
```

Key risk to flag: the `make git-nostr-bridge` step assumes upstream's
Makefile targets stay stable. Worth pinning to a specific commit/tag in
`ynh_setup_source`'s manifest source rather than tracking `main`, given how
actively this repo is still moving.

---

## 4. conf/systemd-bridge.service (skeleton)

```ini
[Unit]
Description=gittr — gitnostr bridge (git-nostr-bridge)
After=network.target

[Service]
Type=simple
User=__APP__
Group=__APP__
WorkingDirectory=__INSTALL_DIR__/ui/gitnostr
ExecStart=__INSTALL_DIR__/ui/gitnostr/bin/git-nostr-bridge
Restart=on-failure
RestartSec=5
Environment=HOME=__INSTALL_DIR__

[Install]
WantedBy=multi-user.target
```

## 5. conf/systemd-ui.service (skeleton)

```ini
[Unit]
Description=gittr — Next.js web UI
After=network.target __APP__-bridge.service
Requires=__APP__-bridge.service

[Service]
Type=simple
User=__APP__
Group=__APP__
WorkingDirectory=__INSTALL_DIR__/ui
ExecStart=/usr/bin/node __INSTALL_DIR__/ui/node_modules/.bin/next start -p __PORT__
Restart=on-failure
RestartSec=5
Environment=NEXT_PUBLIC_API_URL=https://__DOMAIN__
Environment=NEXT_PUBLIC_NOSTR_RELAYS=__NOSTR_RELAYS__

[Install]
WantedBy=multi-user.target
```

## 6. conf/nginx.conf (skeleton)

```nginx
location __PATH__/ {
    proxy_pass http://127.0.0.1:__PORT__/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}

# git-nostr-bridge HTTP API/git-over-HTTPS, if you expose it
location __PATH__/git/ {
    proxy_pass http://127.0.0.1:__BRIDGE_HTTP_PORT__/;
    client_max_body_size 500M;
}
```

SSH git access (`git@yourdomain:npub/repo.git`) rides on the separate
`git_ssh_port` resource, not through nginx — that's handled by
`git-nostr-ssh` listening directly, same pattern Gitea uses.

## 7. conf/bridge-config.json.j2 (skeleton)

```json
{
  "repositoryDir": "__INSTALL_DIR__/repositories",
  "DbFile": "__INSTALL_DIR__/data/git-nostr-db.sqlite",
  "relays": [__NOSTR_RELAYS_JSON_ARRAY__],
  "gitRepoOwners": ["__REPO_OWNER_PUBKEY__"]
}
```

---

## Open questions before this is buildable for real

1. **Pin a commit.** `main` on gittr is moving fast (1000+ commits, 10 open
   PRs) — decide a tagged/pinned ref for `ynh_setup_source` rather than
   tracking HEAD.
2. **Optional features.** Bounties (LNbits/NWC/LNURL), Blossom app blobs, and
   `push_cost_sats` paywall should probably default *off* in the config
   panel rather than exposed at install time — they pull in payment
   integrations most self-hosters won't want live by default.
3. **HTTP git vs SSH-only.** Decide whether to expose git-over-HTTPS through
   nginx (item 6 above) or keep this SSH-only to reduce surface area.
4. **Go/Node version pinning strategy.** Vendoring a pinned Go into
   `install_dir/.go` avoids relying on Debian's often-outdated Go package,
   but adds install-script complexity — worth checking whether YunoHost's
   `ynh_install_go` helper (if present in your YNH version) covers this
   instead of a manual `ynh_setup_source` fetch.
5. **Backup/restore scripts** aren't sketched here — they need to capture
   the sqlite DB, the `repositories/` bare-repo tree, and the bridge config,
   which for busy repos could get large fast.

This is enough structure to start a real `install` script against, but every
path, Makefile target, and config key here needs verifying against the
current gittr/gitnostr source before it's trustworthy.
