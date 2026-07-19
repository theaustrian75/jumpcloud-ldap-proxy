# JumpCloud LDAP caching proxy for QNAP

OpenLDAP `back-ldap` proxy to `ldap.jumpcloud.com` with the `pcache` overlay:
repeat LDAP searches (user lookups, group lookups, Samba NT-hash fetches) are
answered from a local cache instead of paying a WAN round-trip. Binds are
deliberately NOT cached (see the pcacheBind note in the template): SMB
per-user auth rides on cached hash searches, so it survives brief upstream
outages on established connections; LDAP binds themselves always go
upstream.

Validated behavior (slapd 2.6.8 on Alpine 3.22 (musl) and 2.6.10 on Ubuntu 24.04):
- 5 identical queries to the proxy -> exactly 1 reached upstream
- with upstream unreachable, already-bound connections can continue using
  cached searches; new binds fail because binds are never cached

## Deploy

1. `cp .env.example .env`, set `LDAP_PROXY_IMAGE` to an immutable release
   tag or manifest digest, set `JC_ORG_ID` (JumpCloud console -> LDAP; the
   o=<id> component of your base DN), and set `JC_CACHE_READER_UID` to the
   UID of the JumpCloud account configured as QTS's LDAP bind user.
   Only that exact bind identity may read cached password/hash attributes.
   The entrypoint renders slapd.conf from `conf/slapd.conf.template` and
   refuses to start without both values. If the proxy will ever serve a
   client on another host, set `ALLOWED_CLIENT_IP` in `.env` (single IPv4
   or ip%netmask form); unset, it defaults to a harmless loopback duplicate.
   All substituted values are validated at startup.
2. Put a lab-CA-issued cert/key at
   `/share/Container/jc-ldap-proxy/certs/proxy.{crt,key}` for Compose, or
   `/srv/jc-ldap-proxy/certs/proxy.{crt,key}` for Quadlet. The SAN must match
   whatever name/IP you give the QNAP. Make both files readable by the
   container's ldap user (uid 100 in the image, or `chmod 640` plus ownership
   via `podman unshare`). Startup now reports a direct missing/unreadable-file
   error if the mount or permissions are wrong.
3. GitHub Actions builds `linux/amd64` and `linux/arm64` images on native
   runners, publishes them to
   `ghcr.io/theaustrian75/jumpcloud-ldap-proxy`, and creates a multi-arch
   manifest. Pushes to `main` publish `main`, `sha-*`, and `latest`; a `v*`
   tag additionally publishes that release tag. Pull requests build both
   architectures without publishing.

   Use a release/commit tag to discover the resulting manifest digest, then
   put the immutable `ghcr.io/...@sha256:...` reference in `.env` and replace
   the `Image=` placeholder in the Quadlet unit. If the GHCR package is
   private, authenticate the QNAP once with a token that has `read:packages`:

       echo "$GHCR_TOKEN" | docker login ghcr.io -u theaustrian75 --password-stdin
       docker compose up -d

   For Podman hosts, install `jc-ldap-proxy.container` as a Quadlet unit
   instead.

4. Smoke test from the host (expect your JumpCloud entries back):

       ldapsearch -x -H ldaps://<proxy-host> \
         -D "uid=<your-qnap-bind-user>,ou=Users,o=<ORG_ID>,dc=jumpcloud,dc=com" \
         -W -b "ou=Users,o=<ORG_ID>,dc=jumpcloud,dc=com" '(uid=*)' uid

   Note: the host itself must be in the peername ACL in slapd.conf if you
   test from there (127.0.0.1 only covers in-container).

5. Point QTS at it: Control Panel -> Domain Security -> LDAP
   authentication, server host "localhost", LDAP security
   "ldap://(ldap+TLS)" — i.e. STARTTLS on port 389. This is the VERIFIED
   working configuration. Pure LDAPS on port 636 did not work with QTS,
   most likely because QTS-generated Samba (and possibly nss LDAP) backend
   configuration still uses plain LDAP + STARTTLS. Selecting LDAPS in the
   panel therefore produced "wrong version number" errors and empty Domain
   Users/Groups lists. Base DN and the
   Users/Groups base DNs as for direct JumpCloud; One-Level scope matches
   JumpCloud's flat ou=Users layout. Both proxy ports are published
   loopback-only; 636/LDAPS remains available for admin ldapsearch use.
   Import your lab CA into the QNAP's certificate store first; the cert SAN
   must include IP:127.0.0.1 since that is what QTS dials.
   Everything else (base DN, bind DN, credentials) stays identical.
   Rollback is that one field: point it back at ldap.jumpcloud.com.

   NOTE on the ACL: QTS connections to the Compose-published port arrive
   NATed from the pinned `172.28.53.0/24` Docker network. slapd allows exactly
   that subnet, rather than the full private `172.16.0.0/12` range.

## Tune the cache templates (do this once)

pcache only caches queries whose filter *shape* matches a `pcacheTemplate`.
The config ships with the shapes QTS/Samba typically sends, but verify:

1. Leave `SLAPD_LOGLEVEL=stats` on, log in to the NAS / mount a share once.
2. `podman logs jc-ldap-proxy | grep SRCH` — each line shows a filter.
3. For any recurring filter shape not covered, add a `pcacheTemplate` with
   the values stripped, e.g. `(&(objectClass=sambaDomain)(sambaDomainName=))`
   becomes a template of exactly that form. Attributes not in `pcacheAttrset 0`
   must be added there too, or matching queries won't be cached.
4. Restart, re-test, then set `SLAPD_LOGLEVEL=none` in `.env` and
   `docker compose up -d` — no rebuild needed.

### Log levels

`SLAPD_LOGLEVEL` is rendered into `slapd.conf` and also controls slapd's
foreground stderr logging. The entrypoint accepts exactly:

- `stats` (default): log connections, LDAP operations, search filters, and
  results. Use this while tuning cache templates or diagnosing requests.
- `none`: emit only unavoidable/high-priority messages. Use this for quiet
  production operation after tuning.

Any other value is rejected at startup to catch configuration mistakes.

## Authentication

Authenticated clients are handled by pass-through: their own bind is
forwarded to JumpCloud, and their operations run under it. QTS keeps its
existing JumpCloud bind DN and password; the proxy stores only its UID in
`JC_CACHE_READER_UID`, not the password. Every bind is forwarded to
JumpCloud per connection (`rebind-as-user`).

OpenLDAP's pcache is shared across identities and cannot reproduce
JumpCloud's per-identity authorization for cached results. To prevent a
result populated by QTS's privileged bind from disclosing credential
material to another identity, the local ACL permits `userPassword`, Samba
password/hash attributes, and JumpCloud password blobs only when both:

- the bound DN exactly matches
  `uid=$JC_CACHE_READER_UID,ou=Users,o=$JC_ORG_ID,dc=jumpcloud,dc=com`; and
- the connection comes from one of the configured source networks.

All other identities receive no read access to those sensitive attributes,
including on cache hits. Non-sensitive cached directory attributes remain
shared inside the source-IP trust boundary, so this proxy is intended for a
single trusted QTS consumer rather than arbitrary multi-tenant LDAP clients.

Anonymous cache misses are passed through to JumpCloud, which rejects them
with err=32. This behavior is retained because locally refusing the QTS
anonymous probe (err=53) or using idassert was observed to break Domain
Users/Groups ingestion.

Expected auth semantics (re-test after changing `JC_CACHE_READER_UID`):
- Anonymous and non-reader identities cannot read cached password/hash
  attributes. Anonymous cache misses are still rejected by JumpCloud.
- LDAP binds always go upstream, so JumpCloud password changes and account
  disables affect new LDAP binds immediately.
- Samba validates users from hash searches, and those results can remain in
  pcache for the matching template's positive TTL (900 seconds for user
  lookups). An old SMB password can therefore remain usable until that cached
  hash expires even while JumpCloud is reachable.
- While JumpCloud is unreachable, new LDAP binds fail (binds are never
  answered from cache — a cached bind leaves the proxy without upstream
  credentials and breaks later operations). Already-bound connections keep
  working for cached searches, which covers SMB per-user auth.
- TLS on both legs: QTS uses LDAP + STARTTLS on port 389 to the proxy
  (your lab CA); the proxy uses LDAPS to ldap.jumpcloud.com with certificate
  validation required (public CA bundle, TLS_REQCERT demand). Port 636
  remains available for administrative clients that use pure LDAPS.

## Healthcheck

