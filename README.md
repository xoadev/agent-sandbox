# agent-sandbox

A lightweight, zero-trust CLI orchestrator to spin up secure, ephemeral execution environments for AI agents. Uses
[gVisor](https://gvisor.dev), [Agent Vault](https://github.com/Infisical/agent-vault), and a
[Docker Socket Proxy](https://github.com/Tecnativa/docker-socket-proxy) for kernel-level isolation, credential
protection, and safe Docker-in-Docker.

The CLI is pure Bash — no Python, `jq`, or `yq`.

## Architecture

```text
                  ┌──────────────────────────────────────────────────┐
                  │                 HOST MACHINE                     │
                  │                                                  │
                  │  ./.agent-sandbox/[env].[secret|.env] (config)   │
                  └──────┬───────────────────────────────────────────┘
                         │ CLI reads config at startup
                         ▼
┌──────────────────────────────────────────────────────────────────────┐
│                       ISOLATED DOCKER NETWORK                        │
│                                                                      │
│  ┌──────────────────────────┐  ┌──────────────────────────────────┐  │
│  │   docker-socket-proxy    │  │       agent-sandbox              │  │
│  │  (Docker API Firewall)   │  │  ┌────────────────────────────┐  │  │
│  │                          │  │  │ HTTP_PROXY ────────────────┼──┼──► Remote
│  │                          │  │  │ opencode                   │  │  │    AgentVault
│  └──────────▲───────────────┘  │  │ gVisor (runsc)             │  │  │
│             │ (DOCKER_HOST)    │  └────────────────────────────┘  │  │
│             │                  │  /workspace ← host mount         │  │
│             └──────────────────┴──────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

1. **gVisor:** The container runs on Google's `runsc` runtime, virtualizing system calls in a sterile microVM. A
   container breakout cannot reach the host OS.
2. **Agent Vault:** Real credentials live on a remote Agent Vault server. The CLI builds an `HTTP_PROXY` URL from
   the vault token (stored in `.agent-sandbox/[env].secret.env`) and injects it into the container at startup. All
   outbound traffic routes through Agent Vault, which injects real credentials on the fly — the agent never reads
   the real keys.
3. **Docker Proxy:** The sandbox connects to `docker-socket-proxy`, an API firewall that allows safe container
   management (e.g., Testcontainers) while blocking dangerous calls like host root mounts.

## Installation

### Prerequisites

- Docker with the Compose v2 plugin (`docker compose`)
- `openssl`
- gVisor (`runsc`) registered as a Docker runtime

Add `runsc` to `/etc/docker/daemon.json` (or `~/.config/docker/daemon.json` for rootless):

```json
{
  "runtimes": {
    "runsc": {
      "path": "/usr/bin/runsc",
      "runtimeArgs": ["--network=host"]
    }
  }
}
```

```bash
sudo systemctl restart docker
```

### Install the CLI

```bash
curl -fsSL https://raw.githubusercontent.com/xoadev/agent-sandbox/main/install.sh | bash
```

Also works from a local checkout — uses the local file if present.

### Initialize an environment

```bash
# Replace 'opencode' with your environment name
agent-sandbox init opencode
```

You'll be prompted for the vault address, token, and vault name. This creates `.agent-sandbox/opencode.env` and
`.agent-sandbox/opencode.secret.env`.

## Daily Usage

```bash
agent-sandbox run opencode
```

- The CLI reads `.env` + `.secret.env`, provisions the isolated Docker network, builds the image if needed, and
  attaches to the container's CMD (opencode).
- Each run uses a unique session ID (`date +%s`), so launching the same environment multiple times creates
  independent, non-conflicting containers. Use `agent-sandbox ps` to list active sessions.
- Exit opencode or press `Ctrl+C` — the trap tears down all containers, volumes, and networks automatically.
- The CLI prompts to run `init` automatically if you start an unconfigured environment with `run`.

## Configuration

Two files in `.agent-sandbox/`:

| File | Content | Commit? |
|------|---------|---------|
| `[env].env` | Image reference, vault address, vault name | Yes (safe for team) |
| `[env].secret.env` | `AGENT_VAULT_TOKEN` | **No** (gitignored by installer) |

```ini
# .agent-sandbox/opencode.env
AGENT_SANDBOX_IMAGE="agent-sandbox-opencode:latest"
AGENT_VAULT_ADDR="localhost:14321"
AGENT_VAULT_VAULT="kop"
```

```ini
# .agent-sandbox/opencode.secret.env
AGENT_VAULT_TOKEN="your_real_vault_token_here"
```

The `AGENT_SANDBOX_IMAGE` field accepts:
- A **registry image name** (e.g., `myregistry/myimage:1.0`) — used as-is.
- A **path** starting with `./` or `/`, or ending in `Dockerfile` — treated as a local Dockerfile, built and
  tagged `agent-sandbox-<env>:latest` on each run.

API keys like `OPENCODE_API_KEY` stay as placeholders in `.env` — Agent Vault injects the real values at runtime.

## Verification

Once inside the sandbox, confirm the three isolation layers:

```bash
uname -a                        # Should show runsc/gVisor
curl -I https://api.github.com  # Proxy injects the real token transparently
docker ps                       # Docker-in-Docker via the API firewall
```

## Agent Containers

Pre-built images ready to use. Extend them by editing the `Dockerfile` in each directory.

| Container | Description |
|:----------|:------------|
| [opencode](containers/opencode/) | Opencode agent with Docker CLI, Compose plugin, GitHub CLI, and `pnpm`/`npm` for Node.js tooling. |

Inside the container, opencode auto-discovers available tools via `SKILL.md` files in
`~/.config/opencode/skills/`. The image ships with skills for Docker, the GitHub CLI, and pnpm — opencode loads them
when a task matches their description, so it knows when to reach for each tool without being told.

The `init` command also creates a `.opencodeignore` entry for `*.secret.env` files so opencode never reads or exposes
vault tokens.

## Tests

```bash
bash tests/run_tests.sh
```

Self-contained Bash test runner — mocks `docker` via stubs on `PATH`, no real engine needed.

## Troubleshooting

### "configuration not found" / "secrets file missing"

Run `agent-sandbox init <env>`, or let the CLI auto-prompt you.

### Docker Compose can't find `.env` files

Run `agent-sandbox` from the project root (where `.agent-sandbox/` lives). Paths are resolved to absolute at
startup.

### gVisor not available

The sandbox requires `runsc` registered in your Docker daemon. See
[Installation](#installation) for setup.

# TODO

- [ ] Research [act](https://nektosact.com/) and how to build the container using the same script as GitHub Actions.
- [ ] Research [Headroom](https://github.com/headroomlabs-ai/headroom)
