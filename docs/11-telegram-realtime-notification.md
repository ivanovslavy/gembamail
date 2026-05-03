# 11 — Real-Time Email Notifications via Telegram

A self-hosted email server presents a multi-mailbox monitoring problem. With ten or more business mailboxes across multiple domains, regularly logging into SOGo for each one becomes impractical, and IMAP push notifications on phones can be unreliable for low-volume mailboxes that providers throttle.

This chapter documents a small Node.js service that watches multiple IMAP mailboxes in real time via IMAP IDLE and forwards new-message events to a Telegram bot. Latency from email arrival to phone notification is under two seconds.

The pattern is simple, the dependencies are minimal, and the result is reliable enough to replace a checking-the-inbox-every-hour habit with a passive notification stream that wakes the phone exactly when a real human (or a real service) sends mail.

## Why this and not other patterns

A few alternatives were considered:

**Native phone email apps.** Adding each mailbox to Gmail or Apple Mail works for one or two accounts. With ten mailboxes the phone app becomes cluttered and battery-hungry, and providers throttle IMAP push for accounts with low engagement (which all of these are at the start).

**Forwarding to a single inbox.** Setting up Sieve filters that forward every contact mailbox to one master mailbox solves the multi-account problem but obscures the original recipient. Reply-from-correct-account becomes a manual ritual.

**Custom dashboard / PWA.** Browser-based push notifications are unreliable across devices and battery-drain on mobile. Service Workers help but require constant maintenance against browser changes. The custom-app effort buys very little over what SOGo already provides.

**Telegram bot.** Push notifications are Telegram's core competency. The phone app is already running anyway. Desktop client integrates with Linux notification daemons natively. The bot infrastructure is free, the API is stable, and the phone-side reliability matches that of WhatsApp or Signal — which is to say, near-100% in practice.

The Telegram approach was chosen because it cleanly separates "viewing/replying to email" (still done in SOGo or a desktop client) from "knowing that mail arrived" (now handled by Telegram). The two concerns don't have to share an interface.

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│  EMAIL ARRIVES                                             │
│  Customer → contacts@<domain>                              │
│         ↓                                                  │
│  Postfix (mailcow) → Dovecot → INBOX                       │
└─────────────────────────┬──────────────────────────────────┘
                          │ IMAP IDLE event
                          ▼
┌────────────────────────────────────────────────────────────┐
│  gembamail-telegram.service (Node.js, ~140 lines)         │
│    • Long-lived IMAP connection per mailbox                │
│    • imapflow library handles IDLE, reconnects, TLS       │
│    • On 'exists' event: fetch envelope, format, send      │
└─────────────────────────┬──────────────────────────────────┘
                          │ POST sendMessage
                          ▼
┌────────────────────────────────────────────────────────────┐
│  Telegram Bot API                                          │
│  Pushes to all your devices (phone + desktop)              │
└─────────────────────────┬──────────────────────────────────┘
                          ▼
        ┌─────────────────┴────────────────┐
        ▼                                  ▼
┌──────────────────┐              ┌──────────────────┐
│ 📱 Phone Telegram │              │ 💻 Telegram Desktop│
│ Lock screen alert│              │ Native popup      │
│ Sound + vibrate  │              │ Sound + tray icon │
└──────────────────┘              └──────────────────┘
```

End-to-end latency: typically 1–2 seconds from `Postfix received` to the notification ringing the phone.

## Prerequisites

- Mailcow instance with at least one mailbox configured
- A server reachable from the IMAP host (the Mailcow host itself is fine, and convenient — IMAP traffic stays on localhost)
- Node.js 18+ on that server
- A Telegram account
- Outbound HTTPS to `api.telegram.org` (no inbound exposure required)

## Step 1 — Create the Telegram bot

1. Open Telegram, find `@BotFather`, send `/start`.
2. Send `/newbot`. BotFather asks for:
   - **Display name** — anything human-readable (e.g. `GembaMail Notifier`)
   - **Username** — must end in `bot` and be globally unique (e.g. `gembamail_notifier_bot`)
3. BotFather replies with a token of the form `8605890011:AAE5mIPCB3xOhQuUYCThP4Q-...`
4. Save the token in your password manager. It is the entire authentication for the bot — anyone with the token can post as the bot.

## Step 2 — Discover your chat ID

The bot needs to know who to message. Telegram chats have integer IDs distinct from human usernames.

1. Search your bot by username in Telegram, click `Start`.
2. Send any message (`hello` works).
3. Open this URL in a browser, replacing `<TOKEN>`:

   ```
   https://api.telegram.org/bot<TOKEN>/getUpdates
   ```
4. Find the `chat` object in the response:

   ```json
   {
     "ok": true,
     "result": [{
       "message": {
         "chat": { "id": 7427418521, "first_name": "...", "type": "private" },
         "text": "hello"
       }
     }]
   }
   ```

   The number after `"id":` inside `chat` is your chat ID.

5. Save it next to the bot token.

If `result` is `[]`, you haven't sent the bot a message yet — Telegram only queues `getUpdates` data when there's something to deliver.

## Step 3 — Verify the bot can reach you

From the server that will run the notifier:

```bash
TOKEN="..."     # from step 1
CHAT_ID="..."   # from step 2

curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
  -d "chat_id=$CHAT_ID" \
  -d "text=Hello from the notifier server"
```

A `{"ok":true,"result":{"message_id":...}}` response and a phone notification confirm both halves work. If anything fails here, fix it before continuing — the rest of this guide assumes the API path is healthy.

## Step 4 — Project layout

```bash
mkdir -p ~/gembamail-telegram
cd ~/gembamail-telegram
```

`package.json`:

```json
{
  "name": "gembamail-telegram",
  "version": "1.0.0",
  "description": "Telegram notifications for new emails",
  "main": "notifier.js",
  "scripts": { "start": "node notifier.js" },
  "dependencies": {
    "imapflow": "^1.0.156",
    "node-fetch": "^2.7.0",
    "dotenv": "^16.4.5"
  }
}
```

```bash
npm install
```

Three dependencies:
- **imapflow** — modern IMAP client with built-in IDLE support, TLS, and clean reconnect logic
- **node-fetch** — to POST to the Telegram API
- **dotenv** — to read configuration from `.env` (cleaner than inline systemd `Environment=`)

## Step 5 — The notifier script

`notifier.js`:

```javascript
require('dotenv').config();

const { ImapFlow } = require('imapflow');
const fetch = require('node-fetch');

// ─── CONFIGURATION ────────────────────────────────────────
const TELEGRAM_TOKEN = process.env.TELEGRAM_TOKEN;
const TELEGRAM_CHAT_ID = process.env.TELEGRAM_CHAT_ID;
const IMAP_HOST = process.env.IMAP_HOST || 'mail.gembamail.com';
const IMAP_PORT = parseInt(process.env.IMAP_PORT) || 993;

// MAILBOXES env: "user1:pass1,user2:pass2,..."
const MAILBOXES = (process.env.MAILBOXES || '')
  .split(',')
  .filter(Boolean)
  .map(entry => {
    const colonIdx = entry.indexOf(':');
    return {
      user: entry.slice(0, colonIdx).trim(),
      pass: entry.slice(colonIdx + 1).trim(),
    };
  });

// ─── TELEGRAM ────────────────────────────────────────────
async function sendTelegram(text) {
  try {
    const res = await fetch(
      `https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          chat_id: TELEGRAM_CHAT_ID,
          text,
          parse_mode: 'Markdown',
          disable_web_page_preview: true,
        }),
      }
    );
    const data = await res.json();
    if (!data.ok) console.error(`[telegram] ${data.description}`);
  } catch (err) {
    console.error(`[telegram] send failed: ${err.message}`);
  }
}

// ─── EMAIL FORMATTING ───────────────────────────────────
function formatNotification(mailbox, message) {
  const fromAddr = message.envelope.from?.[0]?.address || 'unknown';
  const fromName = message.envelope.from?.[0]?.name || fromAddr;
  const subject = message.envelope.subject || '(no subject)';
  const esc = (s) => String(s).replace(/[_*`\[\]()]/g, '\\$&');
  const domain = mailbox.split('@')[1] || mailbox;
  const tag = domain.replace('.com', '').replace('.io', '').toUpperCase();

  return `🔔 *[${esc(tag)}]*\n\n` +
         `*To:* ${esc(mailbox)}\n` +
         `*From:* ${esc(fromName)} <${esc(fromAddr)}>\n` +
         `*Subject:* ${esc(subject)}`;
}

// ─── IMAP MONITOR ───────────────────────────────────────
async function monitorMailbox({ user, pass }) {
  const RECONNECT_DELAY = 10000;

  while (true) {
    let client;
    try {
      console.log(`[${user}] connecting...`);
      client = new ImapFlow({
        host: IMAP_HOST,
        port: IMAP_PORT,
        secure: true,
        auth: { user, pass },
        logger: false,
      });
      await client.connect();
      console.log(`[${user}] connected, opening INBOX`);
      await client.mailboxOpen('INBOX');
      console.log(`[${user}] watching for new messages (IMAP IDLE)`);

      client.on('exists', async (data) => {
        try {
          const messages = client.fetch(
            `${data.count}:${data.count}`,
            { envelope: true, uid: true }
          );
          for await (const message of messages) {
            const text = formatNotification(user, message);
            await sendTelegram(text);
            console.log(
              `[${user}] notified: ${message.envelope.subject || '(no subject)'}`
            );
          }
        } catch (err) {
          console.error(`[${user}] fetch error: ${err.message}`);
        }
      });

      while (client.usable) {
        await new Promise(r => setTimeout(r, 60000));
        try { await client.noop(); } catch { break; }
      }
    } catch (err) {
      console.error(`[${user}] connection error: ${err.message}`);
    } finally {
      if (client) { try { await client.logout(); } catch {} }
    }
    console.log(`[${user}] reconnecting in ${RECONNECT_DELAY/1000}s`);
    await new Promise(r => setTimeout(r, RECONNECT_DELAY));
  }
}

// ─── MAIN ───────────────────────────────────────────────
async function main() {
  if (!TELEGRAM_TOKEN || !TELEGRAM_CHAT_ID) {
    console.error('TELEGRAM_TOKEN and TELEGRAM_CHAT_ID required');
    process.exit(1);
  }
  if (MAILBOXES.length === 0) {
    console.error('MAILBOXES required (format: user1:pass1,user2:pass2)');
    process.exit(1);
  }
  console.log(`Starting GembaMail Telegram Notifier`);
  console.log(`Monitoring ${MAILBOXES.length} mailbox(es):`);
  MAILBOXES.forEach(({ user }) => console.log(`  - ${user}`));
  await sendTelegram(
    `🟢 *GembaMail Notifier started*\n\n` +
    `Monitoring ${MAILBOXES.length} mailbox(es).`
  );
  await Promise.all(MAILBOXES.map(monitorMailbox));
}

