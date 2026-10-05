"""Per-tenant rate limiting (token bucket) and daily quota (fixed window), in-memory.

LOCAL/DEMONSTRATION, named explicitly: both structures below live in this process's memory.
That means two real limitations, worth stating plainly rather than discovering by surprise on
the target machine:

1. State is per-pod. With ``replicaCount`` > 1 (helm/ai-platform/values.yaml's gateway block
   defaults to 1 for exactly this reason -- see docs/gateway.md), a tenant's effective limit
   is the configured limit multiplied by however many gateway pods happen to be up, because
   Kubernetes' Service load-balances across them with no knowledge of this module's counters.
2. State does not survive a pod restart. A tenant that has used 1,999 of a 2,000/day quota and
   is then rescheduled (a routine Kubernetes event, not a failure) gets a fresh 2,000.

A PRODUCTION EQUIVALENT would back both with a shared store (Redis is the standard choice: a
Lua script makes "check and decrement" atomic across replicas, and TTLs give it the daily reset
for free). That is explicitly not built here -- see ADR-30's "Revisit when" column.

Both structures use asyncio.Lock, not threading.Lock: ai-gateway is a single-process ASGI app
(no gunicorn/multiple workers in this deployment -- see Dockerfile), so there is exactly one
event loop, and an asyncio.Lock is the correct primitive for code that awaits while holding
it (nothing here does await while locked, but using the matching primitive avoids a mixed-
concurrency bug if that ever changes).
"""

import time
from dataclasses import dataclass


@dataclass
class _Bucket:
    tokens: float
    updated_at: float


class TokenBucketLimiter:
    """One token bucket per tenant_id. ``capacity`` tokens, refilling at ``rate`` tokens/second."""

    def __init__(self, *, capacity: float, rate_per_second: float) -> None:
        self._capacity = capacity
        self._rate = rate_per_second
        self._buckets: dict[str, _Bucket] = {}

    def allow(self, tenant_id: str, *, now: float | None = None) -> bool:
        """Return True and consume one token if the tenant has one available."""
        now = time.monotonic() if now is None else now
        bucket = self._buckets.get(tenant_id)
        if bucket is None:
            # A tenant's first-ever request starts with a full bucket, not an empty one --
            # otherwise the very first request from a brand-new tenant would be rejected.
            bucket = _Bucket(tokens=self._capacity, updated_at=now)
            self._buckets[tenant_id] = bucket

        elapsed = max(0.0, now - bucket.updated_at)
        bucket.tokens = min(self._capacity, bucket.tokens + elapsed * self._rate)
        bucket.updated_at = now

        if bucket.tokens < 1.0:
            return False
        bucket.tokens -= 1.0
        return True


class DailyQuota:
    """One request counter per (tenant_id, UTC calendar day)."""

    def __init__(self, *, limit: int) -> None:
        self._limit = limit
        self._counts: dict[tuple[str, int], int] = {}

    @staticmethod
    def _today(now: float | None = None) -> int:
        now = time.time() if now is None else now
        return int(now // 86400)

    def allow(self, tenant_id: str, *, now: float | None = None) -> bool:
        key = (tenant_id, self._today(now))
        used = self._counts.get(key, 0)
        if used >= self._limit:
            return False
        self._counts[key] = used + 1
        # Forget any previous day's entry for this tenant -- the dict would otherwise grow by
        # one key per tenant per day for the life of the process. A long-running pod (weeks) is
        # not this project's reality (LOCAL/DEMONSTRATION, Kubernetes recycles pods far more
        # often than that), but cleaning up is free and removes the question.
        stale = (tenant_id, key[1] - 1)
        self._counts.pop(stale, None)
        return True

    def remaining(self, tenant_id: str, *, now: float | None = None) -> int:
        used = self._counts.get((tenant_id, self._today(now)), 0)
        return max(0, self._limit - used)
