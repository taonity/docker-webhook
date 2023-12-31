#!/bin/bash

IMAGE=$1
SOURCE_PATH=$2
DESTINATION_PATH=$3

CONTAINER_ID=$(docker create "$IMAGE")
docker cp "$CONTAINER_ID:$SOURCE_PATH" "$DESTINATION_PATH"
docker rm "$CONTAINER_ID"