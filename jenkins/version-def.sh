#!/bin/bash
#
# Copyright (c) 2020, NVIDIA CORPORATION. All rights reserved.
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

set -e

# Split abc=123 from $OVERWRITE_PARAMS
# $OVERWRITE_PARAMS patten 'abc=123;def=456;'
PRE_IFS=$IFS
IFS=";"
for VAR in $OVERWRITE_PARAMS;do
    echo $VAR && declare $VAR
done
IFS=$PRE_IFS

CUDF_VER=${CUDF_VER:-"0.15-SNAPSHOT"}
CUDA_CLASSIFIER=${CUDA_CLASSIFIER:-"cuda10-1"}
PROJECT_VER=${PROJECT_VER:-"0.2.0-SNAPSHOT"}
SPARK_VER=${SPARK_VER:-"3.0.0"}
SCALA_BINARY_VER=${SCALA_BINARY_VER:-"2.12"}
SERVER_URL=${SERVER_URL:-"https://urm.nvidia.com:443/artifactory/sw-spark-maven"}
SERVER_ID=${SERVER_ID:-"snapshots"}

# Turn off log out by 'off' parameter
if [ "$1" != "off" ]; then
    echo "CUDF_VER: $CUDF_VER, CUDA_CLASSIFIER: $CUDA_CLASSIFIER, PROJECT_VER: $PROJECT_VER \
        SPARK_VER: $SPARK_VER, SCALA_BINARY_VER: $SCALA_BINARY_VER, SERVER_URL: $SERVER_URL"
fi
