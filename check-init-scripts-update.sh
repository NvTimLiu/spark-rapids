#!/bin/bash

##
# Check if Dataproc init scripts get updated,
#   by comparing Google bucket init scripts with local bucket ones.
#
# Contrast to Google init scripts, local bucket ones changed as below:
#   1, Not installing release version of cudf/rapids/XGBoost jars,
#     because we run integration tests against SNAPSHOT jars in CI job.
#   2, Install pytest python modules to run rapids integration tests.
#
# Save diff log to tag updating init scripts into local bucket,
#   if Google init scripts got updated.
#
##
set -ex

SCRIPT_PATH=${SCRIPT_PATH:-'dataproc'}
INIT_UPDATE_LOG=${INIT_UPDATE_LOG:-'init_update.log'}

# Download from Google GS bucket, overwrite the local scripts
gsutil cp gs://goog-dataproc-initialization-actions-us-central1/rapids/rapids.sh $SCRIPT_PATH/rapids.sh
gsutil cp gs://goog-dataproc-initialization-actions-us-central1/gpu/install_gpu_driver.sh $SCRIPT_PATH/install_gpu_driver.sh

INSTALL_PYTEST="""\
# Install sre_yield and pytest to run rapids integration tests\n\
pip3 install pytest sre_yield\n\
"""
# Insert install CLI before "main"
INSERT_LINE=`grep -n "^main$" $SCRIPT_PATH/rapids.sh  | cut -f1 -d: `
sed -i "$INSERT_LINE i $INSTALL_PYTEST" $SCRIPT_PATH/rapids.sh

# Not install release version of cudf/rapids/XGBoost jars,
# because we run integration tests against SNAPSHOT jars
sed -i "/spark.submit.pyFiles=/d" $SCRIPT_PATH/rapids.sh
sed -i "/install_spark_rapids$/d" $SCRIPT_PATH/rapids.sh

# Compare Google's init scripts with local ones, save diff logs
git diff $SCRIPT_PATH/rapids.sh $SCRIPT_PATH/install_gpu_driver.sh | tee $INIT_UPDATE_LOG
