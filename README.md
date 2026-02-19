# Hivebeam

ACP gateway for persistent Codex/Claude sessions over HTTP/WebSocket.

## Install (release-first)

```bash
curl -fsSL https://raw.githubusercontent.com/douglascorrea/hivebeam/refs/heads/master/install.sh | sh
```

Default install root: `~/.local/hivebeam`.

## Source workflow

```bash
mix deps.get
mix compile
```

## Gateway runtime

Hivebeam runs as a gateway-only app and requires an auth token at boot.

```bash
export HIVEBEAM_GATEWAY_TOKEN="replace-with-strong-token"
mix hivebeam gateway run
```

Or with explicit options:

```bash
mix hivebeam gateway run --bind 0.0.0.0:8080 --token "replace-with-strong-token"
```

Default bind is `0.0.0.0:8080`; APIs are exposed under `/v1`.

## HTTP endpoints

- `POST /v1/sessions`
- `GET /v1/sessions/:gateway_session_key`
- `POST /v1/sessions/:gateway_session_key/attach`
- `POST /v1/sessions/:gateway_session_key/prompts`
- `POST /v1/sessions/:gateway_session_key/cancel`
- `POST /v1/sessions/:gateway_session_key/approvals`
- `GET /v1/sessions/:gateway_session_key/events?after_seq=<n>&limit=<n>`
- `DELETE /v1/sessions/:gateway_session_key`
- `GET /v1/ws?gateway_session_key=<key>&after_seq=<n>`

## Provider routing

Session creation accepts `provider` and routes each session to the corresponding ACP bridge:

- `provider=codex` -> `Hivebeam.CodexBridge`
- `provider=claude` -> `Hivebeam.ClaudeBridge`

## Configuration

Gateway:

- `HIVEBEAM_GATEWAY_TOKEN` (required)
- `HIVEBEAM_GATEWAY_BIND` (default `0.0.0.0:8080`)
- `HIVEBEAM_GATEWAY_DATA_DIR` (default `~/.config/hivebeam/gateway`)
- `HIVEBEAM_GATEWAY_MAX_EVENTS_PER_SESSION` (default `50000`)
- `HIVEBEAM_GATEWAY_RECONNECT_MS` (default `2000`)
- `HIVEBEAM_GATEWAY_APPROVAL_TIMEOUT_MS` (default `120000`)

ACP provider commands:

- `HIVEBEAM_CODEX_ACP_CMD` (default auto-detected `codex-acp`)
- `HIVEBEAM_CLAUDE_AGENT_ACP_CMD` (default `claude-agent-acp`, fallback `npx -y @zed-industries/claude-agent-acp`)

Bridge names:

- `HIVEBEAM_CODEX_BRIDGE_NAME` (default `Hivebeam.CodexBridge`)
- `HIVEBEAM_CLAUDE_BRIDGE_NAME` (default `Hivebeam.ClaudeBridge`)

Timeouts/retry:

- `HIVEBEAM_CODEX_PROMPT_TIMEOUT_MS` (default `120000`)
- `HIVEBEAM_CODEX_CONNECT_TIMEOUT_MS` (default `30000`)
- `HIVEBEAM_ACP_RECONNECT_MS` (default `5000`)
