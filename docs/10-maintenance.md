# 10 — Maintenance

A working email server needs ongoing attention to stay working. This phase covers the routine tasks: updates, backups, log review, and monitoring rituals.

## Update cadence

Mailcow releases updates regularly — bug fixes, security patches, occasional feature additions. The community recommendation is to update **monthly**.

```bash
cd /opt/mailcow-dockerized
./update.sh
```

The script:

- Pulls latest mailcow-dockerized git changes
- Pulls updated Docker images
- Restarts containers in dependency order
- Reports any post-update actions needed

Allow 5–10 minutes for the full update. The mail server is briefly unavailable during container restarts; in-flight messages queue and are delivered after restart completes.

After updating, verify health:

```bash
docker compose ps --format 'table {{.Service}}\t{{.Status}}' | grep -v healthy | grep -v "Up"
```

Empty output is healthy. Any output identifies a problem container.

**When not to update:** Right before sending important mail, or right before leaving for vacation. If something breaks during update, debugging takes time. Update on quiet evenings when there is recovery window.

## OS updates

Ubuntu security updates are independent of Mailcow updates:

```bash
apt update && apt upgrade -y

# Reboot if kernel updated
[ -f /var/run/reboot-required ] && reboot
```

Reboots are disruptive — Mailcow takes 1–2 minutes to fully restart. Schedule them deliberately.

For unattended security patches:

```bash
apt install -y unattended-upgrades
dpkg-reconfigure --priority=low unattended-upgrades
```

Configure `/etc/apt/apt.conf.d/50unattended-upgrades` to apply security updates automatically but require manual reboots.

## Backups

The deployment relies on two backup layers:

### Layer 1 — Cloud provider snapshots

Hetzner Cloud Backups (or equivalent) take daily snapshots of the entire VM and retain 7 days. This is the primary disaster recovery mechanism.

Cost: ~20% of VPS price (~€1/month for a CAX11).

To restore: Hetzner Cloud Console → Server → Backups → select snapshot → Restore. Takes 5 minutes.

### Layer 2 — Mailcow backups

Mailcow's built-in backup script captures application data (mailboxes, configuration, DKIM keys, MariaDB dump). Useful when the VM itself is healthy but specific data needs to be restored.

```bash
cd /opt/mailcow-dockerized
./helper-scripts/backup_and_restore.sh backup all --delete-days 14
```

Daily cron schedule:

```bash
crontab -e

# Add:
0 4 * * * cd /opt/mailcow-dockerized && ./helper-scripts/backup_and_restore.sh backup all --delete-days 14 > /var/log/mailcow-backup.log 2>&1
```

Backups are written to `/var/backups/` by default. For off-site backup, sync to S3 / Backblaze / another server:

```bash
# Example with rclone to S3
rclone sync /var/backups/mailcow/ s3:my-mailcow-backups/
```

Restore:

```bash
./helper-scripts/backup_and_restore.sh restore
```

## SSL certificate renewal

Mailcow's ACME container renews Let's Encrypt certificates automatically every 60 days. No manual action is needed.

If certificates fail to renew, the ACME container logs the reason:

```bash
docker compose logs acme-mailcow --tail 50
```

