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

package org.apache.spark.sql.rapids.execution.python

import ai.rapids.cudf.Cuda
import com.nvidia.spark.rapids.{GpuDeviceManager, RapidsConf}
import com.nvidia.spark.rapids.python.PythonConfEntries._

import org.apache.spark.{SparkConf, SparkEnv}
import org.apache.spark.api.python.ChainedPythonFunctions
import org.apache.spark.internal.Logging
import org.apache.spark.internal.config.{CPUS_PER_TASK, EXECUTOR_CORES}
import org.apache.spark.internal.config.Python._

object GpuPythonHelper extends Logging {

  private val sparkConf = SparkEnv.get.conf
  private lazy val rapidsConf = new RapidsConf(sparkConf)
  private lazy val isPythonOnGpuEnabled = rapidsConf.get(PYTHON_GPU_ENABLED)
  private lazy val gpuId = GpuDeviceManager.getDeviceId()
    .getOrElse(throw new IllegalStateException("No gpu id!"))
    .toString
  private lazy val isPythonPooledMemEnabled = rapidsConf.get(PYTHON_POOLED_MEM)
    .getOrElse(rapidsConf.isPooledMemEnabled)
    .toString
  private lazy val isPythonUvmEnabled = rapidsConf.get(PYTHON_UVM_ENABLED)
    .getOrElse(rapidsConf.isUvmEnabled)
    .toString
  private lazy val (initAllocPerWorker, maxAllocPerWorker) = {
    val info = Cuda.memGetInfo()
    val maxFactionTotal = rapidsConf.get(PYTHON_RMM_MAX_ALLOC_FRACTION)
    val maxAllocTotal = (maxFactionTotal * info.total).toLong
    // Initialize pool size for all pythons workers. If the fraction is not set,
    // use half of the free memory as default.
    val initAllocTotal = rapidsConf.get(PYTHON_RMM_ALLOC_FRACTION)
      .map { fraction =>
        if (0 < maxFactionTotal && maxFactionTotal < fraction) {
          throw new IllegalArgumentException(s"The value of '$PYTHON_RMM_MAX_ALLOC_FRACTION' " +
            s"should not be less than that of '$PYTHON_RMM_ALLOC_FRACTION', but found " +
            s"$maxFactionTotal < $fraction")
        }
        (fraction * info.total).toLong
      }
      .getOrElse((0.5 * info.free).toLong)
    if (initAllocTotal > info.free) {
      logWarning(s"Initial RMM allocation(${initAllocTotal / 1024.0 / 1024} MB) for " +
        s"all the Python workers is larger than free memory(${info.free / 1024.0 / 1024} MB)")
    } else {
      logDebug(s"Configure ${initAllocTotal / 1024.0 / 1024}MB GPU memory for " +
        s"all the Python workers.")
    }

    // Calculate the pool size for each Python worker.
    val concurrentPythonWorkers = rapidsConf.get(CONCURRENT_PYTHON_WORKERS)
    if (0 < concurrentPythonWorkers) {
      (initAllocTotal / concurrentPythonWorkers, maxAllocTotal / concurrentPythonWorkers)
    } else {
      // When semaphore is disabled or invalid, use the number of cpu task slots instead.
      // Spark does not throw exception even the value of CPUS_PER_TASK is negative, so
      // return 1 if it is less than zero to continue the task.
      val cpuTaskSlots = sparkConf.get(EXECUTOR_CORES) / Math.max(1, sparkConf.get(CPUS_PER_TASK))
      (initAllocTotal / cpuTaskSlots, maxAllocTotal / cpuTaskSlots)
    }
  }

  // Called in each task at the executor side
  def injectGpuInfo(funcs: Seq[ChainedPythonFunctions]): Unit = {
    if (isPythonOnGpuEnabled) {
      // Insert GPU related env(s) into `envVars` for all the PythonFunction(s).
      // Yes `PythonRunner` will only use the first one, but just make sure it will
      // take effect no matter the order changes or not.
      funcs.foreach(_.funcs.foreach { pyF =>
        pyF.envVars.put("CUDA_VISIBLE_DEVICES", gpuId)
        pyF.envVars.put("RAPIDS_UVM_ENABLED", isPythonUvmEnabled)
        pyF.envVars.put("RAPIDS_POOLED_MEM_ENABLED", isPythonPooledMemEnabled)
        pyF.envVars.put("RAPIDS_POOLED_MEM_SIZE", initAllocPerWorker.toString)
        pyF.envVars.put("RAPIDS_POOLED_MEM_MAX_SIZE", maxAllocPerWorker.toString)
      })
    }
  }

  // Check the related conf(s) to launch our rapids daemon or worker for
  // the GPU initialization.
  // - python worker module if useDaemon is false, otherwise
  // - python daemon module.
  // This is called at driver side
  def checkPythonConfigs(conf: SparkConf): Unit = {
    val isPythonOnGpuEnabled = new RapidsConf(conf).get(PYTHON_GPU_ENABLED)
    if (isPythonOnGpuEnabled) {
      val useDaemon = {
        val useDaemonEnabled = conf.get(PYTHON_USE_DAEMON)
        // This flag is ignored on Windows as it's unable to fork.
        !System.getProperty("os.name").startsWith("Windows") && useDaemonEnabled
      }
      if (useDaemon) {
        if (conf.get(PYTHON_WORKER_REUSE)) {
          logWarning(s"Setting '${PYTHON_WORKER_REUSE.key}' to false is recommended when" +
            s" running Pandas UDF on the GPU, but found it is set to true, making the GPU memory" +
            s" may not be released in time." )
        }
        val oDaemon = conf.get(PYTHON_DAEMON_MODULE)
        if (oDaemon.nonEmpty) {
          val daemon = oDaemon.get
          if (daemon != "rapids.daemon") {
            throw new IllegalArgumentException("Python daemon module config conflicts." +
              s" Expect 'rapids.daemon' but set to $daemon")
          }
        } else {
          // Set daemon only when not specified
          conf.set(PYTHON_DAEMON_MODULE, "rapids.daemon")
        }
      } else {
        val oWorker = conf.get(PYTHON_WORKER_MODULE)
        if (oWorker.nonEmpty) {
          val worker = oWorker.get
          if (worker != "rapids.worker") {
            throw new IllegalArgumentException("Python worker module config conflicts." +
              s" Expect 'rapids.worker' but set to $worker")
          }
        } else {
          // Set worker only when not specified
          conf.set(PYTHON_WORKER_MODULE, "rapids.worker")
        }
      }
    }
  }
}
