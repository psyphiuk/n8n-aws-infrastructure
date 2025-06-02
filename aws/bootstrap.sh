#!/usr/bin/env bash
set -euxo pipefail

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
  usermod -aG docker ubuntu
fi

CLI_PLUGINS_DIR=/usr/libexec/docker/cli-plugins
if [ ! -x "$CLI_PLUGINS_DIR/docker-compose" ]; then
  echo "Installing Docker Compose..."
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

# 3. Export CFN parameters (already in UserData) and fetch secrets from SSM:
export POSTGRES_NON_ROOT_PASSWORD="$(aws ssm get-parameter --name "$SSM_POSTGRES_PASSWORD_PATH" --with-decryption --query Parameter.Value --output text)"
export ENCRYPTION_KEY="$(aws ssm get-parameter --name "$SSM_ENCRYPTION_KEY_PATH" --with-decryption --query Parameter.Value --output text)"
# (The following are inherited via UserData Fn::Sub)
#   CLIENT_NAME, POSTGRES_DB, POSTGRES_NON_ROOT_USER, N8N_BASIC_AUTH_ACTIVE, N8N_BASIC_AUTH_USER, N8N_BASIC_AUTH_PASSWORD, GENERIC_TIMEZONE, DOCKER_COMPOSE_REPO, DOCKER_COMPOSE_BRANCH, DOCKER_COMPOSE_DIR

# 4. Determine non-root user, repo path, and docker directory
USER_NAME=$(getent passwd 1000 | cut -d: -f1 || echo ubuntu)
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
REPO_PATH="$USER_HOME/app"
DOCKER_DIR="$REPO_PATH/$DOCKER_COMPOSE_DIR"

# 5. Clone or update the infrastructure repo
if [ ! -d "$REPO_PATH/.git" ]; then
  echo "Cloning infra repo $DOCKER_COMPOSE_BRANCH → $REPO_PATH"
  sudo -u "$USER_NAME" git clone --branch "$DOCKER_COMPOSE_BRANCH" "$DOCKER_COMPOSE_REPO" "$REPO_PATH"
else
  echo "Updating infra repo in $REPO_PATH"
  cd "$REPO_PATH"
  sudo -u "$USER_NAME" git pull
fi

# Mark safe directory for Git
sudo -u "$USER_NAME" git config --global --add safe.directory "$REPO_PATH"
chown -R "$USER_NAME:$USER_NAME" "$REPO_PATH"

# 6. Run Docker Compose (as root, since ubuntu is already in docker group)
cd "$DOCKER_DIR"
docker compose pull
docker compose up -d

# 7. Install Nginx & Certbot if missing
echo "Installing Nginx & Certbot..."
if ! command -v nginx &>/dev/null; then
  apt-get update
  apt-get install -y nginx certbot python3-certbot-nginx
fi

# 8. Create an HTTP-only Nginx site for ACME challenge
cat > /etc/nginx/sites-available/n8n-http << 'EOF'
server {
  listen 80;
  server_name n8n.tybi.ai;

  # Proxy everything to n8n on port 5678
  location / {
    proxy_pass http://127.0.0.1:5678;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_buffering off;
    proxy_http_version 1.1;
    proxy_set_header   Upgrade $http_upgrade;
    proxy_set_header   Connection $connection_upgrade;
  }

  # ACME challenge location for Let’s Encrypt
  location ~ /.well-known/acme-challenge/ {
    root /var/www/html;
    allow all;
  }
}
EOF

# Enable HTTP-only site, disable any old SSL config
ln -sf /etc/nginx/sites-available/n8n-http /etc/nginx/sites-enabled/n8n-http
rm -f /etc/nginx/sites-enabled/n8n 2>/dev/null || true

# Test & reload Nginx so port 80 is live
nginx -t && systemctl reload nginx

# 9. Run Certbot’s nginx plugin to get/renew a cert for n8n.tybi.ai
certbot --nginx \
  --agree-tos \
  --non-interactive \
  --redirect \
  --staple-ocsp \
  -m simon@tybi.ai \
  -d n8n.tybi.ai

# 10. Now that Certbot created /etc/letsencrypt/live/n8n.tybi.ai/fullchain.pem & privkey.pem,
#     Certbot will have already updated /etc/nginx/sites-available/n8n (the SSL version).
#     We just need to test & reload:
nginx -t && systemctl reload nginx

# 11. Final n8n health check
if curl -sS http://localhost:5678/healthz; then
  echo "n8n health check succeeded"
else
  echo "ERROR: n8n health check failed" >&2
  exit 1
fi

echo "[$(date)] Bootstrap complete"
