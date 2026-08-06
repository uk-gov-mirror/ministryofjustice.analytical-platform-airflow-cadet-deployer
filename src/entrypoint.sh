#!/usr/bin/env bash

set -euo pipefail

export IS_SUNDAY_DEPLOY="${IS_SUNDAY_DEPLOY:-false}"
export MOJAP_IMAGE_VERSION="${MOJAP_IMAGE_VERSION:-"unknown"}"
export IS_DATASET_CHECK="${IS_DATASET_CHECK:-"False"}"
export DATASET_TARGET="${DATASET_TARGET:-""}"
export UNIQUE_IDS="${UNIQUE_IDS:-}"
export RUN_IN_DF="${RUN_IN_DF:-"False"}"

function dataset_check() {
  local -a command=(uv run check_run_results.py)
  if [ -n "${UNIQUE_IDS}" ]; then
    command+=(--unique-ids "${UNIQUE_IDS}")
  elif [ -n "${DATASET_TARGET}" ]; then
    : # DATASET_TARGET is used by the python script via env var / yaml lookup
  else
    command+=(--check-all-nodes)
  fi
  echo "Running dataset check with command: ${command[*]}"
  if "${command[@]}"; then
    echo "Dataset Check Passed!"
    exit 0
  else
    echo "Dataset Check Failed! See Logs for Details"
    exit 1
  fi
}

echo "=== Running Airflow CaDeT Deployer (version: ${MOJAP_IMAGE_VERSION}) ==="

echo "=== Is Sunday Deploy: ${IS_SUNDAY_DEPLOY} ==="
if [ "${IS_SUNDAY_DEPLOY}" = "True" ]; then
  echo "=== Checking if today is the first Sunday of the month ==="
  ./date-checker.sh
fi

if [ "${RUN_IN_DF}" != "True" ]; then
  echo "=== Running clone-create-a-derived-table.sh ==="
  ./clone-create-a-derived-table.sh
fi

if [ "${RUN_IN_DF}" != "True" ]; then
  echo "=== Am I running a dataset check? ${IS_DATASET_CHECK} ==="
  if [ "${IS_DATASET_CHECK}" = "True" ]; then
    dataset_check
  fi

  echo "=== Running create-a-derived-table.sh ==="
  ./create-a-derived-table.sh
else
  echo "=== Running create-a-derived-table.sh and dataset_check ==="
  ./create-a-derived-table.sh && dataset_check
fi
