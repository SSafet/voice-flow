package com.voiceflow.mobile

import android.app.Application
import android.os.StrictMode
import android.util.Log
import java.util.concurrent.ConcurrentHashMap
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

    /**
     * [lift], then [block], then [restore] — whatever [block] does: return,
     * throw, or return out of the caller.
     *
     * A lifted policy that is never put back would leave the thread unguarded
     * for the rest of the process, so putting it back is the part worth
     * proving. It is a parameter rather than a call so that a test can prove it
     * without Android's own `StrictMode`, which no unit test can reach.
     */
    inline fun <Token, T> restoring(lift: () -> Token, restore: (Token) -> Unit, block: () -> T): T {
        val token = lift()
        try {
            return block()
        } finally {
            restore(token)
        }
    }

    /**
     * Runs [block] with disk detection lifted on the calling thread, and puts
     * the policy back afterwards. Network detection is never lifted.
     *
     * P1 removes nothing, so every surface P4 and P6 replace still reads and
     * writes on the main thread: the history and chat lists, the preferences
     * and keys each surface opens, the bubble's own recording path, the
     * settings screen. A debug build dies on the first of those, which would
     * make the guard impossible to ship before those surfaces are gone. Each
     * of them says so here instead, so the exemption is one greppable name
     * with a delete date rather than a weakened policy: the guard still kills
     * a debug build for any code that does not name itself here.
     */
    inline fun <T> allowingDisk(block: () -> T): T = restoring(
        { StrictMode.allowThreadDiskWrites() },
        { StrictMode.setThreadPolicy(it) },
        block,
    )

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

    /** One sink serves the whole process, and a penalty listener runs on whichever
     * executor installed it, so the membership test and the insertion are one
     * atomic step rather than two that a second thread can slip between. */
    private val seen: MutableSet<String> = ConcurrentHashMap.newKeySet()

    /** What has been reported so far. A copy: the sink's own set is nobody else's
     * to clear, and a caller holding this must not watch it grow. */
    val reported: Set<String> get() = seen.toSet()

    fun accept(kind: String, stack: List<StackTraceElement>): String? {
        val site = MainThreadGuard.siteOf(stack)
        if (!seen.add("$kind@$site")) return null
        return "$kind at $site"
    }
}
