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

- Each node runs a local `codex-acp` subprocess over stdio.
- `Hivebeam.CodexBridge` keeps one long-lived ACP session.
- Cross-node prompt calls use `:erpc`.
- Prompt calls can stream thought/message/tool updates in real time.
- Agent tool operations (`fs/*`, `terminal/*`) are enabled and can request approval.

### Docker node startup (auto)

`docker-compose.yml` auto-starts `mix codex.bridge.run`.

Defaults:

- node name: `codex@localhost`
- cookie: `hivebeam_cookie`
- distribution port: `9100`
- bind IP for exposed dist ports: `0.0.0.0` (`HIVEBEAM_BIND_IP`)
- ACP command: `/usr/local/cargo/bin/codex-acp`

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

Bring it up:

```bash
docker compose up -d --build
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
- **`Executable not found in PATH: codex-acp`**:
  - local host bridge: install/build `codex-acp` in one of the auto-discovery paths above, or set `HIVEBEAM_CODEX_ACP_CMD` to an absolute binary path.
  - Docker remote: ensure container node name matches your host IP:

```bash
LAN_IP=$(ipconfig getifaddr en0)
HIVEBEAM_BIND_IP=$LAN_IP HIVEBEAM_NODE_NAME=codex@$LAN_IP docker compose up -d --build
mix codex.live --remote-self --chat
```

## Mix tasks

- `mix codex.bridge.run`
- `mix codex.live --message "..."`
- `mix codex.live --chat`
- `mix codex.prompt --message "..."`
- `mix codex.prompt --node <node@host> --message "..."`
- `mix codex.status`
- `mix codex.status --node <node@host>`
