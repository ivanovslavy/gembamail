#!/bin/bash
#
# check-blacklist.sh — Multi-DNSBL reputation check
#
# Queries an IP address against multiple DNS-based blacklists and reports
# the result. Useful for verifying a fresh VPS IP before deploying email
# infrastructure, and for periodic reputation monitoring afterward.
#
# Usage:
#   ./check-blacklist.sh             # Auto-detects current public IP
#   ./check-blacklist.sh 1.2.3.4     # Check a specific IP
#
# Exit codes:
#   0 — IP is clean on all blacklists
#   1 — IP is listed on at least one blacklist
#   2 — Lookup errors (network issues, DNS rate limits)
#

set -u

IP="${1:-$(curl -s -4 ifconfig.me)}"

if [ -z "$IP" ]; then
    echo "ERROR: Could not determine IP address" >&2
    exit 2
fi

# Reverse the IP for DNSBL queries (4.3.2.1.bl.example.com)
REVERSED=$(echo "$IP" | awk -F. '{print $4"."$3"."$2"."$1}')

echo "Checking IP: $IP"
echo "Reversed:    $REVERSED"
echo "================================================"

# Major DNSBLs that matter for email deliverability.
# Order is roughly by importance to Gmail / Microsoft / Apple filtering.
BLACKLISTS=(
    zen.spamhaus.org              # The most important — Gmail respects it heavily
    bl.spamcop.net                # Major; Microsoft uses it
    b.barracudacentral.org        # Microsoft heavily uses this
    cbl.abuseat.org               # CBL via Spamhaus
    dnsbl.sorbs.net               # General SORBS list
    spam.dnsbl.sorbs.net          # SORBS spam-specific
    psbl.surriel.com              # Passive Spam Block List
    bl.mailspike.net              # Mailspike (used by some filters)
    bl.blocklist.de               # Real-time bot/abuse list
    all.s5h.net                   # SORBS aggregate
    truncate.gbudb.net            # GBUdb
    spamrbl.imp.ch                # Imp.ch
    rbl.efnetrbl.org              # EFnet RBL
    dnsbl-1.uceprotect.net        # UCEPROTECT Level 1 (single IP)
    dnsbl-2.uceprotect.net        # UCEPROTECT Level 2 (whole network)
    dnsbl-3.uceprotect.net        # UCEPROTECT Level 3 (entire ASN)
)

LISTED=0
CLEAN=0
TIMEOUT=0

for BL in "${BLACKLISTS[@]}"; do
    RESULT=$(dig +short +time=5 +tries=2 "${REVERSED}.${BL}" A 2>&1)

    if echo "$RESULT" | grep -qE "timed out|no servers|connection refused"; then
        echo "⏱  Timeout/unreachable on ${BL}"
        TIMEOUT=$((TIMEOUT+1))
    elif echo "$RESULT" | grep -qE "^127\."; then
        # DNSBLs return 127.x.x.x for listed IPs; the specific code
        # encodes the reason. Anything in the 127.0.0.0/8 range = listed.
        TXT=$(dig +short +time=5 "${REVERSED}.${BL}" TXT 2>/dev/null | head -1)
        echo "❌ LISTED on ${BL}: ${RESULT} ${TXT}"
        LISTED=$((LISTED+1))
    else
        echo "✓  Clean on ${BL}"
        CLEAN=$((CLEAN+1))
    fi
done

echo "================================================"
echo "Clean:    $CLEAN"
echo "Listed:   $LISTED"
echo "Timeout:  $TIMEOUT"
echo

# Spamhaus public DNS lookups via shared resolvers (Google, Cloudflare,
# ISP DNS) are rate-limited and may return false positives ("error: open
# resolver"). The recommended workaround is a local recursive resolver
# (Unbound) on the host, or simply trust that timeouts are not real hits.
if [ "$TIMEOUT" -gt 0 ]; then
    echo "Note: timeouts are typically transient or rate-limit artifacts,"
    echo "not actual blacklist hits. Verify suspicious results via:"
    echo "  https://check.spamhaus.org/results/?query=$IP"
fi

# Exit with appropriate code
if [ "$LISTED" -gt 0 ]; then
    exit 1
elif [ "$CLEAN" -eq 0 ]; then
    exit 2
else
    exit 0
fi
