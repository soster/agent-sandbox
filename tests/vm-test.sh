#!/bin/bash
# Unit tests for vm.sh helpers. No Docker required.
#
# vm.sh only dispatches when executed directly, so it can be sourced here to
# test its functions in isolation.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../vm.sh
source "$SCRIPT_DIR/../vm.sh"
# vm.sh enables errexit; tests deliberately exercise failure paths.
set +e

TESTS_RUN=0
TESTS_FAILED=0
TMPROOT=""

cleanup() { [ -n "$TMPROOT" ] && rm -rf "$TMPROOT"; }
trap cleanup EXIT

TMPROOT="$(mktemp -d)"

fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL: $1"
    echo "    expected: $2"
    echo "    actual:   $3"
}

assert_eq() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$2" = "$3" ]; then
        echo "  ok: $1"
    else
        fail "$1" "$2" "$3"
    fi
}

assert_contains() {
    TESTS_RUN=$((TESTS_RUN + 1))
    case "$3" in
        *"$2"*) echo "  ok: $1" ;;
        *)      fail "$1" "contains: $2" "$3" ;;
    esac
}

assert_not_contains() {
    TESTS_RUN=$((TESTS_RUN + 1))
    case "$3" in
        *"$2"*) fail "$1" "must NOT contain: $2" "$3" ;;
        *)      echo "  ok: $1" ;;
    esac
}

# Join array elements with '|' so boundaries are visible in assertions.
join_bar() {
    local out="" x
    for x in "$@"; do
        if [ -z "$out" ]; then out="$x"; else out="$out|$x"; fi
    done
    printf '%s' "$out"
}

# --- container_name -----------------------------------------------------

echo "container_name:"
assert_eq "strips leading slash and joins path segments" \
    "Users_oster_git_my_project" "$(container_name /Users/oster/git/my-project)"
assert_eq "collapses runs of separators" \
    "a_b" "$(container_name '/a//b/')"
assert_eq "replaces characters docker rejects" \
    "proj_v1_2" "$(container_name 'proj v1.2')"

# --- load_env_file ------------------------------------------------------

echo "load_env_file:"
ENVPROJ="$TMPROOT/envproj"
mkdir -p "$ENVPROJ"
cat > "$ENVPROJ/.env" <<'EOF'
# a comment
   # an indented comment

PLAIN=value
QUOTED="double quoted"
SQUOTED='single quoted'
WITH_EQUALS=a=b=c
EMPTY=
  INDENTED=yes
not a valid line
EOF
env_out="$(load_env_file "$ENVPROJ")"
assert_contains "reads plain values"        "PLAIN=value"              "$env_out"
assert_contains "strips double quotes"      "QUOTED=double quoted"     "$env_out"
assert_contains "strips single quotes"      "SQUOTED=single quoted"    "$env_out"
assert_contains "keeps = inside the value"  "WITH_EQUALS=a=b=c"        "$env_out"
assert_contains "keeps empty values"        "EMPTY="                   "$env_out"
assert_contains "accepts indented keys"     "INDENTED=yes"             "$env_out"
assert_not_contains "skips comments"        "a comment"                "$env_out"
assert_not_contains "skips malformed lines" "not a valid line"         "$env_out"
assert_eq "missing .env yields nothing" "" "$(load_env_file "$TMPROOT/does-not-exist")"

# --- env_get / env_without ---------------------------------------------

echo "env_get / env_without:"
LINES="A=1
HOST_EXTRA_HOSTS=mini:10.0.0.1
B=2"
assert_eq "env_get returns the value"     "mini:10.0.0.1" "$(env_get HOST_EXTRA_HOSTS "$LINES")"
assert_eq "env_get tolerates missing key" ""              "$(env_get NOPE "$LINES")"
assert_not_contains "env_without drops the key" "HOST_EXTRA_HOSTS" "$(env_without HOST_EXTRA_HOSTS "$LINES")"
assert_contains "env_without keeps the rest"    "B=2"              "$(env_without HOST_EXTRA_HOSTS "$LINES")"

