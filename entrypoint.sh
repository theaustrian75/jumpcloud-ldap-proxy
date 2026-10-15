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

# Human-readable slapd log timestamps use this IANA timezone.
TZ="${TZ:-America/New_York}"
case "$TZ" in
  /*|*..*|*[!a-zA-Z0-9_+./-]*|"")
    echo "TZ must be an installed IANA timezone (for example America/New_York)" >&2
    exit 1
    ;;
esac
if [ ! -f "/usr/share/zoneinfo/$TZ" ]; then
  echo "TZ is not installed: $TZ" >&2
  exit 1
fi
export TZ

# Optional extra allowed client (IPv4 or OpenLDAP ip%netmask). Default
# duplicates the loopback entry, i.e. grants nothing new.
ALLOWED_CLIENT_IP="${ALLOWED_CLIENT_IP:-127.0.0.1}"

is_ipv4_octet() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 0 ] && [ "$1" -le 255 ]
}

is_ipv4() {
  ip=$1
  case "$ip" in
    *.*.*.*) ;;
    *) return 1 ;;
  esac
  o1=${ip%%.*}; rest=${ip#*.}
  o2=${rest%%.*}; rest=${rest#*.}
  o3=${rest%%.*}; o4=${rest#*.}
  case "$o4" in
    *.*) return 1 ;;
  esac
  is_ipv4_octet "$o1" && is_ipv4_octet "$o2" && \
    is_ipv4_octet "$o3" && is_ipv4_octet "$o4"
}

case "$ALLOWED_CLIENT_IP" in
  ""|*[!0-9.%]*)
    echo "ALLOWED_CLIENT_IP must be an IPv4 address or ip%netmask" >&2
    exit 1
    ;;
  *%*)
    allowed_ip=${ALLOWED_CLIENT_IP%%\%*}
    allowed_mask=${ALLOWED_CLIENT_IP#*%}
    case "$allowed_mask" in
      *%*)
        echo "ALLOWED_CLIENT_IP must be an IPv4 address or ip%netmask" >&2
        exit 1
        ;;
    esac
    if ! is_ipv4 "$allowed_ip" || ! is_ipv4 "$allowed_mask"; then
      echo "ALLOWED_CLIENT_IP must be an IPv4 address or ip%netmask" >&2
      exit 1
    fi
    ;;
  *)
    if ! is_ipv4 "$ALLOWED_CLIENT_IP"; then
      echo "ALLOWED_CLIENT_IP must be an IPv4 address or ip%netmask" >&2
      exit 1
    fi
    ;;
esac

SLAPD_LOGLEVEL="${SLAPD_LOGLEVEL:-stats}"
case "$SLAPD_LOGLEVEL" in
  stats|none) ;;
  *) echo "SLAPD_LOGLEVEL must be 'stats' or 'none'" >&2; exit 1 ;;
esac

PCACHE_POSITIVE_TTL="${PCACHE_POSITIVE_TTL:-900}"
PCACHE_NEGATIVE_TTL="${PCACHE_NEGATIVE_TTL:-120}"
PCACHE_ENUM_POSITIVE_TTL="${PCACHE_ENUM_POSITIVE_TTL:-300}"
PCACHE_ENUM_NEGATIVE_TTL="${PCACHE_ENUM_NEGATIVE_TTL:-60}"

validate_ttl() {
  ttl_name=$1
  ttl_value=$2
  case "$ttl_value" in
    *[!0-9]*|"")
      echo "$ttl_name must be a positive integer number of seconds" >&2
      exit 1
      ;;
  esac
  if ! [ "$ttl_value" -gt 0 ] 2>/dev/null; then
    echo "$ttl_name must be a positive integer number of seconds" >&2
    exit 1
  fi
}

validate_ttl PCACHE_POSITIVE_TTL "$PCACHE_POSITIVE_TTL"
validate_ttl PCACHE_NEGATIVE_TTL "$PCACHE_NEGATIVE_TTL"
validate_ttl PCACHE_ENUM_POSITIVE_TTL "$PCACHE_ENUM_POSITIVE_TTL"
validate_ttl PCACHE_ENUM_NEGATIVE_TTL "$PCACHE_ENUM_NEGATIVE_TTL"

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

if ! openssl x509 -in /certs/proxy.crt -noout >/dev/null 2>&1; then
  echo "Required TLS file is not a valid X.509 certificate: /certs/proxy.crt" >&2
  exit 1
fi
if ! openssl pkey -in /certs/proxy.key -noout >/dev/null 2>&1; then
  echo "Required TLS file is not a valid private key: /certs/proxy.key" >&2
  exit 1
fi

cert_pub=$(openssl x509 -in /certs/proxy.crt -noout -pubkey 2>/dev/null) || {
  echo "Unable to read public key from /certs/proxy.crt" >&2
  exit 1
}
key_pub=$(openssl pkey -in /certs/proxy.key -pubout 2>/dev/null) || {
  echo "Unable to derive public key from /certs/proxy.key" >&2
  exit 1
}
if [ "$cert_pub" != "$key_pub" ]; then
  echo "TLS certificate and private key do not match: /certs/proxy.crt /certs/proxy.key" >&2
  exit 1
fi

if ! openssl x509 -in /certs/proxy.crt -noout -checkend 0 >/dev/null 2>&1; then
  echo "TLS certificate has expired: /certs/proxy.crt" >&2
  exit 1
fi
# 30 days — warn early; expiry still fails the healthcheck once reached.
if ! openssl x509 -in /certs/proxy.crt -noout -checkend 2592000 >/dev/null 2>&1; then
  echo "WARNING: TLS certificate expires within 30 days: /certs/proxy.crt" >&2
fi

sed -e "s/@@JC_ORG_ID@@/${JC_ORG_ID}/g" \
    -e "s/@@JC_CACHE_READER_UID@@/${JC_CACHE_READER_UID}/g" \
    -e "s/@@ALLOWED_CLIENT_IP@@/${ALLOWED_CLIENT_IP}/g" \
    -e "s/@@SLAPD_LOGLEVEL@@/${SLAPD_LOGLEVEL}/g" \
    -e "s/@@PCACHE_POSITIVE_TTL@@/${PCACHE_POSITIVE_TTL}/g" \
    -e "s/@@PCACHE_NEGATIVE_TTL@@/${PCACHE_NEGATIVE_TTL}/g" \
    -e "s/@@PCACHE_ENUM_POSITIVE_TTL@@/${PCACHE_ENUM_POSITIVE_TTL}/g" \
    -e "s/@@PCACHE_ENUM_NEGATIVE_TTL@@/${PCACHE_ENUM_NEGATIVE_TTL}/g" \
    /etc/openldap/slapd.conf.template > /run/openldap/slapd.conf
chmod 600 /run/openldap/slapd.conf

# SLAPD_LOGLEVEL: 'stats' (default) logs each search for pcache template
# tuning; switch to 'none' once tuned. No rebuild needed for either.
exec slapd -d "$SLAPD_LOGLEVEL" -f /run/openldap/slapd.conf -h "ldap:/// ldaps:///"
