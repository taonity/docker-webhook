#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP_ROOT=$(mktemp -d)
trap 'if [[ -n "${TMP_ROOT:-}" && -d "$TMP_ROOT" ]]; then rm -rf "$TMP_ROOT"; fi' EXIT

SCRIPT_DIR="$TMP_ROOT/scripts"
MOCK_BIN="$TMP_ROOT/bin"
SHARED_DIR="$TMP_ROOT/shared"
WEBHOOK_ROOT="$TMP_ROOT/webhook"
ESCAPED_WEBHOOK_ROOT=$(printf '%s\n' "$WEBHOOK_ROOT" | sed 's#[/&]#\\&#g')

mkdir -p "$SCRIPT_DIR" "$MOCK_BIN" "$SHARED_DIR/envs" "$SHARED_DIR/configs" "$WEBHOOK_ROOT/cache"

sed "s#/etc/webhook#$ESCAPED_WEBHOOK_ROOT#g" "$REPO_ROOT/assets/scripts/restart-project.sh" > "$SCRIPT_DIR/restart-project.sh"

cat > "$SCRIPT_DIR/verify-project.sh" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "$SCRIPT_DIR/extract-file.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
mkdir -p "$3/docker"
cat > "$3/docker/docker-compose.yml" <<'YAML'
services:
  app:
    image: example/app:latest
YAML
EOF

cat > "$MOCK_BIN/docker" <<'EOF'
#!/bin/bash
set -euo pipefail

cmd=$1
shift

case "$cmd" in
  pull|create|cp|rm)
    exit 0
    ;;
  logs)
    echo "mock logs for $1"
    exit 0
    ;;
  inspect)
    format=$2
    case "$format" in
      *com.docker.compose.service*)
        echo "app"
        ;;
      *'.State.Status'*)
        echo "${MOCK_CONTAINER_STATUS:-running}"
        ;;
      *'.State.Health'*)
        echo "${MOCK_HEALTH_STATUS:-none}"
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  compose)
    subcmd=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -f|-p)
          shift 2
          ;;
        *)
          subcmd=$1
          shift
          break
          ;;
      esac
    done

    case "$subcmd" in
      pull|down|up)
        exit 0
        ;;
      ps)
        if [ "${1:-}" = "-q" ]; then
          if [ "${MOCK_NO_CONTAINERS:-0}" = "1" ]; then
            exit 0
          fi
          echo "container-1"
        else
          echo "NAME STATUS"
        fi
        exit 0
        ;;
      *)
        echo "unsupported compose subcommand: $subcmd" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "unsupported docker command: $cmd" >&2
    exit 1
    ;;
esac
EOF

cat > "$MOCK_BIN/chown" <<'EOF'
#!/bin/bash
exit 0
EOF

chmod +x \
  "$SCRIPT_DIR/restart-project.sh" \
  "$SCRIPT_DIR/verify-project.sh" \
  "$SCRIPT_DIR/extract-file.sh" \
  "$MOCK_BIN/docker" \
  "$MOCK_BIN/chown"

printf 'project\n' > "$SHARED_DIR/configs/project-whitelist.list"

run_restart_project() {
  local expected_exit=$1
  shift

  set +e
  (
    cd "$SCRIPT_DIR"
    PATH="$MOCK_BIN:$PATH" \
      SHARED_DIR_PATH="$SHARED_DIR" \
      DOCKER_USERNAME=tester \
      "$@" \
      ./restart-project.sh project stage
  ) >/dev/null 2>&1
  local status=$?
  set -e

  if [ "$status" -ne "$expected_exit" ]; then
    echo "Expected exit code $expected_exit, got $status" >&2
    exit 1
  fi
}

bash -n "$SCRIPT_DIR/restart-project.sh"
run_restart_project 0 env DEPLOY_HEALTHCHECK_TIMEOUT=5 MOCK_CONTAINER_STATUS=running MOCK_HEALTH_STATUS=healthy
run_restart_project 0 env MOCK_CONTAINER_STATUS=exited MOCK_HEALTH_STATUS=none
run_restart_project 1 env DEPLOY_HEALTHCHECK_TIMEOUT=5 MOCK_CONTAINER_STATUS=exited MOCK_HEALTH_STATUS=none
run_restart_project 1 env DEPLOY_HEALTHCHECK_TIMEOUT=5 MOCK_CONTAINER_STATUS=running MOCK_HEALTH_STATUS=unhealthy
run_restart_project 1 env DEPLOY_HEALTHCHECK_TIMEOUT=1 MOCK_CONTAINER_STATUS=running MOCK_HEALTH_STATUS=starting
run_restart_project 1 env DEPLOY_HEALTHCHECK_TIMEOUT=5 MOCK_NO_CONTAINERS=1

echo "restart-project.sh tests passed"
