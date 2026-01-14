# Twenty CRM Deployment Plan for Eaternity

## Overview

- **Provider**: Exoscale (Swiss company)
- **Datacenter**: CH-ZH-1 (Zurich, Switzerland)
- **Data Protection**: Swiss FADP law
- **Estimated Cost**: ~CHF 60-70/month

---

## Security Configuration

| Setting | Value |
|---------|-------|
| Single workspace mode | Enabled |
| Google SSO | Enabled (only @eaternity.org) |
| Domain restriction | eaternity.org |
| Public invite links | Disabled |
| Email verification | Required |

---

## Deployment Steps

### Step 1: Create Exoscale Account & Instance

1. Sign up at https://portal.exoscale.com/register

2. **Create Security Group** (Firewall):
   - Go to Compute → Security Groups → Add
   - Name: `twenty-crm`
   - Add rules:
     - TCP 22 (SSH)
     - TCP 80 (HTTP)
     - TCP 443 (HTTPS)

3. **Create Compute Instance**:
   - Zone: `CH-ZH-1` (Zurich)
   - Template: Ubuntu 24.04 LTS
   - Type: Standard Large (4 vCPU, 8GB RAM)
   - Disk: 50GB SSD
   - Security Group: `twenty-crm`
   - SSH Key: Add your public key

4. Note the IP address

---

### Step 2: Configure DNS

Add A record:
```
A    crm.eaternity.org    →    YOUR_INSTANCE_IP
```

---

### Step 3: Deploy Twenty CRM

```bash
ssh ubuntu@YOUR_INSTANCE_IP

# Run deployment script
curl -sL https://raw.githubusercontent.com/mklarmann/twenty/main/packages/twenty-docker/deploy-exoscale.sh | sudo bash
```

---

### Step 4: Configure Google OAuth

#### 4a. Create Google Cloud OAuth Credentials

1. Go to https://console.cloud.google.com/
2. Create project "Eaternity CRM"
3. Go to APIs & Services → OAuth consent screen
   - Choose **Internal** (only Eaternity users)
   - App name: "Eaternity CRM"
   - Authorized domain: `eaternity.org`
4. Go to APIs & Services → Credentials
5. Create Credentials → OAuth client ID
   - Type: Web application
   - Name: "Twenty CRM"
   - Authorized redirect URIs:
     ```
     https://crm.eaternity.org/auth/google/redirect
     https://crm.eaternity.org/auth/google-apis/get-access-token
     ```
6. Copy Client ID and Client Secret

#### 4b. Enable Google APIs

Enable these APIs in Google Cloud Console:
- Gmail API
- Google Calendar API
- People API

#### 4c. Create Gmail App Password

1. Go to https://myaccount.google.com/security
2. Enable 2-Factor Authentication
3. Go to App passwords
4. Create app password for "Mail"
5. Copy the 16-character password

---

### Step 5: Update .env File

```bash
cd /opt/twenty
sudo nano .env
```

Replace these values:
```
AUTH_GOOGLE_CLIENT_ID=your-client-id.apps.googleusercontent.com
AUTH_GOOGLE_CLIENT_SECRET=your-secret
EMAIL_SMTP_USER=crm@eaternity.org
EMAIL_SMTP_PASSWORD=your-gmail-app-password
```

---

### Step 6: Start Twenty CRM

```bash
cd /opt/twenty
sudo docker compose up -d

# Watch logs (wait ~2 min for first startup)
sudo docker compose logs -f
```

---

### Step 7: First Login & Security Setup

1. Open https://crm.eaternity.org
2. Click "Continue with Google"
3. Sign in with @eaternity.org account (first user = admin)
4. Go to Settings → Security:
   - **Disable** "Public Invite Link"
   - Add **Approved Domain**: `eaternity.org`
   - Verify domain via email

---

## Files Created

| File | Location | Purpose |
|------|----------|---------|
| `deploy-exoscale.sh` | `packages/twenty-docker/` | Deployment script |
| `.env` | `/opt/twenty/` (on server) | Configuration |
| `backup.sh` | `/opt/twenty/` (on server) | Daily backup script |

---

## Useful Commands

```bash
cd /opt/twenty

# View logs
docker compose logs -f

# Restart services
docker compose restart

# Stop services
docker compose down

# Update to latest version
docker compose pull && docker compose up -d

# Manual backup
./backup.sh

# View backups
ls -la backups/
```

---

## Backup Strategy

- Automatic daily backups at 2 AM (via cron)
- Backups stored in `/opt/twenty/backups/`
- Last 7 days retained
- Manual backup: `./backup.sh`

---

## Support

- Twenty docs: https://docs.twenty.com
- Twenty GitHub: https://github.com/twentyhq/twenty
- Exoscale docs: https://community.exoscale.com/documentation/

---

## TODO Before Deploying

- [ ] Create Exoscale account
- [ ] Create Google Cloud project & OAuth credentials
- [ ] Create Gmail App Password for SMTP
- [ ] Set up DNS A record for crm.eaternity.org
- [ ] Run deployment script
- [ ] Configure .env with credentials
- [ ] Start Twenty and verify
- [ ] Disable public invite links
- [ ] Add eaternity.org as approved domain
