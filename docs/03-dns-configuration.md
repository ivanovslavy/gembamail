# 03 — DNS Configuration

This phase publishes all DNS records needed before Mailcow installation. Records are added at the DNS provider — examples use Cloudflare, but any provider supporting TXT, MX, A, AAAA, CNAME records works.

The full set spans authentication (SPF, DMARC), security (MTA-STS, TLS-RPT), and discoverability (autoconfig, autodiscover). DKIM is added in a later phase, after Mailcow generates the key.

## Prerequisites

- Domain registered at a registrar that supports DNSSEC (Cloudflare Registrar, Namecheap, Porkbun)
- DNS hosted at a provider that supports TXT, MX, A, AAAA, CNAME records
- Floating IP and IPv6 known from [02 — VPS Bootstrap](02-vps-bootstrap.md)

If using Cloudflare and the domain was purchased through Cloudflare Registrar, DNS is already active and DNSSEC can be enabled with one click.

## Cloudflare DNS proxy and email

Cloudflare's orange-cloud proxy works only for HTTP and HTTPS traffic. SMTP, IMAP, POP3, and ManageSieve are not supported through the proxy.

**For all email-related records, set proxy status to "DNS only" (gray cloud).** TXT and MX records cannot be proxied at all; A and CNAME records pointing to the mail server must explicitly be set to DNS only.

## Records to publish

The following records are added before Mailcow installation. DKIM is the only one that comes later, because Mailcow generates the key during domain creation.

### A and AAAA — mail server hostname

The hostname `mail.example.com` resolves to the Floating IPv4 (used for outbound) and the primary IPv6.

```
Type:    A
Name:    mail
Content: FLOATING_IP
TTL:     Auto
Proxy:   DNS only
```

```
Type:    AAAA
Name:    mail
Content: PRIMARY_IPV6
TTL:     Auto
Proxy:   DNS only
```

### MX — mail exchange

Tells the world where to deliver mail for the domain.

```
Type:        MX
Name:        @
Mail server: mail.example.com
Priority:    10
TTL:         Auto
```

### SPF — sender policy framework

Authorizes the mail server to send on behalf of the domain. The minimal version uses the MX record:

```
Type:    TXT
Name:    @
Content: v=spf1 mx ~all
TTL:     Auto
```

A more explicit version pins specific IPs, useful if the MX is changed later or for clarity in audits:

```
v=spf1 mx ip4:FLOATING_IP ip6:PRIMARY_IPV6 ~all
```

The `~all` (soft fail) is correct for new deployments. Tightening to `-all` (hard fail) is appropriate after monitoring DMARC reports for two weeks confirms no legitimate mail is being missed.

### DMARC — domain-based message authentication

Defines policy for what receivers should do when SPF or DKIM fail, and where to send aggregate reports.

```
Type:    TXT
Name:    _dmarc
Content: v=DMARC1; p=none; rua=mailto:dmarc@example.com; ruf=mailto:dmarc@example.com; fo=1; adkim=s; aspf=s
TTL:     Auto
```

Field meanings:

- `p=none` — monitoring only, no enforcement (correct for a new deployment)
- `rua=mailto:` — aggregate reports destination
- `ruf=mailto:` — forensic reports destination
- `fo=1` — generate reports on any failure
- `adkim=s; aspf=s` — strict alignment between authentication domains and the From header

The address `dmarc@example.com` must exist as a mailbox or alias in Mailcow. This is set up in [05 — Domain and Mailbox](05-domain-and-mailbox.md).

After two weeks of clean reports, the policy can be tightened progressively:

| Day | Policy |
|---|---|
| 0 | `p=none` |
| 14 | `p=quarantine; pct=10` |
| 30 | `p=quarantine; pct=50` |
| 60 | `p=quarantine; pct=100` |
| 90+ | `p=reject` |

### MTA-STS — TLS policy enforcement

MTA-STS publishes a policy that forces sending mail servers to use TLS when delivering to this domain. It requires two records: a TXT record announcing the policy, and a hostname (`mta-sts.example.com`) that serves the policy file over HTTPS.

```
Type:    TXT
Name:    _mta-sts
Content: v=STSv1; id=20260501120000Z
TTL:     Auto
```

