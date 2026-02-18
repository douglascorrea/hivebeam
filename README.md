# Hivebeam

Distributed multi-agent chat/orchestration for local and remote BEAM nodes.

## Install (release-first)

```bash
curl -fsSL https://raw.githubusercontent.com/douglascorrea/hivebeam/main/install.sh | sh
```

Default install root: `~/.local/hivebeam`.

The installer creates `~/.local/bin/hivebeam` and does **not** install the optional LiveView addon.

## Source workflow (contributors)

```bash
mix deps.get
mix compile
```

## DX defaults

- Remote runtime path default: `~/.local/hivebeam/current`
- Discovery mode default: `hybrid` (`inventory` + runtime peers)
- Inventory/config root: `~/.config/hivebeam`
  - `config.toml`
  - `nodes.toml`
  - `ui.toml`

## Unified CLI (via Mix task)

```bash
mix hivebeam host add --alias prod-a --ssh user@prod-a --tags prod,edge
mix hivebeam host bootstrap --host prod-a --version latest
mix hivebeam discover sync --targets all
mix hivebeam targets ls --targets tag:prod
mix hivebeam chat --targets host:prod-a
```

Selector grammar:

- `all`
- `host:<alias>`
- `tag:<tag>`
- `provider:codex|claude`
- `state:up|degraded`

## Node lifecycle (compatibility tasks)

Legacy tasks remain supported:

```bash
mix node.up --name edge1 --provider codex --remote prod-a
mix node.up --name edge2 --provider claude --remote prod-a
mix node.ls --name edge1 --remote prod-a
mix node.down --name edge1 --remote prod-a
```

If `--remote` matches a host alias in inventory, Hivebeam resolves SSH + remote path automatically.

## Chat and TUI

```bash
mix agents.live --targets all --chat
```

New layout/keybinding capabilities:

- Adaptive layout modes: `auto`, `full`, `focus`, `compact`
- Hideable panes: left fleet pane, right activity pane
- Keybindings:
  - `Ctrl+B` toggle left pane
  - `Ctrl+G` toggle right pane
  - `Ctrl+L` cycle layout
  - `Ctrl+K` command palette hint
  - `Ctrl+J` target switcher hint
  - `Ctrl+R` refresh status
  - `Ctrl+X` cancel prompt
  - `Esc` close overlays
- Slash commands:
  - `/layout <auto|full|focus|compact>`
  - `/pane <left|right> <on|off>`
  - `/keys`

## Hybrid discovery and libcluster

`hivebeam` can merge:

1. Managed inventory nodes (`nodes.toml`)
2. Runtime peers from `Node.list()` + configured cluster peers

Discovery mode can be set with:

```bash
export HIVEBEAM_DISCOVERY_MODE=hybrid
```

Optional libcluster topologies are enabled with env vars:

- `HIVEBEAM_LIBCLUSTER_EPMD_NODES=node1@host,node2@host`
- `HIVEBEAM_LIBCLUSTER_DNS_QUERY=service.namespace.svc.cluster.local`

## Optional LiveView addon (opt-in)

Addon path:

`addons/hivebeam_liveview`

It is local-only and separate from core install/runtime. Core install script never deploys Phoenix dependencies to remote hosts.

Shared UI contract:

`docs/ui-contract.md`
