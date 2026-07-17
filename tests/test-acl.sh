#!/bin/sh
# Run inside the built image to validate rendered config and source/DN ACLs.
set -eu

ORG_ID=testorg
READER_UID=qts-reader
READER_DN="uid=$READER_UID,ou=Users,o=$ORG_ID,dc=jumpcloud,dc=com"
OTHER_DN="uid=other-user,ou=Users,o=$ORG_ID,dc=jumpcloud,dc=com"
TARGET_DN="uid=target,ou=Users,o=$ORG_ID,dc=jumpcloud,dc=com"
CONFIG=/tmp/slapd-test.conf

sed -e "s/@@JC_ORG_ID@@/$ORG_ID/g" \
    -e "s/@@JC_CACHE_READER_UID@@/$READER_UID/g" \
    -e "s/@@ALLOWED_CLIENT_IP@@/192.0.2.10/g" \
    /etc/openldap/slapd.conf.template > "$CONFIG"

slaptest -f "$CONFIG" -u >/dev/null

assert_access() {
  expected=$1
  identity=$2
  peer=$3
  attribute=$4

  if [ "$identity" = anonymous ]; then
    output=$(slapacl -f "$CONFIG" -u \
      -o "peername=IP=$peer:12345" \
      -b "$TARGET_DN" "$attribute/read" 2>&1)
  else
    output=$(slapacl -f "$CONFIG" -u -D "$identity" \
      -o "peername=IP=$peer:12345" \
      -b "$TARGET_DN" "$attribute/read" 2>&1)
  fi

  if ! printf '%s\n' "$output" | grep -q ": $expected"; then
    printf 'Expected %s for %s as %s from %s, got:\n%s\n' \
      "$expected" "$attribute" "$identity" "$peer" "$output" >&2
    exit 1
  fi
}

# Sensitive values require both the exact cache-reader DN and an allowed source.
assert_access ALLOWED "$READER_DN" 127.0.0.1 userPassword
assert_access ALLOWED "$READER_DN" 172.28.53.10 sambaNTPassword
assert_access ALLOWED "$READER_DN" 192.0.2.10 userPassword
assert_access DENIED "$READER_DN" 172.20.0.10 userPassword
assert_access DENIED "$OTHER_DN" 127.0.0.1 userPassword
assert_access DENIED anonymous 127.0.0.1 userPassword

# Preserve QTS anonymous reads of non-sensitive cached directory attributes.
assert_access ALLOWED anonymous 127.0.0.1 cn
assert_access ALLOWED anonymous 172.28.53.10 cn
assert_access DENIED anonymous 172.20.0.10 cn

echo "ACL regression checks passed"
