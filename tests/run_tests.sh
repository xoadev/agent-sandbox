#!/usr/bin/env bash
# agent-sandbox test runner (pure bash, no external framework)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SUBJECT="$REPO_DIR/agent-sandbox.sh"

PASS=0
FAIL=0
FAILURES=()

# ---------- Assertion helpers ----------

assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if [[ $haystack == *"$needle"* ]]; then
        pass "$label"
    else
        fail "$label" "expected to contain: <$needle>"
    fi
}

assert_not_contains() {
    local label="$1" haystack="$2" needle="$3"
    if [[ $haystack != *"$needle"* ]]; then
        pass "$label"
    else
        fail "$label" "expected NOT to contain: <$needle>"
    fi
}

assert_file_exists() {
    local label="$1" path="$2"
    if [ -f "$path" ]; then
        pass "$label"
    else
        fail "$label" "file not found: $path"
    fi
}

pass() {
    PASS=$((PASS + 1))
    echo "  ✔ $1"
}

fail() {
    FAIL=$((FAIL + 1))
    FAILURES+=("$1 :: $2")
    echo "  ✗ $1"
    echo "      $2"
}

# ---------- Helpers ----------

# Create a temp directory with a fake `docker` that records invocations and
# provides a no-op `docker build`. The mock logs to a file whose path is in
# $MOCK_DOCKER_LOG. Put the temp bin dir first in PATH so it shadows the real
# docker CLI.
make_docker_stub() {
    local bin_dir="$1"
    mkdir -p "$bin_dir"
    cat >"$bin_dir/docker" <<'STUB'
#!/usr/bin/env bash
# stub docker: log args, succeed
echo "docker $*" >> "${MOCK_DOCKER_LOG:-/dev/null}"
case "$1" in
    build) exit 0 ;;
    compose) exit 0 ;;
    exec) exit 0 ;;
    *) exit 0 ;;
esac
STUB
    chmod +x "$bin_dir/docker"
}

# Run the CLI exactly as a user would, capturing combined stdout/stderr.
run_cli() {
    local output
    output="$(bash "$SUBJECT" "$@" 2>&1)" || true
    printf '%s' "$output"
}

# ---------- Setup / Teardown ----------

setup() {
    export WORKDIR
    WORKDIR="$(mktemp -d -t agent-sandbox-test-XXXXXX)"
    trap teardown EXIT
}

teardown() {
    rm -rf "$WORKDIR"
}

# ---------- Tests ----------

test_help() {
    echo "test_help"
    local out
    out="$(run_cli help)"
    assert_contains "help mentions Usage" "$out" "Usage:"
    assert_contains "help mentions init" "$out" "init"
    assert_contains "help mentions ps" "$out" "ps"
    assert_contains "help mentions environment" "$out" "environment"
}

test_init_no_args_shows_error() {
    echo "test_init_no_args_shows_error"
    local out
    out="$(run_cli init 2>&1 || true)"
    assert_contains "error mentions init" "$out" "init"
    assert_contains "error mentions <environment>" "$out" "<environment>"
}

test_init_creates_dev_env() {
    echo "test_init_creates_dev_env"
    setup
    # We need to mock the interactive input for 'read'
    # We provide VAULT_ADDR, VAULT_TOKEN, and VAULT_NAME via stdin
    printf "localhost:14321\ndummy_token\ndefault_vault\n" | (cd "$WORKDIR" && bash "$SUBJECT" init dev) >/dev/null 2>&1 || true
    assert_file_exists "dev.env created" "$WORKDIR/.agent-sandbox/dev.env"
    assert_file_exists "secret.env created" "$WORKDIR/.agent-sandbox/dev.secret.env"

    local content secret
    content="$(cat "$WORKDIR/.agent-sandbox/dev.env")"
    assert_not_contains "no workspace_target field" "$content" "workspace_arg"
    assert_contains "default opencode image" "$content" "agent-sandbox-opencode:latest"

    secret="$(cat "$WORKDIR/.agent-sandbox/dev.secret.env")"
    assert_contains "token in secret" "$secret" "dummy_token"
    assert_not_contains "no proxy in secret" "$secret" "HTTP_PROXY"
    teardown
}

