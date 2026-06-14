#!/bin/bash
set -euo pipefail

IMAGE_NAME="agent-vm"

usage() {
    cat <<EOF
Usage:
  vm.sh <command> [options]

Commands:
  run <project> [-p host:container]... [-e KEY=VALUE]... [-- <cmd>]
      Start container with project mounted at /workspace
  claude <project> [-p host:container]... [-e KEY=VALUE]...
      Start container and run Claude Code
  opencode <project> [-p host:container]... [-e KEY=VALUE]...
      Start container and run OpenCode
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
  -- <cmd>            Override default command (run only)
EOF
    exit 1
}

container_name() {
    echo "$1" | sed 's|/|_|g; s|[^a-zA-Z0-9_]|_|g; s|__*|_|g; s|^_||; s|_||'
}

resolve_project() {
    if [[ "$1" = /* ]]; then
        echo "$1"
    else
        echo "$(pwd)/$1"
    fi
}

parse_args() {
    PARSED_PROJECT=""
    PARSED_PORTS=""
    PARSED_ENV=""
    local args=("$@")
    local i=0

    while [ $i -lt ${#args[@]} ]; do
        case "${args[$i]}" in
            -p)
                i=$((i + 1))
                if [ -n "$PARSED_PORTS" ]; then
                    PARSED_PORTS="${PARSED_PORTS}
${args[$i]}"
                else
                    PARSED_PORTS="${args[$i]}"
                fi
                ;;
            -e)
                i=$((i + 1))
                if [ -n "$PARSED_ENV" ]; then
                    PARSED_ENV="${PARSED_ENV}
${args[$i]}"
                else
                    PARSED_ENV="${args[$i]}"
                fi
                ;;
            *)
                if [ -z "$PARSED_PROJECT" ]; then
                    PARSED_PROJECT="${args[$i]}"
                fi
                ;;
        esac
        i=$((i + 1))
    done
}

parse_run_args() {
    PARSED_PROJECT=""
    PARSED_PORTS=""
    PARSED_ENV=""
    PARSED_CMD=""
    local args=("$@")
    local i=0
    local saw_double_dash=false

    while [ $i -lt ${#args[@]} ]; do
        if [ "$saw_double_dash" = true ]; then
            if [ -z "$PARSED_CMD" ]; then
                PARSED_CMD="${args[$i]}"
            else
                PARSED_CMD="$PARSED_CMD ${args[$i]}"
            fi
        elif [ "${args[$i]}" = "-p" ]; then
            i=$((i + 1))
            if [ -n "$PARSED_PORTS" ]; then
                PARSED_PORTS="${PARSED_PORTS}
${args[$i]}"
            else
                PARSED_PORTS="${args[$i]}"
            fi
        elif [ "${args[$i]}" = "-e" ]; then
            i=$((i + 1))
            if [ -n "$PARSED_ENV" ]; then
                PARSED_ENV="${PARSED_ENV}
${args[$i]}"
            else
                PARSED_ENV="${args[$i]}"
            fi
        elif [ "${args[$i]}" = "--" ]; then
            saw_double_dash=true
        elif [ -z "$PARSED_PROJECT" ]; then
            PARSED_PROJECT="${args[$i]}"
        fi
        i=$((i + 1))
    done
}

generate_compose() {
    local project="$1"
    local name="$2"
    local ports="$3"
    local env_vars="$4"
    local command="$5"
    local vm_dir="$project/.vm"

    mkdir -p "$vm_dir"
    local compose_file="$vm_dir/docker-compose.yml"

    {
        echo "services:"
        echo "  agent-vm:"
        echo "    image: ${IMAGE_NAME}:latest"
        echo "    container_name: ${name}"
        echo "    working_dir: /workspace"
        echo "    volumes:"
        echo "      - ${project}:/workspace"
        echo "      - agent-vm-config:/home/agent/.agent-config"
        echo "    environment:"
        echo "      - HOME=/home/agent"

        if [ -n "$env_vars" ]; then
            echo "$env_vars" | while IFS= read -r env_var; do
                [ -n "$env_var" ] && echo "      - ${env_var}"
            done
        fi

        echo "    stdin_open: true"
        echo "    tty: true"

        if [ -n "$ports" ]; then
            echo "    ports:"
            echo "$ports" | while IFS= read -r port; do
                [ -n "$port" ] && echo "      - \"${port}\""
            done
        fi

        if [ -n "$command" ]; then
            echo "    command: ${command}"
        fi

        echo ""
        echo "volumes:"
        echo "  agent-vm-config:"
    } > "$compose_file"

    echo "$compose_file"
}

cmd_run() {
    parse_run_args "$@"

    if [ -z "$PARSED_PROJECT" ]; then
        echo "Error: project path required"
        exit 1
    fi

    local project
    project=$(resolve_project "$PARSED_PROJECT")

    if [ ! -d "$project" ]; then
        echo "Error: project directory does not exist: $project"
        exit 1
    fi

    local name
    name=$(container_name "$project")
    local compose_file
    compose_file=$(generate_compose "$project" "$name" "$PARSED_PORTS" "$PARSED_ENV" "$PARSED_CMD")

    echo "Starting container '${name}' for project '${project}'"
    docker compose -f "$compose_file" up -d

    if [ -n "$PARSED_PORTS" ]; then
        echo "Exposed ports:"
        echo "$PARSED_PORTS" | while IFS= read -r port; do
            local host_port="${port%%:*}"
            [ -n "$host_port" ] && echo "  http://localhost:${host_port}"
        done
    fi
}

cmd_claude() {
    parse_args "$@"

    if [ -z "$PARSED_PROJECT" ]; then
        echo "Error: project path required"
        exit 1
    fi

    local project
    project=$(resolve_project "$PARSED_PROJECT")

    if [ ! -d "$project" ]; then
        echo "Error: project directory does not exist: $project"
        exit 1
    fi

    local name
    name=$(container_name "$project")
    local compose_file
    compose_file=$(generate_compose "$project" "$name" "$PARSED_PORTS" "$PARSED_ENV" "claude")

    echo "Starting Claude Code in container '${name}' for project '${project}'"
    docker compose -f "$compose_file" up --attach stdin
}

cmd_opencode() {
    parse_args "$@"

    if [ -z "$PARSED_PROJECT" ]; then
        echo "Error: project path required"
        exit 1
    fi

    local project
    project=$(resolve_project "$PARSED_PROJECT")

    if [ ! -d "$project" ]; then
        echo "Error: project directory does not exist: $project"
        exit 1
    fi

    local name
    name=$(container_name "$project")
    local compose_file
    compose_file=$(generate_compose "$project" "$name" "$PARSED_PORTS" "$PARSED_ENV" "opencode")

    echo "Starting OpenCode in container '${name}' for project '${project}'"
    docker compose -f "$compose_file" up --attach stdin
}

cmd_exec() {
    if [ $# -lt 2 ]; then
        echo "Usage: vm.sh exec <project> <command>"
        exit 1
    fi
    local project
    project=$(resolve_project "$1")
    shift
    local name
    name=$(container_name "$project")
    docker exec -it "$name" "$@"
}

cmd_stop() {
    if [ $# -lt 1 ]; then
        echo "Usage: vm.sh stop <project>"
        exit 1
    fi
    local project
    project=$(resolve_project "$1")
    local name
    name=$(container_name "$project")
    echo "Stopping container '${name}'"
    docker stop "$name" 2>/dev/null || true
}

cmd_logs() {
    if [ $# -lt 1 ]; then
        echo "Usage: vm.sh logs <project>"
        exit 1
    fi
    local project
    project=$(resolve_project "$1")
    local name
    name=$(container_name "$project")
    docker logs -f "$name"
}

cmd_rm() {
    if [ $# -lt 1 ]; then
        echo "Usage: vm.sh rm <project>"
        exit 1
    fi
    local project
    project=$(resolve_project "$1")
    local name
    name=$(container_name "$project")
    echo "Removing container '${name}'"
    docker rm -f "$name" 2>/dev/null || true
    rm -rf "$project/.vm"
}

cmd_config() {
    echo "Starting config management shell..."
    echo "Config volume mounted at /home/agent/.agent-config"
    docker run --rm -it \
        -v agent-vm-config:/home/agent/.agent-config \
        "${IMAGE_NAME}:latest" \
        bash
}

if [ $# -lt 1 ]; then
    usage
fi

COMMAND="$1"
shift

case "$COMMAND" in
    run)      cmd_run "$@" ;;
    claude)   cmd_claude "$@" ;;
    opencode) cmd_opencode "$@" ;;
    exec)     cmd_exec "$@" ;;
    stop)     cmd_stop "$@" ;;
    logs)     cmd_logs "$@" ;;
    rm)       cmd_rm "$@" ;;
    config)   cmd_config ;;
    *)        echo "Unknown command: $COMMAND"; usage ;;
esac
