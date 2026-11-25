# Reviewed image findings

[CI overview](../README.md)

The MariaDB image's `usr/local/bin/gosu` is a privilege-dropping startup helper.
The full Trivy inventory remains unfiltered. The fixable check excludes only
listed findings after verifying that the helper has the reviewed SHA-256.
Other images, helper binaries, paths, and CVEs receive no exemption. Expired
entries stop being excluded. Scanner, download, and report failures still fail CI.

## Current review

[mariadb-gosu-review.json](mariadb-gosu-review.json) records the exact binary,
compiler, Go advisory mappings, review date, and expiry. The initial review used
MariaDB's official `12.3.3-noble` image and **unfiltered** `govulncheck v1.9.0`
binary analysis. All 26 Trivy HIGH/CRITICAL standard-library findings were
covered by Go advisories, with no matching vulnerable function symbols reported
in this binary. The review does not claim the helper or image is vulnerability-free.

The policy file [mariadb-gosu.trivyignore.yaml](mariadb-gosu.trivyignore.yaml)
contains explicit CVE IDs, the helper path, reasons, and an expiry date. The
selector reads the immutable image digest from the full scan, copies the helper
without executing image binaries, and compares its SHA-256 with the review.
This also permits base-image rebuilds containing the identical helper, while a
changed helper requires reassessment before exclusions can apply.

The fixable report contains the remaining findings. The workflow summary
separates all findings, fixes listed by Trivy, unfixed findings, reviewed
exclusions, and blocking findings. The complete report retains excluded CVEs.

## Separate parser advisory

Unfiltered Go analysis also reported **GO-2026-6686 / CVE-2026-61801** in the
user/group-file parser. Its affected symbols are present. It is **not** covered
by these exclusions. Upstream gosu 1.20 addresses it; its maintainer notes that
an attack would require control of image-provided user/group files. This is a
separate issue to track, not evidence that the standard-library findings apply.
If Trivy starts reporting this advisory, it appears as a warning pending review.
Do not add it to the exclusion list merely to silence the warning.

## Reassessing a helper

1. Obtain the exact helper from the immutable image digest in the full report.
2. Record `sha256sum gosu` and `go version -m gosu`.
3. Run `govulncheck -mode=binary -json ./gosu` using the pinned tool version.
   Inspect the raw output without upstream's exclusion wrapper. Binary analysis
   checks vulnerable function symbols; it does not provide source call stacks.
4. Map every proposed CVE to its Go advisory and inspect symbol-level findings.
   Missing advisory coverage is not proof of non-applicability.
5. Update the review and narrowly scoped policy together, including the expiry,
   then test that changed helpers and new findings remain blocking.

Sources: [gosu security policy](https://github.com/tianon/gosu/blob/1.19/SECURITY.md),
[govulncheck](https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck),
[gosu 1.20 release](https://github.com/tianon/gosu/releases/tag/1.20),
[Trivy filtering](https://trivy.dev/docs/latest/configuration/filtering/).
