#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq programs use $vars in single quotes
# Tests for src/retry.sh. Plain bash; never touches the network.
#
# Each test_* function sets up stub responses, runs the script and checks the
# result with assertions chained by &&. The stub gh (tests/bin/gh) serves
# files from $STUB_DIR and records reruns instead of making them.
#
# tests/fixtures/ holds trimmed copies of real GitHub API responses, with the
# repository renamed to example-owner/example-repo and ids renumbered. Derive
# other scenarios from them with jq instead of writing new JSON.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FX="$ROOT/tests/fixtures"
export PATH="$ROOT/tests/bin:$PATH"

REPO=example-owner/example-repo
TAG="run 1001 (Build, attempt 1)" # decision line prefix for the unacquired run

# --- Setup helpers -----------------------------------------------------------

# serve ENDPOINT FIXTURE [FILTER]: the stub answers repos/$REPO/ENDPOINT with
# FIXTURE, passed through the jq FILTER. Runs are always created "now".
serve() {
  local file
  file="$STUB_DIR/$(printf 'repos/%s/%s' "$REPO" "$1" | tr '/' '_').json"
  jq --arg now "$(days_ago 0)" \
    "if type == \"object\" and has(\"created_at\") then .created_at = \$now else . end | ${3:-.}" \
    "$FX/$2" >"$file"
}

# days_ago N: ISO timestamp N days ago. CRs stripped for jq.exe on Windows.
days_ago() { jq -nr --argjson d "$1" 'now - $d * 86400 | floor | todate' | tr -d '\r'; }

# repo [FILTER]: the repository itself (public by default).
repo() { jq "${1:-.}" <<<'{"full_name": "example-owner/example-repo", "private": false}' >"$STUB_DIR/repos_example-owner_example-repo.json"; }

# newest ID: the newest run of the workflow, for the superseded check.
newest() { jq -n --argjson id "$1" '{workflow_runs: [{id: $id}]}' >"$STUB_DIR/repos_example-owner_example-repo_actions_workflows_2001_runs.json"; }

# unacquired: run 1001 with two unacquired jobs, eligible for a rerun.
unacquired() {
  repo
  serve actions/runs/1001 run-unacquired.json
  serve actions/runs/1001/jobs jobs-unacquired.json
  serve check-runs/3002/annotations annotations-unacquired.json
  serve check-runs/3003/annotations annotations-unacquired.json
  newest 1001
}

# run_action [VAR=value...]: run the script; output goes to $STUB_DIR/out.
run_action() {
  (
    for v in $(compgen -e); do
      case "$v" in INPUT_* | GITHUB_*) unset "$v" ;; esac
    done
    export GITHUB_REPOSITORY="$REPO" GITHUB_EVENT_NAME=schedule \
      GITHUB_WORKFLOW_REF="$REPO/.github/workflows/retry.yml@refs/heads/main" \
      GITHUB_OUTPUT="$STUB_DIR/output" GITHUB_STEP_SUMMARY="$STUB_DIR/summary"
    for kv in "$@"; do export "${kv?}"; done
    bash "$ROOT/src/retry.sh"
  ) >"$STUB_DIR/out" 2>&1
  echo $? >"$STUB_DIR/status"
}

# --- Assertions: each prints why and fails on a mismatch ---------------------

exit_is() { [[ "$(cat "$STUB_DIR/status")" == "$1" ]] || { echo "exit status $(cat "$STUB_DIR/status"), want $1"; return 1; }; }
line() { grep -Fxq -- "$1" "$STUB_DIR/out" || { echo "missing line: $1"; return 1; }; }
says() { grep -Fq -- "$1" "$STUB_DIR/out" || { echo "missing text: $1"; return 1; }; }
output() { grep -Fxq -- "$1" "$STUB_DIR/output" || { echo "missing step output: $1"; return 1; }; }
summary() { grep -Fq -- "$1" "$STUB_DIR/summary" 2>/dev/null || { echo "missing summary text: $1"; return 1; }; }
called() { grep -Fq -- "$1" "$STUB_DIR/calls.log" || { echo "missing gh call: $1"; return 1; }; }
no_call() { ! grep -Fq -- "$1" "$STUB_DIR/calls.log" || { echo "unexpected gh call: $1"; return 1; }; }
reruns() {
  local got
  got=$(cat "$STUB_DIR/reruns.log" 2>/dev/null | tr '\n' ' ')
  [[ "${got% }" == "$1" ]] || { echo "reruns '${got% }', want '$1'"; return 1; }
}

