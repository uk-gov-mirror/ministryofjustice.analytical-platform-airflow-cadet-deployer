#!/usr/bin/env bash

set -euo pipefail

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-"eu-west-1"}"
export REPOSITORY_PATH="${REPOSITORY_PATH:-"${ANALYTICAL_PLATFORM_DIRECTORY}/create-a-derived-table"}"
export MODE="${MODE}"
export DBT_PROFILES_DIR="${DBT_PROFILES_DIR:-"${REPOSITORY_PATH}/.dbt"}"
export DBT_PROFILE_WORKGROUP="${DBT_PROFILE_WORKGROUP}"
export DBT_PROJECT="${DBT_PROJECT}"
export DBT_SELECT_CRITERIA="${DBT_SELECT_CRITERIA}"
export DEPLOY_ENV="${DEPLOY_ENV}"
export S3_BUCKET="${S3_BUCKET:-"mojap-derived-tables"}"
export STATE_MODE="${STATE_MODE:-false}"
export WORKFLOW_NAME="${WORKFLOW_NAME}"
export EM_REMOVE_HISTORIC="${EM_REMOVE_HISTORIC:-false}"
export EM_REMOVE_LIVE="${EM_REMOVE_LIVE:-false}"
export THREAD_COUNT="${THREAD_COUNT:-}"
export VARS="${VARS:-}"
DEPLOY_ENV_UPPER=$(echo "${DEPLOY_ENV}" | tr '[:lower:]' '[:upper:]')
export "DBT_${DEPLOY_ENV_UPPER}_PROFILE_WORKGROUP"="${DBT_PROFILE_WORKGROUP}"
export DBT_PROFILE="${DBT_PROFILE:-"mojap"}"
export ENFORCE_LAKE_FORMATION="${ENFORCE_LAKE_FORMATION:-false}"
export RUN_SOURCE_FRESHNESS="${RUN_SOURCE_FRESHNESS:-false}"
export FULL_REFRESH="${FULL_REFRESH:-false}"
export RUN_UNIT_TESTS="${RUN_UNIT_TESTS:-false}"
export CHECK_DUAL_MATERIALIZATION="${CHECK_DUAL_MATERIALIZATION:-false}"

function run_dbt() {
  local max_retries=3
  local attempt=2
  local previous_attempt=1
  local run_results_exists=false

  # Disable immediate exit on error for the loop
  set +e
  local -a DBT_COMMAND=(dbt "${MODE}" --profiles-dir "${REPOSITORY_PATH}/.dbt" --select "${DBT_SELECT_CRITERIA}" --target "${DEPLOY_ENV}")
  if [ -n "${THREAD_COUNT}" ]; then
    DBT_COMMAND+=(--threads "${THREAD_COUNT}")
  fi
  if [ "${FULL_REFRESH}" = "True" ]; then
    DBT_COMMAND+=(--full-refresh)
  fi
  if [ -n "${VARS}" ]; then
    DBT_COMMAND+=(--vars "${VARS}")
  fi
  if "${DBT_COMMAND[@]}"; then
    echo "dbt command succeeded"
    return 0
  else
    echo "dbt command failed, attempting to dbt retry..."
  fi
  while [[ "${attempt}" -le "${max_retries}" ]]; do
    echo "Attempt ${attempt} of ${max_retries} to run dbt command"
    if [[ "${attempt}" -eq "${max_retries}" ]]; then
      if ! $run_results_exists; then
        echo "dbt command failed after ${max_retries} attempts"
        return 1
      else
        echo "dbt command at least partially succeeded, see run artefacts for details"
        return 0
      fi
    else
      echo "dbt command failed on attempt ${attempt}, retrying"
      if [[ -f "${REPOSITORY_PATH}/${DBT_PROJECT}/target/run_results.json" ]]; then
        run_results_exists=true
        echo "run_results.json exists is ${run_results_exists}"
        cp "${REPOSITORY_PATH}/${DBT_PROJECT}/target/run_results.json" "${REPOSITORY_PATH}/${DBT_PROJECT}/target/run_results_${previous_attempt}.json"
        if dbt retry; then
          echo "dbt retry succeeded"
          return 0
        fi
      else
        echo "DBT run failed without artefacts, re-running full command"
        if "${DBT_COMMAND[@]}"; then
          echo "dbt command succeeded"
          return 0
        fi
      fi
      ((attempt++))
      ((previous_attempt++))
      sleep 10 # Wait before retrying
    fi
  done
  set -e # Re-enable immediate exit on error
}

