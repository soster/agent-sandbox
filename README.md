# agent-sandbox

Sandboxed Docker environment for running AI coding agents (Claude Code, OpenCode, pi) in isolation from your host system.

## Why

Coding agents run with full filesystem access on your machine — including SSH keys, dotfiles, passwords, and other projects. Agent Sandbox gives agents a complete dev environment while hiding everything else.

**What agents get:**
- Full shell with common tools (bash, git, curl, vim, jq, ripgrep, tmux, tree, ...)
- Python 3 with pip and venv
- Node.js LTS with npm
- Claude Code, OpenCode and pi pre-installed
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
| `./vm.sh pi <project>` | Start container and run pi |
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
| `-e HOST_EXTRA_HOSTS="host:ip"` | Add static hostname entries (comma-separated) |
| `-- <args>` | Pass arguments to the agent, or override the command (`run`) |

`HOST_EXTRA_HOSTS` configures the sandbox itself and is never passed into the
container as an environment variable.

Everything after `--` goes to the agent verbatim, so any of its own flags work:

```bash
./vm.sh pi ~/git/my-project -- --provider anthropic --thinking high
./vm.sh claude ~/git/my-project -- --model opus
./vm.sh run ~/git/my-project -- npm test
```

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

**Run pi:**
```bash
./vm.sh pi ~/git/my-project
```

**Run OpenCode with local network host:**
```bash
./vm.sh opencode ~/git/my-project \
  -e HOST_EXTRA_HOSTS="example:192.168.178.2"
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

## Typical Workflow

```bash
# 1. Start a container for your project
./vm.sh run ~/git/my-project -p 3000:3000

# 2. Run Claude Code or OpenCode inside it
./vm.sh exec ~/git/my-project claude
./vm.sh exec ~/git/my-project opencode

# 3. Or use the convenience commands (interactive TTY)
./vm.sh claude ~/git/my-project -e ANTHROPIC_API_KEY=sk-ant-...
./vm.sh opencode ~/git/my-project
./vm.sh pi ~/git/my-project

# 4. When done, stop or remove
./vm.sh stop ~/git/my-project   # keeps container for restart
./vm.sh rm ~/git/my-project     # removes container and .vm/ directory
```

## Connecting to Local AI Providers

If you run AI inference servers locally (LM Studio, Ollama, llama.cpp, etc.), the container can reach them using `host.docker.internal` instead of `localhost`:

1. Open the config shell: `./vm.sh config`
2. Edit `~/.agent-config/opencode/opencode.json` (or `~/.claude/settings.local.json`)
3. Replace `localhost` / `127.0.0.1` with `host.docker.internal`

For example, an LM Studio provider at `http://localhost:1234/v1` becomes:

```json
{
  "provider": {
    "lmstudio": {
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "http://host.docker.internal:1234/v1"
      }
    }
  }
}
```

This works on both Docker Desktop and Colima.

### Local Network Hosts

The container inherits your host's IPv4 DNS servers. For hosts on your local network that aren't resolvable through standard DNS (e.g., mDNS `.local` addresses), use `HOST_EXTRA_HOSTS` to add static hostname entries:

```bash
./vm.sh opencode ~/git/my-project \
  -e HOST_EXTRA_HOSTS="mini:192.168.178.138"
```

This adds `mini` → `192.168.178.138` to the container's `/etc/hosts`, so your provider config can use `http://mini:8001/v1`. You can pass multiple entries separated by commas:

```bash
-e HOST_EXTRA_HOSTS="mini:192.168.178.138,ollama-server:192.168.1.50"
```

### Using `.env` Files

`vm.sh` loads `<project>/.env` automatically for the `run`, `claude`, `opencode`, and `pi` commands. Surrounding quotes around values are stripped, and CLI flags (`-e`) override `.env` values.

Example `~/git/my-project/.env`:
```
HOST_EXTRA_HOSTS=mini:192.168.178.138
ANTHROPIC_API_KEY=sk-ant-...
```

Then just run:
```bash
./vm.sh opencode ~/git/my-project
```

## Running pi

