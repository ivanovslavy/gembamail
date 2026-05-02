# 08 — Warmup Strategy

A new email server with perfect technical configuration still has zero reputation. This phase covers the realistic, time-based process of building deliverability with the major receivers.

This is the part most tutorials skip. They install Mailcow, run mail-tester, get 10/10, declare victory, and leave the reader confused when first messages land in spam folders.

## The cold start problem

Every receiver — Gmail, Outlook, ProtonMail, Yahoo, corporate filters — uses some combination of authentication, content analysis, and **historical behavior** to score incoming mail. With no historical behavior, even perfect authentication only gets the message past the door. After that, it is graded against an empty dataset.

The receiver asks: "Have I seen mail from this domain before? Did recipients engage with it positively?" For a domain that is hours old, both answers are no. The conservative default is the spam folder.

This is correct behavior on the receiver's part. The same protection that keeps spam out of inboxes also delays new legitimate senders.

## Realistic timeline

Based on observed behavior with a properly configured deployment:

| Period | Gmail | Outlook | ProtonMail | Corporate filters |
|---|---|---|---|---|
| Day 1 | First message often Inbox if to known recipients (your own Gmail with engagement history); spam folder for cold contacts | Spam folder common | Often rejected outright (554 rspamd filter) | Variable; strict ones reject |
| Week 1 | Mixed; "Not spam" markings build trust | Improving with engagement | Still rejecting most | Stable for relaxed filters |
| Week 2 | 90%+ Inbox for engaged recipients | Stable Inbox for engaged | Beginning to accept | Stable |
| Week 4 | Stable Inbox delivery | Stable | Mostly delivers, occasional rejects | Stable |
| Month 3+ | Trusted sender for engaged recipients | Trusted | Reliable | Stable |

These are typical curves, not guarantees. Deployments that send too aggressively, hit spam traps, or generate complaints will see this curve broken or reversed.

## Real-world observation: how fast reputation can actually build

The timeline above assumes a typical deployment. In practice, with all the technical pieces in place from day one and natural engagement patterns, reputation can build noticeably faster than the conservative estimates suggest.

A reference deployment showed the following progression for the **first domain** added (`gembamail.com`):

**Hours 0–4:**
- Mail-Tester: 10/10 on first attempt
- First emails to a primary Gmail account (with prior engagement history): Inbox
- First emails to a secondary Gmail account (no prior history): Spam folder, recovered after recipient marked as "Not spam" and replied
- ProtonMail: rejected (`554 5.7.1 rejected by rspamd filter`) on multiple attempts

**Hours 4–24:**
- Continued sending to engaged recipients: stable Inbox delivery at Gmail
- One Yahoo recipient: Inbox direct on first contact, full reply chain
- Service signups (Alchemy): verification emails received cleanly

**Hour 18 (next morning):**
- ProtonMail began accepting messages from the same sender that had been rejected 12 hours earlier
- Multiple ProtonMail addresses (different from the rejected ones) accepted on first attempt

Then **a second domain** (`gembait.com`) was added to the same Mailcow instance — same server, same IP, fresh `From:` domain. Results from the first day of the new domain:

- Gmail (engaged recipient): Inbox direct on first attempt
- Yahoo (cold contact): Inbox direct on first attempt
- ProtonMail (separate addresses): Inbox direct on first attempt

**The pattern that explains this:** receivers track reputation at multiple granularities — IP, IP subnet, sending domain, From domain. Once the IP has built positive reputation through one domain, additional From-domains added to the same IP inherit a portion of that trust. The new domain still has zero individual reputation, but the IP and subnet score remain favorable.

This means the second and third domains migrated to the same Mailcow instance benefit from work done warming up the first one. The conservative "two weeks per domain" timeline collapses substantially.

**This does not mean technical configuration can be skipped.** The fast trajectory observed required:

- All authentication records correct from the start (SPF, DKIM, DMARC, MTA-STS, TLS-RPT, DNSSEC, FCrDNS for both IPv4 and IPv6)
- IP confirmed clean before deployment (Spamhaus, Talos, MXToolbox)
- Real engagement signals — actual replies, not test broadcasts
- Conservative volume — fewer than 50 outbound messages in the first 24 hours
- Conversational content, not formatted promotional templates

