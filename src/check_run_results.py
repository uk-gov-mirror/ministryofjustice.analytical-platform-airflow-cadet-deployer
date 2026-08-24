#!/usr/bin/env python3
"""Validate dbt run_results.json statuses by unique_id."""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import tempfile
from pathlib import Path
from typing import Iterable

import boto3

DEFAULT_UNIQUE_ID_YAML = Path(
    "./create-a-derived-table/scripts/data/airflow-dag-trigger.yaml"
)

DEFAULT_S3_BUCKET = "mojap-derived-tables"

# dbt models finish with 'success'; tests finish with 'pass' or 'warn'.
# All three are considered acceptable (non-failure) statuses.
_ACCEPTABLE_STATUSES = frozenset({"success", "pass", "warn"})


def _normalize_unique_id(value: str) -> str:
    value = value.strip().rstrip(",")
    if (value.startswith('"') and value.endswith('"')) or (
        value.startswith("'") and value.endswith("'")
    ):
        value = value[1:-1].strip()
    return value


def _parse_unique_ids(values: Iterable[str]) -> list[str]:
    unique_ids: list[str] = []
    for value in values:
        for item in value.split(","):
            item = _normalize_unique_id(item)
            if item:
                unique_ids.append(item)
    return unique_ids


def _parse_unique_ids_yaml(path: Path, dataset_target: str) -> list[str]:
    content = path.read_text(encoding="utf-8")
    unique_ids: list[str] = []
    in_target_block = False
    base_indent: int | None = None
    models_indent: int | None = None
    in_dags_section = False
    dags_indent: int | None = None

    def _extract_quoted(line: str) -> list[str]:
        matches = re.findall(r"\"([^\"]+)\"|'([^']+)'", line)
        extracted: list[str] = []
        for first, second in matches:
            extracted.append(first or second)
        return extracted

    for line in content.splitlines():
        dags_match = re.match(r"^(\s*)dags\s*:\s*$", line)
        if dags_match:
            in_dags_section = True
            dags_indent = len(dags_match.group(1))
            continue

        name_match = re.match(r"^(\s*)-\s*name:\s*(.+)$", line)
        if name_match:
            indent = len(name_match.group(1))
            raw_name = _normalize_unique_id(name_match.group(2))
            if in_dags_section and dags_indent is not None and indent <= dags_indent:
                in_dags_section = False
                dags_indent = None
            if in_target_block and base_indent is not None and indent <= base_indent:
                break
            if in_dags_section and dags_indent is not None and indent <= dags_indent:
                continue
            in_target_block = raw_name == dataset_target
            base_indent = indent
            models_indent = None
            continue

        if not in_target_block:
            continue

        if re.search(r"\bmodels\s*:", line):
            models_indent = len(line) - len(line.lstrip())
            unique_ids.extend(_extract_quoted(line))
            continue

        if models_indent is not None:
            indent = len(line) - len(line.lstrip())
            if indent <= models_indent and re.search(r"\S", line):
                models_indent = None
                continue
            unique_ids.extend(_extract_quoted(line))

    return unique_ids


def _load_run_results(path: Path) -> tuple[dict, str]:
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)

    # Extract all completed_at values from timing entries
    completed_times = [
        t["completed_at"]
        for result in data["results"]
        for t in result.get("timing", [])
        if "completed_at" in t
    ]

    # Find the maximum (ISO 8601 strings sort correctly)
    max_completed = max(completed_times) if completed_times else ""
    return data, max_completed


