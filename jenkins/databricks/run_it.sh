#!/bin/bash
#
# Copyright (c) 2022-2026, NVIDIA CORPORATION. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Run integration testing individually by setting environment variable:
#   TEST=xxx
# or
#   TEST_TAGS=xxx
# More details please refer to './integration_tests/run_pyspark_from_build.sh'.
# Note, 'setup.sh' should be executed first to setup proper environment.
#
# This file runs pytests with Jenkins parallel jobs.

set -xe

# 'setup.sh' already be executed before running this script
db_script_path="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
# Init common variables like SPARK_HOME, spark configs
source $db_script_path/common_vars.sh

# Disable parallel test as multiple tests would be executed by leveraging external parallelism, e.g. Jenkins parallelism
export TEST_PARALLEL=${TEST_PARALLEL:-0}

list_python_gateway_pids() {
  command -v pgrep >/dev/null 2>&1 || return
  pgrep -f 'org.apache.spark.api.python.PythonGatewayServer' || true
}

is_python_gateway_pid() {
  [[ -r "/proc/$1/cmdline" ]] && \
    tr '\0' ' ' < "/proc/$1/cmdline" | \
      grep -Fq 'org.apache.spark.api.python.PythonGatewayServer'
}

check_gpu_health() {
  local gpu_health

  if ! gpu_health=$(nvidia-smi -q 2>&1); then
    echo "nvidia-smi failed before the integration test"
    echo "$gpu_health"
    return 1
  fi

  echo "$gpu_health" | grep -E 'Product Name|Addressing Mode|VBIOS Version'
  if echo "$gpu_health" | \
      grep -qiE 'Addressing Mode[[:space:]]*:[[:space:]]*Unknown Error|VBIOS Version[[:space:]]*:[[:space:]]*00[.]00[.]00[.]00[.]00'; then
    echo "GPU health check detected an unusable device"
    return 1
  fi
}

dump_failure_diagnostics() {
  echo "==================== DATABRICKS IT FAILURE DIAGNOSTICS ===================="
  date -u
  uname -a
  id
  umask

  echo "-------------------- FILESYSTEM AND MEMORY --------------------"
  ls -ld /tmp "${TMPDIR:-/tmp}" "$PWD"
  df -h / /tmp "$PWD"
  df -i / /tmp "$PWD"
  free -h
  cat /proc/self/cgroup
  grep -E '^(MemAvailable|MemFree|SwapFree|CommitLimit|Committed_AS):' /proc/meminfo

  echo "-------------------- GPU --------------------"
  nvidia-smi

  echo "-------------------- TEST ARTIFACT FINGERPRINTS --------------------"
  artifact_dir=${LOCAL_JAR_PATH:-/home/ubuntu}
  find "$artifact_dir" -maxdepth 1 -type f \
    \( -name 'rapids-4-spark*.jar' -o -name 'parquet-hadoop*.jar' \) \
    -print0 | sort -z | while IFS= read -r -d '' artifact; do
      stat -c '%n size=%s bytes modified=%y' "$artifact"
      sha256sum "$artifact"
  done

  echo "-------------------- SPARK AND PYTEST PROCESSES --------------------"
  # Avoid printing process arguments because they may contain credentials.
  ps -eo pid,ppid,stat,etime,rss,comm | grep -E 'java|python|spark'

  if command -v jps >/dev/null 2>&1; then
    jps -l
    if command -v jstack >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
      while read -r gateway_pid; do
        [[ -n "$gateway_pid" ]] || continue
        echo "=== PythonGatewayServer JVM thread dump: pid=$gateway_pid ==="
        timeout 5s jstack -l "$gateway_pid" | tail -n 400
      done < <(list_python_gateway_pids)
    fi
  fi

  echo "-------------------- PYTEST WORKER LOGS --------------------"
  find integration_tests/target -maxdepth 3 -type f -name '*_worker_logs.log' \
    -print0 | sort -z | while IFS= read -r -d '' worker_log; do
      echo "=== $worker_log (tail -n 400) ==="
      tail -n 400 "$worker_log"
  done

  echo "-------------------- RECENT KERNEL MESSAGES --------------------"
  dmesg -T | tail -n 200
  echo "================== END DATABRICKS IT FAILURE DIAGNOSTICS =================="
}

terminate_test_gateways() {
  local gateway_pid
  local gateway_pids=()
  local remaining_pids=()

  while read -r gateway_pid; do
    [[ -n "$gateway_pid" ]] || continue
    if [[ " $initial_gateway_pids " == *" $gateway_pid "* ]]; then
      echo "Leaving pre-existing PythonGatewayServer running: pid=$gateway_pid"
    else
      gateway_pids+=("$gateway_pid")
    fi
  done < <(list_python_gateway_pids)

  if [[ ${#gateway_pids[@]} -eq 0 ]]; then
    echo "No test-created PythonGatewayServer processes remain"
    return
  fi

  echo "Terminating test-created PythonGatewayServer processes: ${gateway_pids[*]}"
  kill -TERM "${gateway_pids[@]}"

  for _ in $(seq 1 15); do
    remaining_pids=()
    for gateway_pid in "${gateway_pids[@]}"; do
      if kill -0 "$gateway_pid" 2>/dev/null && is_python_gateway_pid "$gateway_pid"; then
        remaining_pids+=("$gateway_pid")
      fi
    done
    [[ ${#remaining_pids[@]} -eq 0 ]] && return
    sleep 1
  done

  echo "Force-killing unresponsive PythonGatewayServer processes: ${remaining_pids[*]}"
  kill -KILL "${remaining_pids[@]}"
}

initial_gateway_pids=$(list_python_gateway_pids | tr '\n' ' ')

if ! check_gpu_health; then
  dump_failure_diagnostics
  exit 1
fi

set +e
# Run integration testing
./integration_tests/run_pyspark_from_build.sh --runtime_env='databricks' --test_type=$TEST_TYPE
ret=$?
if [[ "$ret" -ne 0 ]]; then
  # Diagnostics are best-effort and must not replace the original pytest exit code.
  dump_failure_diagnostics
  terminate_test_gateways
fi
set -e
if [ "$ret" = 5 ]; then
  # avoid exit script w/ code 5 when the cases are skipped in specific test
  echo "Suppress Exit code 5: No tests were collected"
  exit 0
fi
exit "$ret"
