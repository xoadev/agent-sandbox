# 🚀 agent-sandbox

A lightweight, zero-trust CLI orchestrator to spin up secure, ephemeral execution environments for software development
AI agents. It utilizes [gVisor](https://gvisor.dev), [Infisical Agent Vault](https://infisical.com), and a
[Docker Socket Firewall Proxy](https://github.com/Tecnativa/docker-socket-proxy) to isolate execution entirely and
protect your host system and credentials.

## 🏗️ Architecture & Security (Why is it secure?)

When an AI agent executes code, there is always a risk of a *Prompt Injection* attack (e.g., if the agent reads a
malicious file from an untrusted repository). This environment mitigates the three primary attack vectors using a
three-container isolated design.

```text
                  ┌──────────────────────────────────────────────────┐
                  │                 HOST MACHINE                     │
                  │                                                  │
                  │   ~/.agent-sandbox/secrets.env (Real Secrets)    │
                  └───────────────┬──────────────────────────────────┘
                                  │ (On-the-fly Injection)
                                  ▼
┌────────────────────────────────────────────────────────────────────────┐
│                      ISOLATED DOCKER NETWORK (Bridge)                  │
│                                                                        │
│   ┌─────────────────────┐             ┌─────────────────────────────┐  │
│   │     agent-vault     │             │     docker-socket-proxy     │  │
│   │   (Secrets Proxy)   │             │ (Docker API Firewall Proxy) │  │
│   └──────────▲──────────┘             └──────────────▲──────────────┘  │
│              │ (HTTP/S Proxy)                        │ (DOCKER_HOST)   │
│              │                                       │                 │
│         ┌────┴───────────────────────────────────────┴────┐            │
│         │              agent-environment                  │            │
│         │             (AI Agent Container)                │            │
│         │    =========================================    │            │
│         │    - gVisor (Kernel-level Isolation)            │            │
│         │    - Local Workspace Mounted (/workspace)       │            │
│         └─────────────────────────────────────────────────┘            │
└────────────────────────────────────────────────────────────────────────┘
```

1. **Kernel-level Isolation ([gVisor](https://gvisor.dev)):** The agent's container runs on Google's runsc (gVisor)
   runtime. This virtualizes system calls in a sterile microVM, making it impossible for a malicious container breakout
   to reach your host operating system.
2. **Blind Secrets Injection ([Agent Vault](https://infisical.com)):** Your real API credentials (`GITHUB_TOKEN`, LLM
   keys) stay securely on your host. The agent only sees fake placeholders (e.g., `dummy_github_token`) inside its
   environment variables. When the agent makes an outbound HTTP request, the local network proxy intercepts the traffic
   and injects the real token on the fly, preventing the agent from ever reading the real keys from memory.
3. **Secure Docker-in-Docker ([Docker Proxy](https://github.com/Tecnativa/docker-socket-proxy)):** To support testing
   frameworks like [Testcontainers](https://testcontainers.com), the sandbox connects to docker-socket-proxy. This acts
   as an API firewall, allowing the agent to spin up temporary database containers for integration tests while blocking
   dangerous calls (such as mounting your host's root file system).

## 📦 Installation

### Prerequisites

- `docker` with the **Compose v2 plugin** (`docker compose`) — see [Docker Engine](https://docs.docker.com/engine/)
- `openssl`
- gVisor (`runsc`) registered as a Docker runtime (see Step 1)

> The CLI itself is written in pure Bash and has **no dependency on Python, `jq`, or `yq`**.

### Step 1: Configure gVisor on your Host

gVisor must be registered as a runtime in your local Docker daemon.

1. Install the gVisor binary (example for Debian/Ubuntu):

   ```bash
   sudo apt-get update && sudo apt-get install -y runsc
   ```

2. Edit your Docker configuration file `/etc/docker/daemon.json` (or `~/.config/docker/daemon.json` if using Docker
   Rootless) to register the runtime:

   ```json
   {
     "runtimes": {
       "runsc": {
         "path": "/usr/bin/runsc",
         "runtimeArgs": [
           "--network=host"
         ]
       }
     }
   }
   ```

3. Restart Docker to apply configuration changes:

   ```bash
   sudo systemctl restart docker
   ```

### Step 2: Install the CLI

From a checkout of this repository, run the installer:

```bash
bash install.sh
```

*(This copies the `agent-sandbox` executable into your `PATH` and initializes the secure global config folder at
`~/.agent-sandbox/`.)*

## 🛠️ Initial Configuration

1. **Global Secrets (`~/.agent-sandbox/secrets.env`):** Add your real keys to this local file. It is a plain
   `key=value` file (one assignment per line, `#` comments allowed), automatically locked down with exclusive read
   permissions (`chmod 600`):

   ```ini
   # agent-sandbox secrets
   github=ghp_YOUR_REAL_GITHUB_TOKEN
   anthropic=sk-ant-api03-YOUR_REAL_CLAUDE_KEY
   ```

2. **Project Environment (`.agent-sandbox/dev.json`):** Navigate to your project repository and initialize the workspace
   configuration:

   ```bash
   agent-sandbox init
   ```

   This generates a JSON file defining the agent image and domain interception rules. **This file is 100% safe to
   commit to Git** because it contains no real secrets — only `{{secrets.<key>}}` placeholders that are resolved at
   startup from `secrets.env`:

   ```json
   {
     "image": "xoadev/opencode-sandbox-image:latest",
     "vault": [
       {
         "match": { "host": "api.github.com" },
         "inject": { "headers": { "Authorization": "Bearer {{secrets.github}}" } }
       },
       {
         "match": { "host": "api.anthropic.com" },
         "inject": { "headers": { "x-api-key": "{{secrets.anthropic}}" } }
       }
     ]
   }
   ```

   The `image` field is polymorphic: a registry image name (e.g. `xoadev/opencode-sandbox-image:latest`) is used directly,
   while a path beginning with `./` or `/`, or ending in `Dockerfile`, is treated as a **local Dockerfile** that is
   built and tagged `agent-sandbox-<env>:latest` on each `agent-sandbox <env>` run.

## 💻 Daily Usage

Spin up the sandbox and drop directly into its secure terminal:

```bash
agent-sandbox dev
```

Inside the container, the workspace mounts at `/workspace` (your current host directory) and opencode is on the
`PATH`. For example, with the bundled image:

```bash
opencode
```

- **Seamless Setup:** The script parses your configurations, provisions the private bridge network, mounts your current
  project directory to `/workspace`, and launches the interactive shell.
- **Automatic Destruction:** When you type `exit` or press `Ctrl+D`, a Bash trap instantly and cleanly tears down all
  containers, volumes, and temporary networks.

## 🛡️ Security Audit: Verifying the Protections

Once inside the sandbox shell, you can verify your triple-layered defenses:

- **Is gVisor active?**

  ```bash
  uname -a  # It should indicate you are running on runsc/gVisor
  ```

- **Are secrets protected?**

  ```bash
  echo $GITHUB_TOKEN  # Should output "dummy_github_token"
  curl -I https://api.github.com  # Succeeds because the network proxy silently injected the real token
  ```

- **Is Docker-in-Docker safe?**

  ```bash
  docker ps  # You can interact with Docker to run your integration tests without risking host compromise
  ```

## ✅ Tests

A self-contained Bash test runner (no external framework) validates the CLI's core logic — help output, `init`
generation, secret/placeholder substitution, and the Dockerfile-detection path. It mocks `docker` via stubs on `PATH`,
so no real container engine is required.

```bash
bash tests/run_tests.sh
```

Fixtures live under [`tests/fixtures/`](./tests/fixtures).