def _download_run_results_from_s3(
    deploy_env: str,
    workflow_name: str,
    bucket: str,
) -> list[dict]:
    """Download run_results files from S3 and return parsed JSON objects."""
    if bucket == DEFAULT_S3_BUCKET:
        prefix = f"{deploy_env}/run_artefacts/{workflow_name}/latest/target/"
    else:
        prefix = f"data/{deploy_env}/run_artefacts/{workflow_name}/latest/target/"
    client = boto3.client("s3")
    paginator = client.get_paginator("list_objects_v2")
    keys: list[str] = []
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for item in page.get("Contents", []):
            key = item.get("Key")
            if not key:
                continue
            if re.search(r"run_results_\d+\.json$", key):
                keys.append(key)
            elif key.endswith("run_results.json"):
                keys.append(key)

    if not keys:
        raise FileNotFoundError(
            "No run_results_{n}.json files found in S3 target prefix."
        )

    run_results_with_timestamps: list[tuple[dict, str]] = []
    with tempfile.TemporaryDirectory() as tmp_dir:
        for key in sorted(keys):
            dest = Path(tmp_dir) / Path(key).name
            logging.info("Downloading s3://%s/%s", bucket, key)
            client.download_file(bucket, key, str(dest))
            data, max_completed = _load_run_results(dest)
            run_results_with_timestamps.append((data, max_completed))

    # Sort by max_completed timestamp (ISO 8601 format sorts correctly as strings)
    run_results_with_timestamps.sort(key=lambda x: x[1])

    return [data for data, _ in run_results_with_timestamps]


def _index_statuses(run_results: dict) -> dict[str, str]:
    statuses: dict[str, str] = {}
    for result in run_results.get("results", []):
        unique_id = result.get("unique_id")
        status = result.get("status")
        if unique_id is not None and status is not None:
            statuses[str(unique_id)] = str(status)
    return statuses


def assert_success(
    unique_ids: Iterable[str],
    bucket: str,
    deploy_env: str | None = None,
    workflow_name: str | None = None,
) -> None:
    """Assert that all unique_ids have a final status of 'success'."""
    unique_ids = list(unique_ids)
    last_status: dict[str, str] = {}

    if not deploy_env or not workflow_name:
        raise ValueError(
            "DEPLOY_ENV and WORKFLOW_NAME are required to locate run_results files."
        )

    run_results_list = _download_run_results_from_s3(deploy_env, workflow_name, bucket)

    for run_results in run_results_list:
        statuses = _index_statuses(run_results)
        for unique_id in unique_ids:
            status = statuses.get(unique_id)
            # Only update if found and not already succeeded
            if status and last_status.get(unique_id) != "success":
                last_status[unique_id] = status

    missing: list[str] = []
    failed: list[tuple[str, str]] = []

    for unique_id in unique_ids:
        status = last_status.get(unique_id)
        if status is None:
            logging.error("%s -> not found", unique_id)
            missing.append(unique_id)
        elif status != "success":
            logging.error("%s -> %s", unique_id, status)
            failed.append((unique_id, status))

    if missing or failed:
        parts: list[str] = []
        if missing:
            parts.append(f"{len(missing)} missing")
        if failed:
            parts.append(f"{len(failed)} non-success")
        raise RuntimeError(
            f"{', '.join(parts)} out of {len(unique_ids)} unique_id(s) "
            f"(see ERROR lines above)."
        )

    print(f"All {len(unique_ids)} unique_id(s) finished with status=success.")


def assert_all_models_tests_success(
    bucket: str,
    deploy_env: str | None = None,
    workflow_name: str | None = None,
) -> None:
    """Assert that every model and test node in run_results finished with status 'success'."""
    if not deploy_env or not workflow_name:
        raise ValueError(
            "DEPLOY_ENV and WORKFLOW_NAME are required to locate run_results files."
        )

    run_results_list = _download_run_results_from_s3(deploy_env, workflow_name, bucket)

    # Build the final status for each model/test node across all run_results
    # files (later files override earlier ones, matching retry semantics).
    last_status: dict[str, str] = {}
    for run_results in run_results_list:
        for result in run_results.get("results", []):
            unique_id = result.get("unique_id", "")
            status = result.get("status")
            if unique_id.startswith(("model.", "test.")) and status:
                if last_status.get(unique_id) not in _ACCEPTABLE_STATUSES:
                    last_status[unique_id] = status

    if not last_status:
        raise RuntimeError(
            "No model or test nodes found in run_results. "
            "Check DEPLOY_ENV and WORKFLOW_NAME are correct."
        )

    failed: list[tuple[str, str]] = []
    for unique_id, status in sorted(last_status.items()):
        if status not in _ACCEPTABLE_STATUSES:
            logging.error("%s -> %s", unique_id, status)
            failed.append((unique_id, status))

    if failed:
        raise RuntimeError(
            f"{len(failed)} of {len(last_status)} model/test node(s) "
            f"did not finish successfully (see ERROR lines above)."
        )

    print(f"All {len(last_status)} model/test node(s) finished successfully.")


