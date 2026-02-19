# Hivebeam

Distributed multi-agent chat/orchestration for local and remote BEAM nodes.

## Install (release-first)

```bash
curl -fsSL https://raw.githubusercontent.com/douglascorrea/hivebeam/refs/heads/master/install.sh | sh
```

Default install root: `~/.local/hivebeam`.

The installer creates `~/.local/bin/hivebeam` and does **not** install the optional LiveView addon.
If no prebuilt release asset exists for your platform, installer automatically falls back to source build (`git` + Elixir/Erlang required; it will try to install Elixir on common systems).

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

`nodes.toml` model:

```toml
[[hosts]]
alias="hetzner"
ssh="hetzner-douglas"
remote_path="~/.local/hivebeam/current"
tags=["hetzner"]

[[nodes]]
name="edge1"
host_alias="hetzner"
provider="codex"
mode="native"
managed=true
node_name="codex@hetzner-douglas"
state="up"
```

## Unified CLI (via Mix task)

```bash
mix hivebeam host add --alias prod-a --ssh user@prod-a --tags prod,edge
mix hivebeam host bootstrap --host prod-a --version latest
mix node.up --name edge1 --provider codex --remote prod-a
mix hivebeam targets ls --targets host:prod-a
mix hivebeam chat --targets host:prod-a
```

Important:

- `host add` creates `[[hosts]]` entries only (SSH inventory).
- `node.up` creates `[[nodes]]` entries and starts the remote runtime node.
- `mix hivebeam chat` targets nodes, not hosts. If you only have `[[hosts]]`, there is nothing remote to chat with yet.

### Remote Quickstart (single host)

```bash
# 1) Register remote host (once)
mix hivebeam host add --alias hetzner --ssh hetzner-douglas --tags hetzner

# 2) Install Hivebeam on remote host (once per machine/version)
mix hivebeam host bootstrap --host hetzner --version latest

# 3) Start first agent node on that host (creates [[nodes]] in inventory)
mix node.up --name edge1 --provider codex --remote hetzner

# 4) Verify target resolution
mix hivebeam targets ls --targets host:hetzner

# 5) Open chat against that host's nodes
mix hivebeam chat --targets host:hetzner
```

Add another node on same host:

```bash
mix node.up --name edge2 --provider claude --remote hetzner
mix hivebeam chat --targets host:hetzner --providers codex,claude
```

Troubleshooting (older installs):

- If `mix node.ls --name <node> --remote <host>` shows `status: stale` and `~/.local/hivebeam/current/.hivebeam/nodes/<node>.log` is missing, check if an old literal `~/` directory was created:

```bash
ssh <host> 'ls -ld ~/~/.local/hivebeam/current 2>/dev/null || true'
```

- If it exists, remove the accidental path and restart the node:

```bash
ssh <host> 'rm -rf ~/~'
mix node.down --name <node> --remote <host>
mix node.up --name <node> --provider codex --remote <host>
```

Selector grammar:

- `all`
- `host:<alias>`
- `tag:<tag>`
- `provider:codex|claude`
- `state:up|down|degraded`

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
