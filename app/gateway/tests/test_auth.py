from gateway.auth import ApiKeyStore


def test_unknown_key_resolves_to_none():
    store = ApiKeyStore.from_mapping({"sk-known-0123456789": "demo"})
    assert store.resolve("sk-totally-unknown-key") is None


def test_empty_key_resolves_to_none():
    store = ApiKeyStore.from_mapping({"sk-known-0123456789": "demo"})
    assert store.resolve("") is None


def test_known_key_resolves_to_its_tenant():
    store = ApiKeyStore.from_mapping({"sk-known-0123456789": "demo"})
    assert store.resolve("sk-known-0123456789") == "demo"


def test_two_tenants_resolve_independently():
    store = ApiKeyStore.from_mapping(
        {"sk-aaaaaaaaaaaaaaaa": "demo", "sk-bbbbbbbbbbbbbbbb": "acme-corp"}
    )
    assert store.resolve("sk-aaaaaaaaaaaaaaaa") == "demo"
    assert store.resolve("sk-bbbbbbbbbbbbbbbb") == "acme-corp"


def test_len_reports_the_number_of_configured_keys():
    assert len(ApiKeyStore.from_mapping({})) == 0
    assert len(ApiKeyStore.from_mapping({"a": "demo", "b": "acme-corp"})) == 2


def test_a_key_that_is_a_prefix_of_another_does_not_match():
    store = ApiKeyStore.from_mapping({"sk-aaaaaaaaaaaaaaaaXYZ": "demo"})
    assert store.resolve("sk-aaaaaaaaaaaaaaaa") is None
