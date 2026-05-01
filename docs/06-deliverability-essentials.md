# 06 — Deliverability Essentials

This phase explains the authentication chain that makes self-hosted email actually deliverable. By this point all records are configured and operational; the goal here is to understand what each does and why the chain matters.

## The deliverability question

When mail leaves your server, the receiving system asks one fundamental question: **"Should I trust this message enough to put it in the inbox?"**

The answer comes from a combination of:

- **Authentication** — can I verify this came from who it claims to be from?
- **Reputation** — what is the sending IP and domain's history?
- **Content** — does the message itself look legitimate?
- **Engagement** — do recipients of this sender's mail interact with it?

Authentication is the only one fully within the sender's control. Reputation builds slowly through correct behavior. Content is mostly common sense. Engagement is the recipient's response to the first three.

This guide configures all four to the highest practical standard.

## SPF — Sender Policy Framework

SPF declares which IP addresses are authorized to send mail for the domain. When mail arrives at Gmail claiming to be from `slavy@example.com`, Gmail looks up the SPF record at `example.com`. If the connecting IP matches, SPF passes.

The published record:

```
v=spf1 mx ~all
```

Translation: "The hosts listed in my MX record are authorized senders. For anything else, soft fail (mark as suspicious but accept)."

SPF alone is insufficient. It only authenticates the SMTP envelope sender (`MAIL FROM`), not the From header that users actually see. A spammer can put a legitimate domain in `MAIL FROM` and a fake address in `From:` and SPF still passes. This is why DKIM and DMARC exist.

## DKIM — DomainKeys Identified Mail

DKIM cryptographically signs the message — both selected headers and (usually) the body. The signature is attached as a `DKIM-Signature:` header. The receiver fetches the public key from DNS and verifies the signature.

The published key (in `dkim._domainkey.example.com`):

```
v=DKIM1;k=rsa;t=s;s=email;p=MIIBIjANBgkqhkiG9w0BAQEF...
```

A valid DKIM signature proves two things:

1. **The message was signed by someone holding the private key for `example.com`** — that is, the legitimate operator of the domain
2. **The message was not modified in transit** — any change to signed headers or the body invalidates the signature

The 2048-bit RSA key length is the current minimum. 1024-bit is deprecated. 4096-bit is overkill and causes interoperability issues with some receivers.

Mailcow rotates DKIM keys via the admin UI (Configuration → ARC/DKIM Keys). Rotation requires:

1. Generate new key with a new selector (e.g., `dkim2`)
2. Publish new public key in DNS
3. Wait for DNS propagation
4. Switch active selector in Mailcow to the new one
5. Wait for in-flight messages to be delivered (typically 7 days)
6. Remove old DNS record and old key from Mailcow

Annual rotation is good practice but not urgent.

## DMARC — Domain-based Message Authentication, Reporting, and Conformance

DMARC ties SPF and DKIM together with a policy. It answers: "When SPF or DKIM fails, what should the receiver do?"

The published record:

```
v=DMARC1; p=none; rua=mailto:dmarc@example.com; ruf=mailto:dmarc@example.com; fo=1; adkim=s; aspf=s
```

Three things matter:

**1. Policy (`p=`)**
- `none` — observe and report only (current setting, correct for deployment)
- `quarantine` — failing messages go to spam folder
- `reject` — failing messages are bounced

**2. Alignment**
DMARC requires that SPF or DKIM not just pass, but pass with a domain that aligns with the visible From header. With `adkim=s; aspf=s` (strict), the domain in `From:` must exactly match the domain in `MAIL FROM` (for SPF) or the `d=` of the DKIM signature.

**3. Reports**
Aggregate reports (`rua=`) come from receivers as XML files describing all the messages they saw claiming to be from this domain — both legitimate and spoofed. Forensic reports (`ruf=`) are individual failure reports.

Reports arrive at `dmarc@example.com`. Initially they are intimidating XML, but the structure is simple: who sent mail claiming to be from this domain, from which IPs, with what authentication results, and what the receiver did with each.

After two weeks of clean reports — meaning all legitimate mail authenticates correctly and no surprising senders appear — tighten the policy:

```
v=DMARC1; p=quarantine; pct=10; rua=mailto:...
```

`pct=10` applies the policy to 10% of messages. Increase weekly if no problems arise. Eventually reach `p=reject` with `pct=100`.

## MTA-STS — Mail Transfer Agent Strict Transport Security

MTA-STS forces TLS for connections to the domain's MX. Without MTA-STS, opportunistic TLS can be downgraded by an attacker — the sender falls back to plaintext if TLS appears unavailable.

The policy file at `https://mta-sts.example.com/.well-known/mta-sts.txt`:

```
version: STSv1
mode: enforce
max_age: 86400
mx: mail.example.com
```

