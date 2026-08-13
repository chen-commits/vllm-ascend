#!/usr/bin/env bash
set -eo pipefail

export BENCHMARK_HOME=/usr/local/python3.11.10/lib/python3.11/site-packages

export TEST_ROOT=/mnt/share/c00893695/blue
export PYTHONPATH="${TEST_ROOT}:${PYTHONPATH:-}"

export CONFIG_BASE_PATH="${TEST_ROOT}/tests/e2e/nightly/single_node/models/configs"
export VLLM_ASCEND_DATASET_CACHE=/mnt/share/c00893695/dataset

export HF_HUB_OFFLINE=1
export VLLM_USE_MODELSCOPE=True
export VLLM_ENGINE_READY_TIMEOUT_S=1800
export VLLM_WORKER_MULTIPROC_METHOD=spawn

export VLLM_CI_RUNNER=local-a3-16

BATCH_TIME="$(date +%Y%m%d_%H%M%S)"
export LOG_DIR="/mnt/share/c00893695/single_node_a3_batch_${BATCH_TIME}"

TEST_PATH="tests/e2e/nightly/single_node/models/scripts/test_single_node.py"
NIGHTLY_MATRIX="${TEST_ROOT}/.github/workflows/configs/nightly_config.yaml"
SUMMARY_FILE="${LOG_DIR}/summary.txt"

source /usr/local/Ascend/ascend-toolkit/set_env.sh
source /usr/local/Ascend/nnal/atb/set_env.sh

mkdir -p "${LOG_DIR}"
mkdir -p "${VLLM_ASCEND_DATASET_CACHE}"

cd "${TEST_ROOT}"

# 只提取 nightly_config.yaml 中 A3 single-node 矩阵里的用例。
mapfile -t CONFIG_FILES < <(
    python3 - "${NIGHTLY_MATRIX}" "${CONFIG_BASE_PATH}" <<'PY'
import sys
from pathlib import Path

import yaml

matrix_path = Path(sys.argv[1])
config_base_path = Path(sys.argv[2])

with matrix_path.open(encoding="utf-8") as f:
    matrix = yaml.safe_load(f)

test_configs = (
    matrix.get("a3", {})
    .get("single_node", {})
    .get("test_config", [])
)

for case in test_configs:
    print(config_base_path / case["config_file_path"])
PY
)

TOTAL_COUNT="${#CONFIG_FILES[@]}"
PASS_COUNT=0
FAIL_COUNT=0

{
    echo "Nightly A3 single-node batch test"
    echo "开始时间：$(date '+%F %T')"
    echo "配置目录：${CONFIG_BASE_PATH}"
    echo "用例数量：${TOTAL_COUNT}"
    echo "日志目录：${LOG_DIR}"
    echo
} | tee "${SUMMARY_FILE}"

for CONFIG_FILE in "${CONFIG_FILES[@]}"; do
    CONFIG_NAME="$(basename "${CONFIG_FILE}")"
    CASE_NAME="${CONFIG_NAME%.yaml}"
    CASE_LOG="${LOG_DIR}/${CASE_NAME}.log"

    export CONFIG_YAML_PATH="${CONFIG_NAME}"
    export BENCHMARK_JOB_NAME="local-a3-${CASE_NAME}"

    echo
    echo "============================================================"
    echo "执行 A3 用例：${CONFIG_NAME}"
    echo "日志文件：${CASE_LOG}"
    echo "开始时间：$(date '+%F %T')"
    echo "============================================================"

    START_TIME="$(date +%s)"

    if pytest -sv --show-capture=no \
        "${TEST_PATH}" \
        2>&1 | tee "${CASE_LOG}"
    then
        RESULT="PASS"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        RESULT="FAIL"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    END_TIME="$(date +%s)"
    ELAPSED_SECONDS=$((END_TIME - START_TIME))

    printf '%-6s %-60s %8ss\n' \
        "${RESULT}" \
        "${CONFIG_NAME}" \
        "${ELAPSED_SECONDS}" |
        tee -a "${SUMMARY_FILE}"

    sleep 5
done

{
    echo
    echo "============================================================"
    echo "Nightly A3 single-node 用例执行结束"
    echo "结束时间：$(date '+%F %T')"
    echo "总数：${TOTAL_COUNT}"
    echo "成功：${PASS_COUNT}"
    echo "失败：${FAIL_COUNT}"
    echo "日志目录：${LOG_DIR}"
    echo "汇总文件：${SUMMARY_FILE}"
    echo "============================================================"
} | tee -a "${SUMMARY_FILE}"

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    exit 1
fi