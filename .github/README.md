# Repository Automation

[Project overview](../README.md)

## Validation workflow

GitHub Actions runs `./scripts/validate.sh` for pull requests, pushes to `main`, and
manual workflow runs. It also checks Terraform formatting and validates the
Hetzner configuration. The workflow has read-only repository access and does
not receive Hetzner credentials, so it cannot create or change cloud resources.

Local validation instructions are in the
[operator guide](../scripts/README.md#repository-validation).

## Automated dependency and security checks

Three workflows cover validation, dependency updates, and security:

| Workflow | Trigger | Result |
|---|---|---|
| [Validate](workflows/validate.yml) | Pull requests, pushes to `main`, manual | Shell, Compose, Nginx, Terraform, workflow syntax, and Renovate config checks |
| [Dependency updates](workflows/dependency-updates.yml) | Daily at 06:15 UTC, manual | Renovate opens version-update pull requests |
| [Security](workflows/security.yml) | Pull requests, pushes to `main`, daily at 05:45 UTC, manual | Trivy scans repository files and all configured application container images |

[Renovate configuration](../renovate.json) covers Docker Compose images, GitHub Actions and their supported tool
inputs, Terraform CLI/provider versions and provider lockfiles, and mise tools.
It groups matching container references across local/production templates and
groups the Terraform CLI pins so they can be updated together. CI helper image
versions are tracked through annotated regex rules. All actions are pinned to
commit hashes; Renovate maintains those pins too.

Update pull requests use conventional commits authored as the owner's GitHub
no-reply address (`gitAuthor`), so they are linked to the account instead of
Mend's default bot address. If the optional `RENOVATE_GIT_PRIVATE_KEY`
repository secret holds a GPG key registered on that account, commits are
signed and shown as Verified. The key's user ID email must be exactly the
`gitAuthor` no-reply address, or GitHub still shows the commits as Unverified.
When the secret is unset, Renovate ignores the empty value and commits
unsigned. Patch, minor, and
major update PRs are created automatically, subject to the configured rate limits; no
Dependency Dashboard approval is needed. Review and merge the PR itself:
only selected CI-tool patch/minor updates and pin maintenance can merge
automatically after required checks pass, using rebase merging to preserve the
PR's individual commits. Major updates, application container updates,
Terraform CLI/provider updates, and runner OS updates require a manual
merge. CI tools are explicitly listed in `renovate.json`: GitHub Actions,
Renovate, Trivy, and actionlint. Stable releases are preferred and Nginx is
restricted to its stable (even minor) branches. MariaDB updates are
disabled as requested. Bitwarden CLI remains manual because its version and
download checksums must be updated together. Ubuntu and Docker packages remain
managed by the host's APT update policy.

### Enable the update workflow once

1. Push these files to GitHub's default branch.
2. Create a fine-grained GitHub personal access token scoped to **this repository
   only**, following [Renovate's token permissions](https://docs.renovatebot.com/modules/platform/github/#running-using-a-fine-grained-token).
   It needs read/write access to Contents, Pull requests, Issues, Commit statuses,
   and Workflows, plus read access to Dependabot alerts. For an organization,
   follow the documented Members permission and token approval requirements too.
3. Under **Settings → Secrets and variables → Actions**, save it as the
   repository secret `RENOVATE_TOKEN`, then set the repository variable
   `ENABLE_RENOVATE` to `true`. The workflow is skipped until enabled and only
   runs from the default branch. Rotate the token before it expires.
4. In **Actions → Dependency updates**, select **Run workflow**. Review the
   Dependency Dashboard issue and any pull requests it creates. A PAT is used
   instead of `GITHUB_TOKEN` so update PRs can trigger validation workflows and
   update workflow files themselves. Do not put production secrets in Actions.
5. Run **Actions → Security → Run workflow** for the initial baseline. Reports
   appear under each job and as downloadable artifacts, retained for 14 days.
   No extra token or code-scanning subscription is needed for this workflow.

Container scanning produces two reports for each image:

- **Full advisory report:** all severities, including vulnerabilities without a
  published fix, in `trivy-image-all.json` and `trivy-image-all.txt`. Findings
  alone do not fail this collection step.
- **Fixable vulnerability check (advisory):** only HIGH/CRITICAL
  vulnerabilities with a published fix, in `trivy-image-fixable.json` and
  `trivy-image-fixable.txt`. Findings raise a warning on the run and appear in
  the summary table, but do not fail the image job: official images often lag
  behind a fix in their base OS, which this repository cannot remediate itself.

Each image job publishes a severity/count table on the workflow summary page.
Both reports are retained in its `security-image-*` artifact for 14 days, also
when findings are reported. The scans must refer to the same image ID. Scanner,
registry/network, report-generation, and image-ID mismatch errors still fail
the job; these errors are not treated as clean scans. The full report retains
lower-severity, unfixed, and reviewed non-applicable findings for review.

The fixable check supports [reviewed helper exclusions](security/README.md). They
apply only to an explicitly listed image, verified helper SHA-256, path, CVE IDs,
and review period. New findings and changed helpers are reported in full. The summary displays reviewed exclusions separately from unfixed findings.

The repository scan is unchanged: HIGH/CRITICAL dependency, infrastructure, or
secret findings fail that job. Scans inspect checked-out files and registry
images, not the running server or installed WordPress plugins. `Security checks`
fails on repository findings and on scan errors; container findings only warn.

## Repository settings

These are set in the GitHub settings, not in files. Keep this section in sync
when changing them.

**Branch protection for `main`** (Settings → Branches), applied to
administrators too:

- Pull requests required, with no approving review count: a required review
  would block unattended CI-tool merges, especially when Renovate uses the
  owner's PAT. Major/application updates are manual because Renovate does not
  enable automerge for them; the policy does not enforce a separate reviewer
  for those PRs.
- Required GitHub Actions checks, with branches up to date before merging:
  - `Repository checks`
  - `Workflow and dependency configuration checks`
  - `Security checks`
- Linear history required; force pushes and branch deletion disallowed.

Branches are not updated automatically. Renovate rebases its own branches when
`main` moves; for other PRs, use **Update branch** and wait for the checks.
`Security checks` fails on repository findings and scan errors, so those also
stop eligible CI-tool PRs from auto-merging; container findings only warn.

**Pull requests** (Settings → General): rebase and squash merging allowed,
merge commits disabled (Renovate merges with rebase); squash commits use the
PR title and description; **Allow auto-merge**, **Always suggest updating pull
request branches**, and **Automatically delete head branches** are enabled.

**Security** (Settings → Advanced Security): Dependabot alerts, secret
scanning, and push protection are enabled. Dependabot security and version
update PRs stay disabled; Renovate opens update PRs and reads the alerts.

**Actions** (Settings → Actions → General): the default `GITHUB_TOKEN` is
read-only and cannot create or approve pull requests.

[actionlint.yaml](actionlint.yaml) declares the hosted `ubuntu-26.04` label for
actionlint versions whose built-in runner list predates it. This extends label
recognition without disabling other workflow lint checks.

Merging an update changes the repository only. Existing deployed sites still
need their copied Compose files updated and containers recreated after testing.
These workflows do not connect to Hetzner, deploy sites, apply Terraform,
patch Ubuntu, or automatically merge application or major-version updates.
