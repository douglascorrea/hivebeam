# Hivebeam

This project contains two communication paths:

- **TCP demo path**: simple host/container message exchange (`mix node.listen`, `mix node.send`)
- **Distributed ACP path**: long-lived Codex bridge using ACPex + distributed Erlang

## TCP demo

1. Build and start container:

```bash
docker compose up -d --build
```

2. Start a local listener:

```bash
mix node.listen --name local --port 5050
```

3. Start container listener:

```bash
docker compose exec codex-node mix node.listen --name docker --port 5051
```

4. Send host -> container:

```bash
mix node.send --host 127.0.0.1 --port 5051 --from local --message "hello from host"
```

5. Send container -> host:

```bash
docker compose exec codex-node mix node.send --host host.docker.internal --port 5050 --from docker --message "hello from docker"
```

## Distributed ACP bridge

### What it does

- Each node runs a local ACP subprocess over stdio (`codex-acp` or `claude-agent-acp`).
- `Hivebeam.CodexBridge` keeps one long-lived ACP session.
- Cross-node prompt calls use `:erpc`.
- Prompt calls can stream thought/message/tool updates in real time.
- Agent tool operations (`fs/*`, `terminal/*`) are enabled and can request approval.

### Docker node startup (auto)

`docker-compose.yml` auto-starts `mix agents.bridge.run` (Codex + Claude when available).

Defaults:

- node name: `codex@localhost`
- cookie: `hivebeam_cookie`
- distribution port: `9100`
- bind IP for exposed dist ports: `0.0.0.0` (`HIVEBEAM_BIND_IP`)
- ACP provider: `codex` (`HIVEBEAM_ACP_PROVIDER`)
- Codex ACP command: `/usr/local/cargo/bin/codex-acp` (`HIVEBEAM_CODEX_ACP_CMD`)
- Claude ACP command: `claude-agent-acp` (`HIVEBEAM_CLAUDE_AGENT_ACP_CMD`)

The Docker image installs `codex-acp` from the fork configured in `Dockerfile.codex`:

- `CODEX_ACP_GIT_REPO`
- `CODEX_ACP_GIT_REF`

For local (non-Docker) runs, if `HIVEBEAM_CODEX_ACP_CMD` is not set, the bridge auto-discovers
`codex-acp` in this order:

- `../codex-acp/target/release/codex-acp` (sibling fork build)
- `../codex-acp/target/debug/codex-acp`
- `~/.cargo/bin/codex-acp`
- `/usr/local/cargo/bin/codex-acp`
- `codex-acp` from `PATH`

Provider summary:

| Provider (`HIVEBEAM_ACP_PROVIDER`) | Default command                | Override env                    |
|------------------------------------|--------------------------------|---------------------------------|
| `codex`                            | autodiscovered `codex-acp`     | `HIVEBEAM_CODEX_ACP_CMD`        |
| `claude`                           | `claude-agent-acp` from `PATH` | `HIVEBEAM_CLAUDE_AGENT_ACP_CMD` |

Bring it up:

```bash
docker compose up -d --build
```

### Claude Code nodes (login auth, no API key)

`claude-agent-acp` uses Claude Code authentication. Run login once on the remote node, then start the bridge with the Claude provider.

Authenticate inside the running Docker node (persists in `/home/node/.claude`, `/home/node/.claude.json`, and `/home/node/.config/claude-code`):

```bash
docker compose up -d --build
docker compose exec -it codex-node claude
# inside Claude REPL:
# /login
```

Start a remote Claude bridge node:

```bash
LAN_IP=$(ipconfig getifaddr en0)
HIVEBEAM_ACP_PROVIDER=claude HIVEBEAM_NODE_NAME=claude@$LAN_IP HIVEBEAM_BIND_IP=$LAN_IP docker compose up -d --build
```

Connect from host:

```bash
mix codex.live --remote-name claude --remote-self --chat
```

Same flow with the Claude wrapper task:

```bash
mix claude.live --remote-self --chat
```

Or start a local Claude bridge directly:

```bash
mix claude.bridge.run
```

### One-command dual-provider mode (Codex + Claude)

Start all available providers on a remote node:

```bash
mix agents.bridge.run
```

`agents.bridge.run` keeps Codex as default and auto-starts Claude when `claude-agent-acp` is installed and callable.

From host, connect to all available providers on local/remotes:

```bash
mix agents.live --remote-self --chat
```

Multiple remotes:

```bash
mix agents.live --node codex@10.0.0.20 --node codex@10.0.0.30 --chat
```

Optional provider filter:

```bash
mix agents.live --providers codex --remote-self --chat
```

