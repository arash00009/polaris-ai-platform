"""API-key authentication and tenant derivation.

docs/architecture.md section 7, design decision #1: "the gateway derives the tenant from the
API key, and a mismatching body tenant_id is rejected with 403. A tenant identity supplied by
the caller must never be authoritative." This module owns the first half (key -> tenant); the
second half (comparing against the request body) is main.py's job, since it needs the parsed
body.
"""

import hmac
import json
from dataclasses import dataclass

from gateway.config import Settings

API_KEY_HEADER = "x-api-key"


@dataclass(frozen=True, slots=True)
class ApiKeyStore:
    """An immutable api_key -> tenant_id lookup table, parsed once at startup.

    Deliberately not a plain dict stashed on Settings: Settings.api_keys_json is a SecretStr
    specifically so that logging or exception-formatting a Settings instance can never leak
    the key->tenant map (see config.py). This class is where the one-time, trusted parse of
    that secret happens, and it is stored on app.state -- never on Settings.
    """

    _by_key: dict[str, str]

    @classmethod
    def from_settings(cls, settings: Settings) -> "ApiKeyStore":
        raw = json.loads(settings.api_keys_json.get_secret_value())
        return cls.from_mapping(raw)

    @classmethod
    def from_mapping(cls, mapping: dict[str, str]) -> "ApiKeyStore":
        """Build directly from a plain dict -- used by from_settings() above and by tests,
        which have no reason to go through Settings' SecretStr/JSON round trip just to build a
        known, fixed set of test keys.
        """
        return cls(_by_key=dict(mapping))

    def __len__(self) -> int:
        return len(self._by_key)

    def resolve(self, api_key: str) -> str | None:
        """Return the tenant for ``api_key``, or None if it is missing/unknown.

        Compares against every configured key with hmac.compare_digest, rather than a plain
        dict lookup that returns early on the first non-matching byte, so that looking up a
        wrong key takes the same time regardless of how many characters happened to match --
        a constant-time comparison against *each* candidate. This is a real, if small, defense:
        a dict's hash-based lookup does not leak timing by key content the way a naive
        string-equality loop would, but using compare_digest here costs nothing and removes
        the question entirely rather than relying on CPython dict internals staying that way.
        """
        if not api_key:
            return None
        for candidate, tenant_id in self._by_key.items():
            if hmac.compare_digest(candidate, api_key):
                return tenant_id
        return None
