// scripts/load/chat-load.js — Phase 18 (ADR-39): the first real use of k6 in this project. It
// has sat in docs/architecture.md's Phase 1 toolchain list (line 484) unused since then, because
// nothing before this phase actually needed sustained synthetic traffic against a live endpoint
// while a canary's Argo Rollouts AnalysisTemplate judges real-time Prometheus metrics. This is
// deliberately a small, parameterized script, not a load-testing suite: the proven need is
// "keep ai_requests_total/ai_chat_duration_seconds moving during the analysis window," not a
// performance benchmark (see ADR-39's own "proven need" framing).
//
// Usage: k6 run --vus 3 --duration 6m scripts/load/chat-load.js
//   (or: TARGET_URL=... TENANT_ID=... k6 run scripts/load/chat-load.js — see env vars below)
//
// Env vars (all optional, sensible defaults for a local k3d canary demo):
//   TARGET_URL   base URL to POST against -- default http://127.0.0.1:8000, matching the
//                kubectl port-forward pattern already used throughout this project's own
//                target-machine verification steps.
//   HOST_HEADER  optional Host header, for reaching a Rollout through Traefik's own Ingress the
//                same way scripts/deploy/helm.sh's smoke test does (curl -H "Host: $host"
//                http://localhost:$INGRESS_PORT) rather than a direct Service port-forward --
//                scripts/verify/canary-demo.sh uses this form so the canary's traffic flows
//                through the same real ingress path a user's own traffic would.
//   TENANT_ID    default "canary-demo" -- distinct from the real gateway tenants
//                (demo/acme/globex, Phase 14) and from the eval harness's own "eval" tenant
//                (Phase 17), so canary-demo traffic is never confused with either in ai_service's
//                tenant-labelled metrics/logs.
//
// Status: run for real in the sandbox against a locally-started ai_service (uvicorn,
// MockBackend, no cluster) -- see docs/progressive-delivery.md §5 for that output. Running it
// against a real in-cluster Rollout during an actual canary is the target-machine verification
// step this sandbox cannot do (no cluster, no Argo Rollouts controller).

import http from "k6/http";
import { check, sleep } from "k6";

const TARGET_URL = __ENV.TARGET_URL || "http://127.0.0.1:8000";
const HOST_HEADER = __ENV.HOST_HEADER || "";
const TENANT_ID = __ENV.TENANT_ID || "canary-demo";

// Reused, not invented for this file: the same four topics eval/golden_dataset.json (Phase 17)
// already exercises against MockBackend's own known-topic lookup -- no need for a second set of
// prompts when this one is already proven to produce a real, non-empty MockBackend answer.
const PROMPTS = [
  "What is a Kubernetes Pod?",
  "What is a Kubernetes Deployment?",
  "What does a Kubernetes Service do?",
  "What is a namespace in Kubernetes?",
];

export const options = {
  // Overridable from the CLI (--vus/--duration) or k6's own K6_VUS/K6_DURATION env vars; these
  // are just a sane default for "keep the canary's analysis window from ever seeing zero
  // traffic," not a tuned load profile.
  vus: 3,
  duration: "6m",
};

export default function () {
  const prompt = PROMPTS[Math.floor(Math.random() * PROMPTS.length)];
  const headers = { "Content-Type": "application/json" };
  if (HOST_HEADER) {
    headers["Host"] = HOST_HEADER;
  }
  const res = http.post(
    `${TARGET_URL}/v1/chat`,
    JSON.stringify({ tenant_id: TENANT_ID, prompt }),
    { headers }
  );
  // A real check, logged in k6's own summary -- this script's status is informational for
  // whoever is watching the demo run; the authoritative pass/fail signal for the canary itself
  // is the Argo Rollouts AnalysisTemplate querying Prometheus, not this script's exit code.
  check(res, {
    "status is 200 or a declared ai_service error (504/502)": (r) =>
      [200, 502, 504].includes(r.status),
  });
  sleep(1);
}
