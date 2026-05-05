# Twenty CRM Upgrade Plan: current → v2.2.0

Target: `crm.eaternity.org` running on Exoscale CH-ZH-1 at `/opt/twenty`.

This plan is rollback-first. Each phase has a STOP gate — do not proceed
to the next phase if the current one shows any unexpected behaviour.

---

## License & cost note (verified 2026-05-05)

v2.2.0 is **AGPLv3 for everything Eaternity uses**. Enterprise-licensed
features (SAML/OIDC SSO, row-level permissions, Cloudflare-managed
custom domain, Stripe billing, audit-log retention) are gated behind
`ENTERPRISE_KEY` — leave it unset and they're inactive. Default
`IS_BILLING_ENABLED=false`. No usage caps, no user limit, no trial
expiration. Self-hosted continues to be free indefinitely.

What we use today (Google SSO, Companies, People, Opportunities, custom
objects, GraphQL/REST, Gmail/Calendar sync, workflows, Page Layouts) is
all AGPL. The bug fix we want (page-layout missing-fields after 1.23
backfill, the `useCache` error, the broken Layout-Anpassung mode) is in
the AGPL bucket too.

---

## Why we're upgrading

Symptoms on current version:
- After Twenty's introduction of the new PageLayout system (~v1.23),
  some company fields (`recontactDate`, `recontactReason`,
  `recontactComment`, `onboardingStatus`, `clientStatus`) are not
  rendered as cards on the company detail page, even though the data
  exists and the API returns it.
- Frontend throws `Unhandled Promise Rejection: TypeError: undefined
  is not an object (evaluating 'e.useCache')`.
- "Layout-Anpassung" edit-mode banner appears but no handles work.

Upstream commits that address these symptoms (all post-v1.23):

- `4fa2c400c0` fix(server): skip standard page layout widgets
  referencing missing field metadatas during 1.23 backfill
- `0696290af4` fix(page-layout): hide deactivated fields from FIELDS
  widget and layout editor
- `876214bc1d` scaffold record page layout + fields view when adding
  an object
- `9a9daf77ca` Keep fallback record page layouts read-only in edition mode
- `aa4aea0f9b` Fix layout edition mode dark mode text color
- `0bb345b75f` Fix empty record page on system objects for non-English
  workspace members

Current fork HEAD: `v1.15.0-93-g4fb92404aa` (~2,196 commits behind
upstream/main). Latest stable tag: **v2.2.0**.

---

## Phase 0 — Discovery (BEFORE picking a maintenance window)

Without this we're flying blind. Need to know exactly what's running.

```bash
ssh ubuntu@crm.eaternity.org
cd /opt/twenty

# What's actually running right now?
sudo docker ps --format 'table {{.Names}}\t{{.Image}}'
sudo docker inspect $(sudo docker ps -q --filter "name=server") \
  --format '{{.Image}} {{.Config.Image}}'
sudo docker images twentycrm/twenty --digests

# Disk space (need ~2x DB size free for snapshot + staging)
df -h /var/lib/docker /opt/twenty
sudo docker system df

# DB size
sudo docker compose exec db \
  psql -U postgres -d default -c \
  "SELECT pg_size_pretty(pg_database_size('default'));"

# Existing backup state
ls -lah backups/ 2>/dev/null | tail -10
cat backup.sh 2>/dev/null
crontab -l 2>/dev/null
sudo crontab -l 2>/dev/null

# Capture all of the above into one file
sudo tee UPGRADE_NOTES.txt <<'EOF'
DISCOVERY OUTPUT:
EOF
# (paste relevant lines)
```

**STOP gate.** Before continuing:
- [ ] Confirm the running tag/digest is recorded in `UPGRADE_NOTES.txt`.
- [ ] Confirm there is at least 2× the DB size free on disk.
- [ ] If running version is *very* old (pre-v1.20), the v2.2.0 jump may
      need a v1.23.x intermediate stop. Decide before starting Phase 3.

---

## Phase 1 — Safety net (~30 min, day-of)

### 1.1 Schedule maintenance window
- Pick a low-traffic time.
- Inform anyone using the CRM.
- Stop the local sync agent so it doesn't write during the upgrade:
  ```bash
  # On Manuel's laptop:
  launchctl unload ~/Library/LaunchAgents/com.twenty.sync.plist
  ```

