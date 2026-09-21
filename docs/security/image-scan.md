# Image scan register

The record of what the vulnerability scanner found in the AI service image, and what was decided about each finding. It exists so that "we scanned it" can be backed by dates, versions and reasons.

**Status: one scan recorded (2026-09-21, image `0.3.0-ad9cae81814f`).** Nothing here is a result unless an entry below has a date and a scanner version. The vulnerability database changes daily, so an old entry describes that day only.

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

### 2026-09-21: localhost:5000/polaris/ai-service:0.3.0-ad9cae81814f

- Scanner: Trivy 0.74.0, run as a container, image pinned by digest `sha256:62b1e65e8869bc4b4c6aa4fa2b21595256c7c2f6018a9d9ad61caf87187c1969`. The scan log shows the vulnerability database being downloaded from `mirror.gcr.io/aquasec/trivy-db:2`; the first download took about four minutes.
- Base image: `python:3.12-slim-trixie` pinned by digest `sha256:2f17fc044b579bab302c2e8054d3a686e2cb9a83de48e70534b94cd8ebbe06a9`; operating system reported by the scanner: Debian 13.7, 87 OS packages.
- Result: 0 CRITICAL, 44 HIGH, 49 MEDIUM, 57 LOW, 2 UNKNOWN (fixed and unfixed together, counted per package and CVE, so one CVE in several packages is counted several times).
- Findings with a fix available: none. All 44 HIGH findings are Debian OS packages with no fix in Debian 13 (trixie); the gate ("fail on HIGH/CRITICAL with a fix") passed. No Python dependency was reported.
- Accepted findings without a fix (8 unique CVEs in 5 source packages; the 44 rows are the same CVEs repeated for each binary package built from the same source):

| Severity | ID | Source package (binary packages affected) | Installed | What it is | Reason accepted | Re-check |
|----------|----|-------------------------------------------|-----------|------------|-----------------|----------|
| HIGH | CVE-2026-76642 | util-linux (bsdutils, libblkid1, liblastlog2-2, libmount1, libsmartcols1, libuuid1, login, mount, util-linux) | 2.41.5-0+deb13u1 | `mount` helper exit status is not checked before post-mount hooks | See note A | New base digest, or within one month |
| HIGH | CVE-2026-78408 | util-linux (same) | 2.41.5-0+deb13u1 | `nsenter --join-cgroup` leaves a root file descriptor open | See note A | same |
| HIGH | CVE-2026-78409 | util-linux (same) | 2.41.5-0+deb13u1 | `X-mount.subdir` symlink traversal; needs an fstab entry | See note A | same |
| HIGH | CVE-2026-78410 | util-linux (same) | 2.41.5-0+deb13u1 | restricted bind-mount source not pinned; concerns SUID `mount` | See note A | same |
| HIGH | CVE-2026-54369 | acl (libacl1) | 2.3.2-2+b1 | symlink traversal in the `acl_*` functions; fixed in 2.4.0-1 in unstable, Debian states it will not be backported | See note B | same |
| HIGH | CVE-2025-69720 | ncurses (libncursesw6, libtinfo6, ncurses-base, ncurses-bin) | 6.5+20250216-2 | stack overflow in `infocmp`; fixed in 6.6+20251231-1 in unstable | See note B | same |
| HIGH | CVE-2026-16742 | systemd (libsystemd0, libudev1) | 257.13-1~deb13u1 | local privilege escalation in `systemd-homed`; fixed in 261.2-1 in unstable | See note B | same |
| HIGH | CVE-2026-9538 | perl (perl-base) | 5.40.1-6+deb13u1 | `Archive::Tar` memory exhaustion; fixed in 5.42.3-1 in unstable, postponed for trixie | See note B | same |

  The fix and severity details above were read from the Debian security tracker on 2026-09-21 by a fetch tool that summarises pages, so they should be checked directly on the tracker before being quoted elsewhere. Debian rates most of these as a minor issue with no security advisory planned; the urgency for CVE-2026-78410 and CVE-2026-54369 was not shown. Trivy printed "Using severities from other vendors for some vulnerabilities", so the HIGH label may come from another vendor's rating rather than Debian's.

  **Note A (util-linux).** Every one of these needs either local code execution in the container or a privileged `mount` operation with a crafted mount table. The container runs as uid 10001 with `no-new-privileges`, all capabilities dropped and a read-only root filesystem (`make image-run` and the Kubernetes manifests in Phase 4), so mounting is not permitted to begin with. The service does not call `mount`, `nsenter` or `login` (the source has no subprocess use). These packages are marked Essential in Debian and cannot be removed without breaking `dpkg`.

  **Note B (acl, ncurses, systemd, perl).** Each affects a command-line tool or a daemon (`infocmp`, `systemd-homed`, `Archive::Tar`) or a library used by such tools; the service runs none of them, and reaching them requires code execution inside the container. Only `libacl1`, `libsystemd0`, `libudev1`, `libncursesw6`, `libtinfo6` and `perl-base` are present, and they cannot be removed from this base.

  This reasoning is my reading of the advisories and of how the container is run. It has not been tested by trying to exploit any of them. A distroless or otherwise smaller base would remove most of these packages; that comparison is planned for Phase 15.
- MEDIUM (49), LOW (57) and UNKNOWN (2) findings are counted, **not reviewed**.
- SBOM: `artifacts/sbom-0.3.0-ad9cae81814f.cdx.json`, CycloneDX 1.7, 107 components. Not committed (`artifacts/` is git-ignored).
- Not done: the Trivy release and the image are not signature-verified or signed (cosign, Phase 15).

Note: on 2026-09-21 the local commit history was rewritten (author email only; file contents unchanged). The image 0.3.0-ad9cae81814f above was built from commit ad9cae8, which is 8c4cab9 after the rewrite; the old hash no longer exists in the repository. Rebuild with make image-build to get a tag that matches the current history.
