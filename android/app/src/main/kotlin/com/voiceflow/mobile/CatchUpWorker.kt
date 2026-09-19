package com.voiceflow.mobile

import android.content.Context
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequest
import androidx.work.OutOfQuotaPolicy
import androidx.work.PeriodicWorkRequest
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

/// Why a catch-up run was asked for: the network came back, a local edit was
/// saved, or the periodic fifteen-minute run came around (08 §3.9).
enum class CatchUpReason { NETWORK_RETURNED, LOCAL_CHANGE, PERIODIC }

/// What a reason means to WorkManager: one unique job, always waiting for the
/// network; expedited one-offs for a returning network and a local change; a
/// fifteen-minute periodic run otherwise.
data class CatchUpPlan(
    val uniqueName: String,
    val requiresNetwork: Boolean,
    val expedited: Boolean,
    val periodicMinutes: Int?,
)

/// The one owner of background catch-up. Every reason shares the one unique
/// work name, so a new ask replaces the run already queued instead of adding
/// a second.
object CatchUp {
    const val UNIQUE_NAME = "voiceflow-catch-up"
    const val PERIOD_MINUTES = 15

    fun plan(reason: CatchUpReason): CatchUpPlan = when (reason) {
        CatchUpReason.PERIODIC -> CatchUpPlan(
            uniqueName = UNIQUE_NAME,
            requiresNetwork = true,
            expedited = false,
            periodicMinutes = PERIOD_MINUTES,
        )
        CatchUpReason.NETWORK_RETURNED, CatchUpReason.LOCAL_CHANGE -> CatchUpPlan(
            uniqueName = UNIQUE_NAME,
            requiresNetwork = true,
            expedited = true,
            periodicMinutes = null,
        )
    }

    fun schedule(context: Context, reason: CatchUpReason) {
        val plan = plan(reason)
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()
        val manager = WorkManager.getInstance(context)
        if (plan.periodicMinutes != null) {
            val request = PeriodicWorkRequest.Builder(
                CatchUpWorker::class.java, plan.periodicMinutes.toLong(), TimeUnit.MINUTES,
            ).setConstraints(constraints).build()
            manager.enqueueUniquePeriodicWork(plan.uniqueName, ExistingPeriodicWorkPolicy.KEEP, request)
        } else {
            val builder = OneTimeWorkRequest.Builder(CatchUpWorker::class.java)
                .setConstraints(constraints)
            if (plan.expedited) {
                builder.setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            }
            manager.enqueueUniqueWork(plan.uniqueName, ExistingWorkPolicy.REPLACE, builder.build())
        }
    }
}

/// The WorkManager shell: hand the run to the same pipeline and cloud sync a
/// phone-side change uses, and ask for another attempt while work remains.
class CatchUpWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result =
        if (runCatching { CloudSync(applicationContext).catchUp() }.getOrDefault(true)) {
            Result.retry()
        } else {
            Result.success()
        }
}