test_image_dockerfile_triggers_build() {
    echo "test_image_dockerfile_triggers_build"
    setup

    # Minimal Dockerfile in the workspace
    cat >"$WORKDIR/Dockerfile" <<'DOCKEREOF'
FROM debian:trixie-slim
RUN echo hi
DOCKEREOF

    # dev.env pointing at ./Dockerfile
    mkdir -p "$WORKDIR/.agent-sandbox"
    cat >"$WORKDIR/.agent-sandbox/dev.env" <<'ENVEOF'
AGENT_SANDBOX_IMAGE="./Dockerfile"
ENVEOF

    # Stub docker on PATH
    local stub_bin="$WORKDIR/bin"
    export MOCK_DOCKER_LOG="$WORKDIR/docker-calls.log"
    make_docker_stub "$stub_bin"

    # Run sandbox with docker skipped after resolve, but build is invoked
    # before the skip check, so the stub should record the build call.
    cat >"$WORKDIR/.agent-sandbox/dev.secret.env" <<'SECEOF'
AGENT_VAULT_TOKEN="test-token"
SECEOF
    SANDBOX_SKIP_DOCKER=1 PATH="$stub_bin:$PATH" \
        bash -c 'cd "$1" && bash "$2" run dev' _ "$WORKDIR" "$SUBJECT" \
        >/dev/null 2>&1 || true

    assert_file_exists "docker stub was invoked" "$MOCK_DOCKER_LOG"
    local log
    log="$(cat "$MOCK_DOCKER_LOG" 2>/dev/null || true)"
    assert_contains "docker build called with -f ./Dockerfile" "$log" "build -f ./Dockerfile"
    assert_contains "docker build tagged agent-sandbox-dev:latest" "$log" "agent-sandbox-dev:latest"
    teardown
}

test_image_name_not_dockerfile_no_build() {
    echo "test_image_name_not_dockerfile_no_build"
    setup
    mkdir -p "$WORKDIR/.agent-sandbox"
    cat >"$WORKDIR/.agent-sandbox/dev.env" <<'EOF'
AGENT_SANDBOX_IMAGE="myregistry/myimage:1.0"
EOF
    cat >"$WORKDIR/.agent-sandbox/dev.secret.env" <<'EOF'
AGENT_VAULT_TOKEN="test-token"
EOF

    local stub_bin="$WORKDIR/bin"
    export MOCK_DOCKER_LOG="$WORKDIR/docker-calls.log"
    make_docker_stub "$stub_bin"

    SANDBOX_SKIP_DOCKER=1 PATH="$stub_bin:$PATH" \
        bash -c 'cd "$1" && bash "$2" run dev' _ "$WORKDIR" "$SUBJECT" \
        >/dev/null 2>&1 || true

    local log
    log="$(cat "$MOCK_DOCKER_LOG" 2>/dev/null || echo '')"
    assert_not_contains "no docker build for plain image name" "$log" "build"
    teardown
}

test_image_absolute_path_triggers_build() {
    echo "test_image_absolute_path_triggers_build"
    setup

    mkdir -p "$WORKDIR/sub"
    cat >"$WORKDIR/sub/Dockerfile" <<'DOCKEREOF'
FROM debian:trixie-slim
RUN echo hi
DOCKEREOF

    mkdir -p "$WORKDIR/.agent-sandbox"
    printf 'AGENT_SANDBOX_IMAGE="%s/sub/Dockerfile"\n' "$WORKDIR" >"$WORKDIR/.agent-sandbox/dev.env"

    local stub_bin="$WORKDIR/bin"
    export MOCK_DOCKER_LOG="$WORKDIR/docker-calls.log"
    make_docker_stub "$stub_bin"

    cat >"$WORKDIR/.agent-sandbox/dev.secret.env" <<'SECEOF'
AGENT_VAULT_TOKEN="test-token"
SECEOF

    SANDBOX_SKIP_DOCKER=1 PATH="$stub_bin:$PATH" \
        bash -c 'cd "$1" && bash "$2" run dev' _ "$WORKDIR" "$SUBJECT" \
        >/dev/null 2>&1 || true

    local log
    log="$(cat "$MOCK_DOCKER_LOG" 2>/dev/null || true)"
    assert_contains "absolute path triggers docker build" "$log" "build -f"
    assert_contains "build tagged agent-sandbox-dev:latest" "$log" "agent-sandbox-dev:latest"
    teardown
}

test_start_missing_config_accepts_init() {
    echo "test_start_missing_config_accepts_init"
    setup
    mkdir -p "$WORKDIR/.agent-sandbox"
    # Answer Y to the auto-init prompt, then provide vault inputs
    local out
    out="$(printf "Y\nvault:8200\ntok123\nmyvault\n" | (cd "$WORKDIR" && bash "$SUBJECT" run testenv 2>&1) || true)"
    assert_contains "config created message" "$out" "testenv"
    assert_file_exists "env file created" "$WORKDIR/.agent-sandbox/testenv.env"
    assert_file_exists "secret file created" "$WORKDIR/.agent-sandbox/testenv.secret.env"

    local content secret
    content="$(cat "$WORKDIR/.agent-sandbox/testenv.env")"
    assert_contains "uses provided vault address" "$content" "vault:8200"
    assert_contains "uses provided vault name" "$content" "myvault"

    secret="$(cat "$WORKDIR/.agent-sandbox/testenv.secret.env")"
    assert_contains "token in secret" "$secret" "tok123"
    assert_not_contains "no proxy in secret" "$secret" "HTTP_PROXY"
    teardown
}

