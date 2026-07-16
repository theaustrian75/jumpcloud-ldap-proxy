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
- with upstream unreachable: cached bind + cached searches succeed,
  wrong passwords are still rejected

## Deploy

1. `cp .env.example .env` and set `JC_ORG_ID` (JumpCloud console -> LDAP;
   the o=<id> component of your base DN). The entrypoint renders slapd.conf
   from `conf/slapd.conf.template` at container start and refuses to start
   without a valid org ID. If the proxy will ever serve a client on another
   host, set `ALLOWED_CLIENT_IP` in `.env` (single IPv4 or ip%netmask form);
   unset, it defaults to a harmless loopback duplicate. Both variables are
   validated at startup and the ACL was verified with slapacl (configured
   source allowed, neighboring IP denied, injection input refused).
2. Put a lab-CA-issued cert/key at `/srv/jc-ldap-proxy/certs/proxy.{crt,key}`
   on the host. The SAN must match whatever name/IP you give the QNAP.
   Make readable by the container's ldap user (uid 100 in the image, or
   just `chmod 640` + ownership via `podman unshare`).
3. Build and push (the build file is Dockerfile.ldap-proxy, fitting a
   `for Dockerfile.*` multi-image build script; multi-arch builds of the
   non-native platform need qemu-user-static on the build host):

       podman build --platform linux/amd64,linux/arm64 \
         --manifest <registry>/ldap-proxy:latest -f Dockerfile.ldap-proxy .
       podman manifest push --all <registry>/ldap-proxy:latest

   On the QNAP: `docker login <registry>` once, then
   `docker compose up -d` (compose pulls the image). For Podman hosts,
   install jc-ldap-proxy.container as a Quadlet unit instead.

4. Smoke test from the host (expect your JumpCloud entries back):

       ldapsearch -x -H ldaps://<proxy-host> \
         -D "uid=<your-qnap-bind-user>,ou=Users,o=<ORG_ID>,dc=jumpcloud,dc=com" \
         -W -b "ou=Users,o=<ORG_ID>,dc=jumpcloud,dc=com" '(uid=*)' uid

   Note: the host itself must be in the peername ACL in slapd.conf if you
   test from there (127.0.0.1 only covers in-container).

5. Point QTS at it: Control Panel -> Domain Security -> LDAP
   authentication, server host "localhost", LDAP security
   "ldap://(ldap+TLS)" — i.e. STARTTLS on port 389. This is the VERIFIED
   working configuration. Do NOT use the LDAPS/636 option in the panel:
   QTS generates backend configs (Samba ldapsam, nss LDAP) that speak
   plain LDAP + STARTTLS, and mixing panel-LDAPS with backend-STARTTLS
   produces components spraying plaintext at the TLS port ("wrong version
   number" errors) and empty Domain Users/Groups lists. Base DN and the
   Users/Groups base DNs as for direct JumpCloud; One-Level scope matches
   JumpCloud's flat ou=Users layout. Both proxy ports are published
   loopback-only; 636/LDAPS remains available for admin ldapsearch use.
   Import your lab CA into the QNAP's certificate store first; the cert SAN
   must include IP:127.0.0.1 since that is what QTS dials.
   Everything else (base DN, bind DN, credentials) stays identical.
   Rollback is that one field: point it back at ldap.jumpcloud.com.

   NOTE on the ACL: QTS connections to a published port arrive NATed from
   the Docker bridge gateway, which is why slapd.conf allows 172.16.0.0/12
   (verified with slapacl: bridge range allowed, arbitrary LAN denied).
   Container Station sometimes uses a non-default bridge subnet - if
   connections are denied, check `docker network inspect bridge` and adjust
   that ACL line to the actual bridge range.

## Tune the cache templates (do this once)

pcache only caches queries whose filter *shape* matches a `pcacheTemplate`.
The config ships with the shapes QTS/Samba typically sends, but verify:

1. Leave `loglevel stats` on, log in to the NAS / mount a share once.
2. `podman logs jc-ldap-proxy | grep SRCH` — each line shows a filter.
3. For any recurring filter shape not covered, add a `pcacheTemplate` with
   the values stripped, e.g. `(&(objectClass=sambaDomain)(sambaDomainName=))`
   becomes a template of exactly that form. Attributes not in `pcacheAttrset 0`
   must be added there too, or matching queries won't be cached.
4. Restart, re-test, then set `SLAPD_LOGLEVEL=none` in `.env` and
   `docker compose up -d` — no rebuild needed.

## Authentication

Authenticated clients are handled by pass-through: their own bind is
forwarded to JumpCloud, and their operations run under it. Anonymous
operations are ALSO passed through (default mode, no credentials
configured): JumpCloud rejects them itself with err=32, making the proxy
error-code-identical to a direct JumpCloud connection. This exactness
matters: QTS runs a two-pass sync where the anonymous probe must fail
precisely the way JumpCloud fails it (err=32); both locally refusing it
(err=53) and making it succeed (idassert) were observed to break QTS
Domain Users/Groups ingestion. The proxy holds no credentials of any
kind — there is no bind DN or secret in .env, the compose file, or the
image. QTS keeps its existing JumpCloud bind DN and password; every
bind is forwarded to JumpCloud per connection (back-ldap
`rebind-as-user`), and that connection's searches — including the per-user
Samba hash fetches the cache accelerates — run under that forwarded
identity. The proxy never contacts JumpCloud anonymously: the only
anonymous operation it accepts (the loopback rootDSE healthcheck) is
answered locally by slapd and generates zero upstream operations
(verified: 3 healthcheck queries, 0 upstream ops).

Verified auth semantics (all tested against a live slapd):
- Anonymous access is limited to rootDSE base reads from loopback (the
  healthcheck); any operation on the JumpCloud tree without an
  authenticated bind is refused.
- While JumpCloud is reachable, it is authoritative: a password changed
  there takes effect through the proxy immediately, and the old password
  is rejected at once — the bind cache never overrides a live upstream.
- While JumpCloud is unreachable, new LDAP binds fail (binds are never
  answered from cache — a cached bind leaves the proxy without upstream
  credentials and breaks later operations). Already-bound connections keep
  working for cached searches, which covers SMB per-user auth.
- TLS on both legs: clients speak LDAPS to the proxy (your lab CA), the
  proxy speaks LDAPS to ldap.jumpcloud.com with certificate validation
  required (public CA bundle, TLS_REQCERT demand).

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
placement — see docker-compose.yml. With host networking, QTS points at
127.0.0.1:636: auth traffic never leaves the NAS, the proxy shares the
NAS's failure domain (if the NAS is up, its auth path is up), and the
peername ACL simplifies to loopback only. Any always-on Podman host works
too via the Quadlet unit; that adds one cross-host dependency for NAS auth.

## Operational notes

- Cert expiry is INVISIBLE to the healthcheck (it deliberately skips
  verification on loopback). An expired proxy cert breaks QTS LDAP while
  the container still reports healthy. Issue the loopback cert long-lived
  (it never crosses a wire), and if QTS auth fails with a green container,
  check cert dates first.
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
  the positive TTL.
- Cache is on tmpfs (see the Quadlet unit): no hashes at rest, cold cache
  after restart. Move to a volume only if you accept hashes on disk.
- The proxy answers only the QNAP + localhost (peername ACL) and requires
  authenticated binds; keep host firewalling in front of it anyway.

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
