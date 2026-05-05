#!/bin/bash
# =============================================================================
# Twenty CRM - DigitalOcean Deployment Script for Eaternity
# =============================================================================
#
# Prerequisites:
# 1. Create a DigitalOcean Droplet:
#    - Image: Ubuntu 24.04 LTS
#    - Plan: Premium AMD (8GB RAM / 4 vCPUs) - $56/mo
#    - Datacenter: Frankfurt (fra1) or Amsterdam (ams3) for EU
#    - Enable: Monitoring, IPv6
#    - Add your SSH key
#
# 2. Point your domain to the Droplet IP:
#    - A record: crm.eaternity.org -> YOUR_DROPLET_IP
#
# 3. SSH into your Droplet and run this script:
#    ssh root@YOUR_DROPLET_IP
#    curl -sL https://raw.githubusercontent.com/mklarmann/twenty/main/packages/twenty-docker/deploy-digitalocean.sh | bash
#
# =============================================================================

set -e

echo "=========================================="
echo "Twenty CRM Deployment for Eaternity"
echo "=========================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
INSTALL_DIR="/opt/twenty"
DOMAIN="${DOMAIN:-crm.eaternity.org}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root${NC}"
  exit 1
fi

echo -e "${GREEN}[1/7] Updating system...${NC}"
apt-get update && apt-get upgrade -y

echo -e "${GREEN}[2/7] Installing Docker...${NC}"
if ! command -v docker &> /dev/null; then
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker
  systemctl start docker
else
  echo "Docker already installed"
fi

echo -e "${GREEN}[3/7] Installing Caddy (reverse proxy with auto-SSL)...${NC}"
if ! command -v caddy &> /dev/null; then
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
  apt-get update
  apt-get install -y caddy
else
  echo "Caddy already installed"
fi

echo -e "${GREEN}[4/7] Creating installation directory...${NC}"
mkdir -p ${INSTALL_DIR}
cd ${INSTALL_DIR}

echo -e "${GREEN}[5/7] Downloading Twenty docker-compose...${NC}"
curl -sL https://raw.githubusercontent.com/twentyhq/twenty/main/packages/twenty-docker/docker-compose.yml -o docker-compose.yml

echo -e "${GREEN}[6/7] Creating .env file...${NC}"

# Generate secrets
APP_SECRET=$(openssl rand -base64 32)
PG_PASSWORD=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)

cat > .env << EOF
# =============================================================================
# Twenty CRM Production Configuration for Eaternity
# Generated on: $(date)
# =============================================================================

TAG=latest

# Database
PG_DATABASE_USER=postgres
PG_DATABASE_PASSWORD=${PG_PASSWORD}
PG_DATABASE_HOST=db
PG_DATABASE_PORT=5432

# Redis
REDIS_URL=redis://redis:6379

# Server URL (your domain with HTTPS via Caddy)
SERVER_URL=https://${DOMAIN}

# App Secret (auto-generated)
APP_SECRET=${APP_SECRET}

# Storage
STORAGE_TYPE=local

# =============================================================================
# AUTHENTICATION - CONFIGURE THESE MANUALLY
# =============================================================================

# Single workspace mode
IS_MULTIWORKSPACE_ENABLED=false

# Require email verification
IS_EMAIL_VERIFICATION_REQUIRED=true

# Password auth as backup
AUTH_PASSWORD_ENABLED=true

# Google SSO - GET THESE FROM GOOGLE CLOUD CONSOLE
AUTH_GOOGLE_ENABLED=true
AUTH_GOOGLE_CLIENT_ID=CHANGE_ME
AUTH_GOOGLE_CLIENT_SECRET=CHANGE_ME
AUTH_GOOGLE_CALLBACK_URL=https://${DOMAIN}/auth/google/redirect

# Google APIs (Gmail/Calendar sync)
MESSAGING_PROVIDER_GMAIL_ENABLED=true
CALENDAR_PROVIDER_GOOGLE_ENABLED=true
AUTH_GOOGLE_APIS_CALLBACK_URL=https://${DOMAIN}/auth/google-apis/get-access-token

# =============================================================================
# EMAIL - CONFIGURE FOR NOTIFICATIONS
# =============================================================================
EMAIL_DRIVER=smtp
EMAIL_FROM_ADDRESS=crm@eaternity.org
EMAIL_FROM_NAME=Eaternity CRM
EMAIL_SYSTEM_ADDRESS=noreply@eaternity.org
EMAIL_SMTP_HOST=smtp.gmail.com
EMAIL_SMTP_PORT=587
EMAIL_SMTP_USER=CHANGE_ME
EMAIL_SMTP_PASSWORD=CHANGE_ME

# Rate limiting
API_RATE_LIMITING_SHORT_TTL_IN_MS=1000
API_RATE_LIMITING_SHORT_LIMIT=100
API_RATE_LIMITING_LONG_TTL_IN_MS=60000
API_RATE_LIMITING_LONG_LIMIT=500
EOF

echo -e "${GREEN}[7/7] Configuring Caddy reverse proxy...${NC}"
cat > /etc/caddy/Caddyfile << EOF
${DOMAIN} {
    reverse_proxy localhost:3000

    # Enable compression
    encode gzip

    # Security headers
    header {
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        Referrer-Policy strict-origin-when-cross-origin
    }
}
EOF

# Restart Caddy to apply config
systemctl restart caddy

echo ""
echo "=========================================="
echo -e "${GREEN}Installation complete!${NC}"
echo "=========================================="
echo ""
echo -e "${YELLOW}IMPORTANT: Before starting Twenty, edit the .env file:${NC}"
echo ""
echo "  cd ${INSTALL_DIR}"
echo "  nano .env"
echo ""
echo "Update these values:"
echo "  - AUTH_GOOGLE_CLIENT_ID"
echo "  - AUTH_GOOGLE_CLIENT_SECRET"
echo "  - EMAIL_SMTP_USER"
echo "  - EMAIL_SMTP_PASSWORD"
echo ""
echo -e "${YELLOW}Then start Twenty:${NC}"
echo ""
echo "  cd ${INSTALL_DIR}"
echo "  docker compose up -d"
echo ""
echo -e "${YELLOW}Monitor logs:${NC}"
echo ""
echo "  docker compose logs -f"
echo ""
echo "=========================================="
echo "Generated credentials (SAVE THESE!):"
echo "=========================================="
echo "Database Password: ${PG_PASSWORD}"
echo "App Secret: ${APP_SECRET}"
echo ""
echo "Your CRM will be available at: https://${DOMAIN}"
echo ""
