#!/bin/bash

set -e

PROJECT_NAME=$1
ENVIRONMENT=$2

# If environment is not provided or empty, use default from env var (defaults to "stage")
if [ -z "$ENVIRONMENT" ]; then
    ENVIRONMENT="${DEPLOY_DEFAULT_ENV:-stage}"
fi

echo "Deploying project [$PROJECT_NAME] to environment [$ENVIRONMENT]"

# Check if project name is present in project-whitelist.list
./verify-project.sh "$PROJECT_NAME"

# Use environment-specific paths
PROJECT_CACHE_PATH=/etc/webhook/cache/${PROJECT_NAME}-${ENVIRONMENT}
PROJECT_ENVS_PATH=$SHARED_DIR_PATH/envs/${PROJECT_NAME}-${ENVIRONMENT}
REPO_NAME=$DOCKER_USERNAME/$PROJECT_NAME
COMPOSE_PROJECT_NAME=${PROJECT_NAME}-${ENVIRONMENT}

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

PROJECT_DOCKER_COMPOSE_FILE=$PROJECT_CACHE_PATH/docker-compose.yml
PROJECT_DOCKER_COMPOSE_OVERRIDE=$PROJECT_CACHE_PATH/docker-compose.override.yml

# RESTART PROCESS

# Build docker compose command with override file if it exists
COMPOSE_FILES="-f $PROJECT_DOCKER_COMPOSE_FILE"
if [ -f "$PROJECT_DOCKER_COMPOSE_OVERRIDE" ]; then
    echo "Docker compose override file found for [$PROJECT_NAME] environment [$ENVIRONMENT]"
    COMPOSE_FILES="$COMPOSE_FILES -f $PROJECT_DOCKER_COMPOSE_OVERRIDE"
else
    echo "No docker compose override file for [$PROJECT_NAME] environment [$ENVIRONMENT]"
fi

docker compose $COMPOSE_FILES -p "$COMPOSE_PROJECT_NAME" pull
docker compose $COMPOSE_FILES -p "$COMPOSE_PROJECT_NAME" down
docker compose $COMPOSE_FILES -p "$COMPOSE_PROJECT_NAME" up -d


