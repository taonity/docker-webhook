#!/bin/sh

set -e

. ./util.sh

image_name=$(basename "$(dirname "$(pwd)")")

./test-restart-project.sh

docker build -t "generaltao725/$image_name:test" $(dirname $(pwd))

for dir in $(find -mindepth 1 -maxdepth 1 -type d | sort); do
  dir=$(echo "$dir" | cut -c 3-)
  echo "################################################"
  echo "Now running ${dir}"
  echo "################################################"
  echo ""

  test="${dir}/run.sh"
  eval "$test"

  remove_docker_compose_project "${dir}/docker-compose.yml"
  
  echo ""
  echo "$test passed"
  echo ""
done