The image ships a HEALTHCHECK: an anonymous rootDSE base read over LDAPS on
loopback (allowed by a dedicated ACL; the JumpCloud tree itself still
requires an authenticated bind — verified). It intentionally does not probe
the upstream: JumpCloud being unreachable while the cache serves warm
entries is the designed degraded mode, not a container failure. Under
Docker/Container Station the healthcheck runs natively; under Podman +
Quadlet, `HealthOnFailure=restart` in the unit restarts on failure.

## Where to run it

On the QNAP itself (Container Station / Docker) is the recommended
placement — see docker-compose.yml. The compose deployment publishes both
ports on loopback; QTS points at localhost and uses STARTTLS on port 389,
so auth traffic never leaves the NAS. The proxy shares the NAS's failure
domain (if the NAS is up, its auth path is up). The Quadlet unit is also
loopback-bound and therefore assumes QTS runs on the same host. For a separate
Podman host, deliberately bind `PublishPort` to that host's LAN address, set
`ALLOWED_CLIENT_IP` to the QNAP address, and enforce the same restriction in
the host firewall.

## Operational notes

- Cert expiry is INVISIBLE to the healthcheck (it deliberately skips
  verification on loopback). An expired proxy cert breaks QTS LDAP while
  the container still reports healthy. Issue the loopback cert long-lived
  (it never crosses a wire), and if QTS auth fails with a green container,
  check cert dates first.
- The runtime root filesystem is read-only, all capabilities except
  `NET_BIND_SERVICE` are dropped, privilege escalation is disabled, and
  memory/PID limits are applied. `/run/openldap` and the 256 MiB cache are
  the only writable tmpfs mounts.
- Acceptance test after cutover — prove the cache engages: run the same
  authenticated ldapsearch through the proxy twice and compare wall time
  (first ~ WAN RTT, second ~ 1 ms). If the second is not fast, QTS's filter
  shape is missing a pcacheTemplate: do the tuning pass above.
- After a NAS reboot, Container Station starts the proxy slightly after
  QTS comes up; LDAP logins in that window fail until the container is
  running. It self-heals; just don't debug a post-reboot login failure
  that is younger than a minute.
- Keep this folder in git. Rollback of any change is a checkout plus
  `docker compose up -d --build`; rollback of the whole proxy is pointing
  QTS back at ldap.jumpcloud.com.

## Knobs and trade-offs

- Positive TTL 900s / negative 120s (`pcacheTemplate` cols 3-4): how stale a
  lookup may be. A user disabled in JumpCloud can still resolve for up to
  the positive TTL; cached Samba hashes can retain the same authentication
  window.
- Cache is on tmpfs (see the Quadlet unit): no hashes at rest, cold cache
  after restart. Move to a volume only if you accept hashes on disk.
- The proxy answers only the pinned QNAP bridge, localhost, and an optional
  `ALLOWED_CLIENT_IP`. QTS's required anonymous probes can read non-sensitive
  cached directory attributes, while credential/hash attributes require the
  exact configured reader DN. Keep host firewalling in front of it anyway.

## Automated checks

GitHub Actions runs ShellCheck, validates startup failures, starts the image
with the production hardening constraints, and exercises a `slapacl` matrix.
After validation, native AMD64 and ARM64 runners build architecture-specific
GHCR images and a final job merges them into one multi-arch manifest. The ACL
regression confirms reader-DN plus source-network requirements for sensitive
attributes and preserves QTS's anonymous non-sensitive lookup behavior.

## Measured performance (production baseline, 2026-07)

Steady-state under real QTS/Samba/nslcd traffic (verify-proxy.sh):

    hit ratio: 93% (3592 cached / 289 upstream)
    cached search:   avg 0.0003s
    upstream search: avg 0.0306s  (~108x per-search speedup)
    enumerations (objectClass=*): 98.6% cached

Residual upstream traffic is TTL refreshes on high-frequency shapes,
first-touch misses, and one untemplatable shape (smbd alias expansion,
(&(objectClass=)(sambaGroupType=)(|(sambaSIDList=)...)) — its OR-arity
varies with SID count and pcache templates match exact filter structure).
Raising the 900s template TTLs buys a few points of hit ratio at the cost
of staler entries; not recommended. Re-measure with verify-proxy.sh after
enabling SLAPD_LOGLEVEL=stats temporarily.
