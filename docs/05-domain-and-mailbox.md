# 05 — Domain and Mailbox

This phase adds the first domain to Mailcow, generates the DKIM key, publishes it in DNS, activates MTA-STS, and creates the first mailboxes.

## Add the domain

In Mailcow Admin UI: **E-Mail → Configuration → Domains → Add domain**.

Recommended values for a personal or small business domain:

| Field | Value | Notes |
|---|---|---|
| Domain | `example.com` | The actual mail domain |
| Description | Free-form | Visible only to admins |
| Template | `Default` | Custom templates can be added later |
| Max. possible aliases | `400` | Generous; aliases are cheap |
| Max. possible mailboxes | `100` | Buffer for future growth |
| Default mailbox quota | `2048` (MiB) | 2 GB default; can be raised per mailbox |
| Max. quota per mailbox | `40960` (MiB) | 40 GB ceiling for any single mailbox |
| Total domain quota | `204800` (MiB) | 200 GB across all mailboxes |

Checkbox settings:

- ☑ Active
- ☑ Global Address List (GAL) — enables free/busy info in SOGo
- ☐ Relay this domain — leave unchecked
- ☐ Relay all recipients — leave unchecked
- ☐ Relay non-existing mailboxes — leave unchecked
- ☐ Disable spam filter for this domain — never check this
- ☐ Disable mail attachment scan — never check this

Rate limit (important for reputation):

- Set to `50 msgs / hour` initially.

This is per-mailbox at the domain level. If a mailbox is compromised and starts sending spam, the limit caps damage at 50 messages per hour before manual intervention. For transactional or bulk-sending mailboxes, raise the limit individually later.

DKIM section:

- Selector: `dkim`
- Key length: `2048` bits

The DKIM key is generated automatically when the domain is saved. Click **Add domain and restart SOGo** — the SOGo restart is required so the webmail recognizes the new domain.

## Get the DKIM record

After the domain is created, return to **Domains** and click the **DNS** button next to the new domain. Mailcow displays the full set of expected DNS records and which ones are currently correct.

The DKIM record is the last one in the list:

```
Name:    dkim._domainkey.example.com
Type:    TXT
Content: v=DKIM1;k=rsa;t=s;s=email;p=MIIBIjANB...
```

Copy the entire `Content` value — it is several hundred characters long.

In Cloudflare DNS:

```
Type:    TXT
Name:    dkim._domainkey
Content: [paste the entire string from Mailcow]
TTL:     Auto
```

Cloudflare automatically splits the long string into 255-character segments at the protocol level. This is correct behavior — DNS resolvers concatenate the segments transparently when reading the record.

Verify after a minute:

```bash
dig +short TXT dkim._domainkey.example.com
```

The output may show two strings on separate lines (split by Cloudflare). This is normal.

## Verify DNS state in Mailcow

Return to the **DNS** view in Mailcow Admin. Each record now has either:

- ✅ Green checkmark — record is correct
- ⓦ "²" footnote — record is optional (TLSA, SRV, IPv6 PTR)
- ❌ Red X — record is missing or incorrect

After DKIM is added, only the optional records should show "²". All required records (A, AAAA, MX, SPF, DMARC, MTA-STS announcement, MTA-STS hostname, TLS-RPT, DKIM, autodiscover, autoconfig) should be green.

## Activate MTA-STS

The MTA-STS DNS records announce a policy, but the policy file itself must exist and be served. In newer Mailcow versions, the policy is generated dynamically per-domain and must be activated.

**Edit the domain → MTA-STS tab**:

| Field | Value |
|---|---|
| Version | `STSv1` |
| Mode | `enforce` |
| Max age | `86400` (24 hours) |
| MX server | `mail.example.com` |
| Active | ☑ |

Save. Verify the policy file is now served:

```bash
curl -s https://mta-sts.example.com/.well-known/mta-sts.txt
```

Should output:

```
version: STSv1
mode: enforce
max_age: 86400
mx: mail.example.com
```

Mode meanings:

- `enforce` — receivers reject delivery if TLS cannot be established (strongest, recommended for production)
- `testing` — receivers log issues but still deliver
- `none` — disables MTA-STS