main().catch(err => {
  console.error('Fatal error:', err);
  process.exit(1);
});
```

A few notes on the implementation:

**The reconnect loop.** The `while (true)` wrapper around each mailbox monitor isn't paranoid — IMAP IDLE connections do drop. Network blips, server restarts, IMAP server timeouts (Dovecot defaults to 29 minutes, just under the 30-minute IDLE limit recommended by RFC), all cause the inner loop to exit and the outer loop to reconnect after 10 seconds. Without this, a single transient failure would silently disable monitoring for that mailbox until the service restarts.

**The `noop()` keepalive.** Without periodic activity, NAT routers and stateful firewalls drop "idle" connections. `client.noop()` every 60 seconds keeps the IMAP socket warm. Imapflow's `client.usable` flag means the loop exits cleanly when the underlying connection breaks rather than hanging on `noop()`.

**Per-mailbox isolation.** Each mailbox runs its own loop in parallel via `Promise.all(...).map(monitorMailbox)`. One mailbox's auth failure or connection issue doesn't affect the others. Logs are prefixed with the mailbox address for easy debugging.

**Markdown escaping.** Telegram's Markdown parser is unforgiving about unescaped underscores, asterisks, and brackets in user-controlled content. The `esc()` helper handles this. Without it, an email subject like "*urgent*" or "[ticket #1234]" can crash the formatter and silently fail to deliver.

**No body in the notification.** Subject and sender are enough to decide whether to look. Including the body invites privacy issues (lock-screen visibility), Markdown corruption, and Telegram size limits. The full message stays where it belongs — in the actual mailbox.

## Step 6 — Configuration via .env

`.env`:

```ini
TELEGRAM_TOKEN=8605890011:AAE5mIPCB3xOhQuUYCThP4Q-ua4-YU42BD8
TELEGRAM_CHAT_ID=7427418521
IMAP_HOST=mail.gembamail.com
IMAP_PORT=993

# Comma-separated user:password pairs, one mailbox per pair
MAILBOXES=contacts@example.com:PASS1,support@example.com:PASS2,info@other.com:PASS3
```

The `MAILBOXES` format is intentionally a flat string. Originally the parsing supported a JSON list, but that made systemd `Environment=` quoting awkward. The simple comma-and-colon string format works whether the value comes from `.env` (where neither character has special meaning) or from a future systemd `EnvironmentFile=`.

A constraint: passwords cannot contain `,` or `:`. Mailcow-generated passwords are random alphanumeric+symbols and rarely contain either, but it's worth checking before adding a mailbox to the list.

Set `chmod 600 .env` after editing — the file contains every IMAP password in plaintext. The notifier reads it at startup.

## Step 7 — Which mailboxes to monitor

This is a judgment call. The reasonable default is "anything where a real human or a real customer might write to me, and not the ones I deliberately don't want to read."

For the deployment documented elsewhere in this guide, ten of nineteen active mailboxes were chosen:

```
Monitored (10):
  contacts@gembait.com           ← website inquiries
  contacts@gembapay.com          ← payment platform support
  contacts@gembaindustrial.com   ← refinery services inquiries
  contacts@gembateam.com         ← team site contact form
  contacts@gembatools.io         ← DEX support
  contacts@gembaticket.com       ← ticketing platform support
  office@gembapay.com            ← financial / accounting
  security@gembapay.com          ← vulnerability disclosures (high priority)
  support@gembapay.com           ← customer support
  slavy@gembamail.com            ← personal master inbox

Not monitored (9):
  noreply@*  (×2)  — automated outbound; replies are spam, redirected by auto-responder
  postmaster@*  (×7) — system mail, daily DMARC reports, mostly noise
```

The pattern is: **monitor mailboxes where a missed message has a cost; skip mailboxes where every message is automated infrastructure traffic.** Postmaster, dmarc, tlsrpt, and abuse aliases all fall in the second category — Telegram pings every time a DMARC report arrives would be insufferable.

## Step 8 — Systemd unit

`/etc/systemd/system/gembamail-telegram.service`:

```ini
[Unit]
Description=GembaMail Telegram Notifier
Documentation=https://github.com/ivanovslavy/gembamail
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=slavy
Group=slavy
WorkingDirectory=/home/slavy/gembamail-telegram
ExecStart=/usr/bin/node /home/slavy/gembamail-telegram/notifier.js

# Restart on failure (with backoff)
Restart=always
RestartSec=10
StartLimitBurst=5
StartLimitIntervalSec=300

