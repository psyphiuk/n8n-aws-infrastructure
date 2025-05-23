#!/usr/bin/env bash
set -euo pipefail

# ────────────────────────────
# Required env vars (exported by CFN UserData)
# ────────────────────────────
# CLIENT_NAME
# POSTGRES_DB
# POSTGRES_NON_ROOT_USER
# SSM_POSTGRES_PASSWORD_PATH
# SSM_ENCRYPTION_KEY_PATH
# N8N_BASIC_AUTH_ACTIVE
# N8N_BASIC_AUTH_USER
# N8N_BASIC_AUTH_PASSWORD
# GENERIC_TIMEZONE
# DOCKER_COMPOSE_REPO
# DOCKER_COMPOSE_BRANCH
# DOCKER_COMPOSE_DIR

WORKDIR="/home/ec2-user/n8n"
TARGET="${WORKDIR}/${DOCKER_COMPOSE_DIR}"
REPO="${DOCKER_COMPOSE_REPO}"
BRANCH="${DOCKER_COMPOSE_BRANCH}"

# ────────────────────────────
# 1. Install Docker, Compose & AWS CLI
# ────────────────────────────
yum update -y
amazon-linux-extras install docker -y
systemctl enable docker
systemctl start docker
usermod -a -G docker ec2-user

# Compose plugin
yum install -y docker-compose-plugin

# AWS CLI v2
yum install -y unzip
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install

# ────────────────────────────
# 2. Clone or update your repo
# ────────────────────────────
sudo -u ec2-user bash <<EOF
set -euo pipefail

mkdir -p "${WORKDIR}"
if [ ! -d "${TARGET}/.git" ]; then
  git clone --branch "\${BRANCH}" "\${REPO}" "\${TARGET}"
else
  cd "\${TARGET}"
  git pull
fi

# Ensure ec2-user owns everything
chown -R ec2-user:ec2-user "\${WORKDIR}"
EOF

# ────────────────────────────
# 3. Fetch secrets from SSM
# ────────────────────────────
DB_PASS=\$(aws ssm get-parameter \
  --name "\${SSM_POSTGRES_PASSWORD_PATH}" \
  --with-decryption \
  --query Parameter.Value --output text)

ENC_KEY=\$(aws ssm get-parameter \
  --name "\${SSM_ENCRYPTION_KEY_PATH}" \
  --with-decryption \
  --query Parameter.Value --output text)

# ────────────────────────────
# 4. Write the .env file
# ────────────────────────────
cat > "\${TARGET}/.env" <<ENV
POSTGRES_DB=\${POSTGRES_DB}
POSTGRES_NON_ROOT_USER=\${POSTGRES_NON_ROOT_USER}
POSTGRES_NON_ROOT_PASSWORD=\${DB_PASS}

# n8n Basic Auth
N8N_BASIC_AUTH_ACTIVE=\${N8N_BASIC_AUTH_ACTIVE}
N8N_BASIC_AUTH_USER=\${N8N_BASIC_AUTH_USER}
N8N_BASIC_AUTH_PASSWORD=\${N8N_BASIC_AUTH_PASSWORD}

# Timezone
GENERIC_TIMEZONE=\${GENERIC_TIMEZONE}

# Encryption
ENCRYPTION_KEY=\${ENC_KEY}
ENV

# ────────────────────────────
# 5. Launch the stack
# ────────────────────────────
cd "\${TARGET}"
docker compose pull
docker compose up -d
