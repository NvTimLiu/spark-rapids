#!/bin/bash
#
# Copyright (c) 2020-2022, NVIDIA CORPORATION. All rights reserved.
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

# Argument(s):
#   SIGN_FILE:  true/false, whether to sign the jar/pom file to de deployed
#   DATABRICKS: true/fasle, whether deploying for databricks
#   VERSIONS_BUILT: The spark versions built before calling this script
#
# Used environment(s):
#   SQL_PL:         The path of module 'sql-plugin', relative to project root path.
#   DIST_PL:        The path of module 'dist', relative to project root path.
#   AGGREGATOR_PL:  The path of the module 'aggregator', relative to project root path.
#   TESTS_PL:       The path of the module 'integration_tests', relative to the project root path.
#   SERVER_ID:      The repository id for this deployment.
#   SERVER_URL:     The url where to deploy artifacts.
#   NVSEC_CFG_FILE: The nvsec credentials used to sign via 3S service, only required when <SIGN_FILE> is true.
#   FINAL_AGG_VERSION_TOBUILD: The spark version of the final build and aggregation.
###

set -ex
SIGN_FILE=$1
DATABRICKS=$2
VERSIONS_BUILT=$3

WORKSPACE=${WORKSPACE:-$(pwd)}
export M2DIR=${M2DIR:-"$WORKSPACE/.m2"}

###### Build the path of jar(s) to be deployed ######

cd $WORKSPACE

###### Databricks built tgz file so we need to untar and deploy from that
if [ "$DATABRICKS" == true ]; then
    rm -rf deploy
    mkdir -p deploy
    cd deploy
    tar -zxf ../spark-rapids-built.tgz
    cd spark-rapids
fi

ART_ID=`mvn help:evaluate -q -pl $DIST_PL -Dexpression=project.artifactId -DforceStdout`
ART_VER=`mvn help:evaluate -q -pl $DIST_PL -Dexpression=project.version -DforceStdout`
CUDA_CLASSIFIER=`mvn help:evaluate -q -pl $DIST_PL -Dexpression=cuda.version -DforceStdout`

FPATH="$DIST_PL/target/$ART_ID-$ART_VER-$CUDA_CLASSIFIER"
POM_FPATH="$DIST_PL/target/extra-resources/META-INF/maven/com.nvidia/$ART_ID/pom.xml"

echo "Plan to deploy ${FPATH}.jar to $SERVER_URL (ID:$SERVER_ID)"

FINAL_AGG_VERSION_TOBUILD=${FINAL_AGG_VERSION_TOBUILD:-'311'}

###### Deploy cmd ######
MVN="mvn -Dmaven.wagon.http.retryHandler.count=3 -DretryFailedDeploymentCount=3"
DEPLOY_CMD="$MVN -B deploy:deploy-file -Durl=$SERVER_URL -DrepositoryId=$SERVER_ID -s jenkins/settings.xml"
SIGN_CMD="nvsec sign --job-name 'Spark Jar Signing' --description 'Sign artifact with 3s'"
echo "Deploy CMD: $DEPLOY_CMD, sign CMD: $SIGN_CMD"

###### Deploy the parent pom file ######
if [ "$SIGN_FILE" == true ]; then
    # Apply nvsec configs
    cp $NVSEC_CFG_FILE ~/.nvsec.cfg
    $SIGN_CMD --file pom.xml --out-dir $(dirname pom.xml)
    $DEPLOY_CMD -Dfile=pom.xml-signature -Dpackaging=pom.asc -DpomFile=pom.xml
fi
$DEPLOY_CMD -Dfile=pom.xml -DpomFile=pom.xml

###### Deploy the artifact jar(s) ######
# No aggregated javadoc and sources for dist module, use 'sql-plugin' ones instead
SQL_ART_ID=`mvn help:evaluate -q -pl $SQL_PL -Dexpression=project.artifactId -DforceStdout`
SQL_ART_VER=`mvn help:evaluate -q -pl $SQL_PL -Dexpression=project.version -DforceStdout`
JS_FPATH="${SQL_PL}/target/spark${FINAL_AGG_VERSION_TOBUILD}/${SQL_ART_ID}-${SQL_ART_VER}"