### 1.2 Pin current version explicitly
```bash
cd /opt/twenty
CURRENT_TAG=$(grep ^TAG .env | cut -d= -f2)   # may be empty (= "latest")
CURRENT_DIGEST=$(sudo docker inspect $(sudo docker ps -q --filter name=server) \
  --format '{{.Image}}')
echo "PRE_UPGRADE_TAG=$CURRENT_TAG"          | sudo tee -a UPGRADE_NOTES.txt
echo "PRE_UPGRADE_DIGEST=$CURRENT_DIGEST"    | sudo tee -a UPGRADE_NOTES.txt

# Find which human tag matches that digest, write to .env
sudo docker images twentycrm/twenty --digests \
  | grep ${CURRENT_DIGEST#sha256:} | head -3
# Then explicitly pin .env to whatever tag was found:
# sudo sed -i 's/^TAG=.*//' .env  # remove old line
# echo "TAG=v1.X.Y" | sudo tee -a .env
```
Pinning gives us a known rollback target instead of `latest` (which
could move underneath us).

### 1.3 Full backup (DB + volumes + config)
```bash
cd /opt/twenty
TS=$(date +%Y%m%d-%H%M)
sudo mkdir -p backups/pre-upgrade-$TS

# Layer A: pg_dump (logical, portable)
sudo docker compose exec -T db pg_dump -U postgres -Fc -d default \
  | sudo tee backups/pre-upgrade-$TS/db.dump > /dev/null
sudo docker compose exec -T db pg_dumpall -U postgres --globals-only \
  | sudo tee backups/pre-upgrade-$TS/globals.sql > /dev/null

# Layer B: physical volume snapshot (fastest restore)
sudo docker compose down                # downtime begins HERE
sudo tar czf backups/pre-upgrade-$TS/db-data.tar.gz \
  -C /var/lib/docker/volumes/twenty_db-data/_data .
sudo tar czf backups/pre-upgrade-$TS/server-local-data.tar.gz \
  -C /var/lib/docker/volumes/twenty_server-local-data/_data .

# Layer C: config
sudo cp .env backups/pre-upgrade-$TS/.env
sudo cp docker-compose.yml backups/pre-upgrade-$TS/docker-compose.yml

# Verify size makes sense
sudo ls -lah backups/pre-upgrade-$TS/

# Bring service back up while we prepare staging in Phase 2
sudo docker compose up -d
curl -sf https://crm.eaternity.org/healthz && echo OK
```

### 1.4 Off-host backup copy
```bash
# From Manuel's laptop:
mkdir -p ~/twenty-backups/
scp -r ubuntu@crm.eaternity.org:/opt/twenty/backups/pre-upgrade-$TS \
  ~/twenty-backups/
```

**STOP gate.** Before continuing:
- [ ] `db.dump` is non-zero, restorable file (run `pg_restore -l` on
      laptop copy to verify).
- [ ] `db-data.tar.gz` is roughly the size of the DB volume.
- [ ] Off-host copy completed.
- [ ] Original service running again on same TAG.

---

## Phase 2 — Staging rehearsal (~1 hour, mandatory)

We do not test migrations on production first. We clone to a sibling
docker-compose project on the same host.

### 2.1 Set up staging directory
```bash
cd /opt
sudo mkdir -p twenty-staging
sudo cp /opt/twenty/.env /opt/twenty-staging/.env
sudo cp /opt/twenty/docker-compose.yml /opt/twenty-staging/docker-compose.yml
cd /opt/twenty-staging
```

### 2.2 Edit staging compose for isolation
Edit `/opt/twenty-staging/docker-compose.yml`:
- Change top `name: twenty` → `name: twenty-staging`
- Change server `ports: "3000:3000"` → `ports: "3001:3000"`
- Change `volumes: db-data` → `volumes: db-data-staging`
- Change `volumes: server-local-data` → `volumes: server-local-data-staging`
- At bottom, replace the `volumes:` block with the renamed names

```bash
# Sanity check
sudo docker compose -p twenty-staging config | grep -E "image:|ports:|name"
```

