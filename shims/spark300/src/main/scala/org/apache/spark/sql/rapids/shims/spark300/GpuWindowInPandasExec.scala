/*
 * Copyright (c) 2020, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package org.apache.spark.sql.rapids.shims.spark300
//package org.apache.spark.sql.rapids.execution.python

import java.io.File

import com.nvidia.spark.rapids._
import com.nvidia.spark.rapids.python.PythonWorkerSemaphore
import scala.collection.JavaConverters._
import scala.collection.mutable.ArrayBuffer

import org.apache.spark.{SparkEnv, TaskContext}
import org.apache.spark.api.python.{ChainedPythonFunctions, PythonEvalType}
import org.apache.spark.rdd.RDD
import org.apache.spark.sql.catalyst.InternalRow
import org.apache.spark.sql.catalyst.expressions._
import org.apache.spark.sql.catalyst.plans.physical.{AllTuples, ClusteredDistribution,
  Distribution, Partitioning}
import org.apache.spark.sql.execution.{ExternalAppendOnlyUnsafeRowArray, SparkPlan}
import org.apache.spark.sql.execution.python._
import org.apache.spark.sql.execution.window._
import org.apache.spark.sql.rapids.execution.python._
import org.apache.spark.sql.types.{DataType, IntegerType, StructField, StructType}
import org.apache.spark.sql.util.ArrowUtils
import org.apache.spark.sql.vectorized.ColumnarBatch
import org.apache.spark.util.Utils

/*
 * WindowExecBase changes in Spark 3.1.0 so need to compile in Shim
 */
class GpuWindowInPandasExecMeta(
    winPandas: WindowInPandasExec,
    conf: RapidsConf,
    parent: Option[RapidsMeta[_, _, _]],
    rule: ConfKeysAndIncompat)
  extends SparkPlanMeta[WindowInPandasExec](winPandas, conf, parent, rule) {

  override def couldReplaceMessage: String = "could partially run on GPU"
  override def noReplacementPossibleMessage(reasons: String): String =
    s"cannot run even partially on the GPU because $reasons"

  // Ignore the expressions since columnar way is not supported yet
  override val childExprs: Seq[BaseExprMeta[_]] = Seq.empty

  override def convertToGpu(): GpuExec =
    GpuWindowInPandasExec(
      winPandas.windowExpression,
      winPandas.partitionSpec,
      winPandas.orderSpec,
      childPlans.head.convertIfNeeded()
    )
}

trait WindowExecBaseTrait extends WindowExecBase

case class GpuWindowInPandasExec(
    windowExpression: Seq[NamedExpression],
    partitionSpec: Seq[Expression],
    orderSpec: Seq[SortOrder],
    child: SparkPlan)
  extends WindowExecBase(windowExpression, partitionSpec, orderSpec, child) with GpuExec
/*GpuWindowInPandasExecBase(windowExpression, partitionSpec, orderSpec, child) with WindowExecBaseTrait*/
{
  protected override def doExecute(): RDD[InternalRow] = {
    throw new RuntimeException
  }
  override def output: Seq[Attribute] = Nil

}
