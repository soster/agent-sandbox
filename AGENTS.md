# Agent Sandbox — Agent Instructions

## What This Project Is

A Docker-based sandboxed environment for running AI coding agents (Claude Code, OpenCode) in isolation. Agents get a full dev environment (shell, Python, Node.js, git) without access to the host's home directory, SSH keys, or other projects.

## Architecture

```
agent-sandbox/
├── Dockerfile           # Debian base + tools + agents, non-root "agent" user
├── docker-compose.yml   # Reference template (vm.sh generates per-project files)
├── entrypoint.sh        # Sets up config symlinks on container startup
├── vm.sh                # Wrapper script — all container lifecycle operations
├── docs/                # Design spec and implementation plan
└── .gitignore
```

### Key Concepts

- **Project mount:** User's project is bind-mounted at `/workspace` inside the container.
- **Config volume:** `agent-sandbox-config` Docker named volume persists agent config/skills across containers. Entrypoint symlinks it to `~/.claude`, `~/.config/opencode`, `~/.agents/skills`, `~/.opencode/skills`, `~/.cache/opencode`.
- **Per-project compose:** `vm.sh run <project>` generates `<project>/.vm/docker-compose.yml` dynamically. The root `docker-compose.yml` is a reference template only.
- **Container naming:** `container_name()` sanitizes project path to a valid Docker name.

## Building and Testing

```bash
# Build the image
docker build -t agent-sandbox:latest .

# Quick smoke test
docker run --rm agent-sandbox:latest bash -c 'node --version && python3 --version && git --version'

# Test vm.sh usage
./vm.sh
```

## Coding Conventions

### vm.sh
- Bash strict mode: `set -euo pipefail`
- Functions use `local` for all variables
- Args parsed into `PARSED_*` globals (consistent pattern across `parse_args` / `parse_run_args`)
- Compose generation via `generate_compose()` — outputs YAML to file, returns path via stdout
- Image name controlled by `IMAGE_NAME` variable at top of file

### entrypoint.sh
- `set -e` only (no pipefail needed)
- Symlink creation is idempotent: checks existence before `ln -s`
- Creates target directories with `mkdir -p` after symlink (so config volume subdirs exist)
- Uses `exec "$@"` to replace shell with user command

### Dockerfile
- Debian bookworm-slim base
- All apt installs in single `RUN` with cleanup
- Non-root user `agent` (UID 1000) with passwordless sudo
- Git configured for agent commits: `agent@agent-sandbox.local`

### General
- Cross-platform: macOS (Docker Desktop or Colima) and Linux — no platform-specific code
- No Docker socket mounted — container cannot control Docker
- Port exposure is explicit via `-p` flags, never automatic
- Keep README.md as the single source of truth for end-user documentation

## Important Constraints

- Do not add `code-server` back to the Dockerfile — it was removed due to compatibility issues
- The `.vm/` directory is generated and gitignored by the project it lives in, not by agent-sandbox
- Config volume management uses `./vm.sh config` — agents should not assume direct volume access
