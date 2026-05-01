# 04 — Mailcow Installation

This phase installs Docker, clones Mailcow, generates configuration, and starts all containers. The first start automatically obtains a Let's Encrypt certificate for the mail hostname and additional SAN domains.

## Verify prerequisites

Before starting, confirm the previous phases are complete:

```bash
# Hostname matches PTR
hostname -f
dig +short -x FLOATING_IP

# Port 25 outbound works
nc -zv -w 5 alt1.gmail-smtp-in.l.google.com 25

# DNS records resolve
dig +short A mail.example.com
dig +short MX example.com
```

All must return expected values.

## Install Docker

Mailcow requires the official Docker, not the older `docker.io` package from Ubuntu's repositories.

```bash
# Remove any old versions
apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null

# Dependencies
apt update
apt install -y ca-certificates curl gnupg

# Docker GPG key
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Docker repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker
```

Verify:

```bash
docker --version
docker compose version
docker run --rm hello-world
```

The hello-world container should print a confirmation message.

## Clone Mailcow

```bash
cd /opt
git clone https://github.com/mailcow/mailcow-dockerized
cd mailcow-dockerized

# Show the latest commit (for documentation purposes)
git log -1 --pretty=format:"%h %ad %s" --date=short
```

## Generate configuration

Mailcow ships with a script that prompts for a few values and produces `mailcow.conf`:

```bash
./generate_config.sh
```

Three prompts:

**1. Mail server hostname (FQDN)**
Enter the value matching reverse DNS: `mail.example.com`. This must be exact — Mailcow uses it as the HELO/EHLO greeting and for SSL certificate naming.

**2. Timezone**
Use a real timezone like `Europe/Sofia`. Logs and SOGo webmail will display times in this zone.

**3. Branch**
Choose `1` (master / stable). The nightly branch is for testing; legacy is deprecated.

The script also asks about IPv6 support in Docker. Answer `y` — Mailcow needs IPv6 to receive mail from IPv6-only senders and to deliver to recipients with AAAA records.

## Add additional SAN domains

The Let's Encrypt certificate by default covers only the main hostname. To also cover `mta-sts.example.com`, `autodiscover.example.com`, and `autoconfig.example.com` with the same certificate:

```bash
sed -i 's/^ADDITIONAL_SAN=$/ADDITIONAL_SAN=mta-sts.example.com,autodiscover.example.com,autoconfig.example.com/' mailcow.conf
grep "^ADDITIONAL_SAN" mailcow.conf
```

This avoids needing separate certificates for each subdomain.

## Add subdomain to nginx server_name

Mailcow's nginx serves the main hostname plus a default list of subdomains, but `mta-sts.example.com` is not in that default list. To make Mailcow's nginx respond to requests for it:

```bash
sed -i 's/^ADDITIONAL_SERVER_NAMES=$/ADDITIONAL_SERVER_NAMES=mta-sts.example.com/' mailcow.conf
grep "^ADDITIONAL_SERVER_NAMES" mailcow.conf
```

Without this, requests to `mta-sts.example.com` fall through to a default server block and the MTA-STS policy file returns 404.

## Pull container images

Mailcow consists of approximately 18 containers. Pulling them all takes a few minutes:

```bash
docker compose pull
```

On a fresh Hetzner instance with their fast network, this typically completes in under a minute.

## First start

```bash
docker compose up -d
```

Initial startup takes 2–5 minutes because:

- MariaDB performs first-run database initialization
- Rspamd downloads spam learning data
- ClamAV downloads virus definitions (~250 MB — the slowest step)
- ACME container requests the Let's Encrypt certificate
- SOGo runs database migrations

Watch progress:

```bash
docker compose ps
```

Containers may briefly show `Restarting` or `health: starting` during initialization. After a few minutes, all should reach `Up` or `healthy` state.

## Verify SSL certificate

The ACME container automatically requests a Let's Encrypt certificate covering all SAN domains. Watch the process:

```bash
docker compose logs acme-mailcow --tail 30
```

A successful run shows:

```
Confirmed A record with IP FLOATING_IP
Confirmed AAAA record with IP PRIMARY_IPV6
Found A record for mta-sts.example.com
mail.example.com verified!
mta-sts.example.com verified!
autoconfig.example.com verified!
autodiscover.example.com verified!
Certificate signed!
Certificate successfully obtained
```

If verification fails, the most common cause is DNS records not matching the expected IPs. Re-check the verification commands from [03 — DNS Configuration](03-dns-configuration.md).

## First admin login

Open `https://mail.example.com` in a browser. The page shows the User Login form by default. To access the admin panel, click the small **"Log in as admin"** link below the form.

Default credentials:

- Username: `admin`
- Password: `moohoo`

Log in immediately. Mailcow does not force password change in newer versions, but it is critical to do this manually:

**Navigate to:** System → Configuration → Configuration & Details → Access → Administrators → admin (Edit)

Change to a strong password (20+ characters) and store it in a password manager. Mailcow does not provide password recovery — losing the admin password requires direct database access to reset.

## Enable 2FA on admin

In the same admin edit page, scroll to **Two-factor authentication (TOTP)**:

- Click **Add device**
- Scan the QR code with an authenticator app
- Enter the 6-digit code to confirm

Mailcow displays recovery codes after enrollment. Store these separately from the password — they are the only way to regain access if the authenticator device is lost.

## Optional — create a backup admin

Compromise of a single admin account, or loss of its 2FA device with no recovery codes, leaves Mailcow inaccessible. Create a second admin as insurance:

**Administrators → Add admin**

Repeat the password and 2FA setup. Use a different authenticator device (or store the recovery codes in a separate location) so that compromise of one device does not affect the other.

## System health check

Verify the deployment:

```bash
cd /opt/mailcow-dockerized
docker compose ps --format 'table {{.Service}}\t{{.Status}}'
```

All services should be `Up` or `healthy`. Common ones that take longer to settle: `clamd-mailcow` (downloading definitions) and `acme-mailcow` (renewing certificates).

```bash
df -h /
free -h
```

Disk and memory usage should be reasonable: ~5–10GB used after a fresh install, ~3GB RAM in use.

## Summary

After this phase:

- Docker installed from the official repository
- Mailcow cloned and configured with the correct hostname and timezone
- Let's Encrypt certificate issued for the main hostname and 3 SAN domains
- Admin password changed, 2FA enrolled, recovery codes saved
- All containers running and healthy

The mail server is operational but has no domain or mailbox configured yet. Proceed to [05 — Domain and Mailbox](05-domain-and-mailbox.md).
