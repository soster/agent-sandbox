#!/bin/bash
set -euo pipefail

IMAGE_NAME="agent-sandbox"

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
    echo "$1" | sed 's|/|_|g; s|[^a-zA-Z0-9_]|_|g; s|__*|_|g; s|^_||; s|_$||'
}

host_dns() {
    # Extract IPv4 nameservers from /etc/resolv.conf for host DNS forwarding
    grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | grep -E '^[0-9]+\.' | tr '\n' ',' | sed 's/,$//'
}

extra_hosts_from_env() {
    # Extract HOST_EXTRA_HOSTS from parsed env vars (format: "host:ip,host2:ip2")
    local env_vars="$1"
    local value
    value=$(echo "$env_vars" | grep '^HOST_EXTRA_HOSTS=' | head -1 | cut -d= -f2-)
    echo "$value"
}

extra_hosts_from_file() {
    # Extract HOST_EXTRA_HOSTS from project/.env file
    local project="$1"
    local env_file="$project/.env"
    if [ -f "$env_file" ]; then
        grep '^HOST_EXTRA_HOSTS=' "$env_file" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'"
    fi
}

filter_env_var() {
    # Filter out a specific key from env vars
    local key="$1"
    local env_vars="$2"
    echo "$env_vars" | grep -v "^${key}=" || true
}

