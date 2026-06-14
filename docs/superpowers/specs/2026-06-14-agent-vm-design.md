# Agent VM — Isolated Coding Container

**Date:** 2026-06-14
**Status:** Approved

## Problem

Coding agents (Claude Code, OpenCode) run on the host machine with full access to the filesystem — including SSH keys, dotfiles, passwords, and other projects. This creates two risks:

1. **Safety:** Agents might run destructive commands or modify system configuration
2. **Privacy:** Agents can read sensitive files outside the project

We need a sandboxed environment where agents can work on projects with full tooling (shell, Python, Node.js, git, web servers) while being isolated from the rest of the system.

## Design

### Architecture

A centralized manager project provides a Docker-based dev environment:

```
agent-vm/
├── Dockerfile           # Base dev image
├── docker-compose.yml   # Template with volume + service definitions
├── vm.sh                # Wrapper script
└── .gitignore
```

Workflow: Run `./vm.sh run /path/to/project` to start a sandboxed container with the project mounted at `/workspace`. The script generates a per-project `docker-compose.yml` in a `.vm/` directory alongside the project, using the template from `agent-vm/docker-compose.yml`.

### Docker Image

Based on `debian:bookworm`.

**Pre-installed tools:**
- Shell: bash, curl, wget, git, vim, nano, jq, less, tree, tmux
- Python 3 with pip and venv
- Node.js LTS with npm
- Coding agents: `claude-code` and `opencode` (global npm installs)
- code-server (VS Code in browser, accessible when port is exposed)

**User:** Non-root user `agent` with passwordless sudo.

### Volume Strategy

- **`agent-vm-config`** — Docker named volume for persistent agent configuration, skills, and caches. Mounted at `/home/agent/.agent-config`, with symlinks to `~/.config/opencode`, `~/.agents/skills`, `~/.opencode/skills`, and `~/.cache/opencode` so both agents find their config and skills.
- **Project directories** — bind-mounted read-write at `/workspace`
- **Host home directory** — not mounted; container cannot see SSH keys, passwords, or other projects

### Security

- Only `/workspace` (project) and `/home/agent/.agent-config` (agent config) are accessible
- No Docker socket mounted — container cannot control Docker
- Non-root user by default
- Full outbound internet allowed, but no host credentials available (no SSH keys, no tokens in environment by default)
- API keys passed explicitly via `-e` flags

### Port Exposure

No automatic port exposure. Ports are explicitly mapped via `-p` flags:
- `./vm.sh run ~/git/myproject -p 8080:8080` — web server on 8080
- `./vm.sh run ~/git/myproject -p 3000:3000 -p 8090:8090` — multiple services

### vm.sh Commands

| Command | Description |
|---------|-------------|
| `vm.sh run <project> [-p host:container ...] [-e KEY=VALUE ...] [-- <cmd>]` | Start container with project mounted |
| `vm.sh claude <project> [-p ...] [-e ...]` | Shortcut: start container and run claude code |
| `vm.sh opencode <project> [-p ...] [-e ...]` | Shortcut: start container and run opencode |
| `vm.sh exec <project> <command>` | Run command in running container |
| `vm.sh stop <project>` | Stop container |
| `vm.sh logs <project>` | View container logs |
| `vm.sh rm <project>` | Stop and remove container |
| `vm.sh config` | Interactive shell into config volume for managing skills |

### Cross-Platform Compatibility

- Docker Compose v2 syntax — works with `docker compose` on both macOS (Docker Desktop) and Linux (plain Docker daemon + Compose plugin)
- No platform-specific code in `vm.sh`
- Volume and bind mounts work identically on both platforms
- Debian base image runs on both amd64 and arm64

## Out of Scope

- GUI applications (X11/Wayland forwarding)
- GPU access
- Docker-in-Docker
- Multi-container orchestration beyond a single project