# --- Decisions ---------------------------------------------------------------

test_rerun() {
  unacquired
  run_action INPUT_RUN_ID=1001
  exit_is 0 && line "$TAG: rerun (2 unacquired job(s))" && reruns 1001 \
    && called "run rerun 1001 --failed" && output "rerun-ids=1001" && output "evaluated=1"
}

test_succeeded() {
  unacquired
  serve actions/runs/1001 run-unacquired.json '.conclusion = "success"'
  run_action INPUT_RUN_ID=1001
  line "$TAG: succeeded" && reruns ""
}

test_not_completed() {
  unacquired
  serve actions/runs/1001 run-unacquired.json '.status = "in_progress" | .conclusion = null'
  run_action INPUT_RUN_ID=1001
  line "$TAG: not completed (in_progress)" && reruns ""
}

test_real_failure() {
  repo
  serve actions/runs/1002 run-real-failure.json
  serve actions/runs/1002/jobs jobs-real-failure.json
  newest 1002
  run_action INPUT_RUN_ID=1002
  exit_is 0 && line "run 1002 (Build, attempt 1): real failure (1 job(s) failed after running steps)" && reruns ""
}

test_real_failure_wins_over_unacquired() {
  unacquired
  serve actions/runs/1001/jobs jobs-unacquired.json '(.jobs[] | select(.id == 3001)).conclusion = "timed_out"'
  run_action INPUT_RUN_ID=1001
  line "$TAG: real failure (1 job(s) failed after running steps)" && reruns ""
}

test_not_ours_label_pattern() {
  unacquired
  run_action INPUT_RUN_ID=1001 INPUT_LABEL_PATTERN='^ubuntu'
  line "$TAG: not ours (2 job(s) without steps do not match the label patterns)" && reruns ""
}

test_label_pattern_is_case_insensitive() {
  unacquired
  run_action INPUT_RUN_ID=1001 INPUT_LABEL_PATTERN='^MACOS'
  line "$TAG: rerun (2 unacquired job(s))"
}

test_not_ours_missing_annotation() {
  unacquired
  serve check-runs/3003/annotations annotations-unacquired.json 'map(select(.annotation_level == "notice"))'
  run_action INPUT_RUN_ID=1001
  line "$TAG: not ours (a job without steps lacks the not-acquired annotation)" && reruns ""
}

test_require_annotation_false() {
  unacquired
  run_action INPUT_RUN_ID=1001 INPUT_REQUIRE_ANNOTATION=false
  line "$TAG: rerun (2 unacquired job(s))" && no_call annotations
}

test_not_ours_zero_step_timed_out() {
  unacquired
  serve actions/runs/1001/jobs jobs-unacquired.json '(.jobs[] | select(.id == 3002)).conclusion = "timed_out"'
  run_action INPUT_RUN_ID=1001
  line "$TAG: not ours (1 job(s) without steps do not match the label patterns)"
}

test_not_ours_nothing_unacquired() {
  unacquired
  serve actions/runs/1001/jobs jobs-unacquired.json '(.jobs[] | select(.conclusion == "cancelled")).conclusion = "skipped"'
  run_action INPUT_RUN_ID=1001
  line "$TAG: not ours (nothing unacquired)"
}

test_superseded() {
  unacquired
  newest 1005
  run_action INPUT_RUN_ID=1001
  line "$TAG: superseded (by run 1005)" && no_call /jobs && reruns ""
}

test_skip_superseded_false() {
  unacquired
  newest 1005
  run_action INPUT_RUN_ID=1001 INPUT_SKIP_SUPERSEDED=false
  line "$TAG: rerun (2 unacquired job(s))" && no_call actions/workflows
}

test_excluded_by_pattern() {
  unacquired
  run_action INPUT_RUN_ID=1001 INPUT_EXCLUDE_WORKFLOWS='BUILD\.yml$'
  line "$TAG: excluded (exclude-workflows)" && reruns ""
}

test_excluded_calling_workflow() {
  unacquired
  run_action INPUT_RUN_ID=1001 "GITHUB_WORKFLOW_REF=$REPO/.github/workflows/build.yml@refs/heads/main"
  line "$TAG: excluded (calling workflow)" && reruns ""
}

# --- Limits ------------------------------------------------------------------

