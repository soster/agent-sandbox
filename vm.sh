#!/bin/bash
set -euo pipefail

IMAGE_NAME="agent-sandbox"
CONFIG_VOLUME="agent-sandbox-config"
# Overridable so tests can supply a fixture instead of the host's resolver config.
RESOLV_CONF="${RESOLV_CONF:-/etc/resolv.conf}"

# Agents runnable as a subcommand: <subcommand>:<binary>:<label>
AGENTS="claude:claude:Claude Code
opencode:opencode:OpenCode
pi:pi:pi"

usage() {
    cat <<EOF
Usage:
  vm.sh <command> [options]

Commands:
  run <project> [options] [-- <cmd>]
      Start container with project mounted at /workspace
  claude <project> [options] [-- <args>]
      Start container and run Claude Code
  opencode <project> [options] [-- <args>]
      Start container and run OpenCode
  pi <project> [options] [-- <args>]
      Start container and run pi
  exec <project> <command>
      Execute command in running container
  stop <project>
      Stop container
  logs <project>
      View container logs
  rm <project>
      Stop and remove container
  config
      Interactive shell into config volume

Options:
  -p host:container   Map port (can be repeated)
  -e KEY=VALUE        Set environment variable (can be repeated)
  -- <args>           Arguments passed to the agent, or the command to run
                      instead of the default one (run)

Examples:
  vm.sh run ~/git/my-app -p 3000:3000
  vm.sh pi ~/git/my-app -- --provider anthropic
  vm.sh claude ~/git/my-app -e ANTHROPIC_API_KEY=sk-ant-...
EOF
    exit 1
}

die() {
    echo "Error: $*" >&2
    exit 1
}

agent_binary() {
    echo "$AGENTS" | awk -F: -v a="$1" '$1 == a {print $2}'
}

agent_label() {
    echo "$AGENTS" | awk -F: -v a="$1" '$1 == a {print $3}'
}

container_name() {
    echo "$1" | sed 's|/|_|g; s|[^a-zA-Z0-9_]|_|g; s|__*|_|g; s|^_||; s|_$||'
}

