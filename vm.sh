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
    # Extract IPv4 nameservers from /etc/resolv.conf for host DNS forwarding.
    # Loopback addresses (127.x) are dropped: they point at a resolver on the
    # host, which inside the container resolves to the container itself.
    grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' \
        | grep -E '^[0-9]+\.' | grep -vE '^127\.' | tr '\n' ',' | sed 's/,$//'
}

extra_hosts_from_env() {
    # Extract HOST_EXTRA_HOSTS from parsed env vars (format: "host:ip,host2:ip2").
    # A missing key makes grep exit non-zero; tolerate it so set -e/pipefail
    # don't abort the caller.
    local env_vars="$1"
    echo "$env_vars" | grep '^HOST_EXTRA_HOSTS=' | head -1 | cut -d= -f2- || true
}

extra_hosts_from_file() {
    # Extract HOST_EXTRA_HOSTS from project/.env file (tolerate a missing key)
    local project="$1"
    local env_file="$project/.env"
    if [ -f "$env_file" ]; then
        grep '^HOST_EXTRA_HOSTS=' "$env_file" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" || true
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
                local key="${BASH_REMATCH[1]}"
                local value="${BASH_REMATCH[2]}"
                # Strip a single pair of surrounding quotes, if present
                if [[ "$value" =~ ^\"(.*)\"$ ]]; then
                    value="${BASH_REMATCH[1]}"
                elif [[ "$value" =~ ^\'(.*)\'$ ]]; then
                    value="${BASH_REMATCH[1]}"
                fi
                echo "${key}=${value}"
            fi
        done < "$env_file"
    fi
}

# Populate the global EXTRA_DOCKER_ARGS array with --dns, --add-host, and -e
# flags derived from host DNS, CLI -e vars, and the project's .env file.
# CLI -e values are emitted after .env values so they take precedence.
# Args: <project> <cli_env_vars>
build_network_env_args() {
    local project="$1"
    local cli_env="$2"
    EXTRA_DOCKER_ARGS=()

    local dns_servers dns
    dns_servers=$(host_dns)
    if [ -n "$dns_servers" ]; then
        IFS=',' read -ra DNS_ARR <<< "$dns_servers"
        for dns in "${DNS_ARR[@]}"; do
            EXTRA_DOCKER_ARGS+=("--dns" "$dns")
        done
    fi

    # extra hosts: CLI -e first, then .env (first /etc/hosts match wins, so CLI overrides)
    local cli_hosts file_hosts eh eh_list
    cli_hosts=$(extra_hosts_from_env "$cli_env")
    file_hosts=$(extra_hosts_from_file "$project")
    for eh_list in "$cli_hosts" "$file_hosts"; do
        if [ -n "$eh_list" ]; then
            IFS=',' read -ra EH_ARR <<< "$eh_list"
            for eh in "${EH_ARR[@]}"; do
                EXTRA_DOCKER_ARGS+=("--add-host" "$eh")
            done
        fi
    done

    # env vars: .env file first (minus HOST_EXTRA_HOSTS), CLI -e last so CLI overrides
    local env_file_vars env_var
    env_file_vars=$(filter_env_var "HOST_EXTRA_HOSTS" "$(load_env_file "$project")")
    if [ -n "$env_file_vars" ]; then
        while IFS= read -r env_var; do
            [ -n "$env_var" ] && EXTRA_DOCKER_ARGS+=(-e "$env_var")
        done <<< "$env_file_vars"
    fi
    if [ -n "$cli_env" ]; then
        while IFS= read -r env_var; do
            [ -n "$env_var" ] && EXTRA_DOCKER_ARGS+=(-e "$env_var")
        done <<< "$cli_env"
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

        # env vars: project/.env first (minus HOST_EXTRA_HOSTS), CLI -e last so CLI overrides.
        # These must be emitted before the sibling dns:/extra_hosts: keys below.
        local env_file_vars
        env_file_vars=$(filter_env_var "HOST_EXTRA_HOSTS" "$(load_env_file "$project")")
        if [ -n "$env_file_vars" ]; then
            while IFS= read -r env_var; do
                [ -n "$env_var" ] && echo "      - ${env_var}"
            done <<< "$env_file_vars"
        fi
        if [ -n "$env_vars" ]; then
            echo "$env_vars" | while IFS= read -r env_var; do
                [ -n "$env_var" ] && echo "      - ${env_var}"
            done
        fi

        local dns_servers
        dns_servers=$(host_dns)
        if [ -n "$dns_servers" ]; then
            echo "    dns:"
            IFS=',' read -ra DNS_ARR <<< "$dns_servers"
            for dns in "${DNS_ARR[@]}"; do
                echo "      - ${dns}"
            done
        fi

        # extra hosts: CLI -e first, then project/.env (first match wins, so CLI overrides)
        local cli_hosts file_hosts eh_list
        cli_hosts=$(extra_hosts_from_env "$env_vars")
        file_hosts=$(extra_hosts_from_file "$project")
        if [ -n "$cli_hosts" ] || [ -n "$file_hosts" ]; then
            echo "    extra_hosts:"
            for eh_list in "$cli_hosts" "$file_hosts"; do
                if [ -n "$eh_list" ]; then
                    IFS=',' read -ra EH_ARR <<< "$eh_list"
                    for eh in "${EH_ARR[@]}"; do
                        echo "      - ${eh}"
                    done
                fi
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

    build_network_env_args "$project" "$PARSED_ENV"
    if [ ${#EXTRA_DOCKER_ARGS[@]} -gt 0 ]; then
        docker_args+=("${EXTRA_DOCKER_ARGS[@]}")
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

    build_network_env_args "$project" "$PARSED_ENV"
    if [ ${#EXTRA_DOCKER_ARGS[@]} -gt 0 ]; then
        docker_args+=("${EXTRA_DOCKER_ARGS[@]}")
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
