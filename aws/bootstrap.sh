#!/usr/bin/env bash
set -euo pipefail

# Determine the non-root user home (ubuntu or ec2-user)
USER_NAME=$(getent passwd 1000 | cut -d: -f1)
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)

LOGFILE=/var/log/bootstrap.log
exec > >(tee -a "$LOGFILE") 2>&1

echo "[$(date)] Starting bootstrap on $(hostname) as $USER_NAME ($USER_HOME)"

# 1. Install Docker & Compose plugin
if ! command -v docker &>/dev/null; then
  echo "Installing Docker..."
  apt-get update
  apt-get install -y docker.io unzip
  systemctl enable docker
  systemctl start docker
  usermod -aG docker "$USER_NAME"
fi

# Install Compose CLI plugin if missing
CLI_PLUGINS_DIR=/usr/libexec/docker/cli-plugins
if [ ! -x "$CLI_PLUGINS_DIR/docker-compose" ]; then
  echo "Installing Docker Compose plugin..."
  mkdir -p "$CLI_PLUGINS_DIR"
  curl -fsSL \
    "https://github.com/docker/compose/releases/download/v2.16.0/docker-compose-linux-x86_64" \
    -o "$CLI_PLUGINS_DIR/docker-compose"
  chmod +x "$CLI_PLUGINS_DIR/docker-compose"
fi

# 2. Install AWS CLI v2 if missing
if ! command -v aws &>/dev/null; then
  echo "Installing AWS CLI v2..."
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install --update
fi

# 3. Export parameters for compose
export CLIENT_NAME=${ClientName:-}
export POSTGRES_DB=${PostgresDb:-}
export POSTGRES_NON_ROOT_USER=${PostgresUser:-}
export POSTGRES_NON_ROOT_PASSWORD=$(aws ssm get-parameter --name "$SsmPostgresPasswordPath" --with-decryption --query Parameter.Value --output text)
export ENCRYPTION_KEY=$(aws ssm get-parameter --name "$SsmEncryptionKeyPath" --with-decryption --query Parameter.Value --output text)
export N8N_BASIC_AUTH_ACTIVE=${BasicAuthActive:-false}
export N8N_BASIC_AUTH_USER=${BasicAuthUser:-}
export N8N_BASIC_AUTH_PASSWORD=${BasicAuthPassword:-}
export GENERIC_TIMEZONE=${Timezone:-UTC}
export DOCKER_COMPOSE_REPO=${RepoURL:-}
export DOCKER_COMPOSE_BRANCH=${RepoBranch:-main}
export DOCKER_COMPOSE_DIR=${DockerDir:-docker}

# 4. Clone or update infra repo
REPO_PATH="$USER_HOME/app"
if [ ! -d "$REPO_PATH/.git" ]; then
  echo "Cloning repo $DOCKER_COMPOSE_REPO#$DOCKER_COMPOSE_BRANCH into $REPO_PATH"
  sudo -u "$USER_NAME" git clone --branch "$DOCKER_COMPOSE_BRANCH" "$DOCKER_COMPOSE_REPO" "$REPO_PATH"
else
  echo "Updating existing repo in $REPO_PATH"
  cd "$REPO_PATH"
  sudo -u "$USER_NAME" git pull
fi
chown -R "$USER_NAME:$USER_NAME" "$REPO_PATH"

# 5. Run Docker Compose
COMPOSE_PATH="$REPO_PATH/$DOCKER_COMPOSE_DIR/docker-compose.yml"
echo "Bringing up docker compose stack from $COMPOSE_PATH"
cd "$(dirname "$COMPOSE_PATH")"
# ensure old containers are removed gracefully
sudo -u "$USER_NAME" docker compose down || true
sudo -u "$USER_NAME" docker compose pull
sudo -u "$USER_NAME" docker compose up -d

echo "[$(date)] Bootstrap complete"
