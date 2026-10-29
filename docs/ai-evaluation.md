# AI evaluation: a golden dataset, a keyword-presence score, a Pushgateway

Covers **Phase 17**: `docs/architecture.md`'s own "Done when" wording for this phase is *"Golden
dataset, evaluation scores tracked per prompt/model version, shown next to technical
dashboards."* See ADR-38 for the full design record, including why a custom harness was chosen
over Langfuse/Phoenix and why a Prometheus Pushgateway carries the score.

**Status: unit-tested in the sandbox, 2026-10-29 — not yet confirmed on the target machine.**
`eval/`'s own test suite passes (44 tests, 99.15% coverage, `ruff check`/`ruff format --check`
clean), and the harness was run for real in the sandbox against a live, locally-started
`ai_service` (`MockBackend`) over plain HTTP — see §5 for that output. What is *not* yet
confirmed: a real `helm install` of the Pushgateway chart, a real eval run against the Ollama-
backed `polaris-dev` deployment, and the pushed `polaris_eval_score` metric actually showing up
in Prometheus/Grafana. This sandbox has no `helm` binary and no cluster, so that confirmation
can only happen on Darya.

## 1. What is actually measured

Each golden-dataset item (`eval/golden_dataset.json`) is a prompt plus a list of
`expected_keywords`. A response's score is the fraction of those keywords present as a
case-insensitive substring (`eval/src/eval_harness/scoring.py`); a run's overall score is the
mean across items — `docs/architecture.md` section 9's SLI table's exact wording, "mean
evaluation score on the golden dataset."

This is deliberately a heuristic, not a semantic judgement: it answers "did the response mention
the right things," not "is the response actually correct, well-written, or safe." ADR-38 names
the reasons (no new embedding/judge-model dependency, no "who checks the checker" problem) and
names what *would* need something more (Langfuse, Phoenix, or an LLM-as-judge scorer added
alongside this one, not instead of it).

Every prompt in the dataset matches one of `ai_service/backends/mock.py`'s own known-topic
lookups, and every `expected_keywords` entry is a real, verbatim substring of that backend's
actual canned answer (checked programmatically against the real `MockBackend` code while writing
the dataset, not eyeballed). This means a run against `MockBackend` is a deterministic
regression check that should score at or near 1.0 forever — a canary for the harness itself
breaking, not a measurement of anything interesting — while a run against the real,
non-deterministic `OpenAICompatBackend` is the actually interesting number.

## 2. Where a score comes from and where it goes

