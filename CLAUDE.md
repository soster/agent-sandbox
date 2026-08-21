# agent-sandbox — Claude-Specific Instructions

See [AGENTS.md](./AGENTS.md) for shared project context, architecture, and coding conventions.

## Claude Code Configuration

- Your config lives at `~/.claude` (symlinked from `~/.agent-config/claude`).
- Skills live at `~/.agents/skills` (symlinked from `~/.agent-config/agents-skills`).
- Both are persisted via the `agent-sandbox-config` Docker volume.

## When Modifying How Agents Are Launched

- `claude`, `opencode` and `pi` share one code path: `run_agent()` in `vm.sh`,
  driven by the `AGENTS` table at the top of the file. Change it once and all
  three stay in parity — do not reintroduce per-agent copies.
- `run_agent` uses `docker run -it` (not `docker compose up -d`) so the agent
  stays attached to stdin/stdout.
- Arguments after `--` are appended to the agent's own command line, so
  `./vm.sh claude <project> -- --model opus` works.
- Adding a fourth harness = one line in `AGENTS` + an install in the
  `Dockerfile` + a `link_config` line in `entrypoint.sh` if it needs config.