### Host + Docker on same machine

When both nodes run on one machine, bind Docker distribution ports to your LAN IP to avoid local `epmd` conflicts.

```bash
LAN_IP=$(ipconfig getifaddr en0)
HIVEBEAM_BIND_IP=$LAN_IP HIVEBEAM_NODE_NAME=codex@$LAN_IP docker compose up -d --build
```

Compile once on host:

```bash
mix deps.get && mix compile
```

### Realtime prompt/chat task (recommended)

Use `mix codex.live` so you do not need manual `ERL_AFLAGS` / `ERL_EPMD_ADDRESS` exports.

Local one-shot prompt:

```bash
mix codex.live --message "Reply with exactly HELLO"
```

Remote one-shot prompt (same machine host -> container, no env vars):

```bash
mix codex.live --remote-self --message "What was hardest to find?"
```

Realtime chat with one remote:

```bash
mix codex.live --remote-self --chat
```

`--chat` now uses a full-screen `term_ui` interface with live streaming output.
Tool/reasoning updates are grouped into low-noise activity cards with inferred labels like `Exploring`, `Writing`, `Verifying`, and `Executing`.
Press `Ctrl+O` to expand/collapse the latest activity card.

Controls:

- `Enter`: send message
- `Tab`: switch active target
- `Ctrl+O`: expand/collapse latest activity details
- `Up` / `Down`: scroll transcript by line
- `Page Up` / `Page Down`: scroll transcript by page
- `Home` / `End`: jump to oldest/newest visible history
- `Ctrl+C`: exit chat
- `/targets`: list targets
- `/use <n>`: switch target by index
- `/status`: fetch bridge status for active target
- `/cancel`: request cancellation for the running prompt
- `/help`: show commands
- `/exit`: close chat

If `/targets` shows `host@...`, you are talking to the local bridge. For Docker remote chat you should see `codex@<ip>`.

For Claude remotes, use `--remote-name claude` (or explicit `--node claude@<ip>`) so target discovery matches the Claude node name.

Broadcast one prompt to local + multiple remotes:

```bash
mix codex.live --local --node codex@10.0.0.20 --node codex@10.0.0.30 --message "Status check"
```

Approval policy:

```bash
mix codex.live --remote-self --chat --approve ask
```

`--approve` supports: `ask` (default), `allow`, `deny`.

### Legacy prompt/status tasks

`mix codex.prompt` now also streams thought/tool updates and supports approvals.

Local prompt:

```bash
mix codex.prompt --message "Reply with exactly HELLO"
```

Remote prompt:

```bash
mix codex.prompt --node codex@10.0.0.20 --message "Reply with exactly REMOTE_HELLO"
```

Status:

```bash
mix codex.status
mix codex.status --node codex@10.0.0.20
```

### Troubleshooting

- **Cookie mismatch**: ensure all nodes use same cookie.
- **Node unreachable**: verify `4369` and distribution ports are open/mapped.
- **Bridge degraded**: check `mix codex.status` and `last_error`.
- **No Codex auth**: ensure `~/.codex/auth.json` exists on the node running `codex-acp`.
- **Claude login required**:
  - run `claude /login` on the same node/container where `claude-agent-acp` runs.
  - if prompt fails with `Please run /login`, the Claude session is missing or expired.
  - avoid `docker compose run --rm ...` for login state; use `docker compose exec ...` on the running service so auth files are written to the persisted service volumes.
- **`Executable not found in PATH: claude-agent-acp`**:
  - install `@zed-industries/claude-agent-acp` or set `HIVEBEAM_CLAUDE_AGENT_ACP_CMD` to an absolute path.
- **`Executable not found in PATH: codex-acp`**:
  - local host bridge: install/build `codex-acp` in one of the auto-discovery paths above, or set `HIVEBEAM_CODEX_ACP_CMD` to an absolute binary path.
  - Docker remote: ensure container node name matches your host IP:

```bash
LAN_IP=$(ipconfig getifaddr en0)
HIVEBEAM_BIND_IP=$LAN_IP HIVEBEAM_NODE_NAME=codex@$LAN_IP docker compose up -d --build
mix codex.live --remote-self --chat
```

## Mix tasks

- `mix agents.bridge.run`
- `mix agents.live --chat`
- `mix codex.bridge.run`
- `mix claude.bridge.run`
- `mix claude.live --chat`
- `mix codex.live --message "..."`
- `mix codex.live --chat`
- `mix codex.prompt --message "..."`
- `mix codex.prompt --node <node@host> --message "..."`
- `mix codex.status`
- `mix codex.status --node <node@host>`