test_limit_attempt_fails_step() {
  unacquired
  serve actions/runs/1001 run-unacquired.json '.run_attempt = 51'
  run_action INPUT_RUN_ID=1001
  exit_is 1 \
    && line "run 1001 (Build, attempt 51): limit reached (attempt 51, max 50; age 0d, max 29d)" \
    && summary "### Run 1001 hit GitHub's rerun limits" \
    && output "limit-ids=1001" && output "rerun-ids=" && reruns ""
}

test_limit_age_without_fail_on_limit() {
  unacquired
  serve actions/runs/1001 run-unacquired.json ".created_at = \"$(days_ago 30)\""
  run_action INPUT_RUN_ID=1001 INPUT_FAIL_ON_LIMIT=false
  exit_is 0 && line "$TAG: limit reached (attempt 1, max 50; age 30d, max 29d)" \
    && summary "### Run 1001 hit GitHub's rerun limits" && reruns ""
}

test_limit_not_reported_for_real_failure() {
  repo
  serve actions/runs/1002 run-real-failure.json '.run_attempt = 51'
  serve actions/runs/1002/jobs jobs-real-failure.json
  newest 1002
  run_action INPUT_RUN_ID=1002
  exit_is 0 && says "real failure" && [[ ! -s "$STUB_DIR/summary" ]]
}

# --- Pagination, rerun race, dry run, label patterns -------------------------

test_pagination_past_100_jobs() {
  unacquired
  # Page 1: 100 successful jobs. Page 2: the unacquired jobs.
  serve actions/runs/1001/jobs jobs-unacquired.json '.jobs = [range(100) as $i | .jobs[0]]'
  serve actions/runs/1001/jobs.page2 jobs-unacquired.json '.jobs |= map(select(.conclusion == "cancelled"))'
  run_action INPUT_RUN_ID=1001
  line "$TAG: rerun (2 unacquired job(s))" && reruns 1001
}

test_rerun_race_already_queued() {
  unacquired
  echo "run 1001 is already running" >"$STUB_DIR/rerun.fail"
  # First read: completed. Read after the failed rerun: queued.
  serve actions/runs/1001.call2 run-unacquired.json '.status = "queued" | .conclusion = null'
  run_action INPUT_RUN_ID=1001
  exit_is 0 && line "$TAG: rerun (already queued)" && output "rerun-ids=1001"
}

test_rerun_failure_is_error() {
  unacquired
  echo "HTTP 403: Resource not accessible by integration" >"$STUB_DIR/rerun.fail"
  run_action INPUT_RUN_ID=1001
  exit_is 1 && line "$TAG: error (rerun failed: HTTP 403: Resource not accessible by integration)"
}

test_dry_run() {
  unacquired
  run_action INPUT_RUN_ID=1001 INPUT_DRY_RUN=true
  exit_is 0 && line "$TAG: rerun (dry run, 2 unacquired job(s))" && no_call "run rerun" && output "rerun-ids="
}

test_empty_label_pattern_with_exclude_matching() {
  unacquired
  run_action INPUT_RUN_ID=1001 INPUT_LABEL_PATTERN= INPUT_EXCLUDE_LABEL_PATTERN='^macos'
  line "$TAG: not ours (2 job(s) without steps do not match the label patterns)" && reruns ""
}

test_empty_label_pattern_matches_no_labels() {
  unacquired
  serve actions/runs/1001/jobs jobs-unacquired.json '(.jobs[] | select(.id == 3002)).labels = []'
  run_action INPUT_RUN_ID=1001
  line "$TAG: rerun (2 unacquired job(s))"
}

test_empty_label_pattern_with_exclude_not_matching() {
  unacquired
  run_action INPUT_RUN_ID=1001 INPUT_LABEL_PATTERN= INPUT_EXCLUDE_LABEL_PATTERN='^self-hosted$'
  line "$TAG: rerun (2 unacquired job(s))"
}

# --- Private repositories ----------------------------------------------------

test_private_repo_skipped() {
  unacquired
  repo '.private = true'
  run_action INPUT_RUN_ID=1001
  exit_is 0 \
    && line "repository $REPO is not public: skipping (set allow-private-repos: true to run here)" \
    && no_call actions/runs && output "evaluated=0" && reruns ""
}

test_private_repo_skipped_in_sweep() {
  repo '.private = true'
  run_action
  exit_is 0 && says "is not public: skipping" && no_call actions/runs
}

