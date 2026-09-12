package com.voiceflow.mobile

import android.app.Activity
import android.app.Instrumentation
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Bundle
import org.json.JSONArray

/** QA-only entry points: no UI, transcription/provider calls, or real pairing.
 * The Python driver observes actual Android-scheduled delivery on the server. */
class SyncQADriver : Instrumentation() {
    private lateinit var args: Bundle
    override fun onCreate(arguments: Bundle) { args = arguments; start() }

    override fun onStart() {
        try {
            val context = targetContext
            check(context.packageName == "com.voiceflow.mobile.syncqa")
            if (args.getString("action")?.startsWith("cloud-") == true) {
                val result = CloudQAActions.run(context, args)
                finish(Activity.RESULT_OK, Bundle().apply { putString("stream", "PASS\nCLOUD_JSON:" + result.toString()) })
                return
            }
            val store = Store(context)
            when (args.getString("action")) {
                "configure" -> {
                    Keys(context).save(Keys.SYNC_TOKEN, args.getString("token")!!)
                    // Instrumentation exits its process immediately; flush
                    // the async production preference write before finishing.
                    context.getSharedPreferences("secrets", Context.MODE_PRIVATE).edit().commit()
                    context.getSharedPreferences("app", Context.MODE_PRIVATE).edit()
                        .putBoolean("paired", true)
                        .putString("sync_hosts", JSONArray(listOf(args.getString("host")!!)).toString())
                        .putString("sync_port", args.getString("port")!!)
                        .putString("mac_name", "Isolated sync QA server")
                        .commit()
                }
                "capture" -> store.addDictation(entry())
                "continue" -> check(store.appendToDictation(args.getString("id")!!, "continued"))
                // Seed finished/offline work without scheduling it, then let
                // the real bubble startup/connectivity callback recover it.
                "seed" -> synchronized(Store.lock) {
                    val entries = store.dictations()
                    entries.add(0, entry())
                    store.saveDictations(entries)
                }
                else -> error("Unknown QA action")
            }
            finish(Activity.RESULT_OK, Bundle().apply { putString("stream", "PASS") })
        } catch (error: Throwable) {
            finish(Activity.RESULT_CANCELED, Bundle().apply {
                putString("stream", "FAIL: ${error.javaClass.simpleName}: ${error.message}")
            })
        }
    }

    private fun entry() = DictationEntry.now("Automatic sync QA", "pasted")
        .copy(id = args.getString("id")!!)
}

/** Seed a finished transcript without restarting the running bubble or
 * scheduling a job. Only its existing connectivity callback may pick it up. */
class SyncQASeedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        check(context.packageName == "com.voiceflow.mobile.syncqa")
        val store = Store(context)
        synchronized(Store.lock) {
            val entries = store.dictations()
            entries.add(0, DictationEntry.now("Wi-Fi reconnect QA", "pasted")
                .copy(id = intent.getStringExtra("id")!!))
            store.saveDictations(entries)
        }
        resultCode = Activity.RESULT_OK
    }
}