function run_source_freshness() {
  local source="${1:-}"
  local max_retries=5
  local attempt=2
  set +e

  local -a DBT_COMMAND
  if [ -n "${source}" ]; then
    DBT_COMMAND=(dbt source freshness --target "${DEPLOY_ENV}" --select "source:${source}")
  else
    DBT_COMMAND=(dbt source freshness --target "${DEPLOY_ENV}")
  fi
  if "${DBT_COMMAND[@]}"; then
    echo "Source freshness check passed"
    rm -f "${REPOSITORY_PATH}/${DBT_PROJECT}/target/run_results.json"
  elif [ -f "${REPOSITORY_PATH}/${DBT_PROJECT}/target/run_results.json" ]; then
    echo "Source freshness check failed on freshness, exiting."
    return 1
  else
    echo "Source freshness check failed without running, retrying."
    while [[ "${attempt}" -le "${max_retries}" ]]; do
      echo "Attempt ${attempt} of ${max_retries} to run NOMIS source freshness check"
      if [[ "${attempt}" -eq "${max_retries}" ]]; then
        echo "Source freshness check failed after ${max_retries} attempts, exiting."
        return 1
      else
        echo "Source freshness check failed on attempt ${attempt}, retrying"
        if "${DBT_COMMAND[@]}"; then
          echo "Source freshness check passed on retry"
          rm -f "${REPOSITORY_PATH}/${DBT_PROJECT}/target/run_results.json"
          return 0
        elif [ -f "${REPOSITORY_PATH}/${DBT_PROJECT}/target/run_results.json" ]; then
          echo "Source freshness check failed on freshness, exiting."
          return 1
        else
          echo "Source freshness check failed on attempt ${attempt} without running, retrying."
        fi
        ((attempt++))
        sleep 10 # Wait before retrying
      fi
    done
  fi
}

function nomis_setup() {
  echo "Running NOMIS specific setup"
  run_source_freshness "nomis_unixtime"
  python "${REPOSITORY_PATH}/scripts/generate_partition_queries.py" "${REPOSITORY_PATH}/${DBT_PROJECT}/model_templates/" "${REPOSITORY_PATH}/${DBT_PROJECT}" --target "${DEPLOY_ENV}" --source "nomis"
  dbt run-operation check_if_models_exist_by_tag \
    --args '{"tag_names":["dual_materialization","nomis_daily"], "tag_mode":"intersect"}' \
    --target "${DEPLOY_ENV}" |
    grep "|model_check|" |
    sed 's/.*|model_check|*//' |
    while read -r variable; do
      export "$variable"="$variable"
      echo "Added: $variable"
    done
  set -e
}

function export_run_artefacts() {
  RUN_TIME=$(date +%Y-%m-%dT%H:%M:%S)
  export RUN_TIME
  export AIRFLOW_WORKFLOW_REF="${WORKFLOW_NAME:-"unknown_workflow"}"

  # Skip exporting run artefacts for sdp_tables projects
  if [ "${DBT_PROJECT}" = "sdp_tables" ]; then
    echo "Skipping export of run artefacts for project sdp_tables"
    return 0
  else
    python "${REPOSITORY_PATH}/scripts/export_run_artefacts.py"
  fi
}

function import_run_artefacts() {
  ARTEFACT_TARGET=${ARTEFACT_TARGET:-"target"}
  export ARTEFACT_TARGET

  python "${REPOSITORY_PATH}/scripts/import_run_artefacts.py" --target "$ARTEFACT_TARGET"
}