## Create the postmaster mailbox

`postmaster@` is required by RFC 5321 for every email domain. It receives administrative messages, abuse reports, and verification emails for services like Microsoft SNDS.

**E-Mail → Configuration → Mailboxes → Add mailbox**:

| Field | Value |
|---|---|
| Username | `postmaster` |
| Domain | `example.com` |
| Full name | `Postmaster` |
| Password | Strong, generated, stored in password manager |
| Quota | `1024` (1 GB is plenty for a system mailbox) |
| Active | ☑ |
| Direct forwarding to SOGo | ☑ |

Encryption policy: enable both **Enforce TLS incoming** and **Enforce TLS outgoing**.

Rate limit: `10 msgs / hour` (this mailbox should rarely send anything).

## Create the first user mailbox

Same form, with values for the actual user:

| Field | Value |
|---|---|
| Username | `slavy` |
| Domain | `example.com` |
| Full name | The user's real name (appears in From) |
| Password | Strong, generated, given to the user securely |
| Quota | `10240` (10 GB for a regular user) |
| Active | ☑ |

Encryption policy: enable both **Enforce TLS incoming** and **Enforce TLS outgoing**.

Rate limit: `50 msgs / hour` (sane default; raise for power users).

For mailboxes given to other people, also enable:

- ☑ Force 2FA enrollment at login

This requires the user to set up TOTP on first login before accessing the webmail.

## Create system aliases

Three aliases are needed because the DMARC, TLS-RPT, and abuse contact addresses are referenced in DNS records and by external services like Microsoft JMRP.

**E-Mail → Configuration → Aliases → Add alias**:

| Address | Goes to |
|---|---|
| `abuse@example.com` | `postmaster@example.com` |
| `dmarc@example.com` | `postmaster@example.com` |
| `tlsrpt@example.com` | `postmaster@example.com` |

All three forward to `postmaster@`, which becomes the central inbox for administrative messages. Set Active for all three.

## First test — internal email

Log out of the admin panel and log in as the user mailbox at `https://mail.example.com`:

- Email: `slavy@example.com`
- Password: the mailbox password

The interface forwards to SOGo webmail.

Send a test email to yourself:

- To: `slavy@example.com`
- Subject: anything
- Body: anything

The message should arrive in the inbox within a few seconds. View the source (in SOGo: open message, three-dot menu, **Show source**) to verify the DKIM signature is present:

```
DKIM-Signature: v=1; a=rsa-sha256; c=relaxed/relaxed; d=example.com;
    s=dkim; t=...; ...
    bh=...
    b=...
```

Internal delivery does not show `Authentication-Results:` — that header is added by external receivers, not by Mailcow itself.

## First test — external email (Mail-Tester)

Visit [mail-tester.com](https://www.mail-tester.com) — the page displays a randomly generated test address.

In SOGo, compose an email to this address:

- Use a substantial body (50+ words)
- Avoid words associated with spam ("free", "guaranteed", "click here")
- Use a normal subject

After sending, return to mail-tester and click **Then check your score**.

The expected score for a correctly configured deployment is **10/10**. If the score is lower:

- 8–9: One or two minor issues, usually solvable
- Below 8: Significant problem, likely an authentication record

The breakdown identifies which checks failed. Common issues at this stage:

- DKIM record not yet propagated in DNS (wait 5 minutes, retry)
- DMARC record syntax error (truncated by DNS provider)
- MTA-STS not yet active (revisit the activation step above)

## Summary

After this phase:

- Domain added with appropriate quotas and rate limits
- DKIM key generated and published in DNS
- MTA-STS policy active in enforce mode
- `postmaster@` mailbox created
- First user mailbox created
- System aliases (`abuse@`, `dmarc@`, `tlsrpt@`) point to postmaster
- Internal mail delivery verified
- External deliverability verified at 10/10

The server is ready for production use. The next phases cover deliverability theory, monitoring setup, and warmup. Proceed to [06 — Deliverability Essentials](06-deliverability-essentials.md).