| Step | What happens |
|---|---|
| 1. Run | `make eval-run ARGS='--base-url <ai_service URL> --backend {mock,openai_compat} [--pushgateway-url <url>]'` |
| 2. Read the governance record | The harness calls the live service's `GET /v1/meta` (Phase 16) and tags the run with its real `model_version`/`prompt_version` — it never hardcodes or re-derives which model/prompt is live |
| 3. Call the service | `POST /v1/chat` for every golden-dataset prompt (tenant id `eval`, distinct from the real gateway tenants `demo`/`acme`/`globex` so eval traffic is never confused with real traffic in `ai_service`'s own tenant-labelled metrics/logs) |
| 4. Score | `score_item()` per response, `mean_score()` overall, plus a per-category breakdown (`pods`/`deployments`/`services`/`namespaces`) |
| 5. Push (optional) | `polaris_eval_score{backend, model_version, prompt_version, category}` pushed to a Prometheus Pushgateway, `category="overall"` for the mean and one series per golden-dataset category |
| 6. Scrape | The existing Phase 9 Prometheus scrapes the Pushgateway via its own bundled `ServiceMonitor` (no new Prometheus config needed) |
| 7. Dashboard | `deploy/platform/eval/dashboards/eval-dashboard.json`, provisioned the same ConfigMap-sidecar way every other dashboard in this project is (Phase 9/13) |

`--backend` is a required, explicit CLI flag, not inferred from `/v1/meta`: `MetaResponse` has no
`backend` field (only `model_version`/`prompt_version`/`deployment_version`/`config_version`/
`environment`), and guessing it from `model_version`'s string shape would be fragile. Whoever
runs `make eval-run` already knows which deployment they are pointing at.

## 3. Why keyword presence, and why a Pushgateway

See ADR-38 for the full reasoning; in short:

- **Custom harness, not Langfuse or Phoenix.** Langfuse self-hosted needs Postgres, ClickHouse,
  Redis and object storage (`docs/architecture.md` section 16) for a single-developer project
  with one golden dataset and no second reviewer — disproportionate to what "Done when" asks
  for. Phoenix is lighter but was never evaluated either: there was no concrete need driving it,
  named honestly as untried rather than quietly ruled out.
- **Keyword presence, not semantic similarity or an LLM-as-judge.** No new model dependency, no
  second non-deterministic call whose own correctness nobody checks, fully deterministic and
  explainable — the same style of check `test_mock_backend.py` has used since Phase 2.
- **A Prometheus Pushgateway, not a write-endpoint added to `ai_service`.** The eval harness is
  an external, periodic/batch client, not a continuously-scrapeable process — precisely the one
  case Prometheus's own documentation names the Pushgateway for. Adding an authenticated write
  endpoint to `ai_service` instead would mix "report an offline evaluation result" into a
  service whose threat model (Phase 12-15's auth, rate limits, admission policy) never
  anticipated a write surface at all.
- **`honorLabels: true` on the Pushgateway's ServiceMonitor** (confirmed as the chart's own real
  default, 2026-10-29) is not incidental: without it, Prometheus's scrape-time relabeling would
  overwrite the pushed `job`/`instance` labels with the Pushgateway Pod's own target labels,
  destroying the one thing distinguishing one eval run's series from another's.
- **No persistent volume on the Pushgateway** (the chart's own default) — a restarted Pod loses
  every previously-pushed score until the harness runs again. Accepted and named, not a surprise:
  this is a toy batch workload: re-running `make eval-run` is cheap.

## 4. What this does *not* give you

A Pushgateway holds the *last* pushed value per grouping key (`backend`), not a history of every
run — `polaris_eval_score`'s time series only gets data points for however long Prometheus keeps
scraping that one, now-static value, not one point per actual eval run. A real trend over many
runs needs either a scheduled `make eval-run` (a Kubernetes `CronJob`, not built this phase — see
Revisit when) or a different storage shape entirely (the Langfuse/MLflow-style option ADR-38
deferred). This phase proves the mechanism — a real score, tagged with a real model/prompt
version, visible on a dashboard — not a long-running quality-trend system.

This phase also deliberately does **not** wire the eval score into Argo Rollouts'
`AnalysisTemplate` as a canary gate. `docs/architecture.md` section 8 names that as a later
input ("later eval score"), and Phase 18 (progressive delivery) has not started yet — building
that gate here would be building ahead of this project's own roadmap, the same mistake Phase 16
was careful not to make with MLflow.

## 5. A real run in the sandbox (no cluster needed for this part)

Confirmed for real against a locally-started `ai_service` (`uvicorn`, `MockBackend`, no Docker,
no cluster — the same thing `make app-run` does):

```
$ eval-harness --base-url http://127.0.0.1:8000 --backend mock --dataset golden_dataset.json
{
  "backend": "mock",
  "model_version": "mock-1",
  "prompt_version": "v1",
  "mean_score": 1.0,
  "items": [ ... 8 items, every one scoring 1.0 ... ]
}
```

A perfect 1.0, exactly as designed (§1) — the real, deterministic-by-design canary passing, not
yet the interesting measurement. `--min-score` was also checked for real: `--min-score 1.0`
exits `0`; `--min-score 1.01` exits `1` with the mean score printed in the error.

## 6. Target-machine verification — not yet done

Not yet confirmed: a real `helm install` of the Pushgateway chart (`make pushgateway-install`);
a real eval run against `polaris-dev`'s Ollama-backed `OpenAICompatBackend` (expected to score
well below 1.0 — a real, honest, non-perfect number is the point, not a defect); the pushed
`polaris_eval_score` metric actually appearing in Prometheus (`curl .../api/v1/query?query=
polaris_eval_score`); and the Grafana dashboard (`deploy/platform/eval/dashboards/
eval-dashboard.json`) actually rendering it. This sandbox has no `helm` binary and no Docker
daemon — confirmed the same way every earlier Kubernetes-facing phase in this project has been:
only a real `helm install` and a real `make eval-run` against Darya's own `polaris-dev` prove it.

## Revisit when

A real trend over many eval runs is needed (a Kubernetes `CronJob` running `make eval-run` on a
schedule, rather than a human invoking it) — the real forcing function for moving past "last
pushed value" to an actual history; or Phase 18 (progressive delivery) is ready to gate a canary
on eval score, at which point this phase's batch-pushed metric needs to become something an
`AnalysisTemplate` can query live. See ADR-38 for the Langfuse/Phoenix revisit conditions too.