### 2.3 Restore prod snapshot into staging
```bash
cd /opt/twenty-staging

# Start ONLY db
sudo docker compose -p twenty-staging up -d db
sleep 10
sudo docker compose -p twenty-staging exec -T db \
  pg_isready -U postgres

# Restore from logical dump
sudo docker compose -p twenty-staging exec -T db \
  pg_restore -U postgres -d default --clean --if-exists \
  < /opt/twenty/backups/pre-upgrade-$TS/db.dump

# Confirm row counts match prod (rough sanity)
sudo docker compose -p twenty-staging exec -T db \
  psql -U postgres -d default -c \
  "SELECT count(*) FROM core.\"workspace\";"
```

### 2.4 Upgrade staging to v2.2.0
```bash
cd /opt/twenty-staging
sudo sed -i 's/^TAG=.*//' .env
echo "TAG=v2.2.0" | sudo tee -a .env

sudo docker compose -p twenty-staging pull
sudo docker compose -p twenty-staging up -d

# Watch migration logs — this is the moment of truth
sudo docker compose -p twenty-staging logs -f server \
  | tee /tmp/staging-upgrade.log \
  | grep -iE "migrat|error|fatal|listen"
# Ctrl-C once you see "Application is running on" or equivalent
```

### 2.5 Verify staging
```bash
# Healthcheck
curl -sf http://localhost:3001/healthz && echo OK

# Hit GraphQL (anonymous endpoint that confirms server is up)
curl -s http://localhost:3001/graphql -H "Content-Type: application/json" \
  -d '{"query":"{ __typename }"}'
```

In a browser (with a temporary `crm-staging.eaternity.org` host entry,
or direct IP:3001):
- [ ] Login works (use existing Google SSO).
- [ ] Open Mercedes-Benz AG. **Do recontact / onboarding / clientStatus
      cards now appear?** This is the actual test.
- [ ] Browser console: no `useCache` error.
- [ ] Layout-Anpassung mode shows working drag handles.
- [ ] Run from laptop:
      `node ~/workspace/twenty-integrations/production/sync/sync-companies.js --dry-run`
      against staging. (Set `TWENTY_API_URL=http://staging-host:3001` in
      a temporary `.env`.) Confirm GraphQL schema still matches sync code.
- [ ] Custom objects present: `license`, `inboundRequest`,
      `monthlyMetric`, `companyPartner`.
- [ ] Spot-check one workflow runs.

### 2.6 Tear down staging
```bash
cd /opt/twenty-staging
sudo docker compose -p twenty-staging down -v   # -v removes staging volumes
cd /opt
sudo rm -rf /opt/twenty-staging
```

**STOP gate.** Before continuing:
- [ ] Migration completed without errors in staging.
- [ ] Missing fields are actually visible in staging (otherwise this
      upgrade does NOT solve the original problem — investigate
      before touching prod).
- [ ] Sync script `--dry-run` against staging shows no schema breakage.

---

## Phase 3 — Production upgrade (~15 min downtime)

Only after Phase 2 succeeded.

```bash
cd /opt/twenty

# 1. Stop server + worker (leave db running so no cold start)
sudo docker compose stop server worker

# 2. Update tag
sudo sed -i 's/^TAG=.*//' .env
echo "TAG=v2.2.0" | sudo tee -a .env
grep ^TAG .env

# 3. Defensive: confirm no enterprise key is set, billing is off
grep -E "^ENTERPRISE_KEY|^IS_BILLING_ENABLED" .env || \
  echo "(no enterprise/billing flags set — good)"

# 4. Pull new image (server pulls; worker uses same image)
sudo docker compose pull server

# 5. Bring server up — this triggers DB migration on startup
sudo docker compose up -d server

# 6. Tail logs until migrations complete
sudo docker compose logs -f server | tee /tmp/prod-upgrade.log
# Look for: migration messages, then "Application is running on"
# Ctrl-C once steady-state.

# 7. Healthcheck
curl -sf https://crm.eaternity.org/healthz && echo OK

# 8. Bring up worker
sudo docker compose up -d worker
sudo docker compose ps
```

**STOP gate.** Before continuing:
- [ ] `/healthz` returns ok.
- [ ] No errors with severity `ERROR` or `FATAL` in
      `/tmp/prod-upgrade.log`.
