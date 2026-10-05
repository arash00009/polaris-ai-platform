from gateway.ratelimit import DailyQuota, TokenBucketLimiter


def test_bucket_starts_full_not_empty():
    """A brand-new tenant's first request must not be rejected (ratelimit.py's own docstring)."""
    limiter = TokenBucketLimiter(capacity=3, rate_per_second=1)
    assert limiter.allow("demo") is True


def test_bucket_rejects_once_capacity_is_used():
    limiter = TokenBucketLimiter(capacity=2, rate_per_second=0.0)
    now = 1000.0
    assert limiter.allow("demo", now=now) is True
    assert limiter.allow("demo", now=now) is True
    assert limiter.allow("demo", now=now) is False


def test_bucket_refills_over_time():
    limiter = TokenBucketLimiter(capacity=1, rate_per_second=1.0)
    now = 1000.0
    assert limiter.allow("demo", now=now) is True
    assert limiter.allow("demo", now=now) is False
    # One second later, exactly one token has refilled.
    assert limiter.allow("demo", now=now + 1.0) is True


def test_bucket_is_per_tenant():
    limiter = TokenBucketLimiter(capacity=1, rate_per_second=0.0)
    now = 1000.0
    assert limiter.allow("demo", now=now) is True
    assert limiter.allow("demo", now=now) is False
    assert limiter.allow("acme-corp", now=now) is True


def test_quota_allows_up_to_the_limit_then_rejects():
    quota = DailyQuota(limit=2)
    now = 1_700_000_000.0
    assert quota.allow("demo", now=now) is True
    assert quota.allow("demo", now=now) is True
    assert quota.allow("demo", now=now) is False


def test_quota_remaining_reflects_usage():
    quota = DailyQuota(limit=5)
    now = 1_700_000_000.0
    assert quota.remaining("demo", now=now) == 5
    quota.allow("demo", now=now)
    assert quota.remaining("demo", now=now) == 4


def test_quota_resets_on_a_new_day():
    quota = DailyQuota(limit=1)
    day_one = 1_700_000_000.0
    day_two = day_one + 86_400.0
    assert quota.allow("demo", now=day_one) is True
    assert quota.allow("demo", now=day_one) is False
    assert quota.allow("demo", now=day_two) is True


def test_quota_is_per_tenant():
    quota = DailyQuota(limit=1)
    now = 1_700_000_000.0
    assert quota.allow("demo", now=now) is True
    assert quota.allow("demo", now=now) is False
    assert quota.allow("acme-corp", now=now) is True
