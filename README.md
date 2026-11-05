# retry-unacquired-runners

A GitHub Action that reruns workflow jobs that failed because no runner ever
picked them up.

When a runner pool is out of capacity (most often GitHub's hosted macOS pool),
a job can sit queued for about 20 minutes and then end without running a single
step. Its check run carries an annotation like:

> The job was not acquired by Runner of type hosted even after multiple attempts

Nothing is wrong with the code, so the right response is to rerun the job.
This action finds such runs and reruns their failed jobs. It keeps doing that
until the run succeeds, fails for a real reason, is superseded by a newer run,
or reaches GitHub's rerun limits.

It only acts in public repositories unless you opt in with
`allow-private-repos: true` (see [Caveats](#caveats)).

It works with any OS and any runner label. By default it retries every job
that was never acquired, whatever runner it targeted. You can narrow it to
specific labels with an input.

## Usage

Add this workflow to each repository that should be covered. The triggers have
to live in that repository, because `workflow_run` and `schedule` only fire for
workflow files in the repository itself. It only takes effect once it is on the
default branch.

```yaml
# .github/workflows/retry-unacquired-runners.yml
name: Retry unacquired runners

on:
  workflow_run:
    workflows: ["**"]
    types: [completed]
  schedule:
    - cron: "17 */4 * * *"
  workflow_dispatch:
    inputs:
      run_id:
        description: "Run id to evaluate (empty: sweep recent runs)"
        required: false
        default: ""

permissions:
  actions: write
  checks: read

concurrency:
  group: >-
    ${{ github.workflow }}-${{
      (github.event_name == 'workflow_run' && format('run-{0}', github.event.workflow_run.id))
      || (inputs.run_id != '' && format('run-{0}', inputs.run_id))
      || 'sweep' }}
  cancel-in-progress: false

jobs:
  retry:
    # Skip this workflow's own completions, and runs that did not fail.
    if: >-
      github.event_name != 'workflow_run' || (
        github.event.workflow_run.name != github.workflow &&
        (github.event.workflow_run.conclusion == 'failure' ||
         github.event.workflow_run.conclusion == 'cancelled'))
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: NanashiTheNameless/retry-unacquired-runners@main
        with:
          run-id: ${{ inputs.run_id }}
```

This example workflow is free to use for non-commercial purposes: anyone
may copy, modify, and distribute it for any non-commercial purpose, with no
attribution required, as long as the use follows the NNCL's Section 4
Policy. See [License](#license).

Run the retry job on a runner pool that is not the one you are retrying. A
retry job stuck in the same queue cannot help.

The action needs `bash`, `gh` and `jq` on the runner. GitHub-hosted Ubuntu,
macOS and Windows runners have all three; on a self-hosted runner, install
them first.

### Why three triggers

| Trigger | Role |
|---|---|
| `workflow_run` | Reacts within seconds of a run finishing, so the first retry starts quickly. |
| `schedule` | Sweeps recent runs once an hour. This is what keeps retries going: a rerun started with `GITHUB_TOKEN` may not fire `workflow_run` again, so later retries can wait up to an hour. Shorten the interval if you need them sooner. The odd minute avoids the top of the hour, when GitHub most often delays scheduled runs. |
| `workflow_dispatch` | Manual use. Evaluate one run by id, or sweep with no id. |

## Inputs

| Input | Default | Meaning |
|---|---|---|
| `github-token` | `${{ github.token }}` | Token used for API calls and reruns. Needs `actions: write`, and `checks: read` when `require-annotation` is true. |
| `run-id` | `""` | Evaluate only this run. If empty, the action uses the `workflow_run` event's run when there is one, and otherwise sweeps. |
| `label-pattern` | `""` | Case-insensitive regex. A job without steps counts only if at least one of its runner labels matches. Empty matches every label, including jobs with no labels. Example: `^macos`. |
| `exclude-label-pattern` | `""` | Case-insensitive regex. A job with any label matching this is never treated as unacquired. Example: `^self-hosted$`. |
| `require-annotation` | `true` | Also require the job's check run annotations to match `annotation-pattern`. Set to `false` to retry any failed or cancelled job with zero steps, including queued jobs someone cancelled by hand. |
| `annotation-pattern` | `was not acquired by Runner of type` | Case-insensitive regex matched against each annotation message. |
| `sweep-lookback-hours` | `48` | The sweep only considers runs created within this window, so installing the action does not rerun old history. |
| `max-run-attempt` | `50` | A run whose `run_attempt` is above this is not rerun. GitHub allows at most 50 reruns. |
| `max-run-age-days` | `30` | A run created this many days ago or earlier is not rerun. GitHub refuses reruns after 30 days. |
| `skip-superseded` | `true` | Skip a run when a newer run of the same workflow exists for the same branch and event. |
| `exclude-workflows` | `""` | Case-insensitive regex matched against each run's workflow path (`.github/workflows/x.yml`) and name. Matching runs are ignored. The calling workflow is always excluded. |
| `fail-on-limit` | `true` | Fail the step when an otherwise eligible run has hit a limit, so you get notified. The run is always listed in the job summary. |
| `dry-run` | `false` | Evaluate and log decisions without rerunning anything. `rerun-ids` stays empty. |
| `allow-private-repos` | `false` | Run in private and internal repositories. When `false`, the action logs one line and exits successfully there without evaluating any run. |

## Outputs

| Output | Meaning |
|---|---|
| `rerun-ids` | Space-separated ids of runs that were rerun, including runs found already queued again. |
| `limit-ids` | Space-separated ids of eligible runs that hit a limit. |
| `evaluated` | Number of runs evaluated. |

## What counts as unacquired

The action always looks at the latest attempt of a run.

- **Unacquired job:** conclusion `failure` or `cancelled`, zero steps executed,
  labels matching `label-pattern` and not `exclude-label-pattern`, and (by
  default) an annotation matching `annotation-pattern`.
- **Real failure:** any job with conclusion `failure`, `cancelled` or
  `timed_out` that executed at least one step. The run is left alone.
- **Not ours:** a job with zero steps that fails the label or annotation
  checks. The run is left alone.

A run is rerun with `gh run rerun <id> --failed` only when all of these hold:

- It is completed.
- It has at least one unacquired job.
- It has no real failures and no "not ours" jobs.
- It is not superseded.
- It is within `max-run-attempt` and `max-run-age-days`.

Every evaluated run gets one log line with its decision: `rerun`,
`succeeded`, `not completed`, `real failure`, `not ours`, `superseded`,
`excluded` or `limit reached`.

## Caveats

- **Private repositories.** By default the action does nothing outside public
  repositories: it checks the repository's visibility first and exits
  successfully if it is private or internal. Set `allow-private-repos: true`
  to run there. The retry job itself still starts and is billed even when it
  exits early, so in a private repository you don't want covered, don't add
  the caller workflow at all.
- **Billing.** In private repositories every job is billed as at least one
  minute. The hourly sweep is about 730 runs per month, over a third of the
  Free plan's 2,000 minutes; a 15-minute sweep would be about 2,900, more
  than the whole allowance. If you enable `allow-private-repos`, consider an
  even longer interval. Public repositories are not billed.
- **Inactivity.** In public repositories, GitHub disables scheduled workflows
  after 60 days without repository activity. Once that happens, only the first
  retry (from `workflow_run`) still happens.
- **API budget.** `GITHUB_TOKEN` is limited to 1,000 requests per hour per
  repository. Each invocation costs one request to check visibility. A sweep
  costs about three requests per failed run in the lookback window, plus one
  per candidate job.
- **Forks.** Actions and scheduled workflows are disabled in forks until you
  enable them.
- **Manual cancels.** With `require-annotation: true` (the default), a queued
  job you cancel by hand is not retried, because it never gets the
  not-acquired annotation.

## License

[Nameless Nanashi Code License (NNCL) v1.5](LICENSE.md). In short:

- Free for non-commercial use. Using it to support revenue-generating work,
  including in a company's CI, needs a separate commercial license from the
  licensor.
- Modified versions you share must stay under NNCL v1.5 (or later), with the
  license text and its ethical policy intact, and with source available.
- The policy in Section 4 forbids some uses outright, including use by
  law-enforcement, immigration-enforcement and military entities.
- The licensor can revoke the license (Section 9A).

This is a summary; the license text is what applies.

### Requesting a commercial license

Open a thread in this repository's
[Discussions](https://github.com/NanashiTheNameless/retry-unacquired-runners/discussions)
that describes your intended use case and gives a contact method.
Discussions are public, so give a contact method you are comfortable
sharing publicly.

### Using this action from your workflows

The licensor named in [LICENSE.md](LICENSE.md), NamelessNanashi, is the same
person as NanashiTheNameless, the GitHub account that owns this repository.

As the licensor, I clarify how the NNCL applies to the normal way of using
this action:

- Referencing this action from a workflow with `uses:` (for example
  `uses: NanashiTheNameless/retry-unacquired-runners@main`), so that GitHub
  downloads it from this repository when the workflow runs, is use of the
  Work. It is not Sharing the Work and does not make your repository an
  Adaptation, so Sections 3 and 6 do not apply to your repository.
- This holds for any number of repositories. Referencing the action this way
  from many repositories, including every repository in an organization, is
  not deploying it across an organization for the purpose of Section 10, so
  Section 10 does not apply to that use.
- That use must still be Non-Commercial (Sections 2 and 5), and the Policy in
  Section 4 still applies in full.
- Copying this action's files into your own repository, or publishing a
  modified copy (including a fork), is Sharing, and all of the license's
  terms apply to that copy.

This clarification only grants permission; it does not narrow or replace
any term of the license.

### The example workflow is free for non-commercial use

The example caller workflow in [Usage](#usage) is under lighter terms than
the rest of this repository. Anyone may copy, use, modify, and distribute it, in whole or in part, for
any Non-Commercial purpose (as defined in the NNCL), without attribution and
without any of the NNCL's other terms except the Policy in Section 4, which
applies in full. Commercial use of the example needs permission from the
licensor.

That permission covers the workflow file itself, not the action it calls.
Running the action through that workflow is still use of the Work under the
NNCL, as described above.
