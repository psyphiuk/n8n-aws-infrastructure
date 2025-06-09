#!/usr/bin/env bash
set -euxo pipefail

LOGFILE=/var/log/bootstrap.log
exec > >(tee -a "$LOGFILE") 2>&1
echo "[$(date)] Starting bootstrap on $(hostname)"

# ---------------------------------------------------
# 1) (Your existing steps) Install Docker, Compose
# ---------------------------------------------------

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
  echo "Installing Docker Compose plugin..."
  mkdir -p "$CLI_PLUGINS_DIR"
  curl -fsSL \
    "https://github.com/docker/compose/releases/download/v2.16.0/docker-compose-linux-x86_64" \
    -o "$CLI_PLUGINS_DIR/docker-compose"
  chmod +x "$CLI_PLUGINS_DIR/docker-compose"
fi

# ---------------------------------------------------
# 2) (Your existing steps) Install AWS CLI v2
# ---------------------------------------------------

if ! command -v aws &>/dev/null; then
  echo "Installing AWS CLI v2..."
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install --update
fi

# ---------------------------------------------------
# 3) (Your existing steps) Fetch SSM secrets
# ---------------------------------------------------

export POSTGRES_NON_ROOT_PASSWORD="$(aws ssm get-parameter --name "$SSM_POSTGRES_PASSWORD_PATH" --with-decryption --query Parameter.Value --output text)"
export ENCRYPTION_KEY="$(aws ssm get-parameter --name "$SSM_ENCRYPTION_KEY_PATH" --with-decryption --query Parameter.Value --output text)"

# 3b) Export CFN params into the same shell
export POSTGRES_DB="${POSTGRES_DB}"
export POSTGRES_NON_ROOT_USER="${POSTGRES_NON_ROOT_USER}"
export N8N_BASIC_AUTH_ACTIVE="${N8N_BASIC_AUTH_ACTIVE}"
export N8N_BASIC_AUTH_USER="${N8N_BASIC_AUTH_USER}"
export N8N_BASIC_AUTH_PASSWORD="${N8N_BASIC_AUTH_PASSWORD}"
export GENERIC_TIMEZONE="${GENERIC_TIMEZONE}"

# ---------------------------------------------------
# 4) (Your existing steps) Clone/update repo & run Compose
# ---------------------------------------------------

USER_NAME=$(getent passwd 1000 | cut -d: -f1 || echo ubuntu)
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
REPO_PATH="$USER_HOME/app"
DOCKER_DIR="$REPO_PATH/$DOCKER_COMPOSE_DIR"

if [ ! -d "$REPO_PATH/.git" ]; then
  echo "Cloning infra repo $DOCKER_COMPOSE_BRANCH → $REPO_PATH"
  sudo -u "$USER_NAME" git clone --branch "$DOCKER_COMPOSE_BRANCH" "$DOCKER_COMPOSE_REPO" "$REPO_PATH"
else
  echo "Updating infra repo in $REPO_PATH"
  cd "$REPO_PATH"
  sudo -u "$USER_NAME" git pull
fi

sudo -u "$USER_NAME" git config --global --add safe.directory "$REPO_PATH"
chown -R "$USER_NAME:$USER_NAME" "$REPO_PATH"

cd "$DOCKER_DIR"
docker compose pull
docker compose up -d

# ---------------------------------------------------
# 5) NEW: Install Nginx & Certbot for HTTPS termination
# ---------------------------------------------------

echo "Installing Nginx & Certbot for HTTPS…"
if ! command -v nginx &>/dev/null; then
  apt-get update
  apt-get install -y nginx certbot python3-certbot-nginx
fi

# (a) Create a port 80‐only Nginx site so Certbot’s HTTP challenge can succeed
cat > /etc/nginx/sites-available/n8n-http << 'EOF'
map $http_upgrade $connection_upgrade {
  default       upgrade;
  ''            close;
}

server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name n8n.tybi.ai;

  location ^~ /.well-known/acme-challenge/ {
    root /var/www/html;
    default_type "text/plain";
    allow all;
  }

  location / {
    proxy_pass         http://127.0.0.1:5678;
    proxy_http_version 1.1;
    proxy_set_header   Upgrade    $http_upgrade;
    proxy_set_header   Connection $connection_upgrade;
    proxy_set_header   Host       $host;
    proxy_set_header   X-Real-IP  $remote_addr;
    proxy_set_header   X-Forwarded-For    $proxy_add_x_forwarded_for;
    proxy_set_header   X-Forwarded-Proto  $scheme;
    proxy_buffering    off;
  }
}
EOF

# Enable HTTP‐only site; remove old SSL block if it exists
ln -sf /etc/nginx/sites-available/n8n-http /etc/nginx/sites-enabled/n8n-http
rm -f /etc/nginx/sites-enabled/n8n 2>/dev/null || true

# Test & reload Nginx (now listening on port 80 only)
nginx -t && systemctl reload nginx

# (b) Run Certbot’s nginx plugin to fetch/renew a Let’s Encrypt cert
certbot --nginx \
  --agree-tos \
  --non-interactive \
  --redirect \
  --staple-ocsp \
  -m simon@tybi.ai \
  -d n8n.tybi.ai

# After Certbot finishes, it will have created:
#   /etc/letsencrypt/live/n8n.tybi.ai/fullchain.pem
#   /etc/letsencrypt/live/n8n.tybi.ai/privkey.pem
# And replaced /etc/nginx/sites-available/n8n with an SSL‐enabled config.

# (c) Test & reload Nginx again so HTTPS is live
nginx -t && systemctl reload nginx

# ---------------------------------------------------
# 6) Final: verify n8n is healthy
# ---------------------------------------------------

if curl -sS http://localhost:5678/healthz; then
  echo "n8n health check succeeded"
else
  echo "ERROR: n8n health check failed" >&2
  exit 1
fi

echo "[$(date)] Bootstrap complete"
