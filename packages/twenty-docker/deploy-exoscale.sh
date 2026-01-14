#!/bin/bash
# =============================================================================
# Twenty CRM - Exoscale Zurich Deployment Script for Eaternity
# =============================================================================
#
# Prerequisites:
# 1. Create an Exoscale account at https://portal.exoscale.com/register
#
# 2. Create a Compute Instance:
#    - Zone: CH-ZH-1 (Zurich)
#    - Template: Ubuntu 24.04 LTS
#    - Instance Type: Standard Large (4 vCPU, 8GB RAM)
#    - Disk: 50GB SSD (or more)
#    - Security Group: Create one with ports 22, 80, 443 open
#    - SSH Key: Add your public key
#
# 3. Point your domain to the instance IP:
#    - A record: crm.eaternity.org -> YOUR_INSTANCE_IP
#
# 4. SSH into your instance and run this script:
#    ssh ubuntu@YOUR_INSTANCE_IP
#    curl -sL https://raw.githubusercontent.com/mklarmann/twenty/main/packages/twenty-docker/deploy-exoscale.sh | sudo bash
#
# =============================================================================

set -e

echo "=========================================="
echo "Twenty CRM Deployment for Eaternity"
echo "Exoscale Zurich (CH-ZH-1)"
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
  echo -e "${RED}Please run as root (use sudo)${NC}"
  exit 1
fi

echo -e "${GREEN}[1/8] Updating system...${NC}"
apt-get update && apt-get upgrade -y

echo -e "${GREEN}[2/8] Installing required packages...${NC}"
apt-get install -y curl gnupg2 ca-certificates lsb-release ubuntu-keyring

echo -e "${GREEN}[3/8] Installing Docker...${NC}"
if ! command -v docker &> /dev/null; then
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker
  systemctl start docker
  # Add ubuntu user to docker group
  usermod -aG docker ubuntu || true
else
  echo "Docker already installed"
fi

echo -e "${GREEN}[4/8] Installing Caddy (reverse proxy with auto-SSL)...${NC}"
if ! command -v caddy &> /dev/null; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
  apt-get update
  apt-get install -y caddy
else
  echo "Caddy already installed"
fi

echo -e "${GREEN}[5/8] Configuring firewall (UFW)...${NC}"
if command -v ufw &> /dev/null; then
  ufw allow 22/tcp   # SSH
  ufw allow 80/tcp   # HTTP
  ufw allow 443/tcp  # HTTPS
  ufw --force enable
fi

echo -e "${GREEN}[6/8] Creating installation directory...${NC}"
mkdir -p ${INSTALL_DIR}
cd ${INSTALL_DIR}

echo -e "${GREEN}[7/8] Downloading Twenty docker-compose...${NC}"
curl -sL https://raw.githubusercontent.com/twentyhq/twenty/main/packages/twenty-docker/docker-compose.yml -o docker-compose.yml

echo -e "${GREEN}[8/8] Creating .env file...${NC}"

# Generate secrets
APP_SECRET=$(openssl rand -base64 32)
PG_PASSWORD=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)

cat > .env << EOF
# =============================================================================
# Twenty CRM Production Configuration for Eaternity
# Hosted on Exoscale Zurich (CH-ZH-1) - Swiss Data Protection
# Generated on: $(date)
# =============================================================================

TAG=latest

# =============================================================================
# DATABASE (PostgreSQL)
# =============================================================================
PG_DATABASE_USER=postgres
PG_DATABASE_PASSWORD=${PG_PASSWORD}
PG_DATABASE_HOST=db
PG_DATABASE_PORT=5432

# =============================================================================
# REDIS
# =============================================================================
REDIS_URL=redis://redis:6379

# =============================================================================
# SERVER URL
# =============================================================================
SERVER_URL=https://${DOMAIN}

# =============================================================================
# APP SECRET (auto-generated - keep this safe!)
# =============================================================================
APP_SECRET=${APP_SECRET}

# =============================================================================
# STORAGE
# =============================================================================
STORAGE_TYPE=local

# Optional: Exoscale Object Storage (S3-compatible)
# STORAGE_TYPE=s3
# STORAGE_S3_REGION=ch-zrh-1
# STORAGE_S3_NAME=eaternity-twenty-storage
# STORAGE_S3_ENDPOINT=https://sos-ch-zrh-1.exo.io

# =============================================================================
# AUTHENTICATION & SECURITY
# =============================================================================

# Single workspace mode (only Eaternity)
IS_MULTIWORKSPACE_ENABLED=false

# Require email verification
IS_EMAIL_VERIFICATION_REQUIRED=true

# Password auth as backup to Google SSO
AUTH_PASSWORD_ENABLED=true

# =============================================================================
# GOOGLE SSO - CONFIGURE THESE FROM GOOGLE CLOUD CONSOLE
# =============================================================================
AUTH_GOOGLE_ENABLED=true
AUTH_GOOGLE_CLIENT_ID=CHANGE_ME_YOUR_GOOGLE_CLIENT_ID
AUTH_GOOGLE_CLIENT_SECRET=CHANGE_ME_YOUR_GOOGLE_CLIENT_SECRET
AUTH_GOOGLE_CALLBACK_URL=https://${DOMAIN}/auth/google/redirect

