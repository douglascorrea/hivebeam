# Hivebeam

Simple runbook for local and remote nodes.

## Important: execution mode

- Default (`mix node.up ...`): runs **outside Docker** (native process on the machine).
- Docker mode: add `--docker`.

Examples:

```bash
# Native (default)
mix node.up --name box1 --provider codex

# Docker
mix node.up --docker --name box1 --provider codex
```

## Requirements

- Elixir
- This repo checked out
- Docker only if you use `--docker`

First time:

```bash
mix deps.get
mix compile
```

## 1) Local machine

### 1.1 Start nodes (native, no Docker)

```bash
mix node.up --name box1 --provider codex
mix node.up --name box2 --provider claude
```

### 1.2 Start nodes (Docker)

On macOS, add loopback aliases first (once per IP you use):

```bash
sudo ifconfig lo0 alias 127.0.0.11 up
sudo ifconfig lo0 alias 127.0.0.12 up
```

For more local Docker nodes, keep adding `127.0.0.13`, `127.0.0.14`, etc.

```bash
mix node.up --docker --name box1 --provider codex
mix node.up --docker --name box2 --provider claude
```

### 1.3 Check nodes

```bash
mix node.ls --name box1
mix node.ls --name box2
```

### 1.4 Connect to local nodes

```bash
mix agents.live \
  --node codex@127.0.0.11 \
  --node claude@127.0.0.12 \
  --alias box1=codex@127.0.0.11 \
  --alias box2=claude@127.0.0.12 \
  --chat
```

In chat:

```text
%box1+codex check @mix.exs
%box2+claude review @lib/hivebeam/codex_chat_ui.ex
```

## 2) Remote Linux/macOS machines

### 2.1 One-time setup on remote

```bash
ssh user@remote-host
git clone <your-repo-url> /srv/hivebeam
cd /srv/hivebeam
```

### 2.2 Start remote nodes (native, default)

```bash
mix node.up --name edge1 --provider codex --remote user@remote-host --remote-path /srv/hivebeam
mix node.up --name edge2 --provider claude --remote user@remote-host --remote-path /srv/hivebeam
```

### 2.3 Start remote nodes with Docker

```bash
mix node.up --docker --name edge1 --provider codex --remote user@remote-host --remote-path /srv/hivebeam
mix node.up --docker --name edge2 --provider claude --remote user@remote-host --remote-path /srv/hivebeam
```

### 2.4 Check remote nodes

```bash
mix node.ls --name edge1 --remote user@remote-host --remote-path /srv/hivebeam
mix node.ls --name edge2 --remote user@remote-host --remote-path /srv/hivebeam
```

### 2.5 Connect to remote nodes

```bash
mix agents.live \
  --node codex@remote-host \
  --node claude@remote-host \
  --alias edge1=codex@remote-host \
  --alias edge2=claude@remote-host \
  --chat
```

## 3) Stop nodes

### Local

```bash
mix node.down --name box1
mix node.down --name box2
```

Docker local:

```bash
mix node.down --docker --name box1
mix node.down --docker --name box2
```

### Remote

```bash
mix node.down --name edge1 --remote user@remote-host --remote-path /srv/hivebeam
mix node.down --name edge2 --remote user@remote-host --remote-path /srv/hivebeam
```

Docker remote:

```bash
mix node.down --docker --name edge1 --remote user@remote-host --remote-path /srv/hivebeam
mix node.down --docker --name edge2 --remote user@remote-host --remote-path /srv/hivebeam
```

## 4) Docker build args (only for --docker mode)

You do not need to set these unless you want a custom `codex-acp` source/revision.

Defaults:

- `CODEX_ACP_GIT_REPO=https://github.com/douglascorrea/codex-acp.git`
- `CODEX_ACP_GIT_REF=5d8c939`

Override example:

```bash
CODEX_ACP_GIT_REPO=https://github.com/your-org/codex-acp.git \
CODEX_ACP_GIT_REF=main \
mix node.up --docker --name box1 --provider codex
```