`mode: enforce` means: "Senders should refuse delivery if TLS to my MX cannot be established."

For deployments confident in their TLS setup, `enforce` is correct. `testing` is appropriate during initial rollout if there is uncertainty about TLS configuration — receivers will report problems via TLS-RPT but still deliver.

## TLS-RPT — TLS Reporting

The companion to MTA-STS. Receivers that fail TLS connections can report the failure to a contact address.

```
v=TLSRPTv1; rua=mailto:tlsrpt@example.com
```

In normal operation, no reports arrive — TLS to a properly configured server just works. Reports indicate either a transient network issue, a misconfiguration, or an active downgrade attack.

## DNSSEC — Domain Name System Security Extensions

DNSSEC signs the entire DNS zone with a chain of trust extending to the root zone. Without DNSSEC, an attacker who can intercept or poison DNS responses can redirect mail. With DNSSEC, modified responses are detected and rejected.

DNSSEC is not strictly required for email delivery — most receivers do not insist on it. However:

- It is a strong trust signal for filters that do consider it (notably Google's spam filter incorporates it)
- It enables DANE (DNS-based Authentication of Named Entities) for true cryptographic certificate pinning
- It protects against DNS-based phishing of the domain itself

Cloudflare provides one-click DNSSEC for domains using its DNS. For domains registered through Cloudflare Registrar, DS records are automatically published in the parent zone.

## FCrDNS — Forward-Confirmed Reverse DNS

Required by virtually every major receiver. The check:

1. Sending IP claims to be `mail.example.com` (in HELO/EHLO and as the source of the connection)
2. Receiver does reverse DNS lookup on the IP — gets `mail.example.com`
3. Receiver does forward DNS lookup on `mail.example.com` — gets the IP

If both directions agree, FCrDNS passes. If either fails, the receiver typically rejects or marks as suspicious.

This is configured in two places:

- **A and AAAA records** in DNS (forward) — see [03 — DNS Configuration](03-dns-configuration.md)
- **PTR records** at the cloud provider (reverse) — see [02 — VPS Bootstrap](02-vps-bootstrap.md)

Verification:

```bash
# Forward
dig +short A mail.example.com
dig +short AAAA mail.example.com

# Reverse
dig +short -x FLOATING_IP
dig +short -x PRIMARY_IPV6
```

All four must agree.

## ARC — Authenticated Received Chain

ARC handles the case where mail is forwarded. When a mailing list or forwarding service receives a message and re-sends it, the original DKIM signature usually breaks (because headers like Subject get modified). ARC adds a chain of authentication results that downstream receivers can use to evaluate whether the original authentication was valid before forwarding.

Mailcow handles ARC automatically — no configuration needed. ARC headers are added on outgoing mail and verified on incoming mail.

## TLS — Transport Layer Security

All Mailcow connections use TLS by default. Verify:

- **Inbound SMTP (port 25):** STARTTLS offered, opportunistic
- **Submission (port 587):** STARTTLS required for authenticated users
- **SMTPS (port 465):** Implicit TLS, required
- **IMAP (port 143):** STARTTLS required
- **IMAPS (port 993):** Implicit TLS, required

Mailcow uses TLS 1.2 and 1.3 only — older versions are disabled. Cipher suites prioritize forward secrecy and AEAD modes.

For mailboxes, enable both **Enforce TLS incoming** and **Enforce TLS outgoing**. This prevents downgrade and aligns with MTA-STS enforce mode.

## The complete chain

When a message leaves the server, every protective layer activates:

1. **TLS** — connection to the receiver is encrypted
2. **MTA-STS** — receiver knows TLS is mandatory
3. **DKIM** — message is cryptographically signed
4. **SPF** — sending IP is authorized
5. **DMARC** — alignment between SPF/DKIM and From is enforced
6. **FCrDNS** — sending hostname matches reverse DNS
7. **DNSSEC** — DNS responses are tamper-proof
8. **ARC** — chain of authentication preserved through forwards

When a message arrives at Gmail, the `Authentication-Results` header reflects this chain:

```
Authentication-Results: mx.google.com;
    dkim=pass header.i=@example.com header.s=dkim
    spf=pass smtp.mailfrom=user@example.com
    dmarc=pass (p=NONE sp=NONE dis=NONE) header.from=example.com
```

Three `pass` results is the bar for serious email infrastructure. The deployment in this guide achieves all three from the first message.

## Summary

The authentication chain is now fully configured. Every record is published, every protocol is enforced, and the receiver has every signal it needs to trust mail from this domain.

What remains is **building reputation** — and that is a slower process. Authentication says "I am who I claim to be." Reputation says "I am safe to deliver to the inbox." The next phase covers monitoring tools that show how reputation is building, and the one after covers warmup strategy. Proceed to [07 — Monitoring Setup](07-monitoring.md).