if [ "$SIGN_FILE" == true ]; then
    $SIGN_CMD --file $FPATH.jar --out-dir $(dirname $FPATH.jar)
    $DEPLOY_CMD -Dfile=$FPATH.jar-signature -Dpackaging=jar.asc -DpomFile=$POM_FPATH
    $SIGN_CMD --file $POM_FPATH --out-dir $(dirname $POM_FPATH)
    $DEPLOY_CMD -Dfile=$POM_FPATH-signature -Dpackaging=pom.asc -DpomFile=$POM_FPATH
    SIGN_CLASS=sources
    $SIGN_CMD --file ${JS_FPATH}-$SIGN_CLASS.jar --out-dir $(dirname ${JS_FPATH}-$SIGN_CLASS.jar)
    $DEPLOY_CMD -Dfile=${JS_FPATH}-$SIGN_CLASS.jar-signature -Dclassifier=$SIGN_CLASS -Dpackaging=jar.asc -DpomFile=$POM_FPATH
    SIGN_CLASS=javadoc
    $SIGN_CMD --file ${JS_FPATH}-$SIGN_CLASS.jar --out-dir $(dirname ${JS_FPATH}-$SIGN_CLASS.jar)
    $DEPLOY_CMD -Dfile=${JS_FPATH}-$SIGN_CLASS.jar-signature -Dclassifier=$SIGN_CLASS -Dpackaging=jar.asc -DpomFile=$POM_FPATH
    SIGN_CLASS=$CUDA_CLASSIFIER
    # $FPATH.jar is aleady signed
    $DEPLOY_CMD -Dfile=$FPATH.jar-signature -Dclassifier=$SIGN_CLASS -Dpackaging=jar.asc -DpomFile=$POM_FPATH
fi
# Distribution jar is a shaded artifact so use the reduced dependency pom.
$DEPLOY_CMD -Dfile=$FPATH.jar \
            -DpomFile=$POM_FPATH \
            -Dsources=${JS_FPATH}-sources.jar \
            -Djavadoc=${JS_FPATH}-javadoc.jar \
            -Dfiles=$FPATH.jar \
            -Dtypes=jar \
            -Dclassifiers=$CUDA_CLASSIFIER

###### Deploy Spark 2.x explain meta jar ######
SPARK2_PL=${SPARK2_PL:-"spark2-sql-plugin"}
SPARK2_ART_ID=`mvn help:evaluate -q -pl $SPARK2_PL -Dexpression=project.artifactId -DforceStdout -Dbuildver=24X`
SPARK2_ART_VER=`mvn help:evaluate -q -pl $SPARK2_PL -Dexpression=project.version -DforceStdout -Dbuildver=24X`
SPARK2_FPATH="$M2DIR/com/nvidia/$SPARK2_ART_ID/$SPARK2_ART_VER/$SPARK2_ART_ID-$SPARK2_ART_VER"
# a bit ugly but just hardcode to spark24 for now since only version supported
SPARK2_CLASSIFIER='spark24'
# Oss requires a main jar file along with classifier jars
cp ${SPARK2_FPATH}-${SPARK2_CLASSIFIER}.jar ${SPARK2_FPATH}.jar
SPARK2_POM=${SPARK2_PL}/pom.xml

if [ "$SIGN_FILE" == true ]; then
    $SIGN_CMD --file $SPARK2_FPATH.jar --out-dir $(dirname $SPARK2_FPATH.jar)
    $DEPLOY_CMD -Dfile=$SPARK2_FPATH.jar-signature -Dpackaging=jar.asc -DpomFile=$SPARK2_POM
    $SIGN_CMD --file $SPARK2_POM --out-dir $(dirname $SPARK2_POM)
    $DEPLOY_CMD -Dfile=$SPARK2_POM-signature -Dpackaging=pom.asc -DpomFile=$SPARK2_POM
    SIGN_CLASS=sources
    $SIGN_CMD --file $SPARK2_FPATH-$SIGN_CLASS.jar --out-dir $(dirname $SPARK2_FPATH-$SIGN_CLASS.jar)
    $DEPLOY_CMD -Dfile=$SPARK2_FPATH-$SIGN_CLASS.jar-signature -Dclassifier=$SIGN_CLASS -Dpackaging=jar.asc -DpomFile=$SPARK2_POM
    SIGN_CLASS=javadoc
    $SIGN_CMD --file $SPARK2_FPATH-$SIGN_CLASS.jar --out-dir $(dirname $SPARK2_FPATH-$SIGN_CLASS.jar)
    $DEPLOY_CMD -Dfile=$SPARK2_FPATH-$SIGN_CLASS.jar-signature -Dclassifier=$SIGN_CLASS -Dpackaging=jar.asc -DpomFile=$SPARK2_POM
    SIGN_CLASS=$SPARK2_CLASSIFIER
    $SIGN_CMD --file $SPARK2_FPATH-$SIGN_CLASS.jar --out-dir $(dirname $SPARK2_FPATH-$SIGN_CLASS.jar)
    $DEPLOY_CMD -Dfile=$SPARK2_FPATH-$SIGN_CLASS.jar-signature -Dclassifier=$SIGN_CLASS -Dpackaging=jar.asc -DpomFile=$SPARK2_POM
fi
$DEPLOY_CMD -Dfile=${SPARK2_FPATH}.jar \
            -DpomFile=$SPARK2_POM \
            -Dsources=${SPARK2_FPATH}-sources.jar \
            -Djavadoc=${SPARK2_FPATH}-javadoc.jar \
            -Dfiles=${SPARK2_FPATH}-${SPARK2_CLASSIFIER}.jar \
            -Dtypes=jar \
            -Dclassifiers=$SPARK2_CLASSIFIER