def main() -> int:
    """Parse inputs, load run_results data, and validate unique_id statuses."""
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(message)s",
    )
    logging.getLogger("boto3").setLevel(logging.WARNING)
    logging.getLogger("botocore").setLevel(logging.WARNING)
    logging.getLogger("urllib3").setLevel(logging.WARNING)
    logging.info("Starting check_run_results")
    parser = argparse.ArgumentParser(
        description=(
            "Check dbt run_results.json for specific unique_id statuses. "
            "Exits non-zero if any are missing or not success."
        )
    )
    parser.add_argument(
        "--unique-ids",
        dest="unique_ids",
        nargs="+",
        help=(
            "Unique ID(s) to check. You can pass multiple values or a comma-separated list."
        ),
    )
    parser.add_argument(
        "--unique-id-yaml",
        type=Path,
        help=(
            "Path to a YAML file containing models for a dataset. Uses "
            "DATASET_TARGET to select the name. Defaults to "
            "yaml cloned from repo if present. Mostly for local testing."
        ),
    )
    parser.add_argument(
        "--check-all-nodes",
        action="store_true",
        default=False,
        help=(
            "Instead of checking specific unique_ids, verify that every "
            "model and test node in run_results finished with status=success."
        ),
    )
    parser.add_argument(
        "--log-level",
        default="INFO",
        help="Logging level (default: INFO)",
    )

    args = parser.parse_args()
    logging.info("Parsed CLI arguments")

    logging.getLogger().setLevel(args.log_level.upper())
    logging.info("Configured log level: %s", args.log_level.upper())

    deploy_env = os.environ.get("DEPLOY_ENV")
    workflow_name = os.environ.get("WORKFLOW_NAME")
    bucket = os.environ.get("S3_BUCKET") or DEFAULT_S3_BUCKET
    logging.info(
        "Loaded env DEPLOY_ENV=%s WORKFLOW_NAME=%s S3_BUCKET=%s",
        deploy_env,
        workflow_name,
        bucket,
    )

    if args.check_all_nodes:
        logging.info("CHECK_ALL_NODES is enabled - validating all model and test nodes")
        assert_all_models_tests_success(
            bucket=bucket,
            deploy_env=deploy_env,
            workflow_name=workflow_name,
        )
        logging.info("Validation completed")
        return 0

    unique_ids: list[str] = []
    if args.unique_ids:
        unique_ids.extend(_parse_unique_ids(args.unique_ids))
    yaml_path = args.unique_id_yaml
    if not unique_ids and yaml_path is None and DEFAULT_UNIQUE_ID_YAML.exists():
        yaml_path = DEFAULT_UNIQUE_ID_YAML
        logging.info("Using default unique_id YAML path: %s", yaml_path)
    if not DEFAULT_UNIQUE_ID_YAML.exists():
        logging.info("YAML not found at default path: %s", DEFAULT_UNIQUE_ID_YAML)
    if yaml_path:
        dataset_target = os.environ.get("DATASET_TARGET")
        if not dataset_target:
            raise ValueError("DATASET_TARGET is required when using --unique-id-yaml.")
        unique_ids.extend(_parse_unique_ids_yaml(yaml_path, dataset_target))
    if not unique_ids:
        raise ValueError(
            "At least one unique_id is required via --unique-id or --unique-id-yaml."
        )
    logging.info("Resolved %d unique_id(s)", len(unique_ids))

    if deploy_env and deploy_env != "prod":
        logging.info(
            "Adjusted %d unique_id(s) for deploy_env=%s",
            len(unique_ids),
            deploy_env,
        )

    logging.info("Beginning run_results validation")
    assert_success(
        unique_ids,
        bucket=bucket,
        deploy_env=deploy_env,
        workflow_name=workflow_name,
    )
    logging.info("Validation completed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
