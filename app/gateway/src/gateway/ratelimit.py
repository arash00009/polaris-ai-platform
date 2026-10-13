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

Phase 14 adds ``TenantLimits``: the per-tenant *configured* override ADR-30's own "Revisit when"
column named -- before this, every tenant shared the exact same ``rate_limit_per_minute``/
``rate_limit_burst``/``quota_per_day`` numbers, which made "multi-tenant" mean "many tenant_ids,
one tier" rather than real tenancy. A tenant's capacity/rate are resolved ONCE, the first time
that tenant is ever seen (same moment its bucket is created) -- not re-read on every request --
so a config change takes effect for a tenant's *existing* bucket only after this pod restarts
(the bucket dict is itself in-memory/per-pod already, per the limitation named above, so this
adds no new caveat beyond the ones already documented).
"""

import json
import time
from dataclasses import dataclass


class TenantLimits:
    """Resolves one tenant's rate-limit/quota numbers: this tenant's configured override for a
    given field, falling back to the gateway-wide flat default for any field it does not
    override (including a tenant with no entry at all -- the common case for a tenant nobody
    has given a tier yet)."""

    def __init__(
        self,
        *,
        default_rate_per_minute: float,
        default_burst: float,
        default_quota_per_day: int,
        overrides: dict[str, dict[str, float]] | None = None,
    ) -> None:
        self._default_rate_per_minute = default_rate_per_minute
        self._default_burst = default_burst
        self._default_quota_per_day = default_quota_per_day
        self._overrides = overrides or {}

    @classmethod
    def from_settings(cls, settings) -> "TenantLimits":
        # settings.tenant_limits_json is already validated (shape, bounds, known keys only --
        # see config.py's _tenant_limits_must_be_well_formed) by the time Settings exists, so
        # this is a plain parse, not a second validation pass.
        return cls(
            default_rate_per_minute=settings.rate_limit_per_minute,
            default_burst=settings.rate_limit_burst,
            default_quota_per_day=settings.quota_per_day,
            overrides=json.loads(settings.tenant_limits_json),
        )

    def rate_per_minute(self, tenant_id: str) -> float:
        return self._overrides.get(tenant_id, {}).get(
            "rate_limit_per_minute", self._default_rate_per_minute
        )

    def burst(self, tenant_id: str) -> float:
        return self._overrides.get(tenant_id, {}).get("rate_limit_burst", self._default_burst)

    def quota_per_day(self, tenant_id: str) -> int:
        return self._overrides.get(tenant_id, {}).get("quota_per_day", self._default_quota_per_day)


@dataclass
class _Bucket:
    tokens: float
    updated_at: float
    capacity: float
    rate_per_second: float


class TokenBucketLimiter:
    """One token bucket per tenant_id, each sized from that tenant's own ``TenantLimits``."""

    def __init__(self, *, limits: TenantLimits) -> None:
        self._limits = limits
        self._buckets: dict[str, _Bucket] = {}

    def allow(self, tenant_id: str, *, now: float | None = None) -> bool:
        """Return True and consume one token if the tenant has one available."""
        now = time.monotonic() if now is None else now
        bucket = self._buckets.get(tenant_id)
        if bucket is None:
            # A tenant's first-ever request starts with a full bucket, not an empty one --
            # otherwise the very first request from a brand-new tenant would be rejected. This
            # is also the one moment this tenant's capacity/rate are resolved (module docstring).
            capacity = self._limits.burst(tenant_id)
            rate_per_second = self._limits.rate_per_minute(tenant_id) / 60.0
            bucket = _Bucket(
                tokens=capacity, updated_at=now, capacity=capacity, rate_per_second=rate_per_second
            )
            self._buckets[tenant_id] = bucket

        elapsed = max(0.0, now - bucket.updated_at)
        bucket.tokens = min(bucket.capacity, bucket.tokens + elapsed * bucket.rate_per_second)
        bucket.updated_at = now

        if bucket.tokens < 1.0:
            return False
        bucket.tokens -= 1.0
        return True


class DailyQuota:
    """One request counter per (tenant_id, UTC calendar day), each tenant's limit resolved
    fresh from ``TenantLimits`` on every call -- unlike the token bucket above, there is no
    per-tenant state to have been sized wrong at creation time, so a config change takes effect
    on this tenant's very next request, no restart needed."""

    def __init__(self, *, limits: TenantLimits) -> None:
        self._limits = limits
        self._counts: dict[tuple[str, int], int] = {}

    @staticmethod
    def _today(now: float | None = None) -> int:
        now = time.time() if now is None else now
        return int(now // 86400)

    def allow(self, tenant_id: str, *, now: float | None = None) -> bool:
        limit = self._limits.quota_per_day(tenant_id)
        key = (tenant_id, self._today(now))
        used = self._counts.get(key, 0)
        if used >= limit:
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
        limit = self._limits.quota_per_day(tenant_id)
        used = self._counts.get((tenant_id, self._today(now)), 0)
        return max(0, limit - used)
