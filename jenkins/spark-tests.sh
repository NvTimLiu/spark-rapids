#!/bin/bash
#
# Copyright (c) 2019-2023, NVIDIA CORPORATION. All rights reserved.
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

set -ex

nvidia-smi

RAPIDS_INT_TESTS_HOME=jars/integration-tests
mkdir -p $RAPIDS_INT_TESTS_HOME
find jenkins/

pushd $RAPIDS_INT_TESTS_HOME

run_non_utc_time_zone_tests() {
  # select one time zone according to current day of week
  ABC="$(dirname "$0")"/test-timezones.sh
  DEF="$(realpath "$0")"/test-timezones.sh
  echo ABC: $ABC, DEF: $DEF 0 : $0
  echo $PWD
  ls -l $ABC || true
  ls -l $DEF || true
  source "$(dirname "$0")"/test-timezones.sh
}
run_non_utc_time_zone_tests
popd
