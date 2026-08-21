# Agent Sandbox — Agent Instructions

## What This Project Is

A Docker-based sandboxed environment for running AI coding agents (Claude Code, OpenCode, pi) in isolation. Agents get a full dev environment (shell, Python, Node.js, git) without access to the host's home directory, SSH keys, or other projects.

## Architecture

```
agent-sandbox/
├── Dockerfile           # Debian base + tools + agents, non-root "agent" user
├── docker-compose.yml   # Reference template (vm.sh generates per-project files)
├── entrypoint.sh        # Sets up config symlinks on container startup
├── vm.sh                # Wrapper script — all container lifecycle operations
├── tests/vm-test.sh     # Unit tests for vm.sh helpers (no Docker required)
├── docs/                # Design spec and implementation plan
└── .gitignore
```

### Key Concepts

- **Project mount:** User's project is bind-mounted at `/workspace` inside the container.
- **Config volume:** `agent-sandbox-config` Docker named volume persists agent config/skills across containers. Entrypoint symlinks it to `~/.claude`, `~/.config/opencode`, `~/.pi`, `~/.agents/skills`, `~/.opencode/skills`, `~/.cache/opencode`.
- **Agent subcommands:** `claude`, `opencode` and `pi` all route through `run_agent()`. The `AGENTS` table at the top of `vm.sh` maps subcommand → binary → label; adding a harness means adding one line there.
- **Container spec:** `build_container_spec()` resolves host DNS, `HOST_EXTRA_HOSTS` and `.env`/`-e` variables into `SPEC_DNS`/`SPEC_HOSTS`/`SPEC_ENV`. The `docker run` path renders them via `render_docker_args()`, the compose path via `generate_compose()`. Never duplicate that resolution logic — extend the spec instead.
- **Per-project compose:** `vm.sh run <project>` generates `<project>/.vm/docker-compose.yml` dynamically. The root `docker-compose.yml` is a reference template only.
- **Container naming:** `container_name()` sanitizes project path to a valid Docker name.

## Building and Testing

```bash
# Build the image
docker build -t agent-sandbox:latest .

# Quick smoke test
docker run --rm agent-sandbox:latest bash -c 'node --version && python3 --version && git --version'
docker run --rm agent-sandbox:latest bash -c 'claude --version && opencode --version && pi --version'

# Unit tests for vm.sh (no Docker required)
./tests/vm-test.sh

# Test vm.sh usage
./vm.sh
```

Run `./tests/vm-test.sh` after any change to `vm.sh`. It sources the script, so
`vm.sh` must keep dispatching only under `if [ "${BASH_SOURCE[0]}" = "${0}" ]`.

## Coding Conventions

### vm.sh
- Bash strict mode: `set -euo pipefail`
- Must run under macOS's bash 3.2: no `declare -g`, no associative arrays, and
  expand possibly-empty arrays as `${arr[@]+"${arr[@]}"}` (plain `"${arr[@]}"`
  is an unbound-variable error under `set -u`)
- Functions use `local` for all variables
- Args parsed into `PARSED_*` globals by the single `parse_args`; everything
  after `--` lands in the `PARSED_CMD` array
- Container settings resolved into `SPEC_*` globals by `build_container_spec()`
- Compose generation via `generate_compose()` — outputs YAML to file, returns path via stdout
- YAML values that come from user input go through `yaml_dq()`
- Image name and config volume controlled by `IMAGE_NAME` / `CONFIG_VOLUME` at top of file

### entrypoint.sh
- `set -e` only (no pipefail needed)
- All config symlinks go through `link_config <path> <volume-subdir>`
- Symlink creation is idempotent: checks existence before `ln -s`, so a
  bind-mounted path (e.g. `~/.config/opencode`) is left alone
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
- `container_name()` maps every non-alphanumeric character to `_`, so `my-project` becomes `my_project`. Changing this orphans existing containers.
- pi's config lives at `~/.pi/agent`; the whole `~/.pi` tree is symlinked into the volume so sessions and installed packages persist
