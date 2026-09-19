package com.voiceflow.mobile

import android.app.Application
import android.os.StrictMode
import android.util.Log
import java.util.concurrent.Executor

/**
 * Nothing touches disk or the network on the main thread. The two StrictMode
 * policies are decided here as plain data, so the decision is testable without
 * Android; [install] is the one line that hands them to the framework.
 *
 * A debug build dies on a violation; a release build detects the same work,
 * logs it, and reports it once per kind and site through [ViolationSink].
 */
object MainThreadGuard {

    private const val TAG = "VoiceFlow"
    private const val APP_PACKAGE_PREFIX = "com.voiceflow.mobile."
    private const val GUARD_CLASS = "com.voiceflow.mobile.MainThreadGuard"
    private const val SINK_CLASS = "com.voiceflow.mobile.ViolationSink"
    private const val UNKNOWN_SITE = "unknown"

    enum class Reaction { DEATH, LOG_AND_REPORT }

    data class ThreadPolicy(
        val detectDiskReads: Boolean,
        val detectDiskWrites: Boolean,
        val detectNetwork: Boolean,
        val reaction: Reaction,
    )

    data class VmPolicy(
        val detectLeakedClosableObjects: Boolean,
        val detectLeakedSqlLiteObjects: Boolean,
        val detectActivityLeaks: Boolean,
        val reaction: Reaction,
    )

    fun threadPolicyFor(debuggable: Boolean): ThreadPolicy = ThreadPolicy(
        detectDiskReads = true,
        detectDiskWrites = true,
        detectNetwork = true,
        reaction = reactionFor(debuggable),
    )

    fun vmPolicyFor(debuggable: Boolean): VmPolicy = VmPolicy(
        detectLeakedClosableObjects = true,
        detectLeakedSqlLiteObjects = true,
        detectActivityLeaks = true,
        reaction = reactionFor(debuggable),
    )

    private fun reactionFor(debuggable: Boolean): Reaction =
        if (debuggable) Reaction.DEATH else Reaction.LOG_AND_REPORT

    private val sink = ViolationSink()

    fun install(application: Application, debuggable: Boolean = BuildConfig.DEBUG) {
        val executor = application.mainExecutor
        StrictMode.setThreadPolicy(threadPolicyFor(debuggable).toStrictMode(executor))
        StrictMode.setVmPolicy(vmPolicyFor(debuggable).toStrictMode(executor))
    }

    private fun ThreadPolicy.toStrictMode(executor: Executor): StrictMode.ThreadPolicy {
        val builder = StrictMode.ThreadPolicy.Builder()
        if (detectDiskReads) builder.detectDiskReads()
        if (detectDiskWrites) builder.detectDiskWrites()
        if (detectNetwork) builder.detectNetwork()
        when (reaction) {
            Reaction.DEATH -> builder.penaltyDeath()
            Reaction.LOG_AND_REPORT -> builder.penaltyLog().penaltyListener(
                executor,
                StrictMode.OnThreadViolationListener { violation ->
                    report(violation.javaClass.simpleName, violation.stackTrace)
                },
            )
        }
        return builder.build()
    }

    private fun VmPolicy.toStrictMode(executor: Executor): StrictMode.VmPolicy {
        val builder = StrictMode.VmPolicy.Builder()
        if (detectLeakedClosableObjects) builder.detectLeakedClosableObjects()
        if (detectLeakedSqlLiteObjects) builder.detectLeakedSqlLiteObjects()
        if (detectActivityLeaks) builder.detectActivityLeaks()
        when (reaction) {
            Reaction.DEATH -> builder.penaltyDeath()
            Reaction.LOG_AND_REPORT -> builder.penaltyLog().penaltyListener(
                executor,
                StrictMode.OnVmViolationListener { violation ->
                    report(violation.javaClass.simpleName, violation.stackTrace)
                },
            )
        }
        return builder.build()
    }

    private fun report(kind: String, stack: Array<StackTraceElement>) {
        val line = sink.accept(kind, stack.toList())
        if (line != null) Log.w(TAG, line)
    }

    /**
     * One line per kind and site, and nothing for a repeat, so a violation
     * inside a tight loop is reported once instead of drowning the log.
     */
    internal fun siteOf(stack: List<StackTraceElement>): String {
        for (frame in stack) {
            val className = frame.className
            if (!className.startsWith(APP_PACKAGE_PREFIX)) continue
            if (className == GUARD_CLASS || className.startsWith("$GUARD_CLASS$")) continue
            if (className == SINK_CLASS || className.startsWith("$SINK_CLASS$")) continue
            return "$className.${frame.methodName}:${frame.lineNumber}"
        }
        return UNKNOWN_SITE
    }
}

class ViolationSink {

    private val seen = LinkedHashSet<String>()

    val reported: Set<String> get() = seen

    fun accept(kind: String, stack: List<StackTraceElement>): String? {
        val site = MainThreadGuard.siteOf(stack)
        if (!seen.add("$kind@$site")) return null
        return "$kind at $site"
    }
}
