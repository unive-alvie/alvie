#!/usr/bin/env bash

# Shared completion handling for the experiment wrappers.

ALVIE_JOB_PIDS=()
ALVIE_JOB_NAMES=()
ALVIE_JOB_LOGS=()

# Set when a sequential job fails, so alvie_wait_for_jobs can report a failure
# even though there was no background pid to wait on.
ALVIE_SEQUENTIAL_STATUS=0

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

# Runs a command to completion before returning, instead of backgrounding it.
# The FPGA backend drives a single serial port, so its experiments must not run
# concurrently. Outcomes are reported the same way as background jobs.
alvie_run_sequential() {
  local name="$1"
  local command="$2"
  local logfile="$3"

  echo "$command"
  if bash -c "$command"; then
    echo "$name ... [OK - $logfile]"
  else
    ALVIE_SEQUENTIAL_STATUS=$?
    echo "$name ... [KO - $logfile]" >&2
  fi
}

alvie_wait_for_jobs() {
  local status="$ALVIE_SEQUENTIAL_STATUS"
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