resolve_project() {
    if [[ "$1" = /* ]]; then
        echo "$1"
    else
        echo "$(pwd)/$1"
    fi
}

# Quote a value as a YAML double-quoted scalar, so values containing ':', '#',
# quotes or leading indicators cannot break the generated compose file.
yaml_dq() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"' "$s"
}

# Print the host's routable IPv4 nameservers, one per line.
# Loopback addresses (127.x) are dropped: they point at a resolver on the host,
# which inside the container resolves to the container itself.
host_dns() {
    local conf="${1:-$RESOLV_CONF}"
    [ -f "$conf" ] || return 0
    grep '^nameserver' "$conf" 2>/dev/null | awk '{print $2}' \
        | grep -E '^[0-9]+\.' | grep -vE '^127\.' || true
}

# Read KEY=VALUE pairs from <project>/.env, one per line.
# Comments, blank lines and malformed lines are skipped; a single pair of
# surrounding quotes is stripped from each value.
load_env_file() {
    local env_file="$1/.env"
    [ -f "$env_file" ] || return 0
    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*) ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            if [[ "$value" =~ ^\"(.*)\"$ ]]; then
                value="${BASH_REMATCH[1]}"
            elif [[ "$value" =~ ^\'(.*)\'$ ]]; then
                value="${BASH_REMATCH[1]}"
            fi
            echo "${key}=${value}"
        fi
    done < "$env_file"
}

# Value of the first <key>=... line in a newline-separated KEY=VALUE list.
# A missing key is not an error.
env_get() {
    printf '%s\n' "$2" | grep "^${1}=" | head -1 | cut -d= -f2- || true
}

# The same list with every <key>=... line removed.
env_without() {
    printf '%s\n' "$2" | grep -v "^${1}=" || true
}

# Resolve everything a container needs from the host, the project's .env file
# and CLI -e flags into three arrays, so the docker-run path and the compose
# path render identical settings from one source.
#
#   SPEC_DNS[]    nameservers to forward
#   SPEC_HOSTS[]  host:ip entries for /etc/hosts
#   SPEC_ENV[]    KEY=VALUE variables for the container
#
# Precedence: .env values are emitted first and CLI -e values last, so the CLI
# wins (later -e flags override earlier ones). Extra hosts are ordered the other
# way round because the first matching /etc/hosts entry wins.
#
# Usage: build_container_spec <project> [KEY=VALUE...]
build_container_spec() {
    local project="$1"
    shift
    SPEC_DNS=()
    SPEC_HOSTS=()
    SPEC_ENV=()

    local line
    while IFS= read -r line; do
        [ -n "$line" ] && SPEC_DNS+=("$line")
    done <<< "$(host_dns)"

    local cli_env=""
    if [ $# -gt 0 ]; then
        cli_env="$(printf '%s\n' "$@")"
    fi
    local file_env
    file_env="$(load_env_file "$project")"

    local host_list entry
    for host_list in "$(env_get HOST_EXTRA_HOSTS "$cli_env")" \
                     "$(env_get HOST_EXTRA_HOSTS "$file_env")"; do
        [ -z "$host_list" ] && continue
        local parts
        IFS=',' read -ra parts <<< "$host_list"
        for entry in ${parts[@]+"${parts[@]}"}; do
            [ -n "$entry" ] && SPEC_HOSTS+=("$entry")
        done
    done

    # HOST_EXTRA_HOSTS configures the sandbox itself; it is consumed above and
    # never passed into the container as a variable.
    for line in "$(env_without HOST_EXTRA_HOSTS "$file_env")" \
                "$(env_without HOST_EXTRA_HOSTS "$cli_env")"; do
        [ -z "$line" ] && continue
        while IFS= read -r entry; do
            [ -n "$entry" ] && SPEC_ENV+=("$entry")
        done <<< "$line"
    done
}

# Render the current spec as docker run flags into DOCKER_SPEC_ARGS[].
render_docker_args() {
    DOCKER_SPEC_ARGS=()
    local x
    for x in ${SPEC_DNS[@]+"${SPEC_DNS[@]}"};   do DOCKER_SPEC_ARGS+=(--dns "$x"); done
    for x in ${SPEC_HOSTS[@]+"${SPEC_HOSTS[@]}"}; do DOCKER_SPEC_ARGS+=(--add-host "$x"); done
    for x in ${SPEC_ENV[@]+"${SPEC_ENV[@]}"};   do DOCKER_SPEC_ARGS+=(-e "$x"); done
}

# Mounts and environment shared by every container this script starts.
render_base_docker_args() {
    local project="$1"
    BASE_DOCKER_ARGS=(-w /workspace)
    BASE_DOCKER_ARGS+=(-v "${project}:/workspace")
    BASE_DOCKER_ARGS+=(-v "${CONFIG_VOLUME}:/home/agent/.agent-config")
    BASE_DOCKER_ARGS+=(-v "${HOME}/.config/opencode:/home/agent/.config/opencode")
    BASE_DOCKER_ARGS+=(-e "HOME=/home/agent")
}

# Parse subcommand arguments into:
#   PARSED_PROJECT  project path
#   PARSED_PORTS[]  -p values
#   PARSED_ENV[]    -e values
#   PARSED_CMD[]    everything after --
parse_args() {
    PARSED_PROJECT=""
    PARSED_PORTS=()
    PARSED_ENV=()
    PARSED_CMD=()
    local saw_double_dash=false

    while [ $# -gt 0 ]; do
        if [ "$saw_double_dash" = true ]; then
            PARSED_CMD+=("$1")
            shift
            continue
        fi
        case "$1" in
            -p)
                shift
                [ $# -gt 0 ] || die "-p requires a host:container argument"
                PARSED_PORTS+=("$1")
                ;;
            -e)
                shift
                [ $# -gt 0 ] || die "-e requires a KEY=VALUE argument"
                PARSED_ENV+=("$1")
                ;;
            --)
                saw_double_dash=true
                ;;
            *)
                [ -z "$PARSED_PROJECT" ] || die "unexpected argument: $1"
                PARSED_PROJECT="$1"
                ;;
        esac
        shift
    done
}

# Resolve and validate PARSED_PROJECT, then echo the absolute path.
require_project() {
    [ -n "$PARSED_PROJECT" ] || die "project path required"
    local project
    project="$(resolve_project "$PARSED_PROJECT")"
    [ -d "$project" ] || die "project directory does not exist: $project"
    echo "$project"
}

# Write <project>/.vm/docker-compose.yml from the current spec and parsed args,
# and echo its path.
generate_compose() {
    local project="$1"
    local name="$2"
    local vm_dir="$project/.vm"
    local compose_file="$vm_dir/docker-compose.yml"

    mkdir -p "$vm_dir"

    {
        echo "services:"
        echo "  agent-sandbox:"
        echo "    image: ${IMAGE_NAME}:latest"
        echo "    container_name: ${name}"
        echo "    working_dir: /workspace"
        echo "    volumes:"
        echo "      - ${project}:/workspace"
        echo "      - ${CONFIG_VOLUME}:/home/agent/.agent-config"
        echo "      - ${HOME}/.config/opencode:/home/agent/.config/opencode"

        echo "    environment:"
        echo "      - \"HOME=/home/agent\""
        local x
        for x in ${SPEC_ENV[@]+"${SPEC_ENV[@]}"}; do
            echo "      - $(yaml_dq "$x")"
        done

        if [ ${#SPEC_DNS[@]} -gt 0 ]; then
            echo "    dns:"
            for x in ${SPEC_DNS[@]+"${SPEC_DNS[@]}"}; do
                echo "      - ${x}"
            done
        fi

        if [ ${#SPEC_HOSTS[@]} -gt 0 ]; then
            echo "    extra_hosts:"
            for x in ${SPEC_HOSTS[@]+"${SPEC_HOSTS[@]}"}; do
                echo "      - $(yaml_dq "$x")"
            done
        fi

        echo "    stdin_open: true"
        echo "    tty: true"

        if [ ${#PARSED_PORTS[@]} -gt 0 ]; then
            echo "    ports:"
            for x in ${PARSED_PORTS[@]+"${PARSED_PORTS[@]}"}; do
                echo "      - $(yaml_dq "$x")"
            done
        fi

        if [ ${#PARSED_CMD[@]} -gt 0 ]; then
            local rendered=""
            for x in ${PARSED_CMD[@]+"${PARSED_CMD[@]}"}; do
                if [ -z "$rendered" ]; then
                    rendered="$(yaml_dq "$x")"
                else
                    rendered="${rendered}, $(yaml_dq "$x")"
                fi
            done
            echo "    command: [${rendered}]"
        fi

        echo ""
        echo "volumes:"
        echo "  ${CONFIG_VOLUME}:"
    } > "$compose_file"

    echo "$compose_file"
}

cmd_run() {
    parse_args "$@"
    local project
    project="$(require_project)"

    local name
    name="$(container_name "$project")"
    build_container_spec "$project" ${PARSED_ENV[@]+"${PARSED_ENV[@]}"}

    local compose_file
    compose_file="$(generate_compose "$project" "$name")"

    echo "Starting container '${name}' for project '${project}'"
    docker compose -f "$compose_file" up -d

    local port
    for port in ${PARSED_PORTS[@]+"${PARSED_PORTS[@]}"}; do
        echo "  http://localhost:${port%%:*}"
    done
}

# Start a fresh container running one agent, attached to the terminal.
# Usage: run_agent <agent> <parse_args arguments...>
run_agent() {
    local agent="$1"
    shift
    parse_args "$@"
    local project
    project="$(require_project)"

    local name
    name="$(container_name "$project")"

    echo "Starting $(agent_label "$agent") in container '${name}' for project '${project}'"
    docker rm -f "$name" >/dev/null 2>&1 || true

    build_container_spec "$project" ${PARSED_ENV[@]+"${PARSED_ENV[@]}"}
    render_docker_args
    render_base_docker_args "$project"

    local docker_args=(-it --name "$name")
    docker_args+=(${BASE_DOCKER_ARGS[@]+"${BASE_DOCKER_ARGS[@]}"})
    docker_args+=(${DOCKER_SPEC_ARGS[@]+"${DOCKER_SPEC_ARGS[@]}"})

    local port
    for port in ${PARSED_PORTS[@]+"${PARSED_PORTS[@]}"}; do
        docker_args+=(-p "$port")
    done

    docker_args+=("${IMAGE_NAME}:latest" "$(agent_binary "$agent")")
    docker_args+=(${PARSED_CMD[@]+"${PARSED_CMD[@]}"})

    docker run "${docker_args[@]}"
}

cmd_exec() {
    [ $# -ge 2 ] || die "usage: vm.sh exec <project> <command>"
    local project name
    project="$(resolve_project "$1")"
    shift
    name="$(container_name "$project")"
    if [ -t 0 ]; then
        docker exec -it "$name" "$@"
    else
        docker exec "$name" "$@"
    fi
}

cmd_stop() {
    [ $# -ge 1 ] || die "usage: vm.sh stop <project>"
    local name
    name="$(container_name "$(resolve_project "$1")")"
    echo "Stopping container '${name}'"
    docker stop "$name" 2>/dev/null || true
}

cmd_logs() {
    [ $# -ge 1 ] || die "usage: vm.sh logs <project>"
    local name
    name="$(container_name "$(resolve_project "$1")")"
    docker logs -f "$name"
}

cmd_rm() {
    [ $# -ge 1 ] || die "usage: vm.sh rm <project>"
    local project name
    project="$(resolve_project "$1")"
    name="$(container_name "$project")"
    echo "Removing container '${name}'"
    docker rm -f "$name" 2>/dev/null || true
    rm -rf "$project/.vm"
}

cmd_config() {
    echo "Starting config management shell..."
    echo "Config volume mounted at /home/agent/.agent-config"
    docker run --rm -it \
        -v "${CONFIG_VOLUME}:/home/agent/.agent-config" \
        "${IMAGE_NAME}:latest" \
        bash
}

main() {
    [ $# -ge 1 ] || usage

    local command="$1"
    shift

    case "$command" in
        run)      cmd_run "$@" ;;
        exec)     cmd_exec "$@" ;;
        stop)     cmd_stop "$@" ;;
        logs)     cmd_logs "$@" ;;
        rm)       cmd_rm "$@" ;;
        config)   cmd_config ;;
        *)
            if [ -n "$(agent_binary "$command")" ]; then
                run_agent "$command" "$@"
            else
                echo "Unknown command: $command" >&2
                usage
            fi
            ;;
    esac
}

# Only dispatch when executed; sourcing exposes the functions for tests.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