# =============================================================================
# GOOGLE APIS (Gmail & Calendar sync)
# =============================================================================
MESSAGING_PROVIDER_GMAIL_ENABLED=true
CALENDAR_PROVIDER_GOOGLE_ENABLED=true
AUTH_GOOGLE_APIS_CALLBACK_URL=https://${DOMAIN}/auth/google-apis/get-access-token

# =============================================================================
# EMAIL CONFIGURATION (SMTP)
# =============================================================================
EMAIL_DRIVER=smtp
EMAIL_FROM_ADDRESS=crm@eaternity.org
EMAIL_FROM_NAME=Eaternity CRM
EMAIL_SYSTEM_ADDRESS=noreply@eaternity.org
EMAIL_SMTP_HOST=smtp.gmail.com
EMAIL_SMTP_PORT=587
EMAIL_SMTP_USER=CHANGE_ME_YOUR_EMAIL
EMAIL_SMTP_PASSWORD=CHANGE_ME_GMAIL_APP_PASSWORD

# =============================================================================
# API RATE LIMITING
# =============================================================================
API_RATE_LIMITING_SHORT_TTL_IN_MS=1000
API_RATE_LIMITING_SHORT_LIMIT=100
API_RATE_LIMITING_LONG_TTL_IN_MS=60000
API_RATE_LIMITING_LONG_LIMIT=500
EOF

# Configure Caddy reverse proxy
echo -e "${GREEN}Configuring Caddy reverse proxy with auto-SSL...${NC}"
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
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
    }

    # Logging
    log {
        output file /var/log/caddy/access.log
    }
}
EOF

# Create log directory
mkdir -p /var/log/caddy

# Restart Caddy
systemctl restart caddy

# Create backup script
cat > ${INSTALL_DIR}/backup.sh << 'BACKUP_EOF'
#!/bin/bash
# Twenty CRM Backup Script
BACKUP_DIR="/opt/twenty/backups"
DATE=$(date +%Y%m%d_%H%M%S)
mkdir -p ${BACKUP_DIR}

# Backup database
docker exec twenty-db-1 pg_dump -U postgres default > ${BACKUP_DIR}/twenty_db_${DATE}.sql

# Compress
gzip ${BACKUP_DIR}/twenty_db_${DATE}.sql

# Keep only last 7 days
find ${BACKUP_DIR} -name "*.sql.gz" -mtime +7 -delete

echo "Backup completed: ${BACKUP_DIR}/twenty_db_${DATE}.sql.gz"
BACKUP_EOF
chmod +x ${INSTALL_DIR}/backup.sh

# Add daily backup cron job
(crontab -l 2>/dev/null; echo "0 2 * * * ${INSTALL_DIR}/backup.sh") | crontab -

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
echo "  - AUTH_GOOGLE_CLIENT_ID     (from Google Cloud Console)"
echo "  - AUTH_GOOGLE_CLIENT_SECRET (from Google Cloud Console)"
echo "  - EMAIL_SMTP_USER           (your Gmail address)"
echo "  - EMAIL_SMTP_PASSWORD       (Gmail App Password)"
echo ""
echo -e "${YELLOW}Then start Twenty:${NC}"
echo ""
echo "  cd ${INSTALL_DIR}"
echo "  docker compose up -d"
echo ""
echo -e "${YELLOW}Monitor startup (wait ~2 min for first run):${NC}"
echo ""
echo "  docker compose logs -f"
echo ""
echo "=========================================="
echo -e "${GREEN}Generated credentials (SAVE THESE SECURELY!):${NC}"
echo "=========================================="
echo ""
echo "Database Password: ${PG_PASSWORD}"
echo "App Secret: ${APP_SECRET}"
echo ""
echo "=========================================="
echo -e "${GREEN}Deployment Info:${NC}"
echo "=========================================="
echo ""
echo "Provider:    Exoscale"
echo "Zone:        CH-ZH-1 (Zurich, Switzerland)"
echo "Data law:    Swiss FADP"
echo "URL:         https://${DOMAIN}"
echo ""
echo "=========================================="
echo -e "${GREEN}After starting, configure security:${NC}"
echo "=========================================="
echo ""
echo "1. Open https://${DOMAIN}"
echo "2. Sign in with Google (@eaternity.org account)"
echo "3. Go to Settings → Security"
echo "4. DISABLE 'Public Invite Link'"
echo "5. Add Approved Domain: eaternity.org"
echo ""
echo "=========================================="
echo -e "${GREEN}Useful commands:${NC}"
echo "=========================================="
echo ""
echo "  cd ${INSTALL_DIR}"
echo "  docker compose logs -f      # View logs"
echo "  docker compose restart      # Restart services"
echo "  docker compose down         # Stop services"
echo "  docker compose pull && docker compose up -d  # Update"
echo "  ./backup.sh                 # Manual backup"
echo ""
