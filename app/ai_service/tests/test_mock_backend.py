import asyncio

import pytest

from ai_service.backends import BackendError, MockBackend

pytestmark = pytest.mark.anyio


async def test_answers_are_deterministic() -> None:
    backend = MockBackend()
    first = await backend.generate("Explain Kubernetes pods")
    second = await backend.generate("Explain Kubernetes pods")
    assert first == second


@pytest.mark.parametrize(
    ("prompt", "expected_fragment"),
    [
        ("What is a Pod?", "smallest deployable unit"),
        ("explain deployments", "ReplicaSets"),
        ("How does a Service work", "stable virtual IP"),
        ("what is a namespace", "logical partition"),
    ],
)
async def test_known_topics_get_a_specific_answer(prompt: str, expected_fragment: str) -> None:
    result = await MockBackend().generate(prompt)
    assert expected_fragment in result.text
    assert result.text.startswith("[mock] ")


async def test_topic_words_must_be_whole_words() -> None:
    # "podcast" contains "pod" but is not about Pods.
    result = await MockBackend().generate("recommend a podcast")
    assert "smallest deployable unit" not in result.text


async def test_model_name_and_token_estimates() -> None:
    result = await MockBackend(model="mock-x").generate("one two three")
    assert result.model == "mock-x"
    assert result.prompt_tokens == 3
    assert result.completion_tokens is not None
    assert result.completion_tokens > 0


async def test_latency_is_simulated_with_a_sleep(monkeypatch: pytest.MonkeyPatch) -> None:
    waited: list[float] = []

    async def fake_sleep(seconds: float) -> None:
        waited.append(seconds)

    monkeypatch.setattr(asyncio, "sleep", fake_sleep)

    await MockBackend(latency_ms=250).generate("hi")
    await MockBackend(latency_ms=0).generate("hi")

    assert waited == [0.25]  # no sleep at all when latency is 0


async def test_failure_rate_zero_never_fails() -> None:
    backend = MockBackend(failure_rate=0.0)
    for _ in range(200):
        await backend.generate("hi")


async def test_failure_rate_one_always_fails() -> None:
    backend = MockBackend(failure_rate=1.0)
    for _ in range(20):
        with pytest.raises(BackendError):
            await backend.generate("hi")


async def _outcomes(backend: MockBackend, calls: int) -> list[bool]:
    outcomes = []
    for _ in range(calls):
        try:
            await backend.generate("hi")
            outcomes.append(True)
        except BackendError:
            outcomes.append(False)
    return outcomes


async def test_same_seed_gives_the_same_failure_pattern() -> None:
    first = await _outcomes(MockBackend(failure_rate=0.5, seed=7), 200)
    second = await _outcomes(MockBackend(failure_rate=0.5, seed=7), 200)
    other = await _outcomes(MockBackend(failure_rate=0.5, seed=8), 200)

    assert first == second
    assert first != other


async def test_failure_rate_is_roughly_respected() -> None:
    outcomes = await _outcomes(MockBackend(failure_rate=0.3, seed=1), 2000)
    failure_share = outcomes.count(False) / len(outcomes)
    assert 0.25 < failure_share < 0.35
