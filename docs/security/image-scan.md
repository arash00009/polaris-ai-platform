# Image scan register

The record of what the vulnerability scanner found in the AI service image, and what was decided about each finding. It exists so that "we scanned it" can be backed by dates, versions and reasons.

**Status: no scan has been run on the target machine yet.** The first entry is added after the first `make image-scan`. Nothing in this file is a result until an entry with a date and a scanner version exists.

## How to read and keep this register

- Run `make image-scan` from a clean git state (the image tag then names a real commit). The report is written to `artifacts/trivy-<version>-<git sha>.json` and is not committed.
- The scan **fails** when a HIGH or CRITICAL finding has a fix available. Fix it (a newer base image via `make image-pin`, or a newer pinned dependency) and scan again.
- Findings **without** a fix do not fail the scan. Each HIGH or CRITICAL one is listed below with the reason it is accepted for now and when it is re-checked. "It is in the base image and Debian has no fix yet" is a valid reason; "it is probably not exploitable" needs an explanation of why.
- MEDIUM and LOW findings are counted, not listed one by one.
- A scan describes *known* vulnerabilities in the vulnerability database of that day. It is not proof that the image is safe.

## Entry template

```
### <date> — <image tag>

- Scanner: Trivy <version> (image digest: <sha256 or "not pinned">)
- Base image: <python tag or digest>; operating system reported by the scanner: <family and version>
- Result: <n> CRITICAL, <n> HIGH, <n> MEDIUM, <n> LOW (fixed and unfixed together)
- Findings with a fix available: <none | list, and what was done>
- Accepted findings without a fix:

| Severity | ID | Package | Installed | Reason accepted | Re-check |
|----------|----|---------|-----------|-----------------|----------|

- SBOM: artifacts/sbom-<version>-<git sha>.cdx.json (<n> components)
```

## Entries

None yet.