# --- host_dns -----------------------------------------------------------

echo "host_dns:"
cat > "$TMPROOT/resolv.conf" <<'EOF'
search example.com
nameserver 127.0.0.53
nameserver 192.168.1.1
nameserver fe80::1
nameserver 8.8.8.8
EOF
dns_out="$(host_dns "$TMPROOT/resolv.conf")"
assert_eq "keeps routable IPv4 servers, drops loopback and IPv6" \
    "192.168.1.1
8.8.8.8" "$dns_out"
assert_eq "missing resolv.conf yields nothing" "" "$(host_dns "$TMPROOT/nope.conf")"

# --- build_container_spec ----------------------------------------------

echo "build_container_spec:"
SPECPROJ="$TMPROOT/specproj"
mkdir -p "$SPECPROJ"
cat > "$SPECPROJ/.env" <<'EOF'
HOST_EXTRA_HOSTS=mini:192.168.178.138,llama:192.168.178.9
ANTHROPIC_API_KEY=from-file
FILE_ONLY=yes
EOF
RESOLV_CONF="$TMPROOT/resolv.conf"
build_container_spec "$SPECPROJ" "ANTHROPIC_API_KEY=from-cli" "HOST_EXTRA_HOSTS=cli:10.0.0.9"

assert_eq "collects host DNS servers" "192.168.1.1|8.8.8.8" "$(join_bar ${SPEC_DNS[@]+"${SPEC_DNS[@]}"})"
assert_eq "CLI hosts precede .env hosts (first /etc/hosts match wins)" \
    "cli:10.0.0.9|mini:192.168.178.138|llama:192.168.178.9" \
    "$(join_bar ${SPEC_HOSTS[@]+"${SPEC_HOSTS[@]}"})"
spec_env="$(join_bar ${SPEC_ENV[@]+"${SPEC_ENV[@]}"})"
assert_contains "keeps .env-only variables" "FILE_ONLY=yes" "$spec_env"
assert_eq "CLI -e overrides .env (CLI emitted last)" \
    "ANTHROPIC_API_KEY=from-file|FILE_ONLY=yes|ANTHROPIC_API_KEY=from-cli" "$spec_env"
assert_not_contains "HOST_EXTRA_HOSTS never becomes a container env var" \
    "HOST_EXTRA_HOSTS" "$spec_env"

build_container_spec "$TMPROOT/no-such-project"
assert_eq "no .env and no CLI vars yields an empty env spec" "" \
    "$(join_bar ${SPEC_ENV[@]+"${SPEC_ENV[@]}"})"
assert_eq "no .env yields no extra hosts" "" \
    "$(join_bar ${SPEC_HOSTS[@]+"${SPEC_HOSTS[@]}"})"

# --- render_docker_args -------------------------------------------------

echo "render_docker_args:"
build_container_spec "$SPECPROJ" "X=1"
render_docker_args
rendered="$(join_bar ${DOCKER_SPEC_ARGS[@]+"${DOCKER_SPEC_ARGS[@]}"})"
assert_contains "emits --dns per server"   "--dns|192.168.1.1"                "$rendered"
assert_contains "emits --add-host per host" "--add-host|mini:192.168.178.138" "$rendered"
assert_contains "emits -e per variable"     "-e|X=1"                          "$rendered"

# --- parse_args ---------------------------------------------------------

echo "parse_args:"
parse_args ~/proj -p 3000:3000 -p 8080:80 -e A=1 -e B=2
assert_eq "captures the project"     "$HOME/proj"        "$PARSED_PROJECT"
assert_eq "captures repeated -p"     "3000:3000|8080:80" "$(join_bar ${PARSED_PORTS[@]+"${PARSED_PORTS[@]}"})"
assert_eq "captures repeated -e"     "A=1|B=2"           "$(join_bar ${PARSED_ENV[@]+"${PARSED_ENV[@]}"})"
assert_eq "no passthrough by default" ""                 "$(join_bar ${PARSED_CMD[@]+"${PARSED_CMD[@]}"})"

