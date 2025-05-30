#!/usr/bin/env bash
set -euo pipefail

LOGFILE=/var/log/bootstrap.log
exec > >(tee -a "$LOGFILE") 2>&1

echo "[$(date)] Starting bootstrap on $(hostname)"

# 1. Install Docker & Compose plugin if missing
if ! command -v docker &>/dev/null; then
  echo "Installing Docker..."
  if command -v yum &>/dev/null; then
    yum install -y docker.io unzip
  else
    apt-get update
    apt-get install -y docker.io unzip
  fi
  systemctl enable docker
  systemctl start docker
fi

# Install Compose CLI plugin
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

# 3. Fetch secrets from SSM
export POSTGRES_NON_ROOT_PASSWORD=$(aws ssm get-parameter --name "$SSM_POSTGRES_PASSWORD_PATH" --with-decryption --query Parameter.Value --output text)
export ENCRYPTION_KEY=$(aws ssm get-parameter --name "$SSM_ENCRYPTION_KEY_PATH" --with-decryption --query Parameter.Value --output text)

# 4. Determine non-root user and repo path
USER_NAME=$(getent passwd 1000 | cut -d: -f1 || echo ubuntu)
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
REPO_PATH="$USER_HOME/app"
DOCKER_DIR="$REPO_PATH/$DOCKER_COMPOSE_DIR"

# 5. Clone or update infra repo
if [ ! -d "$REPO_PATH/.git" ]; then
  echo "Cloning repo $DOCKER_COMPOSE_BRANCH from $DOCKER_COMPOSE_REPO"
  sudo -u "$USER_NAME" git clone --branch "$DOCKER_COMPOSE_BRANCH" "$DOCKER_COMPOSE_REPO" "$REPO_PATH"
else
  echo "Updating existing repo"
  cd "$REPO_PATH"
  sudo -u "$USER_NAME" git pull
fi
# allow safe directory for git
sudo -u "$USER_NAME" git config --global --add safe.directory "$REPO_PATH"
chown -R "$USER_NAME:$USER_NAME" "$REPO_PATH"

# 6. Run Docker Compose
if [ -d "$DOCKER_DIR" ]; then
  cd "$DOCKER_DIR"
  echo "Starting Docker Compose services"
  sudo -u "$USER_NAME" docker compose pull
  sudo -u "$USER_NAME" docker compose up -d
else
  echo "ERROR: Docker directory $DOCKER_DIR not found"
  exit 1
fi

echo "[$(date)] Bootstrap complete"
