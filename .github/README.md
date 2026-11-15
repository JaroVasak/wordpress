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

Update pull requests use conventional commits. Patch, minor, and major update
PRs are created automatically, subject to the configured rate limits; no
Dependency Dashboard approval is needed. Review and merge the PR itself:
only selected CI-tool patch/minor updates and pin maintenance can merge
automatically after required checks pass. Major updates, application container
updates, Terraform CLI/provider updates, and runner OS updates require a manual
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

Security jobs fail on HIGH/CRITICAL findings, including vulnerabilities without
a published fix. Scanner/network errors also fail the job; inspect the logs to
distinguish them. Expect existing dependencies or infrastructure settings to
produce findings: review and fix them rather than assuming the first scan will
be green. No findings are suppressed by default. Scans inspect the checked-out
files and registry images, not the running server or installed WordPress plugins.

Protect `main` with a branch protection rule requiring pull requests and these
GitHub Actions checks, with branches up to date before merging:

- `Repository checks`
- `Workflow and dependency configuration checks`

Apply the rule to administrators too, disallow force pushes and branch deletion,
and enable **Settings → General → Pull Requests → Allow auto-merge**. Do not
require an approving review count: that would block unattended CI-tool merges,
especially when Renovate uses the owner's PAT. Major/application updates are
manual because Renovate does not enable automerge for them; the policy does not
enforce a separate reviewer for those PRs.

Security scans remain advisory while their existing findings are addressed;
`Security checks` is not a required status check yet. The fixed job still reports
failure if any scan fails. Make it required once the security baseline is ready.
GitHub's native auto-merge waits for the required validation checks; non-required
security findings do not block eligible CI-tool merges.

[actionlint.yaml](actionlint.yaml) declares the hosted `ubuntu-26.04` label for
actionlint versions whose built-in runner list predates it. This extends label
recognition without disabling other workflow lint checks.

Merging an update changes the repository only. Existing deployed sites still
need their copied Compose files updated and containers recreated after testing.
These workflows do not connect to Hetzner, deploy sites, apply Terraform,
patch Ubuntu, or automatically merge application or major-version updates.
