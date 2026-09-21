import pytest
from fastapi.testclient import TestClient

from ai_service.config import Settings
from ai_service.main import create_app


@pytest.fixture(autouse=True)
def _clean_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    """Tests must not depend on POLARIS_* variables that happen to be set on the machine."""
    import os

    for name in list(os.environ):
        if name.startswith("POLARIS_"):
            monkeypatch.delenv(name)


@pytest.fixture
def anyio_backend() -> str:
    # The async tests use anyio's pytest plugin; the service itself runs on asyncio.
    return "asyncio"


@pytest.fixture
def client() -> TestClient:
    """A client for an app with the default (mock) backend and no artificial latency."""
    with TestClient(create_app(Settings())) as test_client:
        yield test_client