Without these, the curve looks like the conservative timeline above. With them, it can look like this faster trajectory. There is no shortcut for the technical preparation — only for what comes after it.

## What "engagement" means and why it matters

Receivers track several behavioral signals:

- **Open rate** — recipient opened the message
- **Reply rate** — recipient sent a response
- **"Not spam" actions** — recipient moved a message out of spam
- **"Move to inbox" actions** — recipient took a spam-suspected message and explicitly accepted it
- **Star / mark important** — recipient flagged the message
- **Adding to contacts** — recipient added the sender to their address book
- **Time spent reading** — proxies for whether content was read
- **Forwarding** — recipient sent the message to others

The strongest signals are explicit user actions: replies, "Not spam", "Move to inbox", adding to contacts. A single such action permanently improves trust between that specific sender and that specific recipient.

For a new domain, generating a few high-quality engagement signals in the first week disproportionately accelerates reputation building.

## The first-week plan

### Day 1 — Self and known contacts

Send a small number of messages to recipients with whom there is existing Gmail-side history.

```
Recipient: your own Gmail address
Subject:   Brief, conversational
Body:      A few sentences; tell them what the new address is
```

Then **reply from Gmail back to the new address**. This creates a two-way conversation, which is a powerful Gmail trust signal. The reply trains Gmail's per-recipient model that the two addresses interact.

Add the new address to the Google contacts of every recipient who agrees. "Add to contacts" is one of the strongest signals.

### Days 2–4 — Family and close contacts

Brief, real conversations. Not test messages. Not announcements. Topics that would naturally generate replies.

```
Subject:   Casual, specific
Body:      A real question or topic that invites a reply
```

Before sending, brief the recipient via another channel (Signal, WhatsApp): "I'll be sending you a message from a new email address. If it lands in spam, please mark it as 'Not spam' and reply to me." This shortcut is honest and effective.

For each "Not spam" + reply, the receiver learns that messages from the new domain to this specific recipient should go to the inbox.

### Days 5–7 — Wider circle

Continue at 5–15 messages per day. Mix of:

- Replies to existing email threads (forwarded to the new address from the old one, then replied to)
- Outbound messages with substantive content
- Occasional broadcasts to a few people (still not bulk)

Avoid:

- Sending the same message to many recipients
- Mass announcements ("I have a new email!")
- Test messages with single-word bodies
- Time-bunched sending (all messages at the same minute)

### Week 2 onward

By this point, most engaged Gmail recipients should reliably receive messages in their inbox. Outlook and Yahoo follow similar patterns slightly delayed.

ProtonMail typically requires 2–4 weeks of consistent sending before accepting messages. Their filter (`rspamd filter`, same software Mailcow uses internally) is unusually strict toward fresh domains regardless of authentication. As the real-world observation above shows, however, this can collapse to under 24 hours when the technical setup is impeccable and engagement is genuine.

## ProtonMail specifically

ProtonMail rejecting messages from a new domain is the single most common surprise in self-hosted email. They publish no metrics, provide no postmaster tools, and offer no warmup guidance. The rejection message is generic:

```
554 5.7.1 rejected by rspamd filter
```

What is happening: ProtonMail's Rspamd applies high penalties to:

- Domains less than 24 hours old (multiple Rspamd rules)
- Hosts in cloud provider IP space without sending history
- Messages with promotional patterns (URLs, "test", "deliverability")
- Messages with bullet points and technical terminology
- First-contact patterns (no prior conversation thread)

Approaches that work:

1. **Wait** — observed reality is that this can be hours rather than weeks if the underlying IP is clean and engagement at other receivers is real
2. **Recipient-side allowlist** — ProtonMail users can mark senders as trusted in their settings, which bypasses the filter
3. **Conversational content** — short, plain text messages that resemble human conversation are accepted earlier than structured/formatted ones
4. **Avoid early ProtonMail testing** — every rejection adds negative signal; do not stress-test ProtonMail with the new domain

Approaches that do not work:

- Adding more authentication (already at maximum)
- Tweaking SPF or DKIM
- Sending more messages
- Changing IP

The rejection is not a configuration problem and cannot be fixed with configuration changes.

## Specific patterns to follow and avoid

**Follow:**

