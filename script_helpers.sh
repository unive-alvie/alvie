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

alvie_run_background() {
  local name="$1"
  local command="$2"
  local logfile="$3"

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
