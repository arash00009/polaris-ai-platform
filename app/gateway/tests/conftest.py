import json
from collections.abc import Callable, Iterator

import pytest
from fastapi.testclient import TestClient

from gateway.auth import ApiKeyStore
from gateway.config import Settings
from gateway.main import create_app
from tests.fakes import FakeUpstream, Handler, ok_chat_handler

DEMO_API_KEY = "sk-demo-0123456789abcdef"
DEMO_TENANT = "demo"


@pytest.fixture(autouse=True)
def _clean_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    """Tests must not depend on GATEWAY_* variables that happen to be set on the machine."""
    import os

    for name in list(os.environ):
        if name.startswith("GATEWAY_"):
            monkeypatch.delenv(name)


@pytest.fixture
def anyio_backend() -> str:
    return "asyncio"


@pytest.fixture
def api_keys() -> ApiKeyStore:
    return ApiKeyStore.from_mapping({DEMO_API_KEY: DEMO_TENANT})


@pytest.fixture
def build_client(
    api_keys: ApiKeyStore,
) -> Callable[..., tuple[TestClient, FakeUpstream]]:
    """Factory: build a TestClient wired to a FakeUpstream, with overridable settings/keys.

    Returns (TestClient, FakeUpstream) so a test can both drive requests and inspect exactly
    what the gateway forwarded (headers, body) -- see test_main.py's propagation assertions.
    """

    def _build(
        *,
        handler: Handler | None = None,
        settings: Settings | None = None,
        keys: ApiKeyStore | None = None,
    ) -> tuple[TestClient, FakeUpstream]:
        upstream = FakeUpstream(handler or ok_chat_handler())
        app = create_app(
            settings or Settings(),
            client=upstream.client(),
            api_keys=keys if keys is not None else api_keys,
        )
        test_client = TestClient(app)
        return test_client, upstream

    return _build


@pytest.fixture
def client(build_client: Callable[..., tuple[TestClient, FakeUpstream]]) -> Iterator[TestClient]:
    """The common case: one tenant, a healthy upstream, default rate limit/quota."""
    test_client, _ = build_client()
    with test_client as tc:
        yield tc


def auth_headers(api_key: str = DEMO_API_KEY) -> dict[str, str]:
    return {"x-api-key": api_key}


def chat_body(tenant_id: str = DEMO_TENANT, prompt: str = "hello") -> str:
    return json.dumps({"tenant_id": tenant_id, "prompt": prompt})