test_image_dockerfile_not_found() {
    echo "test_image_dockerfile_not_found"
    setup
    mkdir -p "$WORKDIR/.agent-sandbox"
    cat >"$WORKDIR/.agent-sandbox/dev.env" <<'ENVEOF'
AGENT_SANDBOX_IMAGE="./nonexistent/Dockerfile"
ENVEOF
    cat >"$WORKDIR/.agent-sandbox/dev.secret.env" <<'SECEOF'
AGENT_VAULT_TOKEN="test-token"
SECEOF

    local stub_bin="$WORKDIR/bin"
    export MOCK_DOCKER_LOG="$WORKDIR/docker-calls.log"
    make_docker_stub "$stub_bin"

    local out
    out="$(SANDBOX_SKIP_DOCKER=1 PATH="$stub_bin:$PATH" \
        bash -c 'cd "$1" && bash "$2" run dev' _ "$WORKDIR" "$SUBJECT" 2>&1 || true)"
    assert_contains "error mentions Dockerfile not found" "$out" "Dockerfile"
    assert_contains "error mentions nonexistent" "$out" "nonexistent"

    local log
    log="$(cat "$MOCK_DOCKER_LOG" 2>/dev/null || echo '')"
    assert_not_contains "no docker build attempted" "$log" "build"
    teardown
}

test_init_empty_env_name_shows_error() {
    echo "test_init_empty_env_name_shows_error"
    local out
    out="$(echo "" | run_cli init 2>&1 || true)"
    assert_contains "error mentions environment name" "$out" "environment"
    assert_contains "error mentions <environment>" "$out" "<environment>"
}

test_start_missing_config_shows_prompt() {
    echo "test_start_missing_config_shows_prompt"
    setup
    local out
    out="$(printf "n\n" | (cd "$WORKDIR" && bash "$SUBJECT" run nonexistent 2>&1) || true)"
    assert_contains "mentions run init first" "$out" "init"
    assert_not_contains "no config file created" "$(ls "$WORKDIR/.agent-sandbox/" 2>/dev/null || true)" "nonexistent"
    teardown
}

test_start_missing_secret_shows_error() {
    echo "test_start_missing_secret_shows_error"
    setup
    mkdir -p "$WORKDIR/.agent-sandbox"
    cat >"$WORKDIR/.agent-sandbox/test.env" <<'EOF'
AGENT_SANDBOX_IMAGE="myimage:latest"
EOF
    local out
    out="$(cd "$WORKDIR" && bash "$SUBJECT" run test 2>&1 || true)"
    assert_contains "error mentions secrets file" "$out" "secrets file"
    teardown
}

test_image_dockerfile_directory_triggers_build() {
    echo "test_image_dockerfile_directory_triggers_build"
    setup

    # Directory containing a Dockerfile
    mkdir -p "$WORKDIR/mybuild"
    cat >"$WORKDIR/mybuild/Dockerfile" <<'DOCKEREOF'
FROM debian:trixie-slim
RUN echo hi
DOCKEREOF

    mkdir -p "$WORKDIR/.agent-sandbox"
    cat >"$WORKDIR/.agent-sandbox/dev.env" <<'ENVEOF'
AGENT_SANDBOX_IMAGE="./mybuild"
ENVEOF

    local stub_bin="$WORKDIR/bin"
    export MOCK_DOCKER_LOG="$WORKDIR/docker-calls.log"
    make_docker_stub "$stub_bin"

    cat >"$WORKDIR/.agent-sandbox/dev.secret.env" <<'SECEOF'
AGENT_VAULT_TOKEN="test-token"
SECEOF

    SANDBOX_SKIP_DOCKER=1 PATH="$stub_bin:$PATH" \
        bash -c 'cd "$1" && bash "$2" run dev' _ "$WORKDIR" "$SUBJECT" \
        >/dev/null 2>&1 || true

    local log
    log="$(cat "$MOCK_DOCKER_LOG" 2>/dev/null || true)"
    assert_contains "docker build called for directory Dockerfile" "$log" "build -f"
    assert_contains "docker build tagged agent-sandbox-dev:latest" "$log" "agent-sandbox-dev:latest"
    teardown
}

# ---------- Runner ----------

main() {
    echo "Running agent-sandbox tests..."
    echo ""
    test_help
    test_init_no_args_shows_error
    test_init_creates_dev_env
    test_init_empty_env_name_shows_error
    test_start_missing_config_shows_prompt
    test_start_missing_secret_shows_error
    test_start_missing_config_accepts_init
    test_image_dockerfile_triggers_build
    test_image_dockerfile_directory_triggers_build
    test_image_absolute_path_triggers_build
    test_image_dockerfile_not_found
    test_image_name_not_dockerfile_no_build

    echo ""
    echo "----------------------------------------"
    echo "Passed: $PASS   Failed: $FAIL"
    if [ "$FAIL" -ne 0 ]; then
        echo ""
        echo "Failures:"
        for f in "${FAILURES[@]}"; do
            echo "  - $f"
        done
        exit 1
    fi
    echo "All tests passed."
}

main "$@"
