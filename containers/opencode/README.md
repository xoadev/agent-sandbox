# opencode Agent Container

Base image for the agent-sandbox. Includes:

- [opencode](https://opencode.ai) — AI agent framework
- [Docker CLI](https://docs.docker.com/engine/) + [Compose plugin](https://docs.docker.com/compose/)
- [GitHub CLI](https://cli.github.com/) (`gh`)
- [skills.sh](https://skills.sh) — Agent skill ecosystem CLI (`npm` → `pnpm`)

Add tools by editing the `Dockerfile` in this directory.

```bash
docker build -t agent-sandbox-opencode:latest ./containers/opencode
```

For usage with the sandbox, see the [main README](../../README.md).