- [ ] All four containers (`server`, `worker`, `db`, `redis`) show
      `Up (healthy)`.

---

## Phase 4 — Verification

Hit each in order. STOP and rollback if any fails.

1. [ ] `curl -sf https://crm.eaternity.org/healthz` → `ok`.
2. [ ] Login page loads, Google SSO works for `@eaternity.org`.
3. [ ] Companies list view loads, all 4,833 companies visible, count matches.
4. [ ] Open **Mercedes-Benz AG**:
   - timeline shows historical events
   - **recontact / onboarding / clientStatus cards now visible** (the
     original bug).
5. [ ] Open browser devtools console — no `useCache` error on company
   detail page.
6. [ ] Click into Layout-Anpassung mode — drag handles work, you can
   reorder fields and save.
7. [ ] From laptop, dry-run sync:
   ```bash
   cd ~/workspace/twenty-integrations
   node production/sync/sync-companies.js --dry-run
   ```
   Should report no schema mismatches.
8. [ ] Custom objects intact (verify in Settings → Data Model):
   `license`, `inboundRequest`, `monthlyMetric`, `companyPartner`,
   `eatenityProduct`, `frameworkAgreement`, `kitchen`, `supplier`,
   `pricing`, `billing`, `billingAddress`, `contract`, `dashboard`,
   `dashboardKpi`, `empcoComplaint`, `foodProduct`.
9. [ ] Spot-check one record from each custom object opens without
   errors.
10. [ ] Re-enable local sync agent on Manuel's laptop:
    ```bash
    launchctl load ~/Library/LaunchAgents/com.twenty.sync.plist
    ```
    Wait one cycle (≤15 min), confirm it succeeds:
    ```bash
    cat ~/workspace/twenty-integrations/logs/sync-status.json
    ```

If all green: upgrade complete. Update `UPGRADE_NOTES.txt` with
final state and date.

---

## Rollback procedure

Two options. Pick based on what broke.

### Option A — App-only rollback (~3 min)
**Only safe if no DB schema changes were applied.** For v1.x → v2.x this
is almost never safe — assume Option B.
```bash
cd /opt/twenty
sudo sed -i 's/^TAG=.*//' .env
# Restore previous TAG line from backups/pre-upgrade-$TS/.env
sudo grep ^TAG backups/pre-upgrade-$TS/.env >> .env
sudo docker compose pull
sudo docker compose up -d
curl -sf https://crm.eaternity.org/healthz && echo OK
```

### Option B — Full DB restore (~15 min) [DEFAULT for v1→v2]
```bash
cd /opt/twenty
sudo docker compose down

# Wipe the migrated volume contents
sudo rm -rf /var/lib/docker/volumes/twenty_db-data/_data/*

# Restore physical snapshot (fastest)
sudo tar xzf backups/pre-upgrade-$TS/db-data.tar.gz \
  -C /var/lib/docker/volumes/twenty_db-data/_data

# Pin original tag from backed-up .env
sudo cp backups/pre-upgrade-$TS/.env .env

# Bring back up
sudo docker compose up -d
curl -sf https://crm.eaternity.org/healthz && echo OK
```

If physical restore has issues, fall back to logical:
```bash
sudo docker compose up -d db
sudo docker compose exec -T db dropdb -U postgres default
sudo docker compose exec -T db createdb -U postgres default
sudo docker compose exec -T db pg_restore -U postgres -d default \
  < backups/pre-upgrade-$TS/db.dump
sudo docker compose up -d
```

After rollback:
- [ ] Confirm running tag matches `PRE_UPGRADE_TAG` in `UPGRADE_NOTES.txt`.
- [ ] Confirm `/healthz` ok.
- [ ] Companies list loads, sample record opens.
- [ ] Re-enable local sync agent.

---

## Risk-control summary

| Principle | How applied |
|---|---|
| Pin versions, never `latest` | `TAG=v2.2.0` explicitly in `.env`. |
| Always rehearse on a clone | Phase 2 is mandatory, not optional. |
| Multi-layer backup | pg_dump + volume tar + off-host copy. |
| Treat migrations as one-way | Default rollback is Option B (DB restore), not image revert. |
| Stop external writers | Local sync agent off during the window. |
| Decision gates | Each phase ends with a STOP checklist. |
