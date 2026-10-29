"""eval_harness (Phase 17, ADR-38): runs the golden dataset (eval/golden_dataset.json) against a
live ai_service, scores each response by keyword presence, and reports a mean score per
prompt/model version.

This is a tool that calls ai_service over HTTP -- it is deliberately not part of the
`ai_service` Python package (see ADR-38's Consequences: "a tool that calls the service, not
part of the service itself").
"""
