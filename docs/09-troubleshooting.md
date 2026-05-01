# 09 — Troubleshooting

Common issues encountered during deployment and operation, with realistic solutions.

## IP address listed on Spamhaus

**Symptom:** Spamhaus check returns "Listed" or shows recent listing history (last 90 days).

**Diagnosis:** Either a previous tenant of the IP misbehaved, or current behavior triggered a listing.

**For a brand new IP with historical listing:**

The IP carries reputation baggage from a previous owner. Two options:

1. **Request a different IP from the cloud provider.** On Hetzner, this is done via Floating IPs — create one, verify it is clean, attach to the server, route outbound through it. Cost: ~€1.20/month.

2. **Wait for the listing to age out.** Spamhaus CSS listings typically expire after 30–90 days of clean behavior. This requires sending no mail until the listing clears, which defeats the purpose for a production server.

**For an active IP that becomes listed during operation:**

Investigate immediately:

```bash
# Check mail queue for unusual activity
docker compose exec postfix-mailcow postqueue -p

# Recent send patterns
docker compose logs postfix-mailcow --tail 1000 | grep "from=<.*@example.com>" | tail -50

# Per-mailbox send rates
docker compose logs postfix-mailcow --tail 5000 | grep -oE "from=<[^>]+>" | sort | uniq -c | sort -rn
```

A compromised mailbox sending spam is the most common cause. If found:

1. Disable the affected mailbox in Mailcow UI
2. Force password reset
3. Investigate how the password was compromised (weak password? reused on a breached service?)
4. Submit removal request to Spamhaus once cleanup is complete

## Port 25 timing out

**Symptom:** `nc -zv -w 5 alt1.gmail-smtp-in.l.google.com 25` reports "Connection timed out".

**Cause:** Cloud provider has port 25 outbound blocked.

**Solution:** Submit a port 25 unblock request to the provider:

- **Hetzner Cloud:** Console → Support → Technical → Server issue: Sending mails not possible. Automated approval is typical, within minutes.
- **Other providers:** Manual support ticket, may take days.

There is no workaround. Without port 25 outbound, mail to external recipients cannot be sent. If the provider refuses unblocking, the only options are:

1. Switch to a provider that allows port 25
2. Use an SMTP relay (Mailgun, SendGrid, AWS SES) for outbound — but this defeats much of the point of self-hosting

## ProtonMail rejecting all messages

**Symptom:**

```
554 5.7.1 rejected by rspamd filter
```

**Cause:** ProtonMail's filter applies high scores to fresh domains and unfamiliar IPs.

**Solution:** Time. Continue sending to other receivers (Gmail, Outlook) for 2–4 weeks. ProtonMail eventually accepts messages once the domain has built reputation through other channels.

**What does not help:**

- Tweaking SPF, DKIM, DMARC (all already correct)
- Sending more messages (rejections accumulate negative signal)
- Switching IP (ProtonMail has long memory)
- Contacting ProtonMail support (their published policy is "build reputation organically")

**What helps:**

- Recipients who use ProtonMail can mark the sender as trusted in their settings, which bypasses the filter for them specifically
- Conversational, plain-text messages may be accepted earlier than promotional or technical content

## Gmail putting messages in spam

**Symptom:** First messages from the new domain land in Gmail recipients' Spam folder.

**Cause:** Cold start. Gmail's per-recipient model has no history with the new domain.

**Solution:** Recipient action.

Ask the recipient to:

1. Open the message in Spam folder
2. Click **Report not spam** (top of message)
3. Add the sender to contacts
4. Reply to the message

After these actions, future messages from the same sender to the same recipient land in Inbox. Gmail tracks per-sender-per-recipient trust separately.

## Mail-Tester score below 10

**Symptom:** Mail-Tester reports a score under 10 with specific issues identified.

The detail page shows what failed. Common causes:

**SPF issue:**
- Multiple SPF records published (must be exactly one)
- IP not authorized in SPF (check `mx` matches actual MX, or add explicit IPs)

**DKIM issue:**
- DNS record not yet propagated (wait 5 minutes, retry)
- DNS record truncated (long DKIM keys must be split into 255-character segments; Cloudflare does this automatically)
- Selector mismatch between Mailcow and DNS

**DMARC issue:**
- Record syntax error
- Strict alignment failing because From domain ≠ MAIL FROM domain or DKIM domain

**TLS issue:**
- Certificate expired (check ACME container logs)
- Certificate covers wrong domain

**Reverse DNS issue:**
- PTR record not set, or set to wrong hostname
- Hostname does not resolve to the IP

Each issue has its own fix; the Mail-Tester report identifies which.

## Mailcow nginx in restart loop

**Symptom:**

```
docker compose ps  # nginx-mailcow shows "Restarting"
```

**Cause:** Configuration error in custom nginx files. Common after editing `data/conf/nginx/`.

**Diagnosis:**

```bash
docker compose logs nginx-mailcow --tail 30
```

The error message identifies the offending file and directive. Typical:

```
[emerg] "location" directive is not allowed here in /etc/nginx/conf.d/file.conf:1
```

**Solution:** Remove the offending file and restart:

```bash
rm /opt/mailcow-dockerized/data/conf/nginx/PROBLEMATIC_FILE.conf
docker compose restart nginx-mailcow
```

For custom nginx configurations, study Mailcow's existing config structure. Files in `data/conf/nginx/` are included at the http level, not server level — `location` blocks must go inside `server` blocks via different mechanisms.

## MTA-STS policy returns 404

**Symptom:**

