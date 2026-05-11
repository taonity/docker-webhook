#!/bin/bash

set -euo pipefail

PROJECT_NAME=${1:?Project name argument is required}
ENVIRONMENT=${2-}

# If environment is not provided or empty, use default from env var (defaults to "stage")
if [ -z "$ENVIRONMENT" ]; then
    ENVIRONMENT="${DEPLOY_DEFAULT_ENV:-stage}"
fi

: "${SHARED_DIR_PATH:?SHARED_DIR_PATH environment variable is required}"
: "${DOCKER_USERNAME:?DOCKER_USERNAME environment variable is required}"

echo "Deploying project [$PROJECT_NAME] to environment [$ENVIRONMENT]"

PROJECT_DOCKER_COMPOSE_FILE=
PROJECT_DOCKER_COMPOSE_OVERRIDE=
COMPOSE_PROJECT_NAME=
declare -a COMPOSE_ARGS=()
declare -a COMPOSE_CONTAINER_IDS=()
HEALTHCHECK_POLL_INTERVAL=2

print_service_logs() {
    local container_id=$1
    local service_name=$2

    echo "Logs for service [$service_name]:"
    docker logs "$container_id" || true
}

get_compose_container_ids() {
    mapfile -t COMPOSE_CONTAINER_IDS < <(docker compose "${COMPOSE_ARGS[@]}" -p "$COMPOSE_PROJECT_NAME" ps -q)

    if [ "${#COMPOSE_CONTAINER_IDS[@]}" -eq 0 ]; then
        echo "WARN! Deploy for [$PROJECT_NAME] environment [$ENVIRONMENT] did not create any containers"
        exit 1
    fi
}

validate_compose_container_states() {
    local container_id service_name container_status

    get_compose_container_ids

    for container_id in "${COMPOSE_CONTAINER_IDS[@]}"; do
        service_name=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$container_id")
        container_status=$(docker inspect --format '{{.State.Status}}' "$container_id")

        case "$container_status" in
            running)
                ;;
            *)
                echo "WARN! Service [$service_name] is in [$container_status] state after deploy"
                docker compose "${COMPOSE_ARGS[@]}" -p "$COMPOSE_PROJECT_NAME" ps
                print_service_logs "$container_id" "$service_name"
                exit 1
                ;;
        esac
    done
}

wait_for_container_healthchecks() {
    local healthcheck_timeout=${DEPLOY_HEALTHCHECK_TIMEOUT:-0}
    local start_time current_time container_id service_name health_status has_healthcheck pending_healthchecks

    if ! [[ "$healthcheck_timeout" =~ ^[0-9]+$ ]]; then
        echo "WARN! DEPLOY_HEALTHCHECK_TIMEOUT must be a non-negative integer, got [$healthcheck_timeout]"
        exit 1
    fi

    if [ "$healthcheck_timeout" -le 0 ]; then
        return 0
    fi

    echo "Waiting up to [$healthcheck_timeout] seconds for container health checks"
    start_time=$(date +%s)

    while true; do
        has_healthcheck=false
        pending_healthchecks=false

        validate_compose_container_states

        for container_id in "${COMPOSE_CONTAINER_IDS[@]}"; do
            service_name=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$container_id")
            health_status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id")

            case "$health_status" in
                none)
                    ;;
                healthy)
                    has_healthcheck=true
                    ;;
                starting)
                    has_healthcheck=true
                    pending_healthchecks=true
                    ;;
                unhealthy)
                    echo "WARN! Service [$service_name] failed its health check after deploy"
                    docker compose "${COMPOSE_ARGS[@]}" -p "$COMPOSE_PROJECT_NAME" ps
                    print_service_logs "$container_id" "$service_name"
                    exit 1
                    ;;
                *)
                    echo "WARN! Service [$service_name] returned unexpected health status [$health_status]"
                    docker compose "${COMPOSE_ARGS[@]}" -p "$COMPOSE_PROJECT_NAME" ps
                    print_service_logs "$container_id" "$service_name"
                    exit 1
                    ;;
            esac
        done

        if [ "$has_healthcheck" = false ]; then
            echo "No container health checks configured for [$PROJECT_NAME] environment [$ENVIRONMENT], skipping health verification"
            return 0
        fi

        if [ "$pending_healthchecks" = false ]; then
            echo "All container health checks passed for [$PROJECT_NAME] environment [$ENVIRONMENT]"
            return 0
        fi

        current_time=$(date +%s)
        if [ $((current_time - start_time)) -ge "$healthcheck_timeout" ]; then
            echo "WARN! Timed out waiting [$healthcheck_timeout] seconds for container health checks"
            docker compose "${COMPOSE_ARGS[@]}" -p "$COMPOSE_PROJECT_NAME" ps
            exit 1
        fi

        sleep "$HEALTHCHECK_POLL_INTERVAL"
    done
}

