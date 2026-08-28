#!/bin/bash
set -e

CONFIG_DIR="/home/agent/.agent-config"

# Fix ownership of config volume (may be created as root by Docker)
if [ -d "$CONFIG_DIR" ]; then
    sudo chown -R agent:agent "$CONFIG_DIR" 2>/dev/null || true
fi

mkdir -p "$CONFIG_DIR"

# Claude Code config at ~/.claude
if [ ! -d "$HOME/.claude" ]; then
    ln -s "$CONFIG_DIR/claude" "$HOME/.claude"
fi
mkdir -p "$CONFIG_DIR/claude"

# ~/.claude.json must also be persisted; it lives outside ~/.claude/ so the
# volume symlink doesn't cover it.  Point it into the volume and restore from
# backup if the canonical copy is missing.
CLAUDE_JSON_PERSISTED="$CONFIG_DIR/claude/.claude.json"
if [ ! -f "$CLAUDE_JSON_PERSISTED" ]; then
    backup=$(ls -t "$CONFIG_DIR/claude/backups/.claude.json.backup."* 2>/dev/null | head -1 || true)
    [ -n "$backup" ] && cp "$backup" "$CLAUDE_JSON_PERSISTED"
fi
ln -sf "$CLAUDE_JSON_PERSISTED" "$HOME/.claude.json"

# OpenCode config at ~/.config/opencode
if [ ! -d "$HOME/.config/opencode" ]; then
    mkdir -p "$HOME/.config"
    ln -s "$CONFIG_DIR/opencode" "$HOME/.config/opencode"
fi
mkdir -p "$CONFIG_DIR/opencode"

# Claude Code skills at ~/.agents/skills
if [ ! -d "$HOME/.agents/skills" ]; then
    mkdir -p "$HOME/.agents"
    ln -s "$CONFIG_DIR/agents-skills" "$HOME/.agents/skills"
fi
mkdir -p "$CONFIG_DIR/agents-skills"

# OpenCode skills at ~/.opencode/skills
if [ ! -d "$HOME/.opencode/skills" ]; then
    mkdir -p "$HOME/.opencode"
    ln -s "$CONFIG_DIR/opencode-skills" "$HOME/.opencode/skills"
fi
mkdir -p "$CONFIG_DIR/opencode-skills"

# OpenCode cache at ~/.cache/opencode
if [ ! -d "$HOME/.cache/opencode" ]; then
    mkdir -p "$HOME/.cache"
    ln -s "$CONFIG_DIR/cache-opencode" "$HOME/.cache/opencode"
fi
mkdir -p "$CONFIG_DIR/cache-opencode"

exec "$@"
