#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq programs use $vars in single quotes
# Rerun workflow runs whose failed jobs were never picked up by a runner.
#
# Interface and behavior: README.md.
# Inputs arrive as INPUT_* environment variables (see action.yml).
set -uo pipefail

US=$'\x1f' # field separator for jq output; unlike a tab, it never collapses

log() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# jq with CRs stripped: jq.exe on Windows writes CRLF line endings.
jqr() { jq "$@" | tr -d '\r'; }

# bool NAME VALUE: print "true" or "false", or die.
bool() {
  case "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" in
    true) echo true ;;
    false) echo false ;;
    *) die "$1 must be true or false, got '$2'" ;;
  esac
}

# uint NAME VALUE: print VALUE if it is a non-negative integer, or die.
uint() {
  [[ "$2" =~ ^[0-9]+$ ]] || die "$1 must be a non-negative integer, got '$2'"
  echo "$2"
}

# regex NAME VALUE: die unless VALUE compiles as a jq regex.
regex() {
  [[ -z "$2" ]] && return 0
  jqr -n --arg re "$2" '"" | test($re; "i")' >/dev/null 2>&1 \
    || die "$1 is not a valid regex: $2"
}

# --- Inputs ------------------------------------------------------------------

REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
API_URL="${GITHUB_API_URL:-https://api.github.com}"
SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"
SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-/dev/null}"

RUN_ID="${INPUT_RUN_ID:-}"
LABEL_RE="${INPUT_LABEL_PATTERN:-}"
EXCL_LABEL_RE="${INPUT_EXCLUDE_LABEL_PATTERN:-}"
REQUIRE_ANN=$(bool require-annotation "${INPUT_REQUIRE_ANNOTATION:-true}") || exit 1
ANN_RE="${INPUT_ANNOTATION_PATTERN-was not acquired by Runner of type}"
LOOKBACK_HOURS=$(uint sweep-lookback-hours "${INPUT_SWEEP_LOOKBACK_HOURS:-48}") || exit 1
MAX_ATTEMPT=$(uint max-run-attempt "${INPUT_MAX_RUN_ATTEMPT:-50}") || exit 1
MAX_AGE_DAYS=$(uint max-run-age-days "${INPUT_MAX_RUN_AGE_DAYS:-30}") || exit 1
SKIP_SUPERSEDED=$(bool skip-superseded "${INPUT_SKIP_SUPERSEDED:-true}") || exit 1
EXCL_WF_RE="${INPUT_EXCLUDE_WORKFLOWS:-}"
FAIL_ON_LIMIT=$(bool fail-on-limit "${INPUT_FAIL_ON_LIMIT:-true}") || exit 1
DRY_RUN=$(bool dry-run "${INPUT_DRY_RUN:-false}") || exit 1
ALLOW_PRIVATE=$(bool allow-private-repos "${INPUT_ALLOW_PRIVATE_REPOS:-false}") || exit 1

[[ -z "$RUN_ID" || "$RUN_ID" =~ ^[0-9]+$ ]] || die "run-id must be a run id, got '$RUN_ID'"
regex label-pattern "$LABEL_RE"
regex exclude-label-pattern "$EXCL_LABEL_RE"
regex annotation-pattern "$ANN_RE"
regex exclude-workflows "$EXCL_WF_RE"

export GH_REPO="$REPO"
host="${SERVER_URL#*://}"
export GH_HOST="${host%%/*}"
# gh reads GH_TOKEN only for github.com; other hosts (GHES) need this.
export GH_ENTERPRISE_TOKEN="${GH_ENTERPRISE_TOKEN:-${GH_TOKEN:-}}"

# Path of the calling workflow, e.g. .github/workflows/retry.yml.
SELF_PATH=""
if [[ -n "${GITHUB_WORKFLOW_REF:-}" ]]; then
  SELF_PATH="${GITHUB_WORKFLOW_REF#"$REPO"/}"
  SELF_PATH="${SELF_PATH%%@*}"
fi

# --- State -------------------------------------------------------------------

evaluated=0
errors=0
rerun_ids=""
limit_ids=""

write_outputs() {
  [[ -n "${GITHUB_OUTPUT:-}" ]] || return 0
  {
    echo "rerun-ids=${rerun_ids# }"
    echo "limit-ids=${limit_ids# }"
    echo "evaluated=$evaluated"
  } >>"$GITHUB_OUTPUT"
}

