# Self-Hosted Email Server with Mailcow — A Production Deployment Guide

A practical, battle-tested guide for deploying a self-hosted email server that **actually delivers to inbox**, not the spam folder.

This documentation covers the complete deployment of a production-grade email infrastructure using [Mailcow](https://mailcow.email) on Hetzner Cloud, including all the deliverability, security, and reputation-building steps that most tutorials skip.

> **Mail-Tester score: 10/10 on first attempt.** Gmail Inbox delivery confirmed with full SPF/DKIM/DMARC pass.

---

## What this guide covers

This is not another "install Mailcow with Docker" tutorial. It addresses the realities of running a self-hosted email server in 2026:

- **IP reputation matters more than software.** Half the work happens before you install anything.
- **Authentication is non-negotiable.** SPF, DKIM, DMARC, MTA-STS, TLS-RPT, and DNSSEC are all configured and validated.
- **Deliverability is built, not configured.** Real-world warmup strategies for Gmail, Outlook, ProtonMail, and corporate filters.
- **Monitoring is essential.** Google Postmaster Tools, Microsoft SNDS, and JMRP feedback loops.
- **The strict providers are honest signals.** ProtonMail rejecting your fresh domain is normal — and what to do about it.

---

## Who is this for

- DevOps engineers and sysadmins deploying email for small businesses
- Privacy-conscious developers leaving Gmail or Microsoft 365
- Founders building infrastructure for early-stage companies
- Anyone tired of paying €6/user/month for hosted email when they have ten mailboxes

This guide assumes Linux command-line comfort, basic Docker knowledge, and willingness to read DNS records. No deep email protocol expertise required — the relevant parts are explained in context.

---

## Architecture overview

The deployment consists of three layers:

**1. Cloud infrastructure (Hetzner)**
A single ARM-based VPS in Falkenstein, Germany, with both a primary IPv4 and a Floating IPv4. The Floating IP is used for all outbound SMTP, allowing the IP reputation to be portable across server rebuilds. IPv6 is enabled and used by default for outbound connections to Gmail.

**2. Email stack (Mailcow Dockerized)**
Eighteen Docker containers orchestrating a complete email server: Postfix for SMTP, Dovecot for IMAP, Rspamd for spam filtering, ClamAV for antivirus, SOGo for webmail, Nginx as the reverse proxy, ACME for Let's Encrypt automation, MariaDB and Redis for state, and an internal Unbound resolver for DNSBL queries.

**3. DNS and authentication (Cloudflare)**
Cloudflare DNS with DNSSEC enabled. All authentication records published: A, AAAA, MX, SPF, DKIM (2048-bit), DMARC, MTA-STS in enforce mode, and TLS-RPT for TLS failure reporting.

External email providers connect to the server over port 25 with mandatory TLS (enforced via MTA-STS). Outbound mail is sent from the Floating IPv4 address with full FCrDNS validation.

---

## Documentation structure

The guide is organized as a sequence of logical phases. Read in order on first deployment; reference individually afterward.

### Foundation
- [01 — Prerequisites](docs/01-prerequisites.md) — VPS choice, IP reputation requirements, port 25 unblocking, domain selection
- [02 — VPS Bootstrap](docs/02-vps-bootstrap.md) — Server provisioning, Floating IP setup, hostname, hardening, swap

### DNS and Mailcow
- [03 — DNS Configuration](docs/03-dns-configuration.md) — Cloudflare records: A, MX, SPF, DMARC, MTA-STS, TLS-RPT
- [04 — Mailcow Installation](docs/04-mailcow-installation.md) — Docker, Mailcow setup, SSL, first start
- [05 — Domain and Mailbox](docs/05-domain-and-mailbox.md) — Adding the domain, generating DKIM, creating mailboxes

### Deliverability
- [06 — Deliverability Essentials](docs/06-deliverability-essentials.md) — The authentication chain explained
- [07 — Monitoring Setup](docs/07-monitoring.md) — Google Postmaster, Microsoft SNDS, JMRP enrollment
- [08 — Warmup Strategy](docs/08-warmup-strategy.md) — First weeks, realistic expectations, engagement signals

### Operations
- [09 — Troubleshooting](docs/09-troubleshooting.md) — Common issues and their honest fixes
- [10 — Maintenance](docs/10-maintenance.md) — Updates, backups, monitoring rituals

---

## Quick reference

**Tested deployment specs:**

| Component | Choice | Why |
|---|---|---|
| Cloud provider | Hetzner Cloud | Cheap, EU-based, allows port 25 after request |
| VPS plan | CAX11 (ARM64) | 2 vCPU, 4GB RAM — sufficient for 10–50 mailboxes |
| Location | Falkenstein, DE | Isolated from existing infrastructure |
| OS | Ubuntu 24.04 LTS | Mailcow's reference platform |
| Email server | Mailcow Dockerized | All-in-one, well-maintained |
| DNS | Cloudflare | Free, fast, supports DNSSEC out of the box |
| Domain registrar | Cloudflare Registrar | At-cost pricing, automatic DNSSEC integration |

**Approximate cost:** ~€5–7/month for the VPS, ~€10/year for the domain. No per-mailbox fees.

---

## Status of this guide

This documentation is based on a real production deployment completed in May 2026. It captures both the working configuration and the friction points encountered during the process.

The guide is opinionated where opinions help, neutral where they don't. It does not pretend that self-hosted email is the right choice for everyone — it is not. For most small businesses, Google Workspace or Fastmail at €5–6/user/month will be cheaper, simpler, and more reliable. Self-hosting makes sense when you have specific needs: data sovereignty, multi-domain economics, technical preference, or learning goals.

---

## Contributing

Issues and pull requests welcome, especially:

- Corrections to outdated information (Mailcow versions, Hetzner pricing, provider quirks change frequently)
- Additional troubleshooting scenarios
- Translations
- Real-world deliverability data points

---

## License

[MIT](LICENSE) — use freely, attribution appreciated.

---

## Author

**Slavcho Ivanov**, founder of [GEMBA EOOD](https://gembait.com) — a Bulgarian company specializing in payment infrastructure and DevOps consulting.

This guide was written from the experience of deploying email for both internal use and as a building block for client services.