The `id` is a version identifier in `YYYYMMDDhhmmssZ` format. Update it whenever the policy changes.

```
Type:    A
Name:    mta-sts
Content: FLOATING_IP
TTL:     Auto
Proxy:   DNS only
```

The actual policy file is served by Mailcow at `https://mta-sts.example.com/.well-known/mta-sts.txt`. Mailcow generates this dynamically — see [05 — Domain and Mailbox](05-domain-and-mailbox.md) for activation.

### TLS-RPT — TLS reporting

When other servers experience TLS problems connecting to this domain, they can report to a designated address.

```
Type:    TXT
Name:    _smtp._tls
Content: v=TLSRPTv1; rua=mailto:tlsrpt@example.com
TTL:     Auto
```

The address `tlsrpt@example.com` is also set up in [05 — Domain and Mailbox](05-domain-and-mailbox.md).

### Autodiscover and autoconfig — client setup

These hostnames allow email clients (Outlook, Apple Mail, Thunderbird) to automatically configure account settings using only the email address.

```
Type:   CNAME
Name:   autodiscover
Target: mail.example.com
TTL:    Auto
Proxy:  DNS only
```

```
Type:   CNAME
Name:   autoconfig
Target: mail.example.com
TTL:    Auto
Proxy:  DNS only
```

## Enable DNSSEC

If using Cloudflare:

- **DNS → Settings → DNSSEC → Enable**

If the domain is registered through Cloudflare Registrar, the DS records are automatically published in the parent zone (`.com` registry) — no additional action required. Activation takes 5–60 minutes.

For domains registered elsewhere, Cloudflare displays the DS record values that must be added at the registrar. Each registrar's interface is different.

Verify DNSSEC is fully active:

```bash
dig DS example.com +short
```

Should return a DS record. If empty after an hour, check the Cloudflare DNSSEC status page; if it shows "Pending" beyond an hour, the registrar has not published the DS record.

## Verification

After all records are added, verify each one:

```bash
echo "=== A record ==="
dig +short A mail.example.com

echo "=== AAAA record ==="
dig +short AAAA mail.example.com

echo "=== MX record ==="
dig +short MX example.com

echo "=== SPF ==="
dig +short TXT example.com | grep spf1

echo "=== DMARC ==="
dig +short TXT _dmarc.example.com

echo "=== MTA-STS announcement ==="
dig +short TXT _mta-sts.example.com

echo "=== MTA-STS hostname ==="
dig +short A mta-sts.example.com

echo "=== TLS-RPT ==="
dig +short TXT _smtp._tls.example.com

echo "=== Reverse DNS (FCrDNS check) ==="
dig +short -x FLOATING_IP

echo "=== DNSSEC ==="
dig DS example.com +short
```

All records except DKIM should resolve to expected values. DKIM is added in a later phase.

## Common pitfalls

**Cloudflare proxy enabled on mail records.**
The orange cloud must be disabled for `mail`, `mta-sts`, `autodiscover`, `autoconfig`. If enabled, SMTP connections fail because Cloudflare proxies HTTP only.

**SPF record with multiple definitions.**
A domain may have only one SPF record. If multiple TXT records starting with `v=spf1` exist, receivers reject all of them. Merge into one record using `include:` or explicit IPs.

**Mismatched DMARC policy and SPF/DKIM alignment.**
With `adkim=s; aspf=s` (strict), the From header domain must exactly match the SPF and DKIM domains. Subdomain mismatches fail DMARC.

**DNSSEC activated at DNS provider but not registrar.**
If `dig DS example.com` returns empty after an hour, the parent zone (`.com`) does not have the DS record. Check the registrar's DNSSEC settings.

## Summary

After this phase, the domain has:

- A and AAAA records for the mail hostname
- MX record pointing to the mail hostname
- SPF, DMARC, MTA-STS announcement, TLS-RPT records published
- MTA-STS hostname for the policy file (file content comes later)
- Autodiscover and autoconfig CNAMEs for client setup
- DNSSEC active end-to-end (registry, DNS provider, validation)

DKIM is the only authentication record still pending — it requires Mailcow to generate the key first. Proceed to [04 — Mailcow Installation](04-mailcow-installation.md).