- Personal, conversational tone in early messages
- Substantial bodies (50+ words minimum)
- Real subjects related to actual topics
- Replies to existing threads when possible
- Spread sending throughout the day
- Different recipients each session

**Avoid:**

- "Test" messages
- Bullet-point lists in early messages
- HTML-heavy formatting
- External images that load on open
- URLs to non-established domains
- Repeated subjects
- Sending 10 messages in 5 minutes
- Cold-contacting many people in week 1

## Adding additional domains to the same instance

Once the first domain has built reputation, additional domains can be added to the same Mailcow server. Each new domain starts with zero individual `From:` reputation, but inherits IP and subnet reputation from the established domain.

In practice, this means:

- The technical setup repeats per domain (DNS records, MTA-STS, mailboxes, SAN updates) — about 30–45 minutes of work
- Reputation building is faster than the first domain because the IP is already trusted
- Initial sends from the new domain often land in Inbox at Gmail and Yahoo immediately
- ProtonMail acceptance is typically faster than the first domain experienced

This advantage is contingent on continuing to behave the same way: real engagement, conservative volume, conversational content. A new domain on the same IP can damage that IP's reputation if it is misused — for example, if the new domain is used to send mass marketing, transactional bursts, or anything that generates complaints.

A safe migration sequence for multiple business domains:

1. Set up the dedicated infrastructure domain first (e.g., `companymail.com` if it exists separately, or the primary working domain)
2. Use it for personal and infrastructure email for at least 24–72 hours, building genuine engagement
3. Migrate the first business domain — one with relatively low traffic and known recipients
4. Wait a day or two, monitor delivery patterns
5. Migrate higher-traffic domains in sequence

For most small businesses, all relevant domains can be on the new server within a week without delivery problems.

## Monitoring the warmup

In the first weeks:

- Check Google Postmaster Tools daily after day 2
- Check Microsoft SNDS every 2–3 days after enrollment
- Watch for unexpected bounces in Mailcow logs
- Note any "spam" landings and which recipients had them

Trends to look for:

- Postmaster Tools spam rate stays under 0.1%
- Postmaster Tools domain reputation rises from None → Low → Medium → High
- SNDS filter result is Green
- No bounces other than expected ones (typos, defunct addresses)

If spam rate exceeds 0.3%, stop sending until the cause is identified. The cause is almost always one of:

- A compromised mailbox sending spam
- A misconfigured forwarder relaying to a bad list
- Test sending to addresses that are actually spam traps

## The two-week milestone

After 14 days of clean operation:

- Tighten DMARC: change `p=none` to `p=quarantine; pct=10`
- Increase sending volume gradually to actual usage levels
- Begin trusting the deployment for important communications
- Check ProtonMail acceptance — likely working now (often sooner)
- Review Postmaster Tools for any concerns

If reputation has built cleanly, the domain is now a real production sender.

## The thirty-day milestone

- DMARC at `p=quarantine; pct=100`
- Consider BIMI for visual brand verification (requires DMARC enforcement)
- Add additional domains to Mailcow if planned
- Begin transitioning real workflows away from old email providers
- Review and tighten any rate limits that need adjustment

## The ninety-day milestone

- DMARC at `p=reject` if monitoring shows clean operation
- Domain reputation stable at High in Postmaster Tools
- Consider this server's deliverability fully matured
- Performance now matches or exceeds typical hosted email services

## Summary

Authentication is configured. Reputation is built.

The technical setup of this server is at the level of professional email services. Reputation will eventually be at the same level — through consistent, measured, real usage over weeks. In favorable cases, the curve compresses dramatically: the real-world observation in this guide showed Inbox delivery at Gmail, Yahoo, and ProtonMail (after initial rejection) within the first 24 hours, and a second domain on the same IP achieving Inbox delivery on the very first attempt.

These results required the technical groundwork to be solid. They are not magic. They are what happens when authentication is correct, the IP is clean, the volume is conservative, and the engagement is real.

Resist the urge to test aggressively or send broadcasts in the first weeks. The patient approach reaches stable deliverability faster than the impatient one — and as the data shows, "patient" can mean hours, not weeks.

Proceed to [09 — Troubleshooting](09-troubleshooting.md) for issues that may arise during this period.