function enforce_lake_formation() {
  if [ "${ENFORCE_LAKE_FORMATION}" = "True" ]; then
    echo "Enforcing lake formation permissions"
    python "${REPOSITORY_PATH}/scripts/enforce_lake_formation.py"
    return 0
  else
    return 0
  fi
}

function run_unit_tests() {
  if [ "${RUN_UNIT_TESTS}" = "True" ]; then
    echo "Running unit tests"
    dbt test -s test_type:unit --target "${DEPLOY_ENV}"
    return 0
  else
    return 0
  fi
}

function set_dual_materialization_env_vars() {
  if [ "$CHECK_DUAL_MATERIALIZATION" = "True" ]; then
    echo "Checking for models with dual materialization config"

    while IFS= read -r variable; do
      export "$variable"
      echo "Added: $variable"
    done < <(
      dbt run-operation check_if_models_exist_by_tag \
        --args '{"tag_names":["dual_materialization"], "tag_mode":"intersect"}' \
        --target "$DEPLOY_ENV" \
      | grep "|model_check|" \
      | sed 's/.*|model_check|//'
    )
  fi
}

echo "Creating virtual environment and installing dependencies"
cd "${REPOSITORY_PATH}"

uv venv --python 3.12

# shellcheck disable=SC1091
source .venv/bin/activate

uv pip install --requirements requirements.txt

if [ "${DBT_PROJECT}" = "sdp_tables" ]; then
  echo "Installing SDP specific Python dependencies from requirements-sdp.txt"
  uv pip install --force-reinstall --requirement requirements-sdp.txt --no-cache-dir
fi

echo "Changing to project directory [ ${DBT_PROJECT} ]"
cd "${DBT_PROJECT}"

if [ "$DBT_PROJECT" = "hmpps_electronic_monitoring_data_tables" ]; then
  echo "Generating env vars for emd project."
  python3 "${REPOSITORY_PATH}/${DBT_PROJECT}/scripts/environment.py"
  # shellcheck source=entrypoint.sh
  source "${REPOSITORY_PATH}/${DBT_PROJECT}/set_env.sh"
  if [ "$EM_REMOVE_HISTORIC" = "True" ]; then
    echo "Removing historic models for EM..."
    rm -rf "${REPOSITORY_PATH}/${DBT_PROJECT}/models/historic"
    rm -rf "${REPOSITORY_PATH}/${DBT_PROJECT}/analyses"
  fi
  if [ "$EM_REMOVE_LIVE" = "True" ]; then
    echo "Removing live models for EM..."
    rm -rf "${REPOSITORY_PATH}/${DBT_PROJECT}/models/live"
  fi
fi

echo "Generating models"
python "${REPOSITORY_PATH}/scripts/generate_models.py" model_templates/ ./ --target "${DEPLOY_ENV}"

echo "Running dbt debug with target ${DEPLOY_ENV}"
dbt debug --target "${DEPLOY_ENV}"

echo "Running dbt clean"
dbt clean

echo "Running dbt deps"
dbt deps

if [ "$CHECK_DUAL_MATERIALIZATION" = "True" ]; then
  set_dual_materialization_env_vars
fi

echo "Running in mode [ ${MODE} ] for project [ ${DBT_PROJECT} ] to environment [ ${DEPLOY_ENV} ] with select criteria [ ${DBT_SELECT_CRITERIA} ] and thread count [ ${THREAD_COUNT} ] and vars [ ${VARS:-none} ]"

if $STATE_MODE; then
  import_run_artefacts
  export DBT_SELECT_CRITERIA="{$DBT_SELECT_CRITERIA},state:modified"
fi

if [ "$RUN_SOURCE_FRESHNESS" = "True" ]; then
  run_source_freshness
fi

if [ "$WORKFLOW_NAME" = "nomis-daily" ]; then
  nomis_setup
fi

run_unit_tests

if run_dbt; then
  echo "dbt run (partially) succeeded"
  echo "Exporting run artefacts"
  enforce_lake_formation
  export_run_artefacts
  exit 0
else
  echo "dbt run failed after 5 retries"
  echo "Exporting run artefacts"
  export_run_artefacts
  exit 1
fi