# Check if project name is present in project-whitelist.list
./verify-project.sh "$PROJECT_NAME"

# Use environment-specific paths
PROJECT_CACHE_PATH="/etc/webhook/cache/${PROJECT_NAME}-${ENVIRONMENT}"
PROJECT_ENVS_PATH="${SHARED_DIR_PATH}/envs/${PROJECT_NAME}-${ENVIRONMENT}"
REPO_NAME="${DOCKER_USERNAME}/${PROJECT_NAME}"
COMPOSE_PROJECT_NAME="${PROJECT_NAME}-${ENVIRONMENT}"

# Create if not exists a directory for project files
mkdir -p "$PROJECT_CACHE_PATH"
# Pull a latest repository
docker pull "$REPO_NAME"
# Clear the directory for project files
rm -rf "$PROJECT_CACHE_PATH"/*
# Create a temp directory for extraction
TEMP_EXTRACT_PATH="$PROJECT_CACHE_PATH/temp_extract"
mkdir -p "$TEMP_EXTRACT_PATH"
# Extract files placed in docker directory from image into temp dir
./extract-file.sh "$REPO_NAME" docker "$TEMP_EXTRACT_PATH"
# Move contents from docker subdirectory to cache path
mv "$TEMP_EXTRACT_PATH"/docker/* "$PROJECT_CACHE_PATH"/
# Clean up temp directory
rm -rf "$TEMP_EXTRACT_PATH"
chown -R 1000:1000 "$PROJECT_CACHE_PATH"
# Copy there env files if any provided
if [ -d "$PROJECT_ENVS_PATH" ]; then
    echo "Env file for project [$PROJECT_NAME] environment [$ENVIRONMENT] was found"
    cp -a "$PROJECT_ENVS_PATH"/. "$PROJECT_CACHE_PATH"/
else 
    echo "Env file for project [$PROJECT_NAME] environment [$ENVIRONMENT] was not found"
fi

PROJECT_DOCKER_COMPOSE_FILE="$PROJECT_CACHE_PATH/docker-compose.yml"
PROJECT_DOCKER_COMPOSE_OVERRIDE="$PROJECT_CACHE_PATH/docker-compose.override.yml"

# RESTART PROCESS

# Build docker compose command with override file if it exists
COMPOSE_ARGS=(-f "$PROJECT_DOCKER_COMPOSE_FILE")
if [ -f "$PROJECT_DOCKER_COMPOSE_OVERRIDE" ]; then
    echo "Docker compose override file found for [$PROJECT_NAME] environment [$ENVIRONMENT]"
    COMPOSE_ARGS+=(-f "$PROJECT_DOCKER_COMPOSE_OVERRIDE")
else
    echo "No docker compose override file for [$PROJECT_NAME] environment [$ENVIRONMENT]"
fi

docker compose "${COMPOSE_ARGS[@]}" -p "$COMPOSE_PROJECT_NAME" pull
docker compose "${COMPOSE_ARGS[@]}" -p "$COMPOSE_PROJECT_NAME" down
docker compose "${COMPOSE_ARGS[@]}" -p "$COMPOSE_PROJECT_NAME" up -d

validate_compose_container_states
wait_for_container_healthchecks
