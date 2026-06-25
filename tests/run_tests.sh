#!/usr/bin/env bash
# agent-sandbox test runner (pure bash, no external framework)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SUBJECT="$REPO_DIR/agent-sandbox.sh"
FIXTURES="$SCRIPT_DIR/fixtures"

PASS=0
FAIL=0
FAILURES=()

# ---------- Assertion helpers ----------

assert_equals() {
    local label="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$label"
    else
        fail "$label" "expected: <$expected>, got: <$actual>"
    fi
}

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

assert_match() {
    local label="$1" value="$2" regex="$3"
    if [[ $value =~ $regex ]]; then
        pass "$label"
    else
        fail "$label" "expected to match regex: <$regex>"
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
    assert_contains "help mentions environment" "$out" "environment"
}

test_init_creates_dev_json() {
    echo "test_init_creates_dev_json"
    setup
    (cd "$WORKDIR" && bash "$SUBJECT" init) >/dev/null 2>&1 || true
    assert_file_exists "dev.json created" "$WORKDIR/.agent-sandbox/dev.json"

    local content
    content="$(cat "$WORKDIR/.agent-sandbox/dev.json")"
    assert_not_contains "no workspace_target field" "$content" "workspace_target"
    assert_contains "default opencode image" "$content" "xoadev/opencode-sandbox-image:latest"
    assert_contains "github vault rule" "$content" "api.github.com"
    assert_contains "anthropic vault rule" "$content" "api.anthropic.com"
    teardown
}

test_vault_compile_substitutes_secrets() {
    echo "test_vault_compile_substitutes_secrets"
    setup
    # Source the subject so we can call compile_vault_config directly
    # shellcheck disable=SC1090
    (
        source "$SUBJECT"
        compile_vault_config "$WORKDIR/vault-config.json" \
            "$FIXTURES/dev.json" \
            "$FIXTURES/secrets.env"
    ) >/dev/null 2>&1 || true

    assert_file_exists "vault-config.json written" "$WORKDIR/vault-config.json"

    local content
    content="$(cat "$WORKDIR/vault-config.json")"
    assert_contains "github secret injected" "$content" "Bearer ghp_REAL_TOKEN"
    assert_contains "anthropic secret injected" "$content" "sk-ant-REAL_KEY"
    assert_contains "vault wrapper key present" "$content" "local-sandbox-vault"
    assert_contains "rules key present" "$content" '"rules"'
    assert_not_contains "placeholder remains" "$content" "{{secrets."

    # Validate the produced file is well-formed JSON
    if command -v python3 >/dev/null 2>&1; then
        if python3 -c "import json,sys; json.load(open('$WORKDIR/vault-config.json'))" >/dev/null 2>&1; then
            pass "vault-config.json is valid JSON"
        else
            fail "vault-config.json is valid JSON" "python3 could not parse the file"
        fi
    else
        pass "vault-config.json is valid JSON (skipped: python3 unavailable)"
    fi
    teardown
}

test_vault_compile_empty_rules() {
    echo "test_vault_compile_empty_rules"
    setup
    mkdir -p "$WORKDIR"
    cat >"$WORKDIR/dev-empty.json" <<'JSONEOF'
{ "image": "img:latest", "vault": [] }
JSONEOF
    # shellcheck disable=SC1090
    (
        source "$SUBJECT"
        compile_vault_config "$WORKDIR/vault.json" \
            "$WORKDIR/dev-empty.json" \
            "$FIXTURES/secrets.env"
    ) >/dev/null 2>&1 || true
    assert_file_exists "vault.json written" "$WORKDIR/vault.json"
    local content
    content="$(cat "$WORKDIR/vault.json")"
    assert_contains "empty rules array" "$content" '"rules": []'
    if command -v python3 >/dev/null 2>&1; then
        if python3 -c "import json,sys; json.load(open('$WORKDIR/vault.json'))" >/dev/null 2>&1; then
            pass "empty-rules vault.json is valid JSON"
        else
            fail "empty-rules vault.json is valid JSON" "python3 could not parse the file"
        fi
    else
        pass "empty-rules vault.json is valid JSON (skipped: python3 unavailable)"
    fi
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

    # dev.json pointing at ./Dockerfile
    mkdir -p "$WORKDIR/.agent-sandbox"
    cat >"$WORKDIR/.agent-sandbox/dev.json" <<'JSONEOF'
{
  "image": "./Dockerfile",
  "vault": []
}
JSONEOF

    # Stub docker on PATH
    local stub_bin="$WORKDIR/bin"
    export MOCK_DOCKER_LOG="$WORKDIR/docker-calls.log"
    make_docker_stub "$stub_bin"

    # Run sandbox with docker skipped after resolve, but build is invoked
    # before the skip check, so the stub should record the build call.
    mkdir -p "$WORKDIR/.global"
    cp "$FIXTURES/secrets.env" "$WORKDIR/.global/secrets.env"
    GLOBAL_DIR="$WORKDIR/.global" SANDBOX_SKIP_DOCKER=1 PATH="$stub_bin:$PATH" \
        bash -c 'cd "$1" && bash "$2" dev' _ "$WORKDIR" "$SUBJECT" \
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
    mkdir -p "$WORKDIR/.global" "$WORKDIR/.agent-sandbox"
    cat >"$WORKDIR/.global/secrets.env" <<'EOF'
github=ghp_TOKEN
EOF
    cat >"$WORKDIR/.agent-sandbox/dev.json" <<'JSONEOF'
{
  "image": "myregistry/myimage:1.0",
  "vault": []
}
JSONEOF

    local stub_bin="$WORKDIR/bin"
    export MOCK_DOCKER_LOG="$WORKDIR/docker-calls.log"
    make_docker_stub "$stub_bin"

    GLOBAL_DIR="$WORKDIR/.global" SANDBOX_SKIP_DOCKER=1 PATH="$stub_bin:$PATH" \
        bash -c 'cd "$1" && bash "$2" dev' _ "$WORKDIR" "$SUBJECT" \
        >/dev/null 2>&1 || true

    local log
    log="$(cat "$MOCK_DOCKER_LOG" 2>/dev/null || echo '')"
    assert_not_contains "no docker build for plain image name" "$log" "build"
    teardown
}

# ---------- Runner ----------

main() {
    echo "Running agent-sandbox tests..."
    echo ""
    test_help
    test_init_creates_dev_json
    test_vault_compile_substitutes_secrets
    test_vault_compile_empty_rules
    test_image_dockerfile_triggers_build
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
