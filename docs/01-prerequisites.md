# 01 — Prerequisites

Before installing any software, several decisions and verifications need to happen. Skipping these guarantees deliverability problems later.

## Cloud provider selection

Most VPS providers block outbound port 25 by default to prevent abuse. Self-hosted email is impossible without it. Provider choice is therefore largely a question of which providers will unblock port 25 on request.

**Providers that allow port 25 (with a request):**

- **Hetzner Cloud** — automatic approval after a short justification, EU-based, ARM and x86 options, ~€5/month entry tier. This guide uses Hetzner.
- **OVH** — case-by-case approval, larger plans
- **Scaleway** — manual approval process
- **Vultr** — generally allows after request

**Providers that block port 25 with no exceptions:**

- AWS EC2 (without filing for IP unblock at the account level)
- Google Cloud
- Microsoft Azure
- DigitalOcean (some plans)
- Linode

If you are committed to one of the blocking providers, the only path is using an SMTP relay (Mailgun, SendGrid, AWS SES) for outbound — at which point self-hosting becomes harder to justify.

## Sizing the VPS

Mailcow's official requirements suggest 6GB RAM, but this is sized for typical small business deployments with 50–200 mailboxes. For 5–20 mailboxes, the realistic baseline is:

| Component | Idle | Active | Update |
|---|---|---|---|
| ClamAV | ~1 GB | ~1 GB | ~1.2 GB |
| Rspamd | ~400 MB | ~500 MB | ~600 MB |
| Solr | ~500 MB | ~600 MB | ~700 MB |
| MariaDB | ~300 MB | ~400 MB | ~500 MB |
| All other 14 containers | ~700 MB | ~900 MB | ~1.1 GB |
| **Total** | **~2.9 GB** | **~3.4 GB** | **~4.1 GB** |

A 4GB instance with 2GB swap is comfortable for personal and small business use. Avoid 2GB instances — once swap activity starts, performance degrades rapidly and Mailcow updates risk OOM kills.

For the deployment in this guide, the chosen plan is **Hetzner CAX11**: 2 vCPU (ARM Neoverse-N1), 4GB RAM, 40GB SSD, ~€5/month. ARM is fully supported by Mailcow.

## IP reputation — the most important step

This is where most self-hosted email deployments fail before they start. The IP address assigned to a fresh VPS may have a poor reputation from a previous tenant. Even a clean IP in a "spammy neighborhood" — that is, a /24 subnet where neighboring IPs send spam — will face stricter filtering at every major email provider.

### Why it matters

Gmail, Microsoft, and large filtering services (Spamhaus, Barracuda, SpamCop) maintain reputation databases at multiple granularities:

- **Individual IP reputation** — built from sender history, complaint rates, authentication results
- **Subnet reputation** — the /24 containing the IP affects scoring even for clean individual IPs
- **ASN reputation** — the autonomous system (e.g., all Hetzner IPs)

A new VPS inherits all of these, then earns its own individual score over time. Starting with a "burnt" IP — one with recent listings or spammy neighbors — adds weeks of warmup work or makes delivery impossible.

### Pre-flight checks

Before deploying anything, verify the assigned IP:

**1. Spamhaus history**

```
https://check.spamhaus.org/results/?query=YOUR_IP
```

Look for any recent listings (last 90 days). A "currently not listed" status with a clean history is required.

**2. Talos Intelligence (Cisco)**

```
https://talosintelligence.com/reputation_center/lookup?search=YOUR_IP
```

This shows the reverse DNS hostname, neighboring IP behavior, and email volume in the last day and month. Pay attention to the **Top IP Addresses used to send emails** section — if neighbors host spam-pattern domains (algorithmic-looking names, suspicious TLDs like .sbs / .click / .top), the entire subnet is compromised.

**3. MXToolbox blacklist check**

```
https://mxtoolbox.com/SuperTool.aspx?action=blacklist:YOUR_IP
```

Aggregates 100+ DNS-based blacklists.

**4. Multi-DNSBL command-line check**

A shell script that queries the most relevant blacklists directly is provided in `scripts/check-blacklist.sh` of this repository.

### When the IP is unusable

If checks reveal recent listings or compromised neighbors, the right action is to **request a different IP**, not to proceed and hope. Two approaches work on Hetzner:

**Option A — Floating IP**
Request a Floating IP, attach it to the server, route outbound traffic through it, and remove the original primary IP from active use. This costs ~€1.20/month extra but allows trying multiple IPs cheaply until a clean one is found.

**Option B — Recreate the server**
Destroying and recreating may give the same IP back (Hetzner reserves IPs for the account briefly). Floating IPs are more reliable.

The deployment in this guide used Option A after the initial IP was found to have a recent Spamhaus CSS listing and to share its /24 with multiple `.sbs` spam domains.

## Domain selection

Three considerations matter for the domain that will host email:

### Use a clean, separate infrastructure domain

Do not host email on the same domain as production websites or applications. If a deliverability problem arises, it should not affect the reputation of customer-facing domains. Use a dedicated infrastructure domain — something like `companymail.com` or `mailco.io` — and configure all business domains to route mail through it via MX records.

### Verify domain history

Domains, like IPs, can have prior bad reputations. Before purchasing, check:

- **WHOIS history** at SecurityTrails or DomainTools
- **MXToolbox domain blacklist:** `https://mxtoolbox.com/domain/YOUR_DOMAIN`
- **Google Safe Browsing:** `https://transparencyreport.google.com/safe-browsing/search?url=YOUR_DOMAIN`

A domain previously used for spam, malware, or phishing carries that history. Avoid expired domains being resold for the email use case.

### Registrar choice

The registrar should support DNSSEC integration with the DNS provider. Cloudflare Registrar is the simplest choice if Cloudflare DNS is also being used: DNSSEC is automatic and at-cost pricing means no markup (~$10/year for `.com`).

## Port 25 unblock

After provisioning the VPS but before installing Mailcow, request port 25 to be unblocked. On Hetzner, this is a one-click form in the Cloud Console: **Support → Technical → Server issue: Sending mails not possible**.

A short justification is required. Honest, specific text works:

> Self-hosted email server (Mailcow) for [domain.com]. Personal and small business use. No bulk mailing. Server is properly configured with reverse DNS, will publish SPF/DKIM/DMARC, and has been verified clean on Spamhaus.

Hetzner's automated validator approves most requests within minutes. Some require manual review (1–4 hours). Without port 25 unblocked, no email can be sent to external recipients.

## Summary of prerequisites

Before proceeding to VPS bootstrap:

- [ ] Cloud provider chosen (Hetzner Cloud recommended)
- [ ] VPS plan sized appropriately (CAX11 or equivalent)
- [ ] Location selected (separate from existing infrastructure if applicable)
- [ ] IP reputation verified clean
- [ ] Floating IP plan in place if primary IP is questionable
- [ ] Domain selected, history verified, registered with DNSSEC-capable registrar
- [ ] Port 25 unblock request submitted

When these are complete, proceed to [02 — VPS Bootstrap](02-vps-bootstrap.md).
