# Hivebeam Gateway Agent Notes

This repository is the Hivebeam ACP gateway (HTTP/WebSocket) for Codex/Claude sessions.

## Core commands

- Install deps: `mix deps.get`
- Compile: `mix compile`
- Run tests: `mix test`
- Run gateway locally: `mix hivebeam gateway run --token <token>`
- Run gateway with debug logs: `mix hivebeam gateway run --token <token> --debug`
- Format check: `mix format --check-formatted`
- Compile strict: `mix compile --warnings-as-errors`

## Editing expectations

- Keep gateway HTTP routes and `api/v1/openapi.json` aligned.
- If request/response fields change, also update:
  - `api/v1/examples.http.json`
  - `README.md`
- Preserve provider compatibility for both `codex` and `claude`.
- Sandbox/policy logic should be enforced centrally through `Hivebeam.Gateway.PolicyGate`, with consistent enforcement across:
  - session creation
  - session worker approval flow
  - ACP tool execution
- For terminal access in sandboxed sessions, keep capability negotiation and execution behavior aligned:
  - `clientCapabilities.terminal` should reflect terminal jail availability/policy
  - `terminal/create` must be denied when jailed execution is not available in sandbox mode
- Keep `ARCHITECTURE.md` aligned when architecture/runtime behavior changes.

## Verification

When touching gateway contracts or routing, run at least:

- `mix test test/hivebeam/contracts/http_contract_test.exs`
- `mix test test/hivebeam/gateway/http_api_test.exs`
- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
