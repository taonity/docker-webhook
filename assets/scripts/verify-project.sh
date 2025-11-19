#!/bin/bash
set -e
INPUT_PROJECT_NAME=$1
# Read whitelist and strip carriage returns (handle Windows line endings)
PROJECT_WHITELIST=$(cat "$SHARED_DIR_PATH"/configs/project-whitelist.list | tr -d '\r')

for PROJECT_NAME in $PROJECT_WHITELIST
do
    if [ "$PROJECT_NAME" == "$INPUT_PROJECT_NAME" ]; then
        exit 0
    fi
done

echo "WARN! Project [$INPUT_PROJECT_NAME] is not present in project-whitelist.list file"
exit 1