# excluded_reason PATH NAME: print why a workflow is excluded, or fail.
excluded_reason() {
  if [[ -n "$SELF_PATH" && "$1" == "$SELF_PATH" ]]; then
    echo "calling workflow"
    return 0
  fi
  if [[ -n "$EXCL_WF_RE" ]] && jqr -ne --arg re "$EXCL_WF_RE" --arg p "$1" --arg n "$2" \
      '($p | test($re; "i")) or ($n | test($re; "i"))' >/dev/null; then
    echo "exclude-workflows"
    return 0
  fi
  return 1
}

# --- Evaluating one run ------------------------------------------------------

# evaluate_run ID: print exactly one decision line, rerun if eligible.
# Returns non-zero on errors.
evaluate_run() {
  local id="$1" run
  evaluated=$((evaluated + 1))

  if ! run=$(gh api "repos/$REPO/actions/runs/$id" \
      --jq '[.status, .conclusion, .run_attempt, .created_at, .workflow_id, .head_branch, .event, .name, .path]
            | map(. // "" | tostring) | join("\u001f")'); then
    log "run $id (unknown, attempt ?): error (cannot read run)"
    return 1
  fi
  local status conclusion attempt created wf_id branch event name path
  IFS="$US" read -r status conclusion attempt created wf_id branch event name path <<<"$run"
  local tag="run $id ($name, attempt $attempt)" reason

  # 1. Cheap checks on the run itself.
  if reason=$(excluded_reason "$path" "$name"); then
    log "$tag: excluded ($reason)"
    return 0
  fi
  if [[ "$status" != "completed" ]]; then
    log "$tag: not completed ($status)"
    return 0
  fi
  if [[ "$conclusion" == "success" ]]; then
    log "$tag: succeeded"
    return 0
  fi

  # 2. Superseded by a newer run of the same workflow, branch and event.
  if [[ "$SKIP_SUPERSEDED" == true ]]; then
    local newest
    local -a q=(-X GET -F per_page=1 -f event="$event")
    [[ -n "$branch" ]] && q+=(-f branch="$branch")
    if ! newest=$(gh api "repos/$REPO/actions/workflows/$wf_id/runs" "${q[@]}" \
        --jq '.workflow_runs[0].id // 0') || [[ ! "$newest" =~ ^[0-9]+$ ]]; then
      log "$tag: error (cannot list workflow runs)"
      return 1
    fi
    if ((newest > id)); then
      log "$tag: superseded (by run $newest)"
      return 0
    fi
  fi

  # 3. Classify the latest attempt's jobs.
  local jobs summary
  if ! jobs=$(gh api --paginate "repos/$REPO/actions/runs/$id/jobs?filter=latest&per_page=100" \
      --jq '.jobs[] | {conclusion, steps: (.steps // [] | length), labels: (.labels // []), check_run_url}'); then
    log "$tag: error (cannot list jobs)"
    return 1
  fi
  if ! summary=$(jqr -rs --arg inc "$LABEL_RE" --arg exc "$EXCL_LABEL_RE" '
      [.[] | select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out")] as $bad
      | [$bad[] | select(.steps > 0)] as $real
      | [$bad[] | select(.steps == 0
            and (.conclusion == "failure" or .conclusion == "cancelled")
            and ($inc == "" or any(.labels[]; test($inc; "i")))
            and ($exc == "" or (any(.labels[]; test($exc; "i")) | not)))] as $cand
      | [($real | length), (($bad | length) - ($real | length) - ($cand | length)), ($cand | length),
         ([$cand[].check_run_url] | join(" "))]
      | map(tostring) | join("\u001f")' <<<"$jobs"); then
    log "$tag: error (cannot classify jobs)"
    return 1
  fi
  local real other count urls
  IFS="$US" read -r real other count urls <<<"$summary"

  if ((real > 0)); then
    log "$tag: real failure ($real job(s) failed after running steps)"
    return 0
  fi
  if ((other > 0)); then
    log "$tag: not ours ($other job(s) without steps do not match the label patterns)"
    return 0
  fi
  if ((count == 0)); then
    log "$tag: not ours (nothing unacquired)"
    return 0
  fi

  # 4. Each candidate needs the not-acquired annotation.
  if [[ "$REQUIRE_ANN" == true ]]; then
    local url msgs
    for url in $urls; do
      if ! msgs=$(gh api --paginate "${url#"$API_URL"/}/annotations?per_page=100" \
          --jq '.[] | .message | @json'); then
        log "$tag: error (cannot read annotations)"
        return 1
      fi
      if ! jqr -se --arg re "$ANN_RE" 'any(.[]; test($re; "i"))' <<<"$msgs" >/dev/null; then
        log "$tag: not ours (a job without steps lacks the not-acquired annotation)"
        return 0
      fi
    done
  fi

  # 5. GitHub's rerun limits. Checked last so only rerunnable runs are reported.
  local age
  if ! age=$(jqr -nr --arg c "$created" '(now - ($c | fromdateiso8601)) / 86400 | floor'); then
    log "$tag: error (cannot parse created_at '$created')"
    return 1
  fi
  if ((attempt > MAX_ATTEMPT || age >= MAX_AGE_DAYS)); then
    log "$tag: limit reached (attempt $attempt, max $MAX_ATTEMPT; age ${age}d, max $((MAX_AGE_DAYS - 1))d)"
    {
      echo "### Run $id hit GitHub's rerun limits"
      echo
      echo "[$name]($SERVER_URL/$REPO/actions/runs/$id) has $count unacquired job(s) but cannot be rerun: attempt $attempt (max $MAX_ATTEMPT), age $age days (max $((MAX_AGE_DAYS - 1)))."
      echo
    } >>"$SUMMARY_FILE"
    limit_ids+=" $id"
    return 0
  fi

  # 6. Rerun.
  if [[ "$DRY_RUN" == true ]]; then
    log "$tag: rerun (dry run, $count unacquired job(s))"
    return 0
  fi
  local out now_status
  if out=$(gh run rerun "$id" --failed -R "$REPO" 2>&1); then
    log "$tag: rerun ($count unacquired job(s))"
    rerun_ids+=" $id"
    return 0
  fi
  # The event handler and the sweep can race; a run that is no longer
  # completed was rerun by the other invocation.
  now_status=$(gh api "repos/$REPO/actions/runs/$id" --jq '.status' 2>/dev/null)
  if [[ -n "$now_status" && "$now_status" != "completed" ]]; then
    log "$tag: rerun (already queued)"
    rerun_ids+=" $id"
    return 0
  fi
  out="${out//$'\r'/}"
  log "$tag: error (rerun failed: ${out//$'\n'/ })"
  return 1
}

# --- Main --------------------------------------------------------------------

# Do nothing outside public repositories unless asked to: every job there is
# billed, and internal repositories report private=true as well.
if ! private=$(gh api "repos/$REPO" --jq '.private'); then
  die "cannot read repository $REPO"
fi
if [[ "$private" != "false" && "$ALLOW_PRIVATE" != true ]]; then
  log "repository $REPO is not public: skipping (set allow-private-repos: true to run here)"
  write_outputs
  exit 0
fi

ids=""
event_run_id=""
if [[ "${GITHUB_EVENT_NAME:-}" == "workflow_run" && -n "${GITHUB_EVENT_PATH:-}" ]]; then
  event_run_id=$(jqr -r '.workflow_run.id // empty' "$GITHUB_EVENT_PATH") \
    || die "cannot read workflow_run.id from $GITHUB_EVENT_PATH"
fi

if [[ -n "$RUN_ID" ]]; then
  ids="$RUN_ID"
elif [[ -n "$event_run_id" ]]; then
  ids="$event_run_id"
else
  since=$(jqr -nr --argjson h "$LOOKBACK_HOURS" 'now - $h * 3600 | floor | todate')
  log "sweep: runs created since $since"
  seen=" "
  for c in failure cancelled; do
    if ! found=$(gh api --paginate -X GET "repos/$REPO/actions/runs" \
        -f created=">=$since" -f status="$c" -F per_page=100 \
        --jq '.workflow_runs[] | [.id, .run_attempt, .path, .name] | map(. // "" | tostring) | join("\u001f")'); then
      log "sweep: error (cannot list $c runs)"
      errors=$((errors + 1))
      continue
    fi
    while IFS="$US" read -r id attempt path name; do
      [[ -n "$id" && "$seen" != *" $id "* ]] || continue
      seen+="$id "
      [[ -n "$SELF_PATH" && "$path" == "$SELF_PATH" ]] && continue
      if reason=$(excluded_reason "$path" "$name"); then
        evaluated=$((evaluated + 1))
        log "run $id ($name, attempt $attempt): excluded ($reason)"
        continue
      fi
      ids+=" $id"
    done <<<"$found"
  done
fi

for id in $ids; do
  evaluate_run "$id" || errors=$((errors + 1))
done

write_outputs

status=0
if [[ -n "$limit_ids" ]]; then
  log "run(s) hit GitHub's rerun limits:${limit_ids} (see the job summary)"
  [[ "$FAIL_ON_LIMIT" == true ]] && status=1
fi
if ((errors > 0)); then
  log "$errors error(s)"
  status=1
fi
exit "$status"
