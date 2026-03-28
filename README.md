[generaltao725/docker-webhook](https://hub.docker.com/repository/docker/generaltao725/docker-webhook/general) is a docker image that allows you to keep your docker compose projects up-to-date. It listens for DockerHub webhooks, and on an incoming webhook, it pulls an image, extracts the docker-compose file, and then starts/restarts the docker compose project.

The image is based on [thecatlady/webhook](https://hub.docker.com/r/thecatlady/webhook) image and wraps [adnanh/webhook](https://github.com/adnanh/webhook) application.

### Usage
An example of the usage of the image can be found in a [test](test/run-project-on-post-request/docker-compose.yml).

### Prerequiremnts 
 - Target images must have a docker compose project placed into `/docker` directory of the image
 - Docker compose yml file must be named as `docker-compose.yml`
 - Works only with public images from DockerHub
 - Is triggered only on an image being updated with `latest` tag
 - Requires a cache folder `/etc/webhook/cache` that should be mounted in the docker host filesystem.

### Configuration 
 - `WEBHOOK_SECRET` - you have to create a webhook with a secret placed into its URL `http://<server_ip>/hooks/<webhook_secret>/docker-webhook`. The secret can be then loaded as an environment variable `WEBHOOK_SECRET` in `docker-webhook` service. The secret is used for security purposes.
 - `DOCKER_USERNAME` - an env var that contains your DockerHub username.
 - `DEPLOY_DEFAULT_ENV` - (optional) the default environment to deploy to when no environment is specified in the webhook payload. Defaults to `stage` if not set.
 - `project-whitelist.list` - is a file with target image names being listed (without owner name). The tool will check if the list contains the image name from webhook details and will proceed         only on finding a match. Each image name should be written from the new line. The file should placed in `shared/config` folder and the `shared` folder should be mounted into `/etc/webhook/shared` of the container.
 - `envs` - a folder that loads env vars for each docker compose project. Envs should be stored in `.envs` file a placed in `shared/<image_name>-<environment>/` folder (e.g., `shared/envs/myapp-stage/` or `shared/envs/myapp-prod/`). The `shared` folder should be mounted into `/etc/webhook/shared` of the container. This configuration is optional.
 - `docker-compose.override.yml` - (optional) you can place environment-specific Docker Compose override files in `shared/envs/<image_name>-<environment>/docker-compose.override.yml`. These override files will be automatically applied when deploying to that environment, allowing you to customize ports, volumes, environment variables, or any other Docker Compose settings per environment.

### Multi-Environment Deployments (Stage/Prod)

The webhook service supports deploying to multiple environments (e.g., stage and prod) from the same Docker image:

- **Default behavior**: By default, webhooks deploy to the `stage` environment (or whatever `DEPLOY_DEFAULT_ENV` is set to).
- **Production deployments**: To deploy to production, include an `environment` field with value `prod` in your webhook payload.
- **Environment isolation**: Each environment maintains separate:
  - Cache directories: `/etc/webhook/cache/<project>-<environment>`
  - Docker Compose project names: `<project>-<environment>`
  - Environment variable files: `shared/envs/<project>-<environment>/`
  - Docker Compose override files: `shared/envs/<project>-<environment>/docker-compose.override.yml`

**Example webhook payload for production deployment:**
```json
{
  "push_data": {
    "tag": "latest"
  },
  "repository": {
    "name": "myapp"
  },
  "environment": "prod"
}
```

When sending the webhook manually to trigger a production deployment, add `"environment": "prod"` to the JSON payload. Automatic webhooks from DockerHub will deploy to stage by default.

### GitHub Actions Integration

The tool provides a reusable GitHub Actions workflow so you can trigger deployments from CI/CD pipelines and see deployment logs directly in GitHub.

#### Setup

1. Add these secrets to your GitHub repository (or organization):
   - `WEBHOOK_URL` — base URL of your webhook server (e.g. `https://myserver.com:9000`)
   - `WEBHOOK_SECRET` — the webhook secret used in the URL path

2. If using DockerHub callbacks, you can **disable them** and rely on GitHub Actions instead for full control and log visibility.

#### Usage

Reference the reusable workflow from your project's release pipeline:

```yaml
jobs:
  release:
    # ... your build & push steps ...

  deploy-stage:
    needs: release
    uses: taonity/docker-webhook/.github/workflows/deploy.yml@main
    with:
      project_name: myapp
      environment: stage
    secrets:
      WEBHOOK_URL: ${{ secrets.WEBHOOK_URL }}
      WEBHOOK_SECRET: ${{ secrets.WEBHOOK_SECRET }}
```

The deployment logs from docker-webhook are streamed back and visible in the GitHub Actions run.

See a full [example](.github/examples/artist-insight-service-release.yml) for artist-insight-service.

#### Manual deployments

You can trigger deployments manually from the **docker-webhook** repo's Actions tab using the "Deploy (manual)" workflow. Select the project name and environment from the UI.

#### Log visibility

Since the webhook is configured with `stream-command-output: true`, the full deployment output (docker pull, compose down/up, etc.) is streamed as the HTTP response body and appears in the GitHub Actions step log.

### Used in
 - [taonity/prodenv](https://github.com/taonity/prodenv)