# Logging
StandardOutput=journal
StandardError=journal

# Resource limits
MemoryMax=200M
TasksMax=50

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/home/slavy/gembamail-telegram

[Install]
WantedBy=multi-user.target
```

A few choices worth explaining:

**Run as the user, not root.** The notifier reads `.env` (chmod 600 owned by the user) and makes outbound HTTPS connections. Nothing requires elevation. Running as the user limits the blast radius of any vulnerability in `imapflow` or `node-fetch`.

**`After=network-online.target`, not just `network.target`.** The notifier resolves DNS and opens TLS connections at startup. The weaker `network.target` only guarantees the network stack is configured, not that DNS works. On boot this distinction sometimes matters.

**Restart with backoff.** `Restart=always` plus the `StartLimitBurst`/`StartLimitIntervalSec` pair means: if the script keeps crashing, give up after five rapid restarts in five minutes. Without the limit, a misconfigured `.env` would crash-loop forever and fill the journal.

**Memory and task ceilings.** A correctly running notifier uses about 35–40 MB and ~14 tasks (one per IMAP connection plus the Node main thread and a few workers). The 200 MB / 50 task limits are more than generous; if the service exceeds them, something is genuinely wrong (connection leak, runaway loop) and stopping is the right call.

**The hardening block.** `NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=strict`, and `ProtectHome=read-only` together produce a process that cannot escalate privileges, cannot write outside its working directory, cannot read other users' home directories, and gets a private `/tmp`. Worth doing for any service that handles credentials and reaches the internet.

```bash
sudo systemctl daemon-reload
sudo systemctl enable gembamail-telegram
sudo systemctl start gembamail-telegram
sudo systemctl status gembamail-telegram
```

A healthy startup looks like this in `journalctl -u gembamail-telegram`:

```
Started gembamail-telegram.service
Starting GembaMail Telegram Notifier
Monitoring 10 mailbox(es):
  - contacts@gembait.com
  - ...
