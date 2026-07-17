#!/bin/sh
# Render slapd.conf from template using environment, then exec slapd.
set -eu

: "${JC_ORG_ID:?Set JC_ORG_ID (your JumpCloud org ID) in the container environment}"
: "${JC_CACHE_READER_UID:?Set JC_CACHE_READER_UID to the UID of the QTS LDAP bind user}"

# Org IDs are alphanumeric; refuse anything that could mangle the config
case "$JC_ORG_ID" in
  *[!a-zA-Z0-9]*) echo "JC_ORG_ID contains invalid characters" >&2; exit 1 ;;
esac

# The UID is inserted into an exact DN in slapd.conf. Keep the accepted
# character set deliberately narrow so it cannot escape that DN or sed value.
case "$JC_CACHE_READER_UID" in
  *[!a-zA-Z0-9._@-]*|"") echo "JC_CACHE_READER_UID contains invalid characters" >&2; exit 1 ;;
esac

# Optional extra allowed client (IP or ip%netmask). Default duplicates the
# loopback entry, i.e. grants nothing new.
ALLOWED_CLIENT_IP="${ALLOWED_CLIENT_IP:-127.0.0.1}"
case "$ALLOWED_CLIENT_IP" in
  *[!0-9.%]*|"") echo "ALLOWED_CLIENT_IP must be an IPv4 address or ip%netmask" >&2; exit 1 ;;
esac

SLAPD_LOGLEVEL="${SLAPD_LOGLEVEL:-stats}"
case "$SLAPD_LOGLEVEL" in
  stats|none) ;;
  *) echo "SLAPD_LOGLEVEL must be 'stats' or 'none'" >&2; exit 1 ;;
esac

for tls_file in /certs/proxy.crt /certs/proxy.key; do
  if [ ! -f "$tls_file" ]; then
    echo "Required TLS file is missing: $tls_file (check the /certs volume mount)" >&2
    exit 1
  fi
  if [ ! -r "$tls_file" ]; then
    echo "Required TLS file is not readable by uid $(id -u): $tls_file" >&2
    exit 1
  fi
done

sed -e "s/@@JC_ORG_ID@@/${JC_ORG_ID}/g" \
    -e "s/@@JC_CACHE_READER_UID@@/${JC_CACHE_READER_UID}/g" \
    -e "s/@@ALLOWED_CLIENT_IP@@/${ALLOWED_CLIENT_IP}/g" \
    /etc/openldap/slapd.conf.template > /run/openldap/slapd.conf
chmod 600 /run/openldap/slapd.conf

# SLAPD_LOGLEVEL: 'stats' (default) logs each search for pcache template
# tuning; switch to 'none' once tuned. No rebuild needed for either.
exec slapd -d "$SLAPD_LOGLEVEL" -f /run/openldap/slapd.conf -h "ldap:/// ldaps:///"
