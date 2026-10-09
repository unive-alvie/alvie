#!/usr/bin/env bash

# Shared completion handling for the experiment wrappers.

ALVIE_JOB_PIDS=()
ALVIE_JOB_NAMES=()
ALVIE_JOB_LOGS=()

alvie_build_or_exit() {
  if ! dune build; then
    echo "ALVIE error: build failed; no experiment was started." >&2
    exit 1
  fi
}

# Maximum number of experiments running at the same time (default: number of cores; 0: no limit)
ALVIE_JOBS="${ALVIE_JOBS:-$(nproc 2>/dev/null || echo 4)}"

alvie_run_background() {
  local name="$1"
  local command="$2"
  local logfile="$3"

  # Throttle: wait for a slot without reaping finished jobs, so that
  # alvie_wait_for_jobs can still collect their exit status
  if [ "$ALVIE_JOBS" -gt 0 ]; then
    while [ "$(jobs -rp | wc -l)" -ge "$ALVIE_JOBS" ]; do
      sleep 1
    done
  fi

  echo "$command"
  bash -c "$command" &
  ALVIE_JOB_PIDS+=("$!")
  ALVIE_JOB_NAMES+=("$name")
  ALVIE_JOB_LOGS+=("$logfile")
}

alvie_wait_for_jobs() {
  local status=0
  local job_status
  local index

  for index in "${!ALVIE_JOB_PIDS[@]}"; do
    if wait "${ALVIE_JOB_PIDS[$index]}"; then
      echo "${ALVIE_JOB_NAMES[$index]} ... [OK - ${ALVIE_JOB_LOGS[$index]}]"
    else
      job_status=$?
      echo "${ALVIE_JOB_NAMES[$index]} ... [KO - ${ALVIE_JOB_LOGS[$index]}]" >&2
      status=$job_status
    fi
  done

  return "$status"
}
