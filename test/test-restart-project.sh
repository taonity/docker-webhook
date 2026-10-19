#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP_ROOT=$(mktemp -d)
trap 'if [[ -n "${TMP_ROOT:-}" && -d "$TMP_ROOT" ]]; then rm -rf "$TMP_ROOT"; fi' EXIT

SCRIPT_DIR="$TMP_ROOT/scripts"
MOCK_BIN="$TMP_ROOT/bin"
SHARED_DIR="$TMP_ROOT/shared"
WEBHOOK_ROOT="$TMP_ROOT/webhook"
DOCKER_LOG="$TMP_ROOT/docker.log"
ESCAPED_WEBHOOK_ROOT=$(printf '%s\n' "$WEBHOOK_ROOT" | sed 's#[/&]#\\&#g')
SOCKET_ROOT="$TMP_ROOT/socket"
ESCAPED_SOCKET_ROOT=$(printf '%s\n' "$SOCKET_ROOT" | sed 's#[/&]#\\&#g')

mkdir -p "$SCRIPT_DIR" "$MOCK_BIN" "$SHARED_DIR/envs" "$SHARED_DIR/configs" "$WEBHOOK_ROOT/cache" "$SOCKET_ROOT"

sed -e "s#/etc/webhook#$ESCAPED_WEBHOOK_ROOT#g" -e "s#/run/prodenv-doppler#$ESCAPED_SOCKET_ROOT#g" "$REPO_ROOT/assets/scripts/restart-project.sh" > "$SCRIPT_DIR/restart-project.sh"

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
if [ "${MOCK_INCLUDE_PRODENV:-0}" = "1" ]; then
  cat > "$3/docker/docker-compose.prodenv.yml" <<'YAML'
services:
  app:
    environment:
      APP_ENV: production
YAML
fi
if [ "${MOCK_INCLUDE_SECRETS:-0}" = "1" ]; then
  printf 'services: {}\n' > "$3/docker/credentials-files.yml"
  printf 'services: {}\n' > "$3/docker/docker-compose.secrets.yml"
fi
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
    if [ -n "${MOCK_DOCKER_LOG:-}" ]; then
      printf '%s\n' "$*" >> "$MOCK_DOCKER_LOG"
    fi
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

cat > "$MOCK_BIN/curl" <<'EOF'
#!/bin/bash
set -eu
printf '%s\n' "$*" >> "$MOCK_CURL_LOG"
exit "${MOCK_BROKER_EXIT:-0}"
EOF

chmod +x \
  "$SCRIPT_DIR/restart-project.sh" \
  "$SCRIPT_DIR/verify-project.sh" \
  "$SCRIPT_DIR/extract-file.sh" \
  "$MOCK_BIN/docker" \
  "$MOCK_BIN/chown" \
  "$MOCK_BIN/curl"

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
      ./restart-project.sh "${TEST_PROJECT:-project}" stage
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
run_restart_project 0 env MOCK_CONTAINER_STATUS=running MOCK_HEALTH_STATUS=none
run_restart_project 0 env MOCK_CONTAINER_STATUS=exited MOCK_HEALTH_STATUS=none
run_restart_project 1 env DEPLOY_HEALTHCHECK_TIMEOUT=5 MOCK_CONTAINER_STATUS=exited MOCK_HEALTH_STATUS=none
run_restart_project 1 env DEPLOY_HEALTHCHECK_TIMEOUT=5 MOCK_CONTAINER_STATUS=running MOCK_HEALTH_STATUS=unhealthy
run_restart_project 1 env DEPLOY_HEALTHCHECK_TIMEOUT=1 MOCK_CONTAINER_STATUS=running MOCK_HEALTH_STATUS=starting
run_restart_project 1 env DEPLOY_HEALTHCHECK_TIMEOUT=5 MOCK_NO_CONTAINERS=1

: > "$DOCKER_LOG"
run_restart_project 0 env MOCK_INCLUDE_PRODENV=1 MOCK_DOCKER_LOG="$DOCKER_LOG"
if [ "$(grep -c -- "-f $WEBHOOK_ROOT/cache/project-stage/docker-compose.prodenv.yml" "$DOCKER_LOG")" -ne 3 ]; then
  echo "Expected docker-compose.prodenv.yml in all deployment compose commands" >&2
  exit 1
fi

TEST_PROJECT=fullstack-starter
mkdir -p "$SHARED_DIR/envs/fullstack-starter-stage"
printf 'FIXTURE_PASSWORD=must-not-copy\n' > "$SHARED_DIR/envs/fullstack-starter-stage/.env"
CURL_LOG="$TMP_ROOT/curl.log"
: > "$CURL_LOG"
: > "$DOCKER_LOG"
run_restart_project 1 env DOCKER_WEBHOOK_DOPPLER_MANAGED_DEPLOYMENTS=fullstack-starter-stage MOCK_INCLUDE_SECRETS=1 MOCK_CURL_LOG="$CURL_LOG"
python3 - "$SOCKET_ROOT/deploy.sock" <<'PY'
import socket
import sys
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sys.argv[1])
server.close()
PY
run_restart_project 1 env DOCKER_WEBHOOK_DOPPLER_MANAGED_DEPLOYMENTS=fullstack-starter-stage MOCK_CURL_LOG="$CURL_LOG"
printf 'OLD_FIXTURE_PASSWORD=must-not-survive\n' > "$WEBHOOK_ROOT/cache/fullstack-starter-stage/.env"
run_restart_project 22 env DOCKER_WEBHOOK_DOPPLER_MANAGED_DEPLOYMENTS=fullstack-starter-stage MOCK_INCLUDE_SECRETS=1 MOCK_CURL_LOG="$CURL_LOG" MOCK_DOCKER_LOG="$DOCKER_LOG" MOCK_BROKER_EXIT=22
run_restart_project 0 env DOCKER_WEBHOOK_DOPPLER_MANAGED_DEPLOYMENTS=fullstack-starter-stage MOCK_INCLUDE_SECRETS=1 MOCK_CURL_LOG="$CURL_LOG" MOCK_DOCKER_LOG="$DOCKER_LOG"
[ ! -e "$WEBHOOK_ROOT/cache/fullstack-starter-stage/.env" ]
[ ! -s "$DOCKER_LOG" ]
[ "$(wc -l < "$CURL_LOG")" -eq 2 ]
grep -q -- '--unix-socket' "$CURL_LOG"
grep -q 'fullstack-starter-stage' "$CURL_LOG"

echo "restart-project.sh tests passed"
