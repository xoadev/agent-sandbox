# Agent Instruction Guide

## Key Technical Facts

- **Pure Bash**: The logic is implemented entirely in Bash. Avoid looking for Python/Go dependencies for core features.
- **No External Tools**: Heavily favors native shell tools; avoids `jq` or `yq` where possible to keep it simple and
  maintainable.
- **Monorepo Structure**: Includes various components. The `containers/` directory contains pre-prepared agent images.
- **Usage**:
  - `agent-sandbox <env>`: Start the sandbox for a configured environment (e.g., `agent-sandbox dev`).
  - `agent-sandbox init <env>`: Initialize a new environment configuration.
  - `bash tests/run_tests.sh`: Run the internal test suite.
- **Test Directory Usage**: All tests use `mktemp -d` to create temporary directories in system temp location (/tmp) for isolation, and never create persistent folders within the codebase.

## 🚀 Monorepo Versioning & CI/CD

This project utilizes [convco-version](https://github.com/xoadev/convco-version) for independent component versioning
and automated releases via GitHub Actions. Each sub-component follows its own lifecycle:

### Component Versioning

The CI/CD pipeline detects changes in specific directories to trigger the appropriate version bump and release:

- **CLI Tool (`cli-vX.Y.Z`)**: Triggered by changes in the root directory (e.g., `agent-sandbox.sh`, `install.sh`) or
  core configuration files.
- **Agent Container (`opencode-vX.Y.Z`)**: Triggered by changes within `containers/opencode/` (e.g., `Dockerfile`,
  `skills/`).
