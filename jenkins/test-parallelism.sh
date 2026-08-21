#!/bin/bash
#
# Copyright (c) 2026, NVIDIA CORPORATION. All rights reserved.
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

# Worker-sizing policy from integration_tests/run_pyspark_from_build.sh. Memory values are in MiB.
readonly TP_HOST_WORKER_MIB=8192
readonly TP_GPU_RESERVE_MIB=2048
readonly TP_GPU_WORKER_MIB=2286

# Return usable host memory in MiB, capped by the remaining cgroup memory.
# Example: 64 GiB host available, 20 GiB cgroup headroom -> 20480.
_host_memory_mib() {
  local available headroom
  local limit="" usage=""

  available=$(awk '/MemAvailable/ {print int($2 / 1024); exit}' /proc/meminfo 2>/dev/null || true)
  [[ "$available" =~ ^[0-9]+$ ]] || available=0

  if [[ -r /sys/fs/cgroup/memory.max && -r /sys/fs/cgroup/memory.current ]]; then
    limit=$(</sys/fs/cgroup/memory.max)
    usage=$(</sys/fs/cgroup/memory.current)
  elif [[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes &&
          -r /sys/fs/cgroup/memory/memory.usage_in_bytes ]]; then
    limit=$(</sys/fs/cgroup/memory/memory.limit_in_bytes)
    usage=$(</sys/fs/cgroup/memory/memory.usage_in_bytes)
  fi

  if [[ "$limit" =~ ^[0-9]+$ && "$usage" =~ ^[0-9]+$ ]] && (( limit < 2 ** 60 )); then
    headroom=$(((limit - usage) / 1024 / 1024))
    (( headroom < 0 )) && headroom=0
    (( headroom < available )) && available=$headroom
  fi

  echo "$available"
}

# Return usable CPU slots, honoring both CPU affinity and cgroup quotas.
# Example: nproc reports 16 but the cgroup quota is 8 CPUs -> 8.
_cpu_slots() {
  local slots quota_slots
  local quota=0 period=0

  slots=$(nproc 2>/dev/null || echo 1)
  [[ "$slots" =~ ^[1-9][0-9]*$ ]] || slots=1

  if [[ -r /sys/fs/cgroup/cpu.max ]]; then
    read -r quota period < /sys/fs/cgroup/cpu.max
  elif [[ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us &&
          -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]]; then
    quota=$(</sys/fs/cgroup/cpu/cpu.cfs_quota_us)
    period=$(</sys/fs/cgroup/cpu/cpu.cfs_period_us)
  fi

  if [[ "$quota" =~ ^[0-9]+$ && "$period" =~ ^[0-9]+$ ]] && (( period > 0 )); then
    quota_slots=$((quota / period))
    (( quota_slots > 0 )) || quota_slots=1
    (( quota_slots < slots )) && slots=$quota_slots
  fi

  echo "$slots"
}

# Return the most free memory, in MiB, found on any visible GPU.
# Example: GPUs have 8192 and 24576 MiB free -> 24576.
_gpu_memory_mib() {
  nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | \
    awk '{if ($1 > max) {max = $1}} END {print int(max)}'
}

# Convert a resource amount to workers after subtracting its reserve.
# Example: _worker_count 24576 2048 2286 -> 9 workers.
_worker_count() {
  local workers=$((($1 - $2) / $3))
  (( workers > 0 )) && echo "$workers" || echo 1
}

# Use the smallest CPU, host-memory, and GPU-memory worker count, then account
# for the number of GPU JVMs per worker. Example: min(16, 6, 9) / 2 -> 3.
detect_test_parallelism() {
  local cpu host gpu cpu_workers host_workers gpu_workers candidate
  local gpu_jvms=1
  local parallelism

  cpu=$(_cpu_slots)
  host=$(_host_memory_mib)
  gpu=$(_gpu_memory_mib)
  cpu_workers=$(_worker_count "$cpu" 0 1)
  host_workers=$(_worker_count "$host" 0 "$TP_HOST_WORKER_MIB")
  gpu_workers=$(_worker_count "$gpu" "$TP_GPU_RESERVE_MIB" "$TP_GPU_WORKER_MIB")

  parallelism=$cpu_workers
  for candidate in "$host_workers" "$gpu_workers"; do
    (( candidate < parallelism )) && parallelism=$candidate
  done

  if [[ "${NUM_LOCAL_EXECS:-}" =~ ^[1-9][0-9]*$ ]]; then
    gpu_jvms=$NUM_LOCAL_EXECS
  elif [[ "${PYSP_TEST_spark_cores_max:-}" =~ ^[1-9][0-9]*$ &&
          "${PYSP_TEST_spark_executor_cores:-}" =~ ^[1-9][0-9]*$ ]]; then
    gpu_jvms=$((PYSP_TEST_spark_cores_max / PYSP_TEST_spark_executor_cores))
    (( gpu_jvms > 0 )) || gpu_jvms=1
  fi

  parallelism=$((parallelism / gpu_jvms))
  (( parallelism > 0 )) || parallelism=1

  printf 'Auto test parallelism: %d workers (CPU=%d, host=%dMiB, GPU=%dMiB, GPU JVMs=%d)\n' \
    "$parallelism" "$cpu" "$host" "$gpu" "$gpu_jvms" >&2
  echo "$parallelism"
}
