from gateway.config import Settings
from gateway.ratelimit import DailyQuota, TenantLimits, TokenBucketLimiter


def _flat_limits(*, rate_per_minute: float, burst: float, quota_per_day: int) -> TenantLimits:
    """A TenantLimits with no per-tenant overrides -- every tenant gets the same flat numbers,
    exactly the pre-Phase-14 behaviour. Used by the tests below that are not themselves testing
    the override mechanism."""
    return TenantLimits(
        default_rate_per_minute=rate_per_minute,
        default_burst=burst,
        default_quota_per_day=quota_per_day,
    )


def test_bucket_starts_full_not_empty():
    """A brand-new tenant's first request must not be rejected (ratelimit.py's own docstring)."""
    limiter = TokenBucketLimiter(limits=_flat_limits(rate_per_minute=60, burst=3, quota_per_day=1))
    assert limiter.allow("demo") is True


def test_bucket_rejects_once_capacity_is_used():
    limiter = TokenBucketLimiter(limits=_flat_limits(rate_per_minute=0, burst=2, quota_per_day=1))
    now = 1000.0
    assert limiter.allow("demo", now=now) is True
    assert limiter.allow("demo", now=now) is True
    assert limiter.allow("demo", now=now) is False


def test_bucket_refills_over_time():
    limiter = TokenBucketLimiter(limits=_flat_limits(rate_per_minute=60, burst=1, quota_per_day=1))
    now = 1000.0
    assert limiter.allow("demo", now=now) is True
    assert limiter.allow("demo", now=now) is False
    # One second later, exactly one token has refilled (60/min == 1/s).
    assert limiter.allow("demo", now=now + 1.0) is True


def test_bucket_is_per_tenant():
    limiter = TokenBucketLimiter(limits=_flat_limits(rate_per_minute=0, burst=1, quota_per_day=1))
    now = 1000.0
    assert limiter.allow("demo", now=now) is True
    assert limiter.allow("demo", now=now) is False
    assert limiter.allow("acme-corp", now=now) is True


def test_bucket_uses_each_tenants_own_configured_capacity():
    """Phase 14: the whole point. Two tenants, two different burst sizes, same limiter."""
    limits = TenantLimits(
        default_rate_per_minute=0,
        default_burst=1,
        default_quota_per_day=1,
        overrides={"acme": {"rate_limit_burst": 5}},
    )
    limiter = TokenBucketLimiter(limits=limits)
    now = 1000.0
    # "demo" has no override -> the flat default (burst 1): one request, then rejected.
    assert limiter.allow("demo", now=now) is True
    assert limiter.allow("demo", now=now) is False
    # "acme" overrides burst to 5 -> five requests before rejection, not one.
    for _ in range(5):
        assert limiter.allow("acme", now=now) is True
    assert limiter.allow("acme", now=now) is False


def test_quota_allows_up_to_the_limit_then_rejects():
    quota = DailyQuota(limits=_flat_limits(rate_per_minute=1, burst=1, quota_per_day=2))
    now = 1_700_000_000.0
    assert quota.allow("demo", now=now) is True
    assert quota.allow("demo", now=now) is True
    assert quota.allow("demo", now=now) is False


def test_quota_remaining_reflects_usage():
    quota = DailyQuota(limits=_flat_limits(rate_per_minute=1, burst=1, quota_per_day=5))
    now = 1_700_000_000.0
    assert quota.remaining("demo", now=now) == 5
    quota.allow("demo", now=now)
    assert quota.remaining("demo", now=now) == 4


def test_quota_resets_on_a_new_day():
    quota = DailyQuota(limits=_flat_limits(rate_per_minute=1, burst=1, quota_per_day=1))
    day_one = 1_700_000_000.0
    day_two = day_one + 86_400.0
    assert quota.allow("demo", now=day_one) is True
    assert quota.allow("demo", now=day_one) is False
    assert quota.allow("demo", now=day_two) is True


def test_quota_is_per_tenant():
    quota = DailyQuota(limits=_flat_limits(rate_per_minute=1, burst=1, quota_per_day=1))
    now = 1_700_000_000.0
    assert quota.allow("demo", now=now) is True
    assert quota.allow("demo", now=now) is False
    assert quota.allow("acme-corp", now=now) is True


def test_quota_uses_each_tenants_own_configured_limit():
    """Phase 14: unlike the token bucket, a quota override takes effect immediately -- no
    bucket was created up front to have been sized wrong (ratelimit.py's own docstring)."""
    limits = TenantLimits(
        default_rate_per_minute=1,
        default_burst=1,
        default_quota_per_day=1,
        overrides={"globex": {"quota_per_day": 3}},
    )
    quota = DailyQuota(limits=limits)
    now = 1_700_000_000.0
    assert quota.allow("demo", now=now) is True
    assert quota.allow("demo", now=now) is False
    for _ in range(3):
        assert quota.allow("globex", now=now) is True
    assert quota.allow("globex", now=now) is False


def test_tenant_limits_from_settings_parses_overrides_and_falls_back_to_flat_defaults():
    settings = Settings(
        rate_limit_per_minute=60,
        rate_limit_burst=20,
        quota_per_day=2_000,
        tenant_limits_json=(
            '{"acme": {"rate_limit_per_minute": 120, "rate_limit_burst": 40,'
            ' "quota_per_day": 5000}, "globex": {"quota_per_day": 200}}'
        ),
    )
    limits = TenantLimits.from_settings(settings)
    # acme: every field overridden.
    assert limits.rate_per_minute("acme") == 120
    assert limits.burst("acme") == 40
    assert limits.quota_per_day("acme") == 5_000
    # globex: only quota_per_day overridden -- the other two fall back to the flat default.
    assert limits.rate_per_minute("globex") == 60
    assert limits.burst("globex") == 20
    assert limits.quota_per_day("globex") == 200
    # demo: no entry at all -> every field falls back to the flat default.
    assert limits.rate_per_minute("demo") == 60
    assert limits.burst("demo") == 20
    assert limits.quota_per_day("demo") == 2_000