parse_args proj -- npm test --grep "two words"
assert_eq "passthrough preserves argument boundaries" \
    "npm|test|--grep|two words" "$(join_bar ${PARSED_CMD[@]+"${PARSED_CMD[@]}"})"

parse_args proj -- --provider anthropic -p 1:1
assert_eq "flags after -- are passthrough, not vm.sh options" \
    "--provider|anthropic|-p|1:1" "$(join_bar ${PARSED_CMD[@]+"${PARSED_CMD[@]}"})"
assert_eq "options after -- do not reach vm.sh" "" "$(join_bar ${PARSED_PORTS[@]+"${PARSED_PORTS[@]}"})"

rc=0; (parse_args proj -p 2>/dev/null) || rc=$?
assert_eq "-p without a value fails" "1" "$rc"
rc=0; (parse_args proj extra 2>/dev/null) || rc=$?
assert_eq "a second positional argument fails" "1" "$rc"

# --- generate_compose ---------------------------------------------------

echo "generate_compose:"
build_container_spec "$SPECPROJ" "CLI=1"
parse_args "$SPECPROJ" -p 3000:3000 -- npm run "dev server"
compose_file="$(generate_compose "$SPECPROJ" "test_container")"
compose="$(cat "$compose_file")"

assert_eq "writes into the project's .vm directory" "$SPECPROJ/.vm/docker-compose.yml" "$compose_file"
assert_contains "names the container"    "container_name: test_container"        "$compose"
assert_contains "mounts the project"     "- $SPECPROJ:/workspace"                "$compose"
assert_contains "mounts the config volume" "- agent-sandbox-config:/home/agent/.agent-config" "$compose"
assert_contains "renders dns entries"    "- 192.168.1.1"                         "$compose"
assert_contains "renders extra_hosts"    "- \"mini:192.168.178.138\""            "$compose"
assert_contains "quotes environment entries" "- \"FILE_ONLY=yes\""               "$compose"
assert_contains "renders ports"          "- \"3000:3000\""                       "$compose"
assert_contains "renders command as a list so arguments keep their boundaries" \
    'command: ["npm", "run", "dev server"]' "$compose"
assert_not_contains "HOST_EXTRA_HOSTS stays out of environment" \
    "\"HOST_EXTRA_HOSTS=" "$compose"

# YAML sanity: dns/extra_hosts/ports must not be nested under environment.
assert_eq "keeps service keys as siblings" "4" \
    "$(grep -c '^    \(environment\|dns\|extra_hosts\|ports\):$' "$compose_file")"

RESOLV_CONF="$TMPROOT/nope.conf"
build_container_spec "$TMPROOT/no-such-project"
RESOLV_CONF="$TMPROOT/resolv.conf"
parse_args "$SPECPROJ"
compose="$(cat "$(generate_compose "$SPECPROJ" "bare")")"
assert_not_contains "omits dns when there is none"         "dns:"         "$compose"
assert_not_contains "omits extra_hosts when there is none" "extra_hosts:" "$compose"
assert_not_contains "omits ports when there are none"      "ports:"       "$compose"
assert_not_contains "omits command when there is none"     "command:"     "$compose"

# --- yaml_dq ------------------------------------------------------------

echo "yaml_dq:"
assert_eq "escapes embedded double quotes" '"say \"hi\""' "$(yaml_dq 'say "hi"')"
assert_eq "escapes backslashes"            '"a\\\\b"'     "$(yaml_dq 'a\\b')"

# --- summary ------------------------------------------------------------

echo
if [ "$TESTS_FAILED" -eq 0 ]; then
    echo "PASS: $TESTS_RUN assertions"
    exit 0
fi
echo "FAIL: $TESTS_FAILED of $TESTS_RUN assertions failed"
exit 1