[pi](https://www.npmjs.com/package/@earendil-works/pi-coding-agent) is installed in the image and stores everything under `~/.pi/agent` — settings, credentials, installed packages, skills and sessions. That directory is symlinked into the config volume, so it is **isolated from your host `~/.pi`** and persists across containers.

A fresh config volume has no pi settings, and pi defaults to the `google` provider. On the first run, either pick a provider on the command line:

```bash
./vm.sh pi ~/git/my-project -- --provider anthropic
```

or run `/login` inside pi to store a key in `~/.pi/agent/auth.json`. Either way, write the choice into `~/.pi/agent/settings.json` once and later runs need no flags:

```bash
./vm.sh config
mkdir -p ~/.agent-config/pi/agent
cat > ~/.agent-config/pi/agent/settings.json <<'EOF'
{
  "defaultProvider": "anthropic",
  "defaultModel": "claude-sonnet-5"
}
EOF
```

API keys are picked up from the environment, so a project `.env` containing `ANTHROPIC_API_KEY=...` is enough to authenticate.

Installing pi packages works normally and persists, because `~/.pi/agent/npm` lives in the volume:

```bash
./vm.sh pi ~/git/my-project -- install npm:@tintinweb/pi-subagents
```

To point pi at a local inference server, combine `HOST_EXTRA_HOSTS` with pi's `llamaServerUrl` / provider settings — see [Connecting to Local AI Providers](#connecting-to-local-ai-providers).

## Architecture

```
agent-sandbox/
├── Dockerfile              # Base image: Debian + tools + agents
├── docker-compose.yml      # Template (reference only)
├── entrypoint.sh           # Sets up config symlinks on startup
├── vm.sh                   # Wrapper script for all operations
├── tests/vm-test.sh        # Unit tests for vm.sh (no Docker needed)
└── .gitignore
```

### How It Works

1. `vm.sh run ~/git/my-project` generates a Docker Compose file in `~/git/my-project/.vm/docker-compose.yml`
2. The compose file mounts volumes:
   - Your project directory → `/workspace` (read-write)
   - `agent-sandbox-config` Docker volume → `/home/agent/.agent-config`
   - Your host `~/.config/opencode` → `/home/agent/.config/opencode` (bind mount)
3. The entrypoint creates symlinks so Claude Code, OpenCode and pi find their config in the shared volume
4. Host DNS servers are forwarded into the container, enabling mDNS resolution for local network hosts
5. The container runs as a non-root user (`agent`) with passwordless sudo

### Config Volume

The `agent-sandbox-config` Docker volume persists agent configuration, skills, and caches across containers. The entrypoint sets up symlinks:

| Symlink | Target | Used By |
|---------|--------|---------|
| `~/.claude` | `.agent-config/claude` | Claude Code |
| `~/.agents/skills` | `.agent-config/agents-skills` | Claude Code |
| `~/.pi` | `.agent-config/pi` | pi |
| `~/.opencode/skills` | `.agent-config/opencode-skills` | OpenCode |
| `~/.cache/opencode` | `.agent-config/cache-opencode` | OpenCode |

Note: `~/.config/opencode` is bind-mounted directly from your host, so your OpenCode provider config is available automatically.

Use `./vm.sh config` to open a shell and manage these files.

### Per-Project `.vm/` Directory

Each project gets a `.vm/` directory containing its generated `docker-compose.yml`. This directory is:
- Created automatically by `vm.sh run`
- Removed by `vm.sh rm`
- Should be gitignored by the **project** it lives in (not by agent-sandbox itself)

### Container Naming

Container names are derived from the project path by replacing `/` and non-alphanumeric characters with `_`, then stripping leading/trailing underscores. For example:

| Project Path | Container Name |
|--------------|----------------|
| `~/git/my-project` | `Users_oster_git_my_project` |
| `~/Documents/work/app` | `Users_oster_Documents_work_app` |

## Agent Skills

Skills extend agent behavior with specialized instructions and tools. They're stored in the config volume so they persist across containers:

- **Claude Code skills:** `~/.agents/skills/` (symlinked from `.agent-config/agents-skills`)
- **OpenCode skills:** `~/.opencode/skills/` (symlinked from `.agent-config/opencode-skills`)
- **pi skills:** `~/.pi/agent/skills/` (symlinked from `.agent-config/pi`)

Manage skills from the config shell:

```bash
./vm.sh config
# Inside the shell:
ls ~/.agent-config/agents-skills/
ls ~/.agent-config/opencode-skills/
```

## Testing

`tests/vm-test.sh` unit-tests the `vm.sh` helpers — `.env` parsing, CLI/`.env` precedence, DNS filtering, `HOST_EXTRA_HOSTS` handling, argument parsing and compose generation. It sources `vm.sh` (which only dispatches when executed directly) and needs no Docker:

```bash
./tests/vm-test.sh
```

Smoke-test the image itself after a rebuild:

```bash
docker build -t agent-sandbox:latest .
docker run --rm agent-sandbox:latest bash -c 'claude --version && opencode --version && pi --version'
```

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

**pi starts with the wrong provider**

A fresh config volume has no `~/.pi/agent/settings.json`, so pi falls back to its `google` default. Pass `-- --provider <name>` or write a settings file — see [Running pi](#running-pi).

**OpenCode / Claude Code exit immediately**

The agent likely has no AI provider configured. Either:
- Pass an API key: `./vm.sh claude ~/git/my-project -e ANTHROPIC_API_KEY=sk-ant-...`
- Configure a local provider using `host.docker.internal` (see "Connecting to Local AI Providers")
- Run `/connect` inside the agent to add a provider interactively

**Cannot reach local AI server from container**

Use `host.docker.internal` instead of `localhost` in your provider configuration. Verify connectivity:
```bash
./vm.sh exec ~/git/my-project curl -s http://host.docker.internal:1234/v1/models
```

## License

MIT
