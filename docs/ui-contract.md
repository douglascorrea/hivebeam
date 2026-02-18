# Hivebeam Shared UI Contract

This contract is consumed by both:

- Terminal UI renderer (`Hivebeam.CodexChatUi`)
- Optional LiveView addon (`addons/hivebeam_liveview`)

## Event Types

Each event follows:

```elixir
%{
  kind: :message_chunk | :thought_chunk | :tool_update | :approval_request | :status_update | :layout_update | :target_update,
  node: String.t() | nil,
  payload: map()
}
```

## Semantics

- `:message_chunk`: assistant text stream chunk.
- `:thought_chunk`: reasoning/thought stream chunk.
- `:tool_update`: tool activity update (kind/status/summary).
- `:approval_request`: approval prompt details.
- `:status_update`: lifecycle or connection status update.
- `:layout_update`: layout/pane state changes.
- `:target_update`: target discovery/selection changes.

## Compatibility Rules

- Additive fields in `payload` are allowed.
- Existing `kind` names are stable and must not be renamed.
- Unknown payload fields must be ignored by renderers.
