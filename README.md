# agent-sandbox

Sandboxed Docker environment for running AI coding agents (Claude Code, OpenCode) in isolation from your host system.

## Why

Coding agents run with full filesystem access on your machine — including SSH keys, dotfiles, passwords, and other projects. Agent Sandbox gives agents a complete dev environment while hiding everything else.

**What agents get:**
- Full shell with common tools (bash, git, curl, vim, jq, tmux, tree, ...)
- Python 3 with pip and venv
- Node.js LTS with npm
- Claude Code and OpenCode pre-installed
- Full outbound internet access
- Your project directory mounted at `/workspace`

**What agents don't get:**
- Your home directory, SSH keys, or system files
- Access to Docker (no Docker socket mounted)
- Any credentials unless you explicitly pass them via `-e`

## Prerequisites

- Docker (Docker Desktop on macOS, plain Docker daemon on Linux)
- Docker Compose v2 (`docker compose` command available)
- On macOS without Docker Desktop: install Colima (`brew install colima && colima start`)

## Quick Start

```bash
# Clone and build
git clone https://github.com/soster/agent-sandbox.git
cd agent-sandbox
docker build -t agent-sandbox:latest .

# Run a project in a sandboxed container
./vm.sh run ~/git/my-project -p 8080:8080

# Run commands inside the container
./vm.sh exec ~/git/my-project node --version
./vm.sh exec ~/git/my-project python3 --version

# Stop and clean up
./vm.sh stop ~/git/my-project
./vm.sh rm ~/git/my-project
```

## Commands

| Command | Description |
|---------|-------------|
| `./vm.sh run <project>` | Start container with project mounted |
| `./vm.sh claude <project>` | Start container and run Claude Code |
| `./vm.sh opencode <project>` | Start container and run OpenCode |
| `./vm.sh exec <project> <cmd>` | Run command in running container |
| `./vm.sh stop <project>` | Stop container |
| `./vm.sh logs <project>` | View container logs |
| `./vm.sh rm <project>` | Stop and remove container |
| `./vm.sh config` | Interactive shell into config volume |

### Options

| Option | Description |
|--------|-------------|
| `-p host:container` | Map port (repeatable) |
| `-e KEY=VALUE` | Set environment variable (repeatable) |
| `-- <cmd>` | Override default command (`run` only) |

## Examples

**Run a project with web server access:**
```bash
./vm.sh run ~/git/my-app -p 3000:3000 -p 8080:8080
```

**Run Claude Code with API key:**
```bash
./vm.sh claude ~/git/my-project \
  -e ANTHROPIC_API_KEY=sk-ant-...
```

**Run OpenCode:**
```bash
./vm.sh opencode ~/git/my-project
```

**Run a custom command:**
```bash
./vm.sh run ~/git/my-project -- npm test
```

**Manage agent skills and config:**
```bash
./vm.sh config
# You're in a shell with the config volume mounted at ~/.agent-config
# Edit skills, add configs, install plugins — they persist across containers
```

**Run multiple projects simultaneously:**
```bash
# Terminal 1
./vm.sh run ~/git/project-a -p 3000:3000

# Terminal 2
./vm.sh run ~/git/project-b -p 8080:8080
```

Each project gets its own container with a unique name derived from the project path.

## Architecture

```
agent-sandbox/
├── Dockerfile              # Base image: Debian + tools + agents
├── docker-compose.yml      # Template (reference only)
├── entrypoint.sh           # Sets up config symlinks on startup
├── vm.sh                   # Wrapper script for all operations
└── .gitignore
```

### How It Works

1. `vm.sh run ~/git/my-project` generates a Docker Compose file in `~/git/my-project/.vm/docker-compose.yml`
2. The compose file mounts two volumes:
   - Your project directory → `/workspace` (read-write)
   - `agent-sandbox-config` Docker volume → `/home/agent/.agent-config`
3. The entrypoint creates symlinks so both Claude Code and OpenCode find their config in the shared volume
4. The container runs as a non-root user (`agent`) with passwordless sudo

### Config Volume

The `agent-sandbox-config` Docker volume persists agent configuration, skills, and caches across containers. The entrypoint sets up symlinks:

| Symlink | Target | Used By |
|---------|--------|---------|
| `~/.claude` | `.agent-config/claude` | Claude Code |
| `~/.config/opencode` | `.agent-config/opencode` | OpenCode |
| `~/.agents/skills` | `.agent-config/agents-skills` | Claude Code |
| `~/.opencode/skills` | `.agent-config/opencode-skills` | OpenCode |
| `~/.cache/opencode` | `.agent-config/cache-opencode` | OpenCode |

Use `./vm.sh config` to open a shell and manage these files.

## Security

- **Host isolation:** Only the project directory and config volume are mounted. The container cannot see your home directory, SSH keys, or other projects.
- **No Docker access:** The Docker socket is not mounted, so the container cannot control Docker.
- **Non-root user:** All containers run as `agent` (UID 1000), not root.
- **Explicit credentials:** API keys and tokens must be passed explicitly via `-e` flags. Nothing is inherited from the host.

## Cross-Platform

Works on both macOS and Linux with identical commands:

| Platform | Docker Setup |
|----------|-------------|
| macOS | Docker Desktop or Colima (`brew install colima && colima start`) |
| Linux | Plain Docker daemon + Compose plugin |

The Debian base image supports both `amd64` and `arm64` architectures.

## Customization

### Add more tools

Edit `Dockerfile` and rebuild:
```dockerfile
RUN apt-get update && apt-get install -y ruby go ...
```

### Change the base image

Replace `debian:bookworm-slim` with any Debian/Ubuntu-based image.

### Add code-server

code-server (VS Code in browser) can be installed manually inside the container or added to the Dockerfile. Note: it requires native compilation (`build-essential`) and may have compatibility issues with newer Node.js versions.

### Modify the entrypoint

Edit `entrypoint.sh` to add custom setup, environment variables, or additional symlinks.

## Troubleshooting

**`docker: unknown command: docker compose`**

Docker Compose v2 plugin is not installed. On macOS with Homebrew:
```bash
brew install docker-compose
# Add to ~/.docker/config.json:
# "cliPluginsExtraDirs": ["/opt/homebrew/lib/docker/cli-plugins"]
```

**`container is not running`**

The container may have crashed. Check logs:
```bash
./vm.sh logs ~/git/my-project
```

**Permission denied on config volume**

The entrypoint handles this automatically with `sudo chown`. If it persists, rebuild the image.

**`/tmp` projects don't mount on macOS**

Colima doesn't share `/tmp` with the VM by default. Use projects in `~/` or another shared directory.

## License

MIT