test_private_repo_allowed() {
  unacquired
  repo '.private = true'
  run_action INPUT_RUN_ID=1001 INPUT_ALLOW_PRIVATE_REPOS=true
  line "$TAG: rerun (2 unacquired job(s))" && reruns 1001
}

test_unreadable_repo_fails_closed() {
  run_action INPUT_RUN_ID=1001
  exit_is 1 && says "cannot read repository $REPO" && no_call actions/runs
}

# --- Choosing what to evaluate -----------------------------------------------

test_workflow_run_event() {
  unacquired
  echo '{"workflow_run": {"id": 1001}}' >"$STUB_DIR/event.json"
  run_action GITHUB_EVENT_NAME=workflow_run "GITHUB_EVENT_PATH=$STUB_DIR/event.json"
  line "$TAG: rerun (2 unacquired job(s))" && no_call "actions/runs -f"
}

test_run_id_beats_event() {
  unacquired
  echo '{"workflow_run": {"id": 1002}}' >"$STUB_DIR/event.json"
  run_action GITHUB_EVENT_NAME=workflow_run "GITHUB_EVENT_PATH=$STUB_DIR/event.json" INPUT_RUN_ID=1001
  line "$TAG: rerun (2 unacquired job(s))" && no_call runs/1002
}

test_sweep() {
  unacquired
  serve actions/runs/1002 run-real-failure.json
  serve actions/runs/1002/jobs jobs-real-failure.json
  # failure list: 1001, the calling workflow's own run, an excluded run.
  # cancelled list: 1001 again and 1002.
  jq -s '{workflow_runs: [
      .[0],
      (.[0] | .id = 1003 | .path = ".github/workflows/retry.yml" | .name = "Retry"),
      (.[0] | .id = 1004 | .path = ".github/workflows/docs.yml" | .name = "Docs")]}' \
    "$FX/run-unacquired.json" >"$STUB_DIR/repos_example-owner_example-repo_actions_runs.status-failure.json"
  jq -s '{workflow_runs: .}' "$FX/run-unacquired.json" "$FX/run-real-failure.json" \
    >"$STUB_DIR/repos_example-owner_example-repo_actions_runs.status-cancelled.json"
  run_action INPUT_EXCLUDE_WORKFLOWS='^docs$' INPUT_SKIP_SUPERSEDED=false
  exit_is 0 && says "sweep: runs created since " \
    && line "run 1004 (Docs, attempt 1): excluded (exclude-workflows)" \
    && line "$TAG: rerun (2 unacquired job(s))" \
    && says "run 1002 (Build, attempt 1): real failure" \
    && no_call runs/1003 && [[ $(grep -c "^$TAG" "$STUB_DIR/out") == 1 ]] \
    && reruns 1001 && output "evaluated=3"
}

test_sweep_list_error_continues() {
  unacquired
  touch "$STUB_DIR/repos_example-owner_example-repo_actions_runs.status-failure.fail"
  jq '{workflow_runs: [.]}' "$FX/run-unacquired.json" \
    >"$STUB_DIR/repos_example-owner_example-repo_actions_runs.status-cancelled.json"
  run_action
  exit_is 1 && line "sweep: error (cannot list failure runs)" && line "$TAG: rerun (2 unacquired job(s))"
}

# --- Errors and input validation ---------------------------------------------

test_unreadable_run() {
  repo
  run_action INPUT_RUN_ID=123
  exit_is 1 && line "run 123 (unknown, attempt ?): error (cannot read run)"
}

test_invalid_regex() {
  run_action INPUT_RUN_ID=1001 INPUT_LABEL_PATTERN='('
  exit_is 1 && says "label-pattern is not a valid regex"
}

test_invalid_boolean() {
  run_action INPUT_RUN_ID=1001 INPUT_DRY_RUN=yes
  exit_is 1 && says "dry-run must be true or false"
}

# --- Runner ------------------------------------------------------------------

passed=0
failed=0
for t in $(compgen -A function test_); do
  STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/retry-test.XXXXXX")
  export STUB_DIR
  if why=$("$t" 2>&1); then
    printf 'ok   %s\n' "${t#test_}"
    passed=$((passed + 1))
  else
    printf 'FAIL %s: %s\n' "${t#test_}" "$why"
    sed 's/^/    | /' "$STUB_DIR/out" 2>/dev/null
    failed=$((failed + 1))
  fi
  rm -rf "$STUB_DIR"
done

printf '\n%d passed, %d failed\n' "$passed" "$failed"
((failed == 0))