load_env_file() {
    # Load KEY=VALUE pairs from project/.env into docker args
    local project="$1"
    local env_file="$project/.env"
    if [ -f "$env_file" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            # Skip comments and empty lines
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line// }" ]] && continue
            # Extract key=value
            if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*) ]]; then
                echo "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"
            fi
        done < "$env_file"
    fi
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
        echo "  agent-sandbox:"
        echo "    image: ${IMAGE_NAME}:latest"
        echo "    container_name: ${name}"
        echo "    working_dir: /workspace"
        echo "    volumes:"
        echo "      - ${project}:/workspace"
        echo "      - agent-sandbox-config:/home/agent/.agent-config"
        echo "      - ${HOME}/.config/opencode:/home/agent/.config/opencode"
        echo "    environment:"
        echo "      - HOME=/home/agent"

        local dns_servers
        dns_servers=$(host_dns)
        if [ -n "$dns_servers" ]; then
            echo "    dns:"
            IFS=',' read -ra DNS_ARR <<< "$dns_servers"
            for dns in "${DNS_ARR[@]}"; do
                echo "      - ${dns}"
            done
        fi

        local extra_hosts
        extra_hosts=$(extra_hosts_from_env "$env_vars")
        if [ -n "$extra_hosts" ]; then
            echo "    extra_hosts:"
            IFS=',' read -ra EH_ARR <<< "$extra_hosts"
            for eh in "${EH_ARR[@]}"; do
                echo "      - ${eh}"
            done
        fi

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
        echo "  agent-sandbox-config:"
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

    echo "Starting Claude Code in container '${name}' for project '${project}'"
    docker rm -f "$name" 2>/dev/null || true
    local docker_args=(-it --name "$name" -w /workspace)
    docker_args+=(-v "${project}:/workspace")
    docker_args+=(-v "agent-sandbox-config:/home/agent/.agent-config")
    docker_args+=(-v "${HOME}/.config/opencode:/home/agent/.config/opencode")
    docker_args+=(-e "HOME=/home/agent")

    local dns_servers
    dns_servers=$(host_dns)
    if [ -n "$dns_servers" ]; then
        IFS=',' read -ra DNS_ARR <<< "$dns_servers"
        for dns in "${DNS_ARR[@]}"; do
            docker_args+=("--dns" "$dns")
        done
    fi

    local extra_hosts
    extra_hosts=$(extra_hosts_from_env "$PARSED_ENV")
    if [ -n "$extra_hosts" ]; then
        IFS=',' read -ra EH_ARR <<< "$extra_hosts"
        for eh in "${EH_ARR[@]}"; do
            docker_args+=("--add-host" "$eh")
        done
    fi

    # Load .env file from project directory
    local env_file_vars
    env_file_vars=$(load_env_file "$project")

    # Also check .env for HOST_EXTRA_HOSTS
    local file_extra_hosts
    file_extra_hosts=$(echo "$env_file_vars" | grep '^HOST_EXTRA_HOSTS=' | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
    if [ -n "$file_extra_hosts" ]; then
        IFS=',' read -ra EH_ARR <<< "$file_extra_hosts"
        for eh in "${EH_ARR[@]}"; do
            docker_args+=("--add-host" "$eh")
        done
    fi

    # Filter HOST_EXTRA_HOSTS from env vars
    env_file_vars=$(echo "$env_file_vars" | grep -v '^HOST_EXTRA_HOSTS=' || true)

    if [ -n "$env_file_vars" ]; then
        while IFS= read -r env_var; do
            [ -n "$env_var" ] && docker_args+=(-e "$env_var")
        done <<< "$env_file_vars"
    fi

    if [ -n "$PARSED_ENV" ]; then
        while IFS= read -r env_var; do
            [ -n "$env_var" ] && docker_args+=(-e "$env_var")
        done <<< "$PARSED_ENV"
    fi

    docker_args+=("${IMAGE_NAME}:latest" claude)
    docker run "${docker_args[@]}"
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

    echo "Starting OpenCode in container '${name}' for project '${project}'"
    docker rm -f "$name" 2>/dev/null || true
    local docker_args=(-it --name "$name" -w /workspace)
    docker_args+=(-v "${project}:/workspace")
    docker_args+=(-v "agent-sandbox-config:/home/agent/.agent-config")
    docker_args+=(-v "${HOME}/.config/opencode:/home/agent/.config/opencode")
    docker_args+=(-e "HOME=/home/agent")

    local dns_servers
    dns_servers=$(host_dns)
    if [ -n "$dns_servers" ]; then
        IFS=',' read -ra DNS_ARR <<< "$dns_servers"
        for dns in "${DNS_ARR[@]}"; do
            docker_args+=("--dns" "$dns")
        done
    fi

    local extra_hosts
    extra_hosts=$(extra_hosts_from_env "$PARSED_ENV")
    if [ -n "$extra_hosts" ]; then
        IFS=',' read -ra EH_ARR <<< "$extra_hosts"
        for eh in "${EH_ARR[@]}"; do
            docker_args+=("--add-host" "$eh")
        done
    fi

    # Load .env file from project directory
    local env_file_vars
    env_file_vars=$(load_env_file "$project")

    # Also check .env for HOST_EXTRA_HOSTS
    local file_extra_hosts
    file_extra_hosts=$(echo "$env_file_vars" | grep '^HOST_EXTRA_HOSTS=' | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
    if [ -n "$file_extra_hosts" ]; then
        IFS=',' read -ra EH_ARR <<< "$file_extra_hosts"
        for eh in "${EH_ARR[@]}"; do
            docker_args+=("--add-host" "$eh")
        done
    fi

    # Filter HOST_EXTRA_HOSTS from env vars
    env_file_vars=$(echo "$env_file_vars" | grep -v '^HOST_EXTRA_HOSTS=' || true)

    if [ -n "$env_file_vars" ]; then
        while IFS= read -r env_var; do
            [ -n "$env_var" ] && docker_args+=(-e "$env_var")
        done <<< "$env_file_vars"
    fi

    if [ -n "$PARSED_ENV" ]; then
        while IFS= read -r env_var; do
            [ -n "$env_var" ] && docker_args+=(-e "$env_var")
        done <<< "$PARSED_ENV"
    fi

    docker_args+=("${IMAGE_NAME}:latest" opencode)
    docker run "${docker_args[@]}"
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
    if [ -t 0 ]; then
        docker exec -it "$name" "$@"
    else
        docker exec "$name" "$@"
    fi
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
        -v agent-sandbox-config:/home/agent/.agent-config \
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
