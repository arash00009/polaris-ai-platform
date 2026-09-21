"""MockBackend (LOCAL / DEMO): a deterministic stand-in for a language model.

It exists for three reasons: the service runs anywhere without a GPU or model download,
tests and evaluations get repeatable answers, and failure engineering (Phase 19) can
inject latency and errors on demand. Every answer starts with "[mock]" so nobody mistakes
it for real model output.
"""

import asyncio
import random
import re

from ai_service.backends.base import BackendError, BackendResult, ModelBackend

# Short, accurate answers for a few Kubernetes topics, so the demo prompt
# ("Explain Kubernetes pods") returns something meaningful. First matching topic wins.
_TOPICS: tuple[tuple[re.Pattern[str], str], ...] = (
    (
        re.compile(r"\bpods?\b"),
        "A Pod is the smallest deployable unit in Kubernetes. It wraps one or more containers "
        "that share a network namespace (one IP address) and can share storage volumes. Pods "
        "are ephemeral: when one is deleted or its node fails, a controller such as a "
        "Deployment creates a replacement instead of repairing it.",
    ),
    (
        re.compile(r"\bdeployments?\b"),
        "A Deployment declares the desired state for a set of identical Pods: which image and "
        "how many replicas. It manages ReplicaSets to roll changes out gradually and to roll "
        "back to an earlier revision if an update goes wrong.",
    ),
    (
        re.compile(r"\bservices?\b"),
        "A Service gives a set of Pods a stable virtual IP address and DNS name, selecting them "
        "by label. Pods come and go with changing IP addresses, so clients talk to the Service "
        "and Kubernetes spreads the traffic over the healthy Pods behind it.",
    ),
    (
        re.compile(r"\bnamespaces?\b"),
        "A Namespace is a logical partition of a cluster. It scopes object names and is the unit "
        "where access rules (RBAC), resource quotas and network policies are usually applied, "
        "which makes it a common building block for multi-tenancy.",
    ),
)


def _estimate_tokens(text: str) -> int:
    # Whitespace-separated words. A rough estimate, good enough for a mock; real backends
    # report real token counts.
    return len(text.split())


def _answer(prompt: str) -> str:
    lowered = prompt.lower()
    for pattern, answer in _TOPICS:
        if pattern.search(lowered):
            return f"[mock] {answer}"
    return (
        f"[mock] This is a mock answer and no language model was called. "
        f"Your prompt contained {_estimate_tokens(prompt)} words."
    )


class MockBackend(ModelBackend):
    def __init__(
        self,
        *,
        model: str = "mock-1",
        latency_ms: int = 0,
        failure_rate: float = 0.0,
        seed: int | None = None,
        ready: bool = True,
    ) -> None:
        self._model = model
        self._ready = ready
        self._latency_ms = latency_ms
        self._failure_rate = failure_rate
        # A private generator: seeding it never touches global random state.
        self._rng = random.Random(seed)  # noqa: S311 - failure injection, not cryptography

    async def check_ready(self) -> None:
        if not self._ready:
            raise BackendError("mock backend: not ready")

    async def generate(self, prompt: str) -> BackendResult:
        if self._latency_ms:
            await asyncio.sleep(self._latency_ms / 1000)
        # A failure is decided after the wait, like a real backend that fails slowly.
        if self._failure_rate and self._rng.random() < self._failure_rate:
            raise BackendError("mock backend: injected failure")
        text = _answer(prompt)
        return BackendResult(
            text=text,
            model=self._model,
            prompt_tokens=_estimate_tokens(prompt),
            completion_tokens=_estimate_tokens(text),
        )
