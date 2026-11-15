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

Update pull requests use conventional commits and require review: automatic
merging is disabled. Stable releases are preferred, Nginx is restricted to its
stable (even minor) branches, and major updates require approval in Renovate's
Dependency Dashboard before a pull request is opened. MariaDB updates are
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

In **Settings → Rules → Rulesets**, protect `main` by requiring pull requests
and the `Repository checks`, `Workflow and dependency configuration checks`,
and `Security checks` checks once their first runs have registered them. The
fixed `Security checks` job requires all scans to succeed, including every image
in the dynamically discovered and deduplicated Compose image matrix.

Merging an update changes the repository only. Existing deployed sites still
need their copied Compose files updated and containers recreated after testing.
These workflows do not connect to Hetzner, deploy sites, apply Terraform,
patch Ubuntu, or merge changes automatically.
