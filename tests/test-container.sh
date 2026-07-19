#!/bin/sh
# Build-independent container smoke tests. Pass the image reference as $1.
set -eu

IMAGE="${1:?Usage: tests/test-container.sh IMAGE}"
TMP_ROOT=$(mktemp -d)
CERT_DIR="$TMP_ROOT/certs"
CONTAINER="jc-ldap-proxy-test-$$"

# Invoked through trap.
# shellcheck disable=SC2317
cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

mkdir "$CERT_DIR"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj "/CN=localhost" -addext "subjectAltName=IP:127.0.0.1" \
  -keyout "$CERT_DIR/proxy.key" -out "$CERT_DIR/proxy.crt" >/dev/null 2>&1
chmod 755 "$TMP_ROOT" "$CERT_DIR"
chmod 644 "$CERT_DIR/proxy.crt" "$CERT_DIR/proxy.key"

default_identity=$(docker run --rm --entrypoint /bin/sh "$IMAGE" \
  -c 'printf "%s:%s" "$(id -u)" "$(id -g)"')
if [ "$default_identity" != "99:100" ]; then
  echo "Expected default container identity 99:100, got $default_identity" >&2
  exit 1
fi

assert_failure() {
  expected=$1
  shift
  if output=$("$@" 2>&1); then
    echo "Expected command to fail: $*" >&2
    exit 1
  fi
  case "$output" in
    *"$expected"*) ;;
    *)
      printf 'Expected failure containing %s, got:\n%s\n' "$expected" "$output" >&2
      exit 1
      ;;
  esac
}

assert_failure "Required TLS file is missing: /certs/proxy.crt" \
  docker run --rm \
  -e JC_ORG_ID=testorg -e JC_CACHE_READER_UID=qts-reader "$IMAGE"
assert_failure "JC_ORG_ID contains invalid characters" \
  docker run --rm -e JC_ORG_ID='bad/id' -e JC_CACHE_READER_UID=qts-reader "$IMAGE"
assert_failure "JC_CACHE_READER_UID contains invalid characters" \
  docker run --rm -e JC_ORG_ID=testorg -e JC_CACHE_READER_UID='bad,user' "$IMAGE"
assert_failure "SLAPD_LOGLEVEL must be 'stats' or 'none'" \
  docker run --rm \
  -e JC_ORG_ID=testorg -e JC_CACHE_READER_UID=qts-reader \
  -e SLAPD_LOGLEVEL=verbose "$IMAGE"

chmod 000 "$CERT_DIR/proxy.key"
assert_failure "Required TLS file is not readable" \
  docker run --rm \
  -e JC_ORG_ID=testorg -e JC_CACHE_READER_UID=qts-reader \
  -v "$CERT_DIR:/certs:ro" "$IMAGE"
chmod 644 "$CERT_DIR/proxy.key"

docker run --rm --entrypoint /bin/sh \
  -v "$CERT_DIR:/certs:ro" \
  -v "$PWD/tests/test-acl.sh:/tests/test-acl.sh:ro" \
  "$IMAGE" /tests/test-acl.sh

# Exercise the same read-only/capability/tmpfs constraints used in production.
RUNTIME_UID=12345
RUNTIME_GID=12346
docker run -d --name "$CONTAINER" \
  --user "$RUNTIME_UID:$RUNTIME_GID" \
  --read-only \
  --security-opt no-new-privileges:true \
  --cap-drop ALL --cap-add NET_BIND_SERVICE \
  --pids-limit 128 --memory 512m \
  --tmpfs "/run/openldap:rw,size=16m,uid=$RUNTIME_UID,gid=$RUNTIME_GID,mode=0700" \
  --tmpfs "/var/lib/ldap/pcache:rw,size=256m,uid=$RUNTIME_UID,gid=$RUNTIME_GID,mode=0700" \
  -v "$CERT_DIR:/certs:ro" \
  -e JC_ORG_ID=testorg -e JC_CACHE_READER_UID=qts-reader \
  -e SLAPD_LOGLEVEL=none \
  "$IMAGE" >/dev/null

attempt=0
while [ "$attempt" -lt 30 ]; do
  status=$(docker inspect -f \
    '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
    "$CONTAINER")
  case "$status" in
    healthy)
      echo "Hardened container smoke test passed"
      exit 0
      ;;
    exited|dead)
      docker logs "$CONTAINER" >&2
      echo "Container exited before becoming healthy" >&2
      exit 1
      ;;
  esac
  attempt=$((attempt + 1))
  sleep 1
done

docker logs "$CONTAINER" >&2
echo "Container did not become healthy within 30 seconds" >&2
exit 1
