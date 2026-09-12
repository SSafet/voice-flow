package com.voiceflow.mobile

import android.content.Context
import android.os.Bundle
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.URL
import java.net.URLEncoder

/** Isolated synthetic-account entry points, compiled only into .syncqa. */
object CloudQAActions {
    fun run(context: Context, args: Bundle): JSONObject {
        check(context.packageName == "com.voiceflow.mobile.syncqa")
        val cloud = CloudSync(context)
        when (args.getString("action")) {
            "cloud-login" -> {
                val origin = args.getString("origin")!!
                check(origin.startsWith("http://127.0.0.1:"))
                val email = args.getString("email")!!; check(email.endsWith("@native-sync.fixture"))
                val api = CloudHTTP(origin, cloud.vault, allowLoopback = true)
                val challenge = api.start(email)
                val code = JSONObject(URL("$origin/fixture/code?email=${URLEncoder.encode(email, "UTF-8")}").readText()).getString("code")
                val credentials = api.complete(challenge, code, "Isolated Android QA")
                cloud.preferences.use(credentials); cloud.importLegacy()
            }
            "cloud-sync" -> cloud.sync("isolated-qa")
            "cloud-logout" -> { cloud.client().logout(); cloud.preferences.prefs.edit().putBoolean(cloud.preferences.statusKey("auth_required"), true).commit() }
            "cloud-seed-legacy" -> {
                check(cloud.preferences.partition == null)
                val count = args.getString("count")!!.toInt(); check(count in 1..5000)
                val values = JSONArray((0 until count).map { DictationEntry.now("Synthetic retained dictation $it " + "x".repeat(1000), "pasted").copy(id = "legacy-$it").toJson() })
                File(context.filesDir, "dictations.json").writeText(values.toString())
            }
            "cloud-edit" -> cloud.capture(listOf(CloudEdit(CloudCollection.DICTATIONS, args.getString("id")!!, CloudPayload.Dictation(args.getString("text")!!, "pasted"))))
            "cloud-capture" -> {
                Store(context).addDictation(DictationEntry.now(args.getString("text")!!, "pasted").copy(id = args.getString("id")!!))
                (context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as android.app.job.JobScheduler).cancelAll()
            }
            "cloud-delete" -> cloud.capture(listOf(CloudEdit(CloudCollection.DICTATIONS, args.getString("id")!!, null)))
            "cloud-restore" -> {
                val id = args.getString("id")!!; val row = cloud.state()!!.records["dictations:$id"]!!
                cloud.capture(listOf(CloudEdit(CloudCollection.DICTATIONS, id, row.lastLivePayload!!, restore = true)))
            }
            "cloud-select" -> cloud.preferences.setIncluded(args.getString("include")!!.split(',').filter { it.isNotBlank() }.map(CloudCollection::parse).toSet())
            "cloud-resolve" -> {
                val conflict = cloud.state()!!.conflicts.first { it.recordId == args.getString("id") }
                cloud.engine.resolve(conflict, cloud.client().record(conflict.collection, conflict.recordId), CloudResolution.valueOf(args.getString("choice")!!), cloud.preferences.partition!!)
            }
            "cloud-state" -> Unit
            else -> error("Unknown cloud QA action")
        }
        val state = cloud.state(); val row = state?.records?.get("dictations:${args.getString("id")}")
        return JSONObject().put("records", state?.records?.size ?: 0).put("pending", state?.pendingCount ?: 0).put("conflicts", state?.conflicts?.size ?: 0)
            .put("sequence", state?.appliedSequence).put("partition", cloud.preferences.partition).put("email", cloud.credentials()?.email)
            .put("deviceId", cloud.credentials()?.deviceId).put("configured", cloud.configured()).put("status", cloud.status()).put("more", cloud.hasDelivery())
            .put("selected", JSONArray(cloud.preferences.included().map { it.wire })).put("row", row?.json()).put("visibleCount", Store(context).dictations().size)
    }
}
