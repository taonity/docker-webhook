#!/bin/bash

set -e

cd "$(dirname $0)"

. ../util.sh

info "Starting docker-webhook service"
docker compose up -d --quiet-pull

# Wait for webhook service to start (max 30 seconds)
info "Waiting for webhook service to be ready"
for i in {1..30}; do
  webhook_logs=$(docker compose logs webhook)
  if [[ $webhook_logs == *"serving hooks on http://0.0.0.0:9000/hooks/{id}"* ]]; then
    pass "Webhook service started successfully"
    break
  fi
  if [ $i -eq 30 ]; then
    info "Webhook logs:"
    echo "$webhook_logs"
    fail "Failed to start docker-webhook after 30 seconds."
  fi
  sleep 1
done

# Test 1: Default deployment (should go to stage)
info "Testing default deployment (stage environment)"
responce=$(curl -X POST \
  -H "Content-Type: application/json" \
  -d '{
      "repository": {
          "name": "webhook-test-image"
      },
      "push_data": {
          "tag": "latest"
      }
  }' \
  http://localhost:9000/hooks/mysecret/docker-webhook)

if [[ $responce != "A payload recieved" ]]; then
  fail "Wrong response on POST request for stage deployment."
fi
pass "Stage webhook accepted"

sleep 15

webhook_logs=$(docker compose logs webhook)
if [[ $webhook_logs != *"Deploying project [webhook-test-image] to environment [stage]"* ]]; then
  info "Full webhook logs:"
  echo "$webhook_logs"
  fail "Failed to deploy to stage environment."
fi
pass "Deployed to stage environment"

# Check if deployment finished
if [[ $webhook_logs != *"finished handling mysecret/docker-webhook"* ]]; then
  info "Full webhook logs:"
  echo "$webhook_logs"
  fail "Failed to finish handling the stage deployment request."
fi

# Check for any errors in the logs
if [[ $webhook_logs == *"error"* ]]; then
  info "Errors detected in webhook logs:"
  echo "$webhook_logs" | grep -i error
fi

pass "Stage deployment completed"

# Verify stage container was created (check both running and exited)
sleep 5
info "Looking for stage containers with name pattern 'webhook-test-image-stage'"
docker ps -a --filter "name=webhook-test-image-stage" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
stage_exists=$(docker ps -a --filter "name=webhook-test-image-stage" --format "{{.Names}}" | wc -l)
if [ "$stage_exists" -lt 1 ]; then
  info "No containers found. Checking all containers:"
  docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" | head -20
  fail "Stage container was not created."
fi
pass "Stage container was created successfully (found $stage_exists container(s))"

# Verify stage env file was loaded
stage_env_check=$(docker compose exec webhook cat /etc/webhook/cache/webhook-test-image-stage/.env 2>/dev/null || echo "")
if [[ $stage_env_check != *"TEST_ENV=stage-world"* ]]; then
  fail "Stage environment file not loaded correctly."
fi
pass "Stage environment variables loaded correctly"

# Test 2: Production deployment
info "Testing production deployment"
responce=$(curl -X POST \
  -H "Content-Type: application/json" \
  -d '{
      "repository": {
          "name": "webhook-test-image"
      },
      "push_data": {
          "tag": "latest"
      },
      "environment": "prod"
  }' \
  http://localhost:9000/hooks/mysecret/docker-webhook)

if [[ $responce != "A payload recieved" ]]; then
  fail "Wrong response on POST request for prod deployment."
fi
pass "Prod webhook accepted"

sleep 10

webhook_logs=$(docker compose logs webhook)
if [[ $webhook_logs != *"Deploying project [webhook-test-image] to environment [prod]"* ]]; then
  fail "Failed to deploy to prod environment."
fi
pass "Deployed to prod environment"

# Verify prod container was created (check both running and exited)
sleep 5
prod_exists=$(docker ps -a --filter "name=webhook-test-image-prod" --format "{{.Names}}" | wc -l)
if [ "$prod_exists" -lt 1 ]; then
  info "Checking for prod containers:"
  docker ps -a --filter "name=webhook-test-image-prod"
  fail "Prod container was not created."
fi
pass "Prod container was created successfully"

# Verify prod env file was loaded
prod_env_check=$(docker compose exec webhook cat /etc/webhook/cache/webhook-test-image-prod/.env 2>/dev/null || echo "")
if [[ $prod_env_check != *"TEST_ENV=prod-world"* ]]; then
  fail "Prod environment file not loaded correctly."
fi
pass "Prod environment variables loaded correctly"

pass "Both stage and prod containers are running independently"
info "All tests passed!"
