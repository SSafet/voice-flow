package com.voiceflow.mobile

import android.animation.ValueAnimator
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.Toast
import java.io.File
import java.util.concurrent.Executors

/// The always-on floating bubble (ticket VF-51): a small draggable dot drawn
/// over every app — tap to dictate, tap again to stop, and the transcript
/// lands in whatever text field holds the cursor (InsertionService), with the
/// clipboard as fallback. A foreground service so it outlives the activity;
/// recordings ride the same queue → Transcriber pipeline as in-app takes
/// ("bubble" mode), so offline recordings survive and everything syncs.
class BubbleService : Service() {
    private enum class State { IDLE, RECORDING, TRANSCRIBING }

    private lateinit var store: Store
    private lateinit var keys: Keys
    private lateinit var syncClient: SyncClient
    private val recorder = Recorder()
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val prefs by lazy { getSharedPreferences("app", Context.MODE_PRIVATE) }

    private var wm: WindowManager? = null
    private var bubble: FrameLayout? = null
    private var dot: View? = null
    private lateinit var lp: WindowManager.LayoutParams
    private var state = State.IDLE
    private var pulse: ValueAnimator? = null
    private var netCallback: ConnectivityManager.NetworkCallback? = null

    private val accent = Color.parseColor("#E8A33D")
    private val red = Color.parseColor("#E25B55")

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        running = true
        store = Store(this)
        keys = Keys(this)
        syncClient = SyncClient(this, store, keys)
        startInForeground(recording = false)
        if (Settings.canDrawOverlays(this)) addBubble()
        val cm = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { executor.execute { drain(null) } }
        }
        cm.registerDefaultNetworkCallback(cb)
        netCallback = cb
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_HIDE) {
            prefs.edit().putBoolean("bubble_enabled", false).apply()
            stopSelf()
            return START_NOT_STICKY
        }
        if (intent?.action == ACTION_TOGGLE) {
            onBubbleTap()
            return START_STICKY
        }
        if (bubble == null && Settings.canDrawOverlays(this)) addBubble()
        // Catch up on anything queued offline. "fresh_id" (adb test seam —
        // the service is not exported) marks one queued item as
        // just-recorded so the insertion path is exercisable end to end.
        val freshId = intent?.getStringExtra("fresh_id")
        executor.execute { drain(freshId) }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        pulse?.cancel()
        recorder.stopQuietly()
        netCallback?.let {
            (getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager)
                .unregisterNetworkCallback(it)
        }
        bubble?.let { runCatching { wm?.removeView(it) } }
        bubble = null
        super.onDestroy()
    }

    // ══════════════════════ foreground plumbing ══════════════════════

    /// Foreground type juggling for Android 14+: the service lives as
    /// specialUse (bubble host) and only claims the microphone type for the
    /// span of a recording — claiming it up front would make background
    /// starts (boot, sticky restart) illegal.
    private fun startInForeground(recording: Boolean) {
        val notif = buildNotification()
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                if (recording) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                startForeground(NOTIF_ID, notif, type)
            } else {
                startForeground(NOTIF_ID, notif)
            }
        } catch (_: Exception) {
            // Type upgrade refused (edge OEM policies) — recording still
            // proceeds; the overlay-permission exemption covers mic access.
        }
    }

    private fun buildNotification(): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "Floating bubble", NotificationManager.IMPORTANCE_MIN))
        }
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val hide = PendingIntent.getService(
            this, 1, Intent(this, BubbleService::class.java).setAction(ACTION_HIDE),
            PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_mic)
            .setContentTitle("Dictation bubble is on")
            .setContentText("Tap the floating dot to dictate into any app")
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, "Hide", hide).build())
            .setOngoing(true)
            .build()
    }

    // ══════════════════════ the bubble ══════════════════════

    private fun addBubble() {
        val windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        wm = windowManager
        val size = dp(46)
        val view = FrameLayout(this)
        view.background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(Color.parseColor("#F01B1B20"))
            setStroke(dp(1), Color.parseColor("#33FFFFFF"))
        }
        val d = View(this).apply {
            background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(accent) }
        }
        view.addView(d, FrameLayout.LayoutParams(dp(12), dp(12), Gravity.CENTER))
        dot = d

        val dm = resources.displayMetrics
        lp = WindowManager.LayoutParams(
            size, size,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            // NOT_FOCUSABLE is load-bearing: tapping the bubble must not steal
            // input focus from the field the transcript will land in.
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT,
        )
        lp.gravity = Gravity.TOP or Gravity.START
        lp.x = prefs.getInt("bubble_x", dm.widthPixels - size - dp(4))
        lp.y = prefs.getInt("bubble_y", (dm.heightPixels * 0.38f).toInt())
        view.setOnTouchListener(DragTapListener(size))
        windowManager.addView(view, lp)
        bubble = view
    }

    /// Tap vs drag on one listener: past touch slop it's a drag (bubble
    /// follows the finger, snaps to the nearer side edge on release and the
    /// spot persists), under it it's a tap → toggle recording.
    private inner class DragTapListener(private val size: Int) : View.OnTouchListener {
        private val slop = ViewConfiguration.get(this@BubbleService).scaledTouchSlop
        private var startX = 0; private var startY = 0
        private var downRawX = 0f; private var downRawY = 0f
        private var dragging = false

        override fun onTouch(v: View, e: MotionEvent): Boolean {
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    startX = lp.x; startY = lp.y
                    downRawX = e.rawX; downRawY = e.rawY
                    dragging = false
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = e.rawX - downRawX; val dy = e.rawY - downRawY
                    if (dragging || dx * dx + dy * dy > slop * slop) {
                        dragging = true
                        lp.x = startX + dx.toInt()
                        lp.y = startY + dy.toInt()
                        wm?.updateViewLayout(v, lp)
                    }
                }
                MotionEvent.ACTION_UP -> {
                    if (!dragging) { onBubbleTap(); return true }
                    val dm = resources.displayMetrics
                    lp.x = if (lp.x + size / 2 < dm.widthPixels / 2) dp(4)
                        else dm.widthPixels - size - dp(4)
                    lp.y = lp.y.coerceIn(dp(4), dm.heightPixels - size - dp(4))
                    wm?.updateViewLayout(v, lp)
                    prefs.edit().putInt("bubble_x", lp.x).putInt("bubble_y", lp.y).apply()
                }
            }
            return true
        }
    }

    private fun onBubbleTap() {
        when (state) {
            State.RECORDING -> stopRecording()
            State.TRANSCRIBING -> {}          // hands off while a take is in flight
            State.IDLE -> startRecording()
        }
    }

    private fun setState(s: State) {
        state = s
        val d = dot ?: return
        pulse?.cancel(); pulse = null
        d.scaleX = 1f; d.scaleY = 1f; d.alpha = 1f
        (d.background as GradientDrawable).setColor(if (s == State.RECORDING) red else accent)
        when (s) {
            State.RECORDING -> pulse = ValueAnimator.ofFloat(1f, 1.6f).apply {
                duration = 520; repeatCount = ValueAnimator.INFINITE
                repeatMode = ValueAnimator.REVERSE
                addUpdateListener { a ->
                    val v = a.animatedValue as Float
                    d.scaleX = v; d.scaleY = v
                }
                start()
            }
            State.TRANSCRIBING -> pulse = ValueAnimator.ofFloat(1f, 0.25f).apply {
                duration = 340; repeatCount = ValueAnimator.INFINITE
                repeatMode = ValueAnimator.REVERSE
                addUpdateListener { a -> d.alpha = a.animatedValue as Float }
                start()
            }
            State.IDLE -> {}
        }
    }

    /// One bright expand-and-settle on the dot: the transcript went into the
    /// focused field, no toast needed.
    private fun flashInserted() {
        val d = dot ?: return
        ValueAnimator.ofFloat(2.2f, 1f).apply {
            duration = 450
            addUpdateListener { a ->
                val v = a.animatedValue as Float
                d.scaleX = v; d.scaleY = v
            }
            start()
        }
    }

    // ══════════════════════ record → transcribe → deliver ══════════════════════

    private fun startRecording() {
        if (checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED) {
            toast("Open Voice Flow once to grant microphone access")
            startActivity(Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            return
        }
        startInForeground(recording = true)
        try {
            recorder.start(store.audioDir)
            setState(State.RECORDING)
        } catch (e: Exception) {
            toast("Mic unavailable: ${e.message?.take(80)}")
            setState(State.IDLE)
            startInForeground(recording = false)
        }
    }

    private fun stopRecording() {
        val file = recorder.stop()
        startInForeground(recording = false)
        if (file == null) {
            setState(State.IDLE)
            toast("Too short — nothing captured")
            return
        }
        store.enqueue(QueueItem(file.name, file.absolutePath, "bubble",
            System.currentTimeMillis()))
        setState(State.TRANSCRIBING)
        val freshId = file.name
        executor.execute { drain(freshId) }
    }

    /// Drain "bubble" items from the shared queue (MainActivity's drain skips
    /// them while this service runs). Only the take the user just finished —
    /// freshId — goes through field insertion; older items recovered after an
    /// offline stretch land on the clipboard silently, because the field they
    /// were meant for is long gone.
    private fun drain(freshId: String?) {
        val pending = store.queue().filter { it.mode == "bubble" }
        if (pending.isEmpty()) { main.post { if (state == State.TRANSCRIBING) setState(State.IDLE) }; return }
        val openAIKey = keys.load(Keys.OPENAI)
        if (openAIKey.isNullOrBlank()) {
            main.post {
                setState(State.IDLE)
                if (freshId != null) toast("No API key yet — open Voice Flow and sync with the Mac")
            }
            return
        }
        for (item in pending) {
            val file = File(item.file)
            if (!file.exists()) { store.dequeue(item.id); continue }
            val raw = try {
                Transcriber.transcribe(file, openAIKey, syncClient.vocabulary())
            } catch (e: Net.HttpError) {
                main.post {
                    setState(State.IDLE)
                    if (freshId != null) toast("Transcription failed: ${e.message?.take(80)}")
                }
                if (e.code == 401 || e.code == 429) return
                store.dequeue(item.id); continue
            } catch (_: Exception) {
                main.post {
                    setState(State.IDLE)
                    if (freshId != null) toast("Offline — queued, lands on the clipboard when back")
                }
                return
            }
            val agentKey = keys.load(Keys.AGENT)
            val cleaned = if (prefs.getBoolean("cleanup_enabled", true) && !agentKey.isNullOrBlank())
                Transcriber.clean(raw, agentKey, syncClient.vocabulary()) else raw
            store.dequeue(item.id)
            if (cleaned.isBlank()) {
                main.post { setState(State.IDLE); if (freshId != null) toast("Nothing heard") }
                continue
            }
            store.addDictation(DictationEntry.now(cleaned, "pasted"))
            val insert = item.id == freshId
            main.post { deliver(cleaned, insert) }
            syncClient.sync()
        }
        main.post { if (state == State.TRANSCRIBING) setState(State.IDLE) }
    }

    private fun deliver(text: String, insert: Boolean) {
        setState(State.IDLE)
        if (insert && InsertionService.instance?.insert(text) == true) {
            flashInserted()
            return
        }
        val cm = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
        cm.setPrimaryClip(ClipData.newPlainText("dictation", text))
        if (insert) {
            toast(if (InsertionService.instance == null)
                "On clipboard — enable Voice Flow in Accessibility to auto-insert"
            else "On clipboard — no text field focused")
        }
    }

    private fun toast(msg: String) {
        main.post { Toast.makeText(this, msg, Toast.LENGTH_SHORT).show() }
    }

    companion object {
        @Volatile var running = false
            private set
        const val ACTION_HIDE = "com.voiceflow.mobile.HIDE_BUBBLE"
        const val ACTION_TOGGLE = "com.voiceflow.mobile.TOGGLE_BUBBLE_RECORDING"
        private const val CHANNEL = "bubble"
        private const val NOTIF_ID = 3
    }
}

/// Invisible trampoline behind the ".Dictate" assist alias (side-key long
/// press): with the bubble running it toggles bubble recording in place —
/// the frontmost app keeps focus, so the transcript still lands at the
/// cursor — and only without the bubble does it open the app to record,
/// as before. Theme.NoDisplay: nothing flashes on screen.
class DictateTrampoline : android.app.Activity() {
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        if (BubbleService.running) {
            startService(Intent(this, BubbleService::class.java)
                .setAction(BubbleService.ACTION_TOGGLE))
        } else {
            startActivity(Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra("start_recording", true))
        }
        finish()
    }
}

/// Restores the bubble after a reboot when it was on — "always on" should
/// survive the phone restarting without a trip into the app.
class BubbleBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        val prefs = context.getSharedPreferences("app", Context.MODE_PRIVATE)
        if (!prefs.getBoolean("bubble_enabled", false)) return
        if (!Settings.canDrawOverlays(context)) return
        context.startForegroundService(Intent(context, BubbleService::class.java))
    }
}
