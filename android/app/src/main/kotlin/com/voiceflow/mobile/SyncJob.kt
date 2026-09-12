package com.voiceflow.mobile

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.Executors
import java.util.concurrent.Future

/** Persisted delivery for new changes, plus periodic catch-up from the Mac. */
class SyncJob : JobService() {
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private class Run(val params: JobParameters) { var future: Future<*>? = null }
    // JobService callbacks and completions touch this only on the main thread.
    private val runs = mutableMapOf<Int, Run>()

    override fun onStartJob(params: JobParameters): Boolean {
        val run = Run(params)
        runs.put(params.jobId, run)?.future?.cancel(true)
        run.future = executor.submit {
            val store = Store(applicationContext)
            val client = SyncClient(applicationContext, store, Keys(applicationContext))
            val retry = runCatching {
                if (!client.configured()) false
                else if (params.jobId == DELIVERY_ID && store.pendingSyncCount() == 0) false
                else {
                    client.sync(if (params.jobId == DELIVERY_ID) "delivery-job" else "periodic-job")
                    client.lastError != null || store.pendingSyncCount() > 0
                }
            }.getOrDefault(true)
            main.post {
                // An old, stopped attempt must never finish a replacement run.
                if (runs[params.jobId] === run) {
                    runs.remove(params.jobId)
                    Log.i("VoiceFlowSync", "job finished id=${params.jobId} retry=$retry")
                    jobFinished(params, retry)
                }
            }
        }
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        runs.remove(params.jobId)?.future?.cancel(true)
        Log.i("VoiceFlowSync", "job stopped id=${params.jobId}")
        return true
    }

    override fun onDestroy() {
        runs.values.forEach { it.future?.cancel(true) }
        runs.clear()
        executor.shutdownNow()
        super.onDestroy()
    }

    companion object {
        const val PERIODIC_ID = 8793
        const val DELIVERY_ID = 8794

        private fun builder(context: Context, id: Int) =
            JobInfo.Builder(id, ComponentName(context, SyncJob::class.java))
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                .setPersisted(true)
                .setBackoffCriteria(30_000, JobInfo.BACKOFF_POLICY_EXPONENTIAL)

        fun schedule(context: Context) {
            val scheduler = context.getSystemService(JobScheduler::class.java)
            if (scheduler.getPendingJob(PERIODIC_ID) != null) return
            val result = scheduler.schedule(builder(context, PERIODIC_ID)
                .setPeriodic(15 * 60 * 1000L)
                .build())
            Log.i("VoiceFlowSync", "scheduled periodic result=$result")
        }

        /** Call only for local edits, after saving them. Replacing the job is
         * intentional: a capture racing an upload must get its own attempt,
         * even if that upload was just about to finish. SyncMerge preserves it. */
        fun request(context: Context) {
            if (!context.getSharedPreferences("app", Context.MODE_PRIVATE).getBoolean("paired", false)) return
            val scheduler = context.getSystemService(JobScheduler::class.java)
            val job = builder(context, DELIVERY_ID)
            var result = if (Build.VERSION.SDK_INT >= 31)
                scheduler.schedule(job.setExpedited(true).build()) else JobScheduler.RESULT_FAILURE
            if (result != JobScheduler.RESULT_SUCCESS) {
                if (Build.VERSION.SDK_INT >= 31) job.setExpedited(false)
                result = scheduler.schedule(job.build())
            }
            Log.i("VoiceFlowSync", "scheduled delivery result=$result")
        }
    }
}