Common causes:
- DNS record changed and no longer matches expected IP
- Port 80 blocked (Let's Encrypt verifies via HTTP)
- Rate limit hit (Let's Encrypt enforces per-domain limits)

The certificate is also visible in Mailcow Admin: **System → Configuration → Configuration & Details → Encryption**.

## Log review

Mailcow logs are stored inside containers. Useful one-liners:

**Postfix delivery activity:**

```bash
docker compose logs postfix-mailcow --tail 200 --follow
```

**Rspamd spam scoring:**

```bash
docker compose logs rspamd-mailcow --tail 200 --follow
```

**SOGo webmail activity:**

```bash
docker compose logs sogo-mailcow --tail 100
```

**ACME / SSL renewal:**

```bash
docker compose logs acme-mailcow --tail 100
```

The Mailcow Admin UI also exposes logs under **System → Logs**, with filtering and search.

## Mail queue

The mail queue holds outbound messages that haven't been delivered yet — usually because the receiver is temporarily unavailable. Postfix retries automatically.

Inspect the queue:

```bash
docker compose exec postfix-mailcow postqueue -p
```

Empty output (`Mail queue is empty`) means all sent mail has been accepted by recipients. Persistent items in the queue indicate ongoing delivery problems.

Force immediate delivery attempt for all queued mail:

```bash
docker compose exec postfix-mailcow postqueue -f
```

Delete a specific message from the queue:

```bash
docker compose exec postfix-mailcow postsuper -d MESSAGE_ID
```

A queue with hundreds of items waiting for one specific recipient suggests that recipient is rejecting; check logs to confirm.

## Disk usage monitoring

Mail storage and logs grow over time. Monitor regularly:

```bash
df -h /
du -sh /var/lib/docker/volumes/mailcowdockerized_*
```

Common large volumes:

- `vmail-vol-1` — actual mail storage
- `mysql-vol-1` — database (mostly metadata)
- `clamd-db-vol-1` — virus definitions (rebuilt regularly)
- `rspamd-vol-1` — spam learning data

When disk approaches 80%, action is needed:

1. **Increase disk size** — Hetzner allows attaching block storage volumes
2. **Identify large mailboxes** — in Mailcow Admin, sort by quota usage
3. **Archive old mail** — move old folders out of mail storage

## Health check script

A daily script that summarizes server health, run via cron and emailed to `postmaster@`:

```bash
#!/bin/bash
# /usr/local/bin/mailcow-health-check.sh

cd /opt/mailcow-dockerized

echo "=== $(date) — Mailcow Health Report ==="
echo

echo "=== Container status ==="
UNHEALTHY=$(docker compose ps --format 'table {{.Service}}\t{{.Status}}' | grep -v healthy | grep -v "Up" | tail -n +2)
if [ -z "$UNHEALTHY" ]; then
    echo "All containers healthy."
else
    echo "PROBLEMS DETECTED:"
    echo "$UNHEALTHY"
fi
echo

echo "=== Disk usage ==="
df -h /
echo

echo "=== Memory ==="
free -h
echo

echo "=== Mail queue ==="
docker compose exec -T postfix-mailcow postqueue -p | tail -3
echo

echo "=== Recent rejections (last 24h) ==="
docker compose logs postfix-mailcow --since 24h | grep -iE "reject|bounce" | wc -l
echo "rejections logged"
echo

echo "=== Certificate expiry ==="
echo | openssl s_client -servername mail.example.com -connect mail.example.com:443 2>/dev/null | openssl x509 -noout -dates
```

Cron entry:

```
0 8 * * * /usr/local/bin/mailcow-health-check.sh | mail -s "Mailcow health" postmaster@example.com
```

A reference implementation is in [scripts/](../scripts/) of this repository.

## Weekly review

Worth doing every Monday:

- Open Google Postmaster Tools — review spam rate, reputation, authentication
- Open Microsoft SNDS — confirm filter result is Green
- Scan Mailcow Admin → System → Logs for unusual entries
- Check `df -h` — disk trending toward full?
- Review `postmaster@` mailbox for unusual reports

This takes 5 minutes and catches drifts early.

## Quarterly review

Every three months:

- Review user mailboxes — any inactive ones to deactivate?
- Review aliases — still needed?
- Review domain quotas — adjust based on growth
- Test backups — pick a random day's backup and verify it restores
- Update runbook documentation (if changes were made)
- Review SSL certificate auto-renewal logs

## Annual review

Annually:

- Rotate DKIM keys (generate new selector, publish, switch, retire old)
- Review DMARC policy — should be at `p=reject` by now
- Review TLS settings — disable deprecated ciphers
- Audit admin and user 2FA — recovery codes still secure?
- Review IP reputation history in Postmaster Tools — any incidents?

## When to migrate

Self-hosted email scales well to ~50–100 mailboxes on a single CAX11. Beyond that, performance starts to suffer.

Triggers for upgrade:

- RAM consistently above 90%
- Disk usage above 80%
- Mail queue persistently has items
- Webmail (SOGo) feels slow
- Multiple mailboxes hitting rate limits

Path forward:

1. **Vertical scale first** — upgrade VPS to CAX21 (8GB RAM) or CAX31 (16GB RAM). Hetzner allows in-place resize.
2. **Add a Volume** — attach Hetzner block storage for mail, freeing the OS disk.
3. **Horizontal scale** — Mailcow does not natively cluster. For higher loads, consider hosted alternatives or commercial mail platforms.

## When to migrate away

Self-hosted email is not for everyone forever. Reasons to migrate to hosted email:

- Personal time has become more valuable than €5–6/user/month savings
- Reliability requirements exceed what one operator can provide
- Compliance requirements need an enterprise email vendor
- Family / business growth pushes mailbox count past comfortable scale

Migration tools:

- **imapsync** — copies mail from any IMAP source to any IMAP target
- **Mailcow's helper scripts** — export/import mailbox data

Migration is straightforward but slow for large mailboxes; allow a weekend.

## Summary

Routine operation of a self-hosted email server is mostly automation:

- Cloud backups: automatic daily
- Mailcow application backups: automatic daily via cron
- SSL renewal: automatic every 60 days
- OS security updates: automatic if unattended-upgrades is configured

Active work amounts to ~30 minutes per month:

- Mailcow updates (10 min)
- Weekly Postmaster Tools / SNDS check (5 min × 4 = 20 min)
- Occasional log review when something looks off

This is the genuine cost of self-hosting once everything is running. The setup is the demanding part; operation is mostly observing and occasionally responding.

---

## End of guide

The deployment described across these ten phases produces a self-hosted email server with:

- Production-grade authentication (SPF, DKIM, DMARC, MTA-STS, TLS-RPT, DNSSEC)
- Encrypted transport (TLS 1.2/1.3, MTA-STS enforce)
- Direct monitoring via three major receivers (Google, Microsoft, Mail-Tester)
- Realistic operational expectations (warmup, ProtonMail, Gmail behavior)
- Backup and update cadence appropriate for ongoing reliability

For most small businesses with 5–20 mailboxes, this delivers email infrastructure equivalent in quality to hosted services at ~10% the cost. For individuals seeking data sovereignty and infrastructure understanding, it provides both.

Issues, corrections, and contributions to this guide are welcome via GitHub.