```bash
curl -s https://mta-sts.example.com/.well-known/mta-sts.txt
# Returns nothing or HTML 404
```

**Cause:** Either the subdomain is not in nginx server_name (returns to default server), or the policy is not activated for the domain in Mailcow.

**Diagnosis:**

```bash
docker compose exec nginx-mailcow cat /etc/nginx/conf.d/server_name.active
```

If `mta-sts.example.com` is not listed, add it via `mailcow.conf`:

```bash
sed -i 's/^ADDITIONAL_SERVER_NAMES=$/ADDITIONAL_SERVER_NAMES=mta-sts.example.com/' /opt/mailcow-dockerized/mailcow.conf
docker compose up -d nginx-mailcow
```

If the subdomain is in nginx but the policy still 404s, activate MTA-STS for the domain in Mailcow Admin: **Domains → Edit → MTA-STS tab → Active**. Set version, mode (`enforce`), max age, MX server, and save.

## Container repeatedly OOM-killed

**Symptom:** A container (often ClamAV, Rspamd, or MariaDB) repeatedly restarts. `dmesg` shows OOM kill events.

**Cause:** Insufficient RAM. Mailcow needs ~3–4 GB minimum, and the documented 6 GB recommendation exists for a reason.

**Solution:**

1. Add swap if not present:

```bash
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

2. Lower swap aggressiveness:

```bash
echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
sysctl -p /etc/sysctl.d/99-swappiness.conf
```

3. If on a 2 GB instance, upgrade to 4 GB. Mailcow does not run reliably under 4 GB.

4. Optionally disable ClamAV (saves ~1 GB):

```
SKIP_CLAMD=y    # in mailcow.conf
docker compose up -d
```

Without ClamAV, Rspamd alone catches most spam and malware. ClamAV adds a second layer that is valuable for high-volume servers but expendable for personal use.

## Mail not being delivered to a specific recipient

**Symptom:** Messages to a specific external address bounce or do not arrive.

**Diagnosis:**

```bash
# Find recent attempts to that recipient
docker compose logs postfix-mailcow --tail 1000 | grep "to=<recipient@somewhere.com>"
```

Common causes from log patterns:

**`status=bounced (host ... said: 5xx ...)`**
The receiver rejected. The 5xx code and message identify why. Most common:
- 550 — recipient address does not exist
- 554 — content-based rejection (often "rejected by rspamd filter" from ProtonMail, see above)
- 5.7.1 — policy rejection, often spam-related

**`status=deferred (...)`**
Temporary failure. Postfix retries automatically. Common reasons:
- Receiver rate-limiting
- Temporary DNS resolution issue
- Receiver server outage

**`status=sent (...)` with no delivery to user**
The message was accepted by the receiver but landed in their spam folder. See "Gmail putting messages in spam" above.

## DKIM signature failing verification

**Symptom:** Recipients report DKIM failure, or `Authentication-Results` shows `dkim=fail`.

**Cause:** Several possibilities.

**DNS record not matching the key:**

```bash
# Local key
docker compose exec rspamd-mailcow cat /var/lib/rspamd/dkim/example.com.dkim.key.pub

# Compare to:
dig +short TXT dkim._domainkey.example.com
```

The public key in DNS must exactly match what Mailcow has stored. If they differ, regenerate the DNS record from Mailcow's Admin UI (Domains → DNS button).

**Mail being modified in transit by a forwarder:**

If the recipient is forwarding mail (e.g., an email-list address), the original DKIM signature breaks because Subject or other signed headers get modified. ARC headers preserve authentication chain through forwards — Mailcow adds these automatically on outgoing mail.

**Selector mismatch:**

If the domain was created with a custom selector (not `dkim`), the DNS record name must match.

## Checking Mailcow update health

After running `./update.sh`, verify everything came up correctly:

```bash
cd /opt/mailcow-dockerized
docker compose ps --format 'table {{.Service}}\t{{.Status}}' | grep -v healthy | grep -v "Up"
```

Empty output means all containers are healthy. Any output identifies the problem container; investigate with:

```bash
docker compose logs SERVICE_NAME --tail 50
```

Updates occasionally introduce regressions. If a new version causes problems, Mailcow supports rolling back:

```bash
./helper-scripts/backup_and_restore.sh restore /path/to/backup
```

## When something is genuinely broken

If a change has rendered Mailcow inaccessible and the cause is not obvious from logs:

1. **Don't panic-restart everything.** Identify the specific failed component first.
2. **Roll back recent changes.** If the issue started after editing a config file, revert it.
3. **Check the Mailcow community.** [community.mailcow.email](https://community.mailcow.email) and the GitHub issues are active and well-monitored.
4. **Restore from backup.** Daily snapshot from the cloud provider can recover the entire VM in minutes.

The deployment described in this guide enables Hetzner's daily backups precisely for this reason. €1/month for an off-site, automatic, restorable copy of the entire system is one of the highest-value expenses in self-hosted email.

## Summary

Most issues fall into a few categories:

- **Reputation problems** — solved by time and engagement, not configuration changes
- **DNS issues** — solved by careful verification of every record
- **Configuration drift** — solved by following Mailcow's documented patterns and not editing internal containers
- **Resource exhaustion** — solved by appropriate sizing and swap

Operating an email server is mostly invisible work — it does what it does and the operator's role is to notice when something changes. The monitoring tools from [07 — Monitoring Setup](07-monitoring.md) make this practical.

Proceed to [10 — Maintenance](10-maintenance.md) for the routine work that keeps a deployment healthy long-term.
