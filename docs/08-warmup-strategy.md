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

ProtonMail typically requires 2–4 weeks of consistent sending before accepting messages. Their filter (`rspamd filter`, same software Mailcow uses internally) is unusually strict toward fresh domains regardless of authentication.

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

1. **Wait** — after 2–4 weeks of clean sending to other receivers, ProtonMail reputation builds passively
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
- Check ProtonMail acceptance — likely working now
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

The technical setup of this server is at the level of professional email services. Reputation will eventually be at the same level — through consistent, measured, real usage over weeks.

Resist the urge to test aggressively or send broadcasts in the first weeks. The patient approach reaches stable deliverability faster than the impatient one.

Proceed to [09 — Troubleshooting](09-troubleshooting.md) for issues that may arise during this period.
