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
mix hivebeam gateway run --bind 0.0.0.0:8080 --token "replace-with-strong-token" --sandbox-root "$PWD"
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

## Permission enforcement

Gateway `approval_mode` is authoritative for gateway-created sessions.

- Gateway enforces provider session mode during ACP bootstrap (`session/set_mode`) instead of inheriting machine runtime permission defaults.
- `provider=claude` sessions are created with project-only settings sources (`settingSources=["project"]`) to avoid user/local machine permission policy inheritance.
- Session startup fails fast and remains degraded if permission-mode enforcement cannot be applied.

## Sandbox enforcement

Session creation and tool operations are sandboxed by path policy.

- Session creation canonicalizes `cwd` and rejects out-of-sandbox paths.
- Approval requests targeting out-of-sandbox paths are auto-denied by the gateway worker.
- ACP filesystem/terminal operations are hard-blocked outside the sandbox (defense in depth).
- Session create request accepts `dangerously: true` to bypass sandbox checks for that session.
- Global bypass flag: `mix hivebeam gateway run --dangerously` (or `HIVEBEAM_GATEWAY_DANGEROUSLY=true`).

## Configuration

Gateway:

- `HIVEBEAM_GATEWAY_TOKEN` (required)
- `HIVEBEAM_GATEWAY_BIND` (default `0.0.0.0:8080`)
- `HIVEBEAM_GATEWAY_DATA_DIR` (default `~/.config/hivebeam/gateway`)
- `HIVEBEAM_GATEWAY_MAX_EVENTS_PER_SESSION` (default `50000`)
- `HIVEBEAM_GATEWAY_RECONNECT_MS` (default `2000`)
- `HIVEBEAM_GATEWAY_APPROVAL_TIMEOUT_MS` (default `120000`)
- `HIVEBEAM_GATEWAY_SANDBOX_ALLOWED_ROOTS` (path-separated roots, default `HIVEBEAM_GATEWAY_SANDBOX_DEFAULT_ROOT`)
- `HIVEBEAM_GATEWAY_SANDBOX_DEFAULT_ROOT` (default process cwd at boot)
- `HIVEBEAM_GATEWAY_DANGEROUSLY` (default `false`)

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

## API contracts

Formal v1 protocol contracts are versioned in git under `api/v1/`:

- `openapi.json` (HTTP contract)
- `ws.client.schema.json` (WS client frames)
- `ws.server.schema.json` (WS server frames)
- `event.schema.json` (event envelope)
- `examples.http.json` / `examples.ws.json` (validation fixtures)
- `CONTRACT_VERSION` (contract artifact version)

Release tags publish the same `api/v1/*` files as release assets (`api-v1/*`) so SDK CI can pin against tagged artifacts.

### Contract versioning policy

- Wire compatibility is anchored by route namespace major (`/v1`).
- Breaking protocol changes require a new major namespace (`/v2`) and a new contract directory (`api/v2`).
- Backward-compatible clarifications or additive updates may update `api/v1/CONTRACT_VERSION` without changing route major.

### SDK compatibility matrix

See the Elixir SDK matrix in `hivebeam-client-elixir/COMPATIBILITY.md` (or that repository root `COMPATIBILITY.md`) for SDK-to-contract support mapping.

## Capabilities and roadmap

Detailed gateway support matrix and architecture recommendations:

- `docs/gateway-capabilities.md`
