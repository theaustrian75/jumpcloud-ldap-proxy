#!/bin/sh
# verify-proxy.sh — measure the JumpCloud LDAP proxy cache from its own logs.
# Requires SLAPD_LOGLEVEL=stats on the container. Run after a few hours of
# normal use (cache starts cold on every container recreate).
#
# Reading the results:
#   1. hit ratio      — % of searches answered locally (healthy: >80%)
#   2. latency        — avg cached vs upstream search time (the per-op win)
#   3. enumerations   — QTS full-sync (objectClass=*) cache behavior,
#                       paired by conn/op ID (expect ~1 upstream per TTL
#                       window, cached in between)
#   4. traffic mix    — ALL query shapes by frequency (not just misses);
#                       shapes with no matching pcacheTemplate are
#                       candidates for a new template line
#   5. upstream-only  — filter shapes of the SLOW searches specifically;
#                       this is the actual tuning worklist

CONTAINER="${1:-01-ldap-proxy-01}"
LOG=$(docker logs "$CONTAINER" 2>&1)

echo "=== 1. Cache hit ratio (searches only, binds excluded) ==="
echo "$LOG" | grep -oE "SEARCH RESULT.*etime=[0-9.]+" | \
  awk -F'etime=' '{ if ($2+0 < 0.005) f++; else s++ } END \
  { if (f+s) printf "cache-served: %d   upstream: %d   hit ratio: %.0f%%\n", f, s, f*100/(f+s);
    else print "no SEARCH RESULT lines found — is SLAPD_LOGLEVEL=stats?" }'

echo ""
echo "=== 2. Latency: cached vs upstream searches ==="
echo "$LOG" | grep -oE "SEARCH RESULT.*etime=[0-9.]+" | awk -F'etime=' \
  '{ if ($2+0 < 0.005) { cf+=$2; cn++ } else { sf+=$2; sn++ } } END \
  { if (cn) printf "cached:   n=%-6d avg=%.4fs\n", cn, cf/cn;
    if (sn) printf "upstream: n=%-6d avg=%.4fs\n", sn, sf/sn;
    if (cn && sn) printf "per-search speedup: %.0fx\n", (sf/sn)/(cf/cn) }'

echo ""
echo "=== 3. Enumerations (objectClass=*), paired by conn/op ==="
echo "$LOG" | awk '
  /SRCH base=.*filter="\(objectClass=\*\)"/ { want[$3 $4] = 1 }
  /SEARCH RESULT/ && ($3 $4) in want {
    if (match($0, /etime=[0-9.]+/)) {
      e = substr($0, RSTART+6, RLENGTH-6) + 0
      if (e < 0.005) f++; else s++
    }
    delete want[$3 $4]
  }
  END { printf "cached: %d   upstream: %d\n", f+0, s+0 }'

echo ""
echo "=== 4. Traffic mix: ALL query shapes by frequency ==="
echo "$LOG" | grep 'SRCH base=' | grep -oE 'filter="[^"]*"' | \
  sed 's/=[^)(*]*)/=)/g' | sort | uniq -c | sort -rn | head -10

echo ""
echo "=== 5. Tuning worklist: shapes of UPSTREAM (slow) searches only ==="
echo "$LOG" | awk '
  /SRCH base=/ {
    if (match($0, /filter="[^"]*"/)) {
      flt = substr($0, RSTART, RLENGTH)
      gsub(/=[^)(*"]*\)/, "=)", flt)
      shape[$3 $4] = flt
    }
  }
  /SEARCH RESULT/ && ($3 $4) in shape {
    if (match($0, /etime=[0-9.]+/)) {
      e = substr($0, RSTART+6, RLENGTH-6) + 0
      if (e >= 0.005) slow[shape[$3 $4]]++
    }
    delete shape[$3 $4]
  }
  END { for (fl in slow) printf "%6d  %s\n", slow[fl], fl }' | sort -rn | head -10
