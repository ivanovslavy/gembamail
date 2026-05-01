# 02 — VPS Bootstrap

This phase covers everything between provisioning a VPS and installing Mailcow: networking, hostname, hardening, swap, and Floating IP routing.

## Provisioning the server

On Hetzner Cloud Console:

- **Type:** Cost-Optimized → CAX11 (ARM64, 2 vCPU, 4GB RAM, 40GB SSD)
- **Location:** Falkenstein (or any location separate from existing services)
- **Image:** Ubuntu 24.04 LTS
- **Networking:** IPv4 + IPv6 (both required for modern email)
- **SSH key:** Add your public key now; do not enable root password
- **Backups:** Enable (~20% of VPS cost). Daily snapshots for 7 days are essential for an email server. Restoring a corrupted Mailcow setup from snapshot takes 5 minutes; rebuilding from scratch takes hours.

After creation, the server boots with a primary IPv4 (e.g., `178.105.16.164`) and an IPv6 from a Hetzner-assigned `/64` block.

## First SSH login

The default user on Hetzner Ubuntu images is `root`. Connect with the SSH key configured during provisioning:

```bash
ssh root@PRIMARY_IP
```

If the connection prompts for a password rather than using the key, the local SSH key did not match the one provisioned. Either add the correct public key in the Hetzner Cloud Console (Security → SSH Keys) and recreate the server, or use Hetzner's web console to set a temporary password.

## Create a non-root user

Working as root is unnecessary for daily operations. Create a sudo-capable user:

```bash
adduser slavy
usermod -aG sudo slavy

mkdir -p /home/slavy/.ssh
cp /root/.ssh/authorized_keys /home/slavy/.ssh/
chown -R slavy:slavy /home/slavy/.ssh
chmod 700 /home/slavy/.ssh
chmod 600 /home/slavy/.ssh/authorized_keys
```

Verify the new user can log in via SSH from a separate terminal **before disabling root login** — never close the working session until the new path is confirmed.

## Harden SSH

Once the new user works:

```bash
cat > /etc/ssh/sshd_config.d/99-hardening.conf << 'EOF'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
EOF

sshd -t
systemctl restart ssh
```

The `sshd -t` step validates the configuration before applying it. If it returns errors, do not restart sshd until they are fixed — a broken config will leave the server inaccessible until the Hetzner web console is used to fix it.

Verify in a fresh terminal:

```bash
ssh root@PRIMARY_IP    # Should now fail
ssh slavy@PRIMARY_IP   # Should succeed
```

## Set the hostname

The hostname must match the planned reverse DNS entry. For an email server hosted at `mail.example.com`:

```bash
hostnamectl set-hostname mail.example.com

cat > /etc/hosts << 'EOF'
127.0.0.1   localhost
127.0.1.1   mail.example.com mail

PRIMARY_IPV4 mail.example.com mail
PRIMARY_IPV6 mail.example.com mail

::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
```

Replace `PRIMARY_IPV4` and `PRIMARY_IPV6` with the actual server addresses. The hostname must resolve forward and reverse — Mailcow's HELO/EHLO and most major email providers verify this match (Forward-Confirmed reverse DNS, FCrDNS).

Verify:

```bash
hostname        # Should print: mail.example.com
hostname -f     # Should print: mail.example.com
```

## Add swap

A 4GB instance can run Mailcow comfortably during normal operation, but updates briefly spike memory usage. Adding 2GB of swap as a safety margin prevents OOM kills:

```bash
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

# Lower swap aggressiveness — prefer RAM, swap only when necessary
echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
sysctl -p /etc/sysctl.d/99-swappiness.conf

# Increase file descriptor limits for Mailcow
cat >> /etc/security/limits.conf << 'EOF'
* soft nofile 65536
* hard nofile 65536
EOF
```

## Floating IP setup

When the primary IP has reputation concerns or to enable IP portability across server rebuilds, attach a Floating IP and route outbound traffic through it.

### Create the Floating IP

In Hetzner Cloud Console:

- **Networking → Floating IPs → Create**
- Type: IPv4
- Location: same as the server
- Description: a meaningful label (e.g., `mailserver-public-ip`)

Before assigning, verify the new IP's reputation using the same checks from [01 — Prerequisites](01-prerequisites.md). If it is dirty, delete the Floating IP and create another. Hetzner does not charge for the few seconds an unused Floating IP exists.

Once a clean IP is found, assign it to the server.

### Attach the Floating IP to the network interface

The Floating IP is routed to the server by Hetzner, but the server itself does not know about it until it is added to the network interface. The persistent way is via netplan:

```bash
cat > /etc/netplan/90-floating-ip.yaml << 'EOF'
network:
  version: 2
  ethernets:
    eth0:
      addresses:
        - FLOATING_IP/32
      routes:
        - to: 0.0.0.0/0
          via: 172.31.1.1
          on-link: true
          metric: 50
EOF

chmod 600 /etc/netplan/90-floating-ip.yaml
netplan try
```

`netplan try` applies the configuration with a 120-second auto-revert: if SSH connectivity is lost, the change is rolled back automatically. Confirm in a fresh terminal that SSH still works on both the primary IP and the new Floating IP, then press Enter to accept.

The `metric: 50` route ensures outbound traffic uses the Floating IP as the source address. Verify:

```bash
curl -4 ifconfig.me     # Should print the Floating IP
ip route show           # Should show two default routes; metric 50 wins
ip addr show eth0       # Should list both IPs on the interface
```

## Configure reverse DNS (PTR records)

This step is critical for email deliverability. Both forward and reverse DNS must resolve to the mail hostname.

In Hetzner Cloud Console:

- **Servers → [your server] → Networking → Floating IPs**
- Click the IP → **Edit reverse DNS**
- Set value: `mail.example.com`
- Repeat for IPv6 if email will be sent over IPv6 (recommended)

Verify after a few minutes:

```bash
dig +short -x FLOATING_IP
# Should print: mail.example.com.

dig +short -x PRIMARY_IPV6
# Should print: mail.example.com.
```

Forward-Confirmed reverse DNS (FCrDNS) requires that:

- `mail.example.com` resolves to the Floating IP
- The Floating IP resolves back to `mail.example.com`

Both directions must match. Gmail, Microsoft, and most filtering services reject mail from servers that fail FCrDNS.

## Install dependencies

Update the system and install tools that Mailcow requires:

```bash
apt update && apt upgrade -y
apt install -y jq curl wget git ca-certificates dnsutils net-tools

[ -f /var/run/reboot-required ] && echo "REBOOT NEEDED" || echo "OK"
```

If a kernel update was applied, reboot before continuing.

## Configure firewall

Mailcow manages its own iptables rules via the netfilter container, but the host-level firewall must allow the relevant ports:

```bash
ufw allow 22/tcp    comment 'SSH'
ufw allow 25/tcp    comment 'SMTP'
ufw allow 465/tcp   comment 'SMTPS'
ufw allow 587/tcp   comment 'SMTP Submission'
ufw allow 143/tcp   comment 'IMAP'
ufw allow 993/tcp   comment 'IMAPS'
ufw allow 80/tcp    comment 'HTTP — Lets Encrypt and redirect'
ufw allow 443/tcp   comment 'HTTPS — Mailcow UI and webmail'
ufw allow 4190/tcp  comment 'ManageSieve'

ufw --force enable
ufw status verbose
```

Avoid adding broader UFW rules that might conflict with Mailcow's iptables management.

## Verify port 25 is unblocked

After Hetzner approves the port 25 unblock request:

```bash
nc -zv -w 5 alt1.gmail-smtp-in.l.google.com 25
nc -zv -w 5 outlook-com.olc.protection.outlook.com 25
```

Both should print `Connection to ... succeeded!`. If they time out, the unblock has not been applied yet — wait or follow up with Hetzner support.

## Verify time synchronization

Email servers require accurate clocks. SSL certificates and DKIM signatures depend on correct timestamps:

```bash
timedatectl status | grep -E "synchronized|Time zone"
```

Should report `System clock synchronized: yes`. Ubuntu 24.04 enables systemd-timesyncd by default; no action is normally required.

## DNSSEC support in systemd-resolved

systemd-resolved on Ubuntu 24.04 ships with DNSSEC validation disabled (`DNSSEC=no/unsupported`). For an infrastructure server it is worth enabling:

```bash
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/dnssec.conf << 'EOF'
[Resolve]
DNSSEC=yes
EOF

systemctl restart systemd-resolved
resolvectl status | grep DNSSEC | head -2
```

Should now show `DNSSEC=yes/supported`.

## Summary

After this phase the server has:

- A non-root sudo user with SSH key authentication
- Root SSH login disabled, password authentication disabled
- Hostname matching planned PTR record
- 2GB swap with low swappiness
- Floating IP attached and routed for outbound traffic
- FCrDNS configured for both IPv4 and IPv6
- Firewall open for email and web ports
- Port 25 verified working outbound
- DNSSEC validation enabled in the resolver

The system is ready for DNS configuration and Mailcow installation. Proceed to [03 — DNS Configuration](03-dns-configuration.md).
