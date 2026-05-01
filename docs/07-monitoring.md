# 07 — Monitoring Setup

A correctly configured email server still needs monitoring. The major receivers (Google, Microsoft, Apple) provide direct feedback channels for senders, and using them is the difference between learning about delivery problems immediately versus discovering them weeks later.

This phase enrolls in three monitoring services: Google Postmaster Tools, Microsoft SNDS, and Microsoft JMRP.

## Why monitoring matters

Reputation builds and breaks silently. A compromised mailbox sending spam, a misconfigured forwarder, an automated process generating bounces — none of these announce themselves. By the time a sender notices delivery problems through user complaints, reputation has already been damaged for days.

The monitoring tools below show:

- **What receivers see** when this domain sends mail
- **Spam complaint rates** from real recipients
- **Authentication results** at scale across millions of messages
- **Reputation trends** over time
- **Specific events** that affected reputation

All three are free.

## Google Postmaster Tools

Tracks Gmail-side metrics for any domain that sends mail to Gmail users.

### Enrollment

1. Visit [postmaster.google.com](https://postmaster.google.com)
2. Sign in with any Google account
3. Click **+ Add domain** (top right)
4. Enter the domain — `example.com`
5. Google generates a TXT record for verification:

```
google-site-verification=ABC123...
```

6. Add this in DNS as a TXT record:

```
Type:    TXT
Name:    @
Content: google-site-verification=ABC123...
TTL:     Auto
```

7. Return to Postmaster Tools and click **Verify**.

If verification fails, wait 1–2 minutes for DNS propagation and retry.

### What it shows

After 24–48 hours of mail flow, the dashboard populates with:

- **Spam Rate** — percentage of messages marked as spam by Gmail users
- **IP Reputation** — Google's internal rating of the sending IP
- **Domain Reputation** — Google's internal rating of the domain
- **Authentication** — pass rates for SPF, DKIM, DMARC
- **Encryption** — percentage of mail sent over TLS
- **Delivery Errors** — bounce reasons aggregated

Healthy values for a well-configured deployment:

| Metric | Healthy | Warning | Critical |
|---|---|---|---|
| Spam Rate | < 0.1% | 0.1–0.3% | > 0.3% |
| Domain Reputation | High / Medium | Low | Bad |
| IP Reputation | High / Medium | Low | Bad |
| Authentication | 99%+ pass | 95–99% | < 95% |
| Encryption | 100% TLS | < 100% | < 95% |

A spam rate above 0.3% triggers Gmail's filtering for the entire domain. Recovery from "Bad" reputation takes weeks of clean sending.

### Multi-domain monitoring

Each domain that sends mail needs separate enrollment. For an infrastructure where one Mailcow instance serves multiple domains (`example.com`, `another.com`, `third.com`), each is added separately to Postmaster Tools.

## Microsoft SNDS — Smart Network Data Services

Provides similar feedback for Outlook.com, Hotmail, and Microsoft 365 recipients.

### Enrollment

1. Visit [sendersupport.olc.protection.outlook.com/snds](https://sendersupport.olc.protection.outlook.com/snds)
2. Sign in with a Microsoft account (free Outlook.com account works)
3. Click **Request Access** in the left sidebar
4. Enter the IP address (single IP, range, or CIDR)
5. Provide a justification — short and factual:

> Self-hosted email server (Mailcow) for example.com. Personal and small business correspondence. Requesting SNDS access to monitor IP reputation and deliverability to Outlook recipients.

6. Submit.

Microsoft displays addresses derived from WHOIS that can receive verification email. Choose `postmaster@example.com` (which exists as the system mailbox from [05 — Domain and Mailbox](05-domain-and-mailbox.md)).

Microsoft sends a confirmation email containing two links: one to approve, one to deny access. Clicking the approve link finalizes enrollment.

### What it shows

After 24–48 hours:

- **Filter result** — Green (deliverable), Yellow (warnings), Red (blocked)
- **Complaint rate** — percentage of recipients marking messages as junk
- **Trap hits** — if any messages reached spam traps (significant red flag)
- **RCPT commands** — number of attempted deliveries
- **Sample messages** — content of a few flagged messages

Healthy values:

| Metric | Healthy | Warning | Critical |
|---|---|---|---|
| Filter result | Green | Yellow | Red |
| Complaint rate | < 0.1% | 0.1–0.3% | > 0.3% |
| Trap hits | 0 | 1–5 | 5+ |

Traps are addresses that Microsoft has seeded into spam lists. Hitting a trap means the sender has a bad address list — sometimes a sign of a compromised mailbox, sometimes a sign of buying email lists.

## Microsoft JMRP — Junk Mail Reporting Program

Where SNDS shows aggregated metrics, JMRP delivers actual complaint reports. When an Outlook user marks a message as junk, JMRP forwards a copy of the report to a designated address.

### Enrollment

1. From the SNDS dashboard, click **Junk Mail Reporting Program**
2. Fill the form:

| Field | Value |
|---|---|
| Company name | The legal entity name |
| Contact email | A monitored mailbox (`slavy@example.com`) |
| Complaint feedback email | `abuse@example.com` (alias to postmaster) |
| Complaint format | ARF (default; standard format) |
| Max complaints per IP per day | `1000` (a high ceiling) |
| Max complaints per day, all IPs | `1000` |

3. Select the IP range (the one already authorized in SNDS)
4. Accept the agreement and submit

### What arrives

When an Outlook user marks a message as junk, an ARF (Abuse Reporting Format) email arrives at `abuse@`:

```
From: staff@hotmail.com
To: abuse@example.com
Subject: Email Feedback Report for: ...

This is an email abuse report for an email message received from
IP FLOATING_IP on Tue, 01 Sep 2026 15:23:00 +0000.

[ARF metadata + original message attached]
```

Mailcow's Rspamd can be configured to ingest these reports automatically and feed them into the spam filter learning model — improving accuracy for the specific senders being complained about.

In the first weeks of operation, no JMRP reports arriving is **good news**. It means no Outlook users are marking messages as junk.

## Apple iCloud Mail

Apple does not provide a postmaster tools equivalent. Their main feedback mechanism is the recipient marking messages as junk in Mail.app, which feeds back into Apple's filters anonymously.

For senders to iCloud recipients, the only useful signal is whether messages arrive. The good news: Apple's filtering largely respects Gmail-grade authentication (SPF, DKIM, DMARC). A deployment that delivers cleanly to Gmail typically delivers cleanly to iCloud as well.

## Mail-Tester

Not a continuous monitoring service, but worth running periodically (monthly) to catch configuration drift. It sends a synthetic test through 30+ checks and assigns a score out of 10.

A correctly configured deployment scores 10/10. A drop to 9/10 indicates something has changed — usually a DNS record gone stale or a TLS issue. Worth investigating.

[mail-tester.com](https://www.mail-tester.com) — generate a test address, send a message to it, view the score.

## Local monitoring

Beyond the receiver-side tools, monitor the server itself:

```bash
# Mail queue — anything stuck?
docker compose exec postfix-mailcow postqueue -p

# Recent errors
docker compose logs postfix-mailcow --tail 100 | grep -iE "error|reject|bounce"

# Container health
docker compose ps --format 'table {{.Service}}\t{{.Status}}' | grep -v healthy | grep -v "Up"

# Disk usage trend
df -h /
```

A daily cron job that runs these and emails the results to `postmaster@` provides early warning for:

- Queue buildup (relay issues, bad addresses)
- Container crashes (autorecovery may hide them)
- Disk filling (mail log growth, mailbox growth)

A reference health-check script is included in [scripts/](../scripts/).

## Summary

After this phase, three external monitoring channels are active:

- **Google Postmaster Tools** — Gmail metrics, populated within 48 hours
- **Microsoft SNDS** — Outlook IP reputation and complaint rate
- **Microsoft JMRP** — Outlook user complaint reports forwarded to abuse@

Local monitoring of the server itself catches operational problems before they become deliverability problems.

These tools are most useful when checked regularly — weekly review of all three takes 5 minutes and catches drifts early. Set a calendar reminder.

Proceed to [08 — Warmup Strategy](08-warmup-strategy.md) for the realistic plan of how to use the new server in its first weeks without damaging the brand-new reputation.
