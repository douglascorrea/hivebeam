# hivebeam_liveview (opt-in addon)

This addon provides a local-only Phoenix LiveView UI for Hivebeam.

## Important

- This addon is **not** installed by core `install.sh`.
- Core remote installs remain terminal-only and free of Phoenix dependencies.
- The addon consumes the shared UI contract from `Hivebeam.UI.SessionModel`.

## Run locally

```bash
cd addons/hivebeam_liveview
mix deps.get
mix phx.server
```
