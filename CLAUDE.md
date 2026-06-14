# agent-sandbox — Claude-Specific Instructions

See [AGENTS.md](./AGENTS.md) for shared project context, architecture, and coding conventions.

## Claude Code Configuration

- Your config lives at `~/.claude` (symlinked from `~/.agent-config/claude`).
- Skills live at `~/.agents/skills` (symlinked from `~/.agent-config/agents-skills`).
- Both are persisted via the `agent-sandbox-config` Docker volume.

## When Modifying vm.sh `cmd_claude`

- The `claude` subcommand sets `command: claude` in the generated compose file.
- Use `docker compose up` (not `up -d`) so Claude Code stays attached to stdin/stdout.
- If you change how the claude command is invoked, also update `cmd_opencode` for parity.
