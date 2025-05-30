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
export DOCKER_COMPOSE_BRANCH=${RepoBranch:-master}
export DOCKER_COMPOSE_DIR=${DockerDir:-docker}

if [ ! -d "${USER_HOME}/app/.git" ]; then
  git clone --branch "${RepoBranch}" "${RepoURL}" "${USER_HOME}/app"
else
  cd "${USER_HOME}/app"
  git pull
fi
chown -R "${USER_NAME}:${USER_NAME}" "${USER_HOME}/app"

# 4. Launch Docker Compose as ubuntu
cd "${USER_HOME}/app/${DockerDir}"
sudo -u "${USER_NAME}" docker compose up -d

echo "[$(date)] Bootstrap complete"
