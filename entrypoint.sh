#!/bin/bash
set -e

CONFIG_DIR="/home/agent/.agent-config"

# Fix ownership of config volume (may be created as root by Docker)
if [ -d "$CONFIG_DIR" ]; then
    sudo chown -R agent:agent "$CONFIG_DIR" 2>/dev/null || true
fi

mkdir -p "$CONFIG_DIR"

# Point <path> at $CONFIG_DIR/<name> so the agent's config lives in the
# persistent volume. Idempotent: an existing path (symlink or real directory,
# e.g. a bind mount) is left alone.
link_config() {
    local path="$1"
    local name="$2"

    if [ ! -d "$path" ]; then
        mkdir -p "$(dirname "$path")"
        ln -s "$CONFIG_DIR/$name" "$path"
    fi
    mkdir -p "$CONFIG_DIR/$name"
}

link_config "$HOME/.claude"          claude           # Claude Code config
link_config "$HOME/.config/opencode" opencode         # OpenCode config
link_config "$HOME/.pi"              pi               # pi config (reads ~/.pi/agent)
link_config "$HOME/.agents/skills"   agents-skills    # Claude Code skills
link_config "$HOME/.opencode/skills" opencode-skills  # OpenCode skills
link_config "$HOME/.cache/opencode"  cache-opencode   # OpenCode cache

# pi keeps settings, auth, packages, skills and sessions under ~/.pi/agent
mkdir -p "$CONFIG_DIR/pi/agent"

exec "$@"
