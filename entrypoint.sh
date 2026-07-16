#!/bin/sh
# Render slapd.conf from template using environment, then exec slapd.
set -eu

: "${JC_ORG_ID:?Set JC_ORG_ID (your JumpCloud org ID) in the container environment}"

# Org IDs are alphanumeric; refuse anything that could mangle the config
case "$JC_ORG_ID" in
  *[!a-zA-Z0-9]*) echo "JC_ORG_ID contains invalid characters" >&2; exit 1 ;;
esac

# Optional extra allowed client (IP or ip%netmask). Default duplicates the
# loopback entry, i.e. grants nothing new.
ALLOWED_CLIENT_IP="${ALLOWED_CLIENT_IP:-127.0.0.1}"
case "$ALLOWED_CLIENT_IP" in
  *[!0-9.%]*|"") echo "ALLOWED_CLIENT_IP must be an IPv4 address or ip%netmask" >&2; exit 1 ;;
esac

sed -e "s/@@JC_ORG_ID@@/${JC_ORG_ID}/g" \
    -e "s/@@ALLOWED_CLIENT_IP@@/${ALLOWED_CLIENT_IP}/g" \
    /etc/openldap/slapd.conf.template > /run/openldap/slapd.conf
chmod 600 /run/openldap/slapd.conf

# SLAPD_LOGLEVEL: 'stats' (default) logs each search for pcache template
# tuning; switch to 'none' once tuned. No rebuild needed for either.
exec slapd -d "${SLAPD_LOGLEVEL:-stats}" -f /run/openldap/slapd.conf -h "ldap:/// ldaps:///"