[contacts@gembait.com] connecting...
[contacts@gembait.com] connected, opening INBOX
[contacts@gembait.com] watching for new messages (IMAP IDLE)
... (one block per mailbox)
```

And on the phone, a Telegram message from the bot:

```
🟢 GembaMail Notifier started
Monitoring 10 mailbox(es).
```

## Step 9 — End-to-end test

Send mail from any external address to one of the monitored mailboxes:

```
To: contacts@gembait.com
Subject: Notifier verification
```

Within one to two seconds, two things should happen:

1. The journal logs `[contacts@gembait.com] notified: Notifier verification`.
2. The phone (and desktop, if Telegram Desktop is running) shows a notification:

```
🔔 [GEMBAIT]
To: contacts@gembait.com
From: Sender Name <sender@example.com>
Subject: Notifier verification
```

If the journal logs the notification but the phone doesn't show it, check the bot's chat — sometimes Telegram silences notifications when the chat is open on another device. Sending `/start` to the bot from the phone often fixes this.

## Step 10 — Telegram Desktop on the workstation

Cross-device synchronization is automatic. Install Telegram Desktop on the workstation:

```bash
sudo snap install telegram-desktop
# or
sudo apt install telegram-desktop
```

Sign in with the same Telegram account, and the bot's chat appears in the sidebar. Linux notifications use the system tray and the desktop notification daemon — same as Slack or Discord do natively. Notifications come through whether the Telegram Desktop window is open or not (only the application needs to be running, not focused).

iOS, Android, and macOS clients all behave the same way. Once the bot is paired with a Telegram account, any device signed into that account receives notifications.

## Operating it

**Adding a mailbox.** Edit `.env`, append `,user@domain:password` to `MAILBOXES`, then `sudo systemctl restart gembamail-telegram`. The startup notification confirms the new count.

**Removing a mailbox.** Edit `.env`, remove the entry, restart. No state to clean up — the script holds nothing persistent.

**Rotating a password.** Update Mailcow first (the mailbox owner), then update `.env`, then restart. The IMAP IDLE connection for that mailbox will fail on the next connection attempt and reconnect with the new credential.

**Pausing notifications.** `sudo systemctl stop gembamail-telegram`. Mail still arrives normally; the notifier just isn't watching. Restart when ready.

**Filtering noise.** The current implementation notifies on every new message. If a particular sender or subject pattern becomes spammy (e.g., automated reports a service started sending), filter at the source — Sieve rules in SOGo can move messages to a folder, and the notifier only watches INBOX. Out of sight, out of notification.

## What this doesn't try to do

A few deliberate non-features:

- **No body preview.** Subject and sender are enough to decide whether to look. Bodies invite privacy and parsing issues.
- **No replies from the bot.** Telegram is for awareness; replies happen in SOGo or Thunderbird where the full UI exists.
- **No filtering or routing logic.** The notifier is a thin pipe. Sieve is the right place for filtering, before the message hits the inbox.
- **No high-availability.** Single-process, single-host. If the host dies, notifications stop. The mail still arrives correctly; only the side-channel signal is offline. This is acceptable for the use case.
- **No multi-recipient or per-mailbox routing.** All notifications go to one chat ID. If you want one chat per priority tier or per team member, that's a small extension — the `chat_id` could be looked up from a per-mailbox map. But the simple case covers the typical user well enough that this hasn't been needed.

## Resource footprint

The service settles at:

- ~35–40 MB resident memory
- 14 OS tasks (10 IMAP connections + main + a handful of workers)
- Negligible CPU (only spikes briefly on each new message)
- About 1 KB/minute of network traffic (IMAP NOOP keepalives) plus whatever Telegram needs per notification (~1 KB)

On a 2 vCPU / 4 GB Hetzner CAX11 already running Mailcow (which takes ~2 GB), the notifier is essentially free. Co-locating it on the mail server keeps IMAP traffic on localhost and avoids any external port exposure.

## Troubleshooting

**`Authentication failed`.** Wrong password in `.env`. Check the corresponding mailbox in Mailcow Admin. If the password contains `:` or `,`, it conflicts with the parsing format — generate a new one without those characters.

**`Connection refused` or `ENOTFOUND`.** IMAP_HOST or IMAP_PORT is wrong, or DNS isn't resolving. Test with `openssl s_client -connect mail.gembamail.com:993` from the same host.

**Service starts but no Telegram messages.** Check the journal for `[telegram] ...` errors. Most commonly this is a wrong `TELEGRAM_TOKEN` or `TELEGRAM_CHAT_ID`. Verify with the curl test from Step 3.

**Phone doesn't notify but desktop does.** Telegram suppresses phone notifications when the chat is open on another device. Open the bot's chat on the phone and the notifications resume.

**One mailbox keeps reconnecting.** Check IMAP IDLE timeouts in your mail server. Dovecot's default 29 minutes is fine; if it's been lowered, the noop-every-60-seconds keepalive may not be enough. Either increase the IMAP timeout or shorten the noop interval.

**The journal fills with reconnect messages.** Something is repeatedly knocking the IMAP connection out — usually a misbehaving stateful firewall between the notifier host and the mail host. If they're the same host, this shouldn't happen; otherwise consider running the notifier on the mail host.

## Summary

Ten mailboxes, one Node.js process, ~140 lines of code, ~40 MB of memory, sub-2-second notification latency. Setup time once the bot is created: about 30 minutes. The infrastructure to run it reliably (IMAP, TLS, the mail server itself) was already there.

The result is a working passive monitoring system that covers a multi-domain self-hosted email setup without custom apps, browser tabs, or polling loops. It complements the Mailcow installation rather than competing with it — SOGo and Thunderbird remain the right places to read and reply, and the bot just makes sure nothing arrives unnoticed.

Proceed to [12 — Maintenance](12-maintenance.md) for ongoing operational concerns.
