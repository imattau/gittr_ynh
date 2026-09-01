#!/bin/bash

# Go and Node.js versions are NOT set here — they're declared as manifest
# resources (`[resources.go]` / `[resources.nodejs]`) and provisioned
# automatically; sourcing the helpers puts `go`/`node`/`npm` on $PATH with
# no scripted install call needed. See doc/DECISIONS.md item 9.
#
# The upstream tag itself is pinned via manifest.toml's
# [resources.sources.main] url/sha256 (see doc/DECISIONS.md item 1) —
# not here, so upgrading the pin means editing the manifest, not this file.

# Paths, relative to $install_dir, used by more than one script.
bridge_dir="ui/gitnostr"
bridge_config_dir=".config/git-nostr"
bridge_config_file="git-nostr-bridge.json"
repositories_dir="repositories"

# Upstream's own in-code default (ui/.env.example) — used as this package's
# initial blossom_url setting so the field always has a value to show/edit
# in the config panel, see doc/DECISIONS.md item 8.
DEFAULT_BLOSSOM_URL="https://blossom.band"

# Turns a comma-separated list into a JSON array of strings, e.g.
# "a,b" -> "\"a\",\"b\"". Used to fill __NOSTR_RELAYS_JSON_ARRAY__ and
# __GIT_REPO_OWNERS_JSON_ARRAY__ in bridge-config.json.j2. An empty input
# produces an empty (not single-blank-string) array — important since an
# empty gitRepoOwners means upstream's "watch all authors" mode, not a
# filter matching nothing (see doc/DECISIONS.md item 2).
csv_to_json_array() {
	local csv="$1"
	[ -z "$csv" ] && return 0
	local IFS=','
	local -a items=($csv)
	local out=""
	for item in "${items[@]}"; do
		item="${item## }"
		item="${item%% }"
		[ -z "$item" ] && continue
		[ -n "$out" ] && out+=","
		out+="\"$item\""
	done
	echo -n "$out"
}
