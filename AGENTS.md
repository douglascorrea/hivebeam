# Hivebeam Gateway Agent Notes

This repository is the Hivebeam ACP gateway (HTTP/WebSocket) for Codex/Claude sessions.

## Core commands

- Install deps: `mix deps.get`
- Compile: `mix compile`
- Run tests: `mix test`
- Run gateway locally: `mix hivebeam gateway run --token <token>`

## Editing expectations

- Keep gateway HTTP routes and `api/v1/openapi.json` aligned.
- If request/response fields change, also update:
  - `api/v1/examples.http.json`
  - `README.md`
- Preserve provider compatibility for both `codex` and `claude`.
- Sandbox/policy logic should be enforced centrally and consistently across:
  - session creation
  - session worker approval flow
  - ACP tool execution

## Verification

When touching gateway contracts or routing, run at least:

- `mix test test/hivebeam/contracts/http_contract_test.exs`
- `mix test test/hivebeam/gateway/http_api_test.exs`
