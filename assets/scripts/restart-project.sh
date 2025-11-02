#!/bin/bash

set -e

PROJECT_NAME=$1
# Check if project name is present in project-whitelist.list
./verify-project.sh "$PROJECT_NAME"

PROJECT_CACHE_PATH=/etc/webhook/cache/$PROJECT_NAME
PROJECT_ENVS_PATH=$SHARED_DIR_PATH/envs/$PROJECT_NAME
REPO_NAME=$DOCKER_USERNAME/$PROJECT_NAME

# Create if not exists a directory for project files
mkdir -p "$PROJECT_CACHE_PATH"
# Pull a latest repository
docker pull "$REPO_NAME"
# Clear the directory for project files
rm -r "$PROJECT_CACHE_PATH"
# Extrect files placed in docker directory from image into casche dir
./extract-file.sh "$REPO_NAME" docker "$PROJECT_CACHE_PATH"
chown -R 1000:1000 "$PROJECT_CACHE_PATH"
# Copy there env files if any provided
if [ -d "$PROJECT_ENVS_PATH" ]; then
    echo "Env file for project [$PROJECT_NAME] was found"
    cp -a "$PROJECT_ENVS_PATH"/. "$PROJECT_CACHE_PATH"/
else 
    echo "Env file for project [$PROJECT_NAME] was not found"
fi

PROJECT_DOCKER_COMPOSE_FILE=$PROJECT_CACHE_PATH/docker-compose.yml

# RESTART PROCESS

docker compose -f "$PROJECT_DOCKER_COMPOSE_FILE" -p "$PROJECT_NAME" pull
docker compose -f "$PROJECT_DOCKER_COMPOSE_FILE" -p "$PROJECT_NAME" down
docker compose -f "$PROJECT_DOCKER_COMPOSE_FILE" -p "$PROJECT_NAME" up -d


