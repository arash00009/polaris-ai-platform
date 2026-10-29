"""CLI entry point: `make eval-run` / `python -m eval_harness.cli`. Wires the real
ServiceClient and (optionally) the real Pushgateway push around runner.py's pure evaluate()/
build_run_result() -- this module is the one place in the package that is not meant to be
unit-tested with fakes; eval_harness/tests cover runner.py/scoring.py/dataset.py instead.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict
from pathlib import Path

from eval_harness.client import ServiceClient, ServiceClientError
from eval_harness.dataset import GoldenDatasetError, load_golden_dataset
from eval_harness.pushgateway import push_eval_metrics
from eval_harness.runner import EvalRunResult, build_run_result, evaluate

DEFAULT_DATASET = Path(__file__).resolve().parent.parent.parent / "golden_dataset.json"


def _report(result: EvalRunResult) -> dict:
    return {
        "backend": result.backend,
        "model_version": result.model_version,
        "prompt_version": result.prompt_version,
        "mean_score": result.mean_score,
        "items": [asdict(item) for item in result.items],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Phase 17 (ADR-38): run the golden dataset against a live ai_service and "
        "report a mean evaluation score, tagged with the Phase 16 governance version."
    )
    parser.add_argument(
        "--base-url",
        required=True,
        help="ai_service base URL, e.g. http://localhost:8000 (called directly, not through "
        "ai-gateway -- see client.py)",
    )
    parser.add_argument(
        "--backend",
        required=True,
        choices=["mock", "openai_compat"],
        help="which backend this ai_service instance is configured with (ai_service/config.py's "
        "Settings.backend) -- not discoverable from /v1/meta alone, so it is named explicitly "
        "rather than inferred from model_version's string shape",
    )
    parser.add_argument(
        "--dataset", default=str(DEFAULT_DATASET), help="path to golden_dataset.json"
    )
    parser.add_argument(
        "--pushgateway-url",
        default=None,
        help="e.g. http://pushgateway.observability:9091 -- if omitted, the report is printed "
        "but nothing is pushed (--dry-run equivalent)",
    )
    parser.add_argument("--timeout", type=float, default=30.0, help="per-request timeout, seconds")
    parser.add_argument(
        "--min-score",
        type=float,
        default=None,
        help="exit 1 if the mean score falls below this (0-1) -- for use in a CI/make check, "
        "not wired into Argo Rollouts analysis yet (ADR-38's Consequences)",
    )
    args = parser.parse_args(argv)

    try:
        dataset = load_golden_dataset(args.dataset)
    except (GoldenDatasetError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    client = ServiceClient(args.base_url, timeout_s=args.timeout)
    try:
        meta = client.get_meta()
        items = evaluate(dataset, chat_fn=client.chat)
    except ServiceClientError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    finally:
        client.close()

    result = build_run_result(
        backend=args.backend,
        model_version=meta["model_version"],
        prompt_version=meta["prompt_version"],
        items=items,
    )
    print(json.dumps(_report(result), indent=2))

    if args.pushgateway_url:
        push_eval_metrics(args.pushgateway_url, result)
        print(f"pushed to {args.pushgateway_url} (job=polaris_eval)", file=sys.stderr)

    if args.min_score is not None and result.mean_score < args.min_score:
        print(
            f"error: mean score {result.mean_score:.3f} is below --min-score {args.min_score}",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
