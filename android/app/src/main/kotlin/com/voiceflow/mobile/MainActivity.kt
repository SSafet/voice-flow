package com.voiceflow.mobile

import android.Manifest
import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.content.res.ColorStateList
import android.net.ConnectivityManager
import android.net.Network
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.util.Base64
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class MainActivity : Activity() {
    // ── palette: modern dark, amber accent (Mac Theme kin) ──
    private val bg = Color.parseColor("#0F0F12")
    private val card = Color.parseColor("#1B1B20")
    private val cardHi = Color.parseColor("#26262C")
    private val accent = Color.parseColor("#E8A33D")
    private val accentDim = Color.parseColor("#33E8A33D")
    private val textPrimary = Color.parseColor("#F2F2F4")
    private val textDim = Color.parseColor("#8E8E96")
    private val red = Color.parseColor("#E25B55")

    private lateinit var store: Store
    private lateinit var keys: Keys
    private lateinit var syncClient: SyncClient
    private lateinit var pairing: Pairing
    private val recorder = Recorder()
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val prefs by lazy { getSharedPreferences("app", Context.MODE_PRIVATE) }

    private lateinit var pages: FrameLayout
    private lateinit var recordPage: LinearLayout
    private lateinit var historyPage: LinearLayout
    private lateinit var chatPage: LinearLayout
    private lateinit var pairPage: LinearLayout
    private lateinit var tabBar: LinearLayout
    private lateinit var tabViews: List<LinearLayout>

    // record page
    private lateinit var recordButton: FrameLayout
    private lateinit var recordDot: View
    private lateinit var recordRing: View
    private lateinit var modeDictate: TextView
    private lateinit var modeIdea: TextView
    private lateinit var recordStatus: TextView
    private lateinit var lastCard: LinearLayout
    private lateinit var lastLabel: TextView
    private lateinit var lastTranscript: TextView
    private lateinit var offlineBanner: TextView
    private var ideaMode = false
    private var chatVoiceCapture = false
    private var quickCapture = false     // quick-action: transcript → inbox AND clipboard

    // history / chat
    private lateinit var historyList: LinearLayout
    private lateinit var chatList: LinearLayout
    private lateinit var chatScroll: ScrollView
    private lateinit var chatInput: EditText
    private lateinit var attachLabel: TextView
    private var pendingImageBase64: String? = null

    // pairing
    private lateinit var pairStatus: TextView
    private var pairingLoopRunning = false

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()
    private fun dpf(v: Int): Float = dp(v).toFloat()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = Store(this)
        keys = Keys(this)
        syncClient = SyncClient(this, store, keys)
        pairing = Pairing(this, keys)
        buildUI()
        applyPairedState()
        handleIntent(intent)
        watchConnectivity()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        applyPairedState()
        refreshHistory()
        refreshChat()
        executor.execute { processQueue(); quietSync() }
    }

    override fun onPause() {
        super.onPause()
        if (recorder.isRecording) stopRecording()
        pairing.stopDiscovery()
        pairingLoopRunning = false
    }

    private fun handleIntent(intent: Intent?) {
        intent ?: return
        if (intent.getBooleanExtra("start_recording", false)) {
            intent.removeExtra("start_recording")
            quickCapture = true
            showTab(0)
            if (!recorder.isRecording) toggleRecording()
            return
        }
        if (intent.action == Intent.ACTION_SEND) {
            showTab(2)
            intent.getStringExtra(Intent.EXTRA_TEXT)?.let { chatInput.setText(it) }
            @Suppress("DEPRECATION")
            (intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))?.let { attachImage(it) }
        }
    }

    // ══════════════════════ pairing gate ══════════════════════

    private fun applyPairedState() {
        val isPaired = pairing.paired
        pairPage.visibility = if (isPaired) View.GONE else View.VISIBLE
        tabBar.visibility = if (isPaired) View.VISIBLE else View.GONE
        if (!isPaired) {
            listOf(recordPage, historyPage, chatPage).forEach { it.visibility = View.GONE }
            startPairingLoop()
        } else if (recordPage.visibility == View.GONE && historyPage.visibility == View.GONE &&
            chatPage.visibility == View.GONE) {
            showTab(0)
        }
    }

    private fun startPairingLoop() {
        if (pairingLoopRunning) return
        pairingLoopRunning = true
        pairing.startDiscovery()
        pairStatus.text = "Looking for your Mac…"
        fun attempt() {
            if (!pairingLoopRunning) return
            executor.execute {
                val result = pairing.tryPair()
                main.post {
                    if (!pairingLoopRunning) return@post
                    when {
                        result?.startsWith("paired:") == true -> {
                            pairingLoopRunning = false
                            pairing.stopDiscovery()
                            pairStatus.text = "Connected to ${result.removePrefix("paired:")}"
                            Toast.makeText(this, "Paired with ${result.removePrefix("paired:")}", Toast.LENGTH_SHORT).show()
                            executor.execute { quietSync() }
                            applyPairedState()
                        }
                        result == "window-closed" -> {
                            pairStatus.text = "Mac found — click “Pair Phone” in the\nVoice Flow menu bar to finish"
                            main.postDelayed({ attempt() }, 2500)
                        }
                        else -> {
                            pairStatus.text = "Looking for your Mac…\n(same Wi-Fi or Tailscale, Voice Flow running)"
                            main.postDelayed({ attempt() }, 3000)
                        }
                    }
                }
            }
        }
        attempt()
    }

    // ══════════════════════ UI construction ══════════════════════

    private fun roundBg(color: Int, radius: Int): GradientDrawable =
        GradientDrawable().apply { setColor(color); cornerRadius = dpf(radius) }

    private fun ripple(content: GradientDrawable): RippleDrawable =
        RippleDrawable(ColorStateList.valueOf(accentDim), content, null)

    private fun buildUI() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(bg)
        }
        pages = FrameLayout(this)
        root.addView(pages, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))

        recordPage = buildRecordPage()
        historyPage = buildHistoryPage()
        chatPage = buildChatPage()
        pairPage = buildPairPage()
        listOf(recordPage, historyPage, chatPage, pairPage).forEach {
            pages.addView(it, FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        }

        tabBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setBackgroundColor(Color.parseColor("#161619"))
            setPadding(dp(12), dp(6), dp(12), dp(10))
        }
        val tabs = listOf(
            Pair("Record", R.drawable.ic_mic),
            Pair("History", R.drawable.ic_history),
            Pair("Chat", R.drawable.ic_chat),
        )
        tabViews = tabs.mapIndexed { i, (label, iconRes) ->
            val item = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER
                setPadding(0, dp(6), 0, dp(2))
                setOnClickListener { showTab(i) }
            }
            val icon = ImageView(this).apply {
                setImageResource(iconRes)
                layoutParams = LinearLayout.LayoutParams(dp(22), dp(22))
            }
            val text = TextView(this).apply {
                this.text = label
                textSize = 11f
                gravity = Gravity.CENTER
                setPadding(0, dp(3), 0, 0)
            }
            item.addView(icon)
            item.addView(text)
            tabBar.addView(item, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            item
        }
        root.addView(tabBar, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        setContentView(root)
    }

    private fun showTab(index: Int) {
        if (!pairing.paired) return
        listOf(recordPage, historyPage, chatPage).forEachIndexed { i, page ->
            page.visibility = if (i == index) View.VISIBLE else View.GONE
        }
        tabViews.forEachIndexed { i, item ->
            val active = i == index
            (item.getChildAt(0) as ImageView).imageTintList =
                ColorStateList.valueOf(if (active) accent else textDim)
            (item.getChildAt(1) as TextView).apply {
                setTextColor(if (active) accent else textDim)
                setTypeface(null, if (active) Typeface.BOLD else Typeface.NORMAL)
            }
        }
        when (index) {
            1 -> refreshHistory()
            2 -> refreshChat()
        }
    }

    private fun pageTitle(text: String): TextView = TextView(this).apply {
        this.text = text
        setTextColor(textPrimary)
        textSize = 26f
        setTypeface(null, Typeface.BOLD)
        setPadding(dp(20), dp(20), dp(20), dp(10))
    }

    private fun buildPairPage(): LinearLayout {
        val page = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(32), 0, dp(32), dp(40))
            visibility = View.GONE
        }
        val logo = FrameLayout(this)
        val circle = View(this).apply { background = roundBg(card, 48) }
        logo.addView(circle, FrameLayout.LayoutParams(dp(96), dp(96)))
        val mic = ImageView(this).apply {
            setImageResource(R.drawable.ic_mic)
            imageTintList = ColorStateList.valueOf(accent)
        }
        logo.addView(mic, FrameLayout.LayoutParams(dp(40), dp(40), Gravity.CENTER))
        page.addView(logo, LinearLayout.LayoutParams(dp(96), dp(96)).apply {
            gravity = Gravity.CENTER_HORIZONTAL; bottomMargin = dp(20)
        })
        page.addView(TextView(this).apply {
            text = "Voice Flow"
            setTextColor(textPrimary); textSize = 24f; setTypeface(null, Typeface.BOLD)
            gravity = Gravity.CENTER
        })
        pairStatus = TextView(this).apply {
            text = "Looking for your Mac…"
            setTextColor(textDim); textSize = 14f
            gravity = Gravity.CENTER
            setPadding(0, dp(14), 0, 0)
            setLineSpacing(dpf(2), 1f)
        }
        page.addView(pairStatus)
        return page
    }

    private fun buildRecordPage(): LinearLayout {
        val page = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
        }

        offlineBanner = TextView(this).apply {
            text = "Mac unreachable — everything keeps working and syncs later"
            setTextColor(accent)
            textSize = 12f
            gravity = Gravity.CENTER
            background = roundBg(Color.parseColor("#1FE8A33D"), 10)
            setPadding(dp(12), dp(8), dp(12), dp(8))
            visibility = View.GONE
        }
        page.addView(offlineBanner, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            leftMargin = dp(16); rightMargin = dp(16); topMargin = dp(16)
        })

        page.addView(View(this), LinearLayout.LayoutParams(0, 0, 1f))

        // mode segmented control
        val seg = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            background = roundBg(card, 22)
            setPadding(dp(4), dp(4), dp(4), dp(4))
        }
        fun segButton(label: String, onTap: () -> Unit): TextView = TextView(this).apply {
            text = label
            textSize = 14f
            gravity = Gravity.CENTER
            setPadding(dp(26), dp(9), dp(26), dp(9))
            setOnClickListener { onTap() }
        }
        modeDictate = segButton("Dictate") { ideaMode = false; styleModeRow() }
        modeIdea = segButton("Idea") { ideaMode = true; styleModeRow() }
        seg.addView(modeDictate)
        seg.addView(modeIdea)
        page.addView(seg, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            gravity = Gravity.CENTER_HORIZONTAL
        })
        styleModeRow()

        // record button: soft ring + solid core
        recordButton = FrameLayout(this).apply { setOnClickListener { toggleRecording() } }
        recordRing = View(this).apply { background = roundBg(accentDim, 82) }
        recordButton.addView(recordRing, FrameLayout.LayoutParams(dp(164), dp(164), Gravity.CENTER))
        recordDot = View(this).apply { background = roundBg(accent, 66) }
        recordButton.addView(recordDot, FrameLayout.LayoutParams(dp(132), dp(132), Gravity.CENTER))
        val micIcon = ImageView(this).apply {
            setImageResource(R.drawable.ic_mic)
            imageTintList = ColorStateList.valueOf(Color.parseColor("#101014"))
        }
        recordButton.addView(micIcon, FrameLayout.LayoutParams(dp(44), dp(44), Gravity.CENTER))
        page.addView(recordButton, LinearLayout.LayoutParams(dp(164), dp(164)).apply {
            topMargin = dp(28); gravity = Gravity.CENTER_HORIZONTAL
        })

        recordStatus = TextView(this).apply {
            text = "tap to record"
            setTextColor(textDim)
            gravity = Gravity.CENTER
            textSize = 14f
            setPadding(dp(24), dp(18), dp(24), 0)
        }
        page.addView(recordStatus)

        page.addView(View(this), LinearLayout.LayoutParams(0, 0, 1f))

        lastCard = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = roundBg(card, 16)
            setPadding(dp(16), dp(12), dp(16), dp(14))
            visibility = View.GONE
            setOnClickListener {
                copyToClipboard(lastTranscript.text.toString())
                Toast.makeText(this@MainActivity, "Copied", Toast.LENGTH_SHORT).show()
            }
        }
        lastLabel = TextView(this).apply {
            setTextColor(textDim); textSize = 11f
            letterSpacing = 0.08f
        }
        lastTranscript = TextView(this).apply {
            setTextColor(textPrimary); textSize = 15f
            setPadding(0, dp(6), 0, 0)
            setLineSpacing(dpf(2), 1f)
        }
        lastCard.addView(lastLabel)
        lastCard.addView(lastTranscript)
        page.addView(lastCard, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            leftMargin = dp(16); rightMargin = dp(16); bottomMargin = dp(20)
        })
        return page
    }

    private fun styleModeRow() {
        modeDictate.background = if (!ideaMode) roundBg(accent, 18) else null
        modeDictate.setTextColor(if (!ideaMode) Color.parseColor("#101014") else textDim)
        modeDictate.setTypeface(null, if (!ideaMode) Typeface.BOLD else Typeface.NORMAL)
        modeIdea.background = if (ideaMode) roundBg(accent, 18) else null
        modeIdea.setTextColor(if (ideaMode) Color.parseColor("#101014") else textDim)
        modeIdea.setTypeface(null, if (ideaMode) Typeface.BOLD else Typeface.NORMAL)
    }

    private fun buildHistoryPage(): LinearLayout {
        val page = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        page.addView(pageTitle("History"))
        val scroll = ScrollView(this).apply { isVerticalScrollBarEnabled = false }
        historyList = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), 0, dp(16), dp(16))
        }
        scroll.addView(historyList)
        page.addView(scroll, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        return page
    }

    private fun buildChatPage(): LinearLayout {
        val page = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        chatScroll = ScrollView(this).apply { isVerticalScrollBarEnabled = false }
        chatList = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(14), dp(14), dp(14), dp(14))
        }
        chatScroll.addView(chatList)
        page.addView(chatScroll, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))

        attachLabel = TextView(this).apply {
            setTextColor(accent); textSize = 12f
            setPadding(dp(18), 0, dp(18), dp(4))
            visibility = View.GONE
            setOnClickListener {
                pendingImageBase64 = null
                visibility = View.GONE
            }
        }
        page.addView(attachLabel)

        val inputRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.BOTTOM
            setPadding(dp(10), dp(4), dp(10), dp(10))
        }
        val attach = TextView(this).apply {
            text = "+"; textSize = 24f; setTextColor(textDim)
            setPadding(dp(10), 0, dp(10), dp(6))
            setOnClickListener {
                startActivityForResult(
                    Intent(Intent.ACTION_GET_CONTENT).setType("image/*"), REQ_PICK_IMAGE)
            }
        }
        val mic = ImageView(this).apply {
            setImageResource(R.drawable.ic_mic)
            imageTintList = ColorStateList.valueOf(accent)
            setPadding(dp(8), 0, dp(8), dp(8))
            setOnClickListener { chatMicTapped(this) }
        }
        chatInput = EditText(this).apply {
            hint = "Ask the assistant"
            setHintTextColor(textDim)
            setTextColor(textPrimary)
            textSize = 15f
            background = roundBg(card, 20)
            setPadding(dp(16), dp(10), dp(16), dp(10))
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES or
                InputType.TYPE_TEXT_FLAG_MULTI_LINE
            maxLines = 4
        }
        val send = TextView(this).apply {
            text = "➤"; textSize = 19f; setTextColor(accent)
            setPadding(dp(12), 0, dp(12), dp(7))
            setOnClickListener { sendChat() }
        }
        inputRow.addView(attach)
        inputRow.addView(mic, LinearLayout.LayoutParams(dp(38), dp(38)))
        inputRow.addView(chatInput, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        inputRow.addView(send)
        page.addView(inputRow)
        return page
    }

    // ══════════════════════ recording flow ══════════════════════

    private fun toggleRecording() {
        if (recorder.isRecording) { stopRecording(); return }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQ_MIC)
            return
        }
        try {
            recorder.start(store.audioDir)
            recordDot.background = roundBg(red, 66)
            recordRing.background = roundBg(Color.parseColor("#33E25B55"), 82)
            recordStatus.text = when {
                chatVoiceCapture -> "recording for the assistant… tap to stop"
                quickCapture -> "recording… goes to your inbox + clipboard"
                ideaMode -> "recording idea… tap to stop"
                else -> "recording… tap to stop"
            }
        } catch (e: Exception) {
            recordStatus.text = "mic error: ${e.message}"
        }
    }

    override fun onRequestPermissionsResult(code: Int, permissions: Array<String>, results: IntArray) {
        if (code == REQ_MIC && results.firstOrNull() == PackageManager.PERMISSION_GRANTED) toggleRecording()
    }

    private fun stopRecording() {
        val file = recorder.stop()
        recordDot.background = roundBg(accent, 66)
        recordRing.background = roundBg(accentDim, 82)
        val forChat = chatVoiceCapture
        val quick = quickCapture
        chatVoiceCapture = false
        quickCapture = false
        if (file == null) { recordStatus.text = "too short — nothing captured"; return }
        val mode = when {
            forChat -> "assistant"
            quick -> "quick"
            ideaMode -> "kept"
            else -> "pasted"
        }
        store.enqueue(QueueItem(file.name, file.absolutePath, mode, System.currentTimeMillis()))
        recordStatus.text = "transcribing…"
        executor.execute { processQueue(); quietSync() }
    }

    private fun chatMicTapped(mic: ImageView) {
        if (recorder.isRecording) {
            stopRecording()
            mic.imageTintList = ColorStateList.valueOf(accent)
            return
        }
        chatVoiceCapture = true
        toggleRecording()
        if (recorder.isRecording) mic.imageTintList = ColorStateList.valueOf(red)
    }

    /// Drains the pending-audio queue: transcribe → clean → route. Network
    /// failure leaves the item queued (store-and-forward); empty transcripts
    /// are dropped. Runs on the background executor.
    private fun processQueue() {
        if (store.queue().isEmpty()) return
        val openAIKey = keys.load(Keys.OPENAI)
        if (openAIKey.isNullOrBlank()) {
            main.post { recordStatus.text = "waiting for keys from the Mac (sync)" }
            return
        }
        for (item in store.queue()) {
            val file = java.io.File(item.file)
            if (!file.exists()) { store.dequeue(item.id); continue }
            val raw = try {
                Transcriber.transcribe(file, openAIKey, syncClient.vocabulary())
            } catch (e: Net.HttpError) {
                main.post { recordStatus.text = "transcription failed: ${e.message}" }
                if (e.code == 401 || e.code == 429) return
                store.dequeue(item.id); continue
            } catch (e: Exception) {
                main.post { showOffline(true); recordStatus.text = "offline — ${store.queue().size} recording(s) queued" }
                return
            }
            val cleaned = if (prefs.getBoolean("cleanup_enabled", true) &&
                !keys.load(Keys.AGENT).isNullOrBlank() && item.mode != "assistant")
                Transcriber.clean(raw, keys.load(Keys.AGENT)!!, syncClient.vocabulary())
            else raw
            store.dequeue(item.id)
            if (cleaned.isBlank()) {
                main.post { recordStatus.text = "nothing heard" }
                continue
            }
            when (item.mode) {
                "assistant" -> main.post {
                    chatInput.setText(cleaned)
                    showTab(2)
                }
                else -> {
                    // quick-action captures land in the inbox (kept) AND on
                    // the clipboard; in-app Dictate = clipboard, Idea = inbox.
                    val kind = if (item.mode == "quick") "kept" else item.mode
                    val toClipboard = item.mode != "kept"
                    store.addDictation(DictationEntry.now(cleaned, kind))
                    main.post {
                        if (toClipboard) copyToClipboard(cleaned)
                        recordStatus.text = when (item.mode) {
                            "quick" -> "in your inbox + on the clipboard"
                            "kept" -> "idea captured"
                            else -> "on your clipboard"
                        }
                        lastLabel.text = when (item.mode) {
                            "quick" -> "INBOX + CLIPBOARD"
                            "kept" -> "IDEA"
                            else -> "ON YOUR CLIPBOARD"
                        }
                        lastTranscript.text = cleaned
                        lastCard.visibility = View.VISIBLE
                        refreshHistory()
                    }
                }
            }
        }
    }

    private fun copyToClipboard(text: String) {
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        cm.setPrimaryClip(ClipData.newPlainText("dictation", text))
    }

    private fun showOffline(offline: Boolean) {
        offlineBanner.visibility = if (offline) View.VISIBLE else View.GONE
    }

    // ══════════════════════ history ══════════════════════

    private fun refreshHistory() {
        if (!::historyList.isInitialized) return
        historyList.removeAllViews()
        val entries = store.dictations().take(100)
        if (entries.isEmpty()) {
            historyList.addView(TextView(this).apply {
                text = "No dictations yet"
                setTextColor(textDim)
                setPadding(dp(6), dp(24), dp(6), 0)
            })
            return
        }
        for (e in entries) {
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                background = ripple(roundBg(card, 14))
                setPadding(dp(14), dp(11), dp(14), dp(12))
                setOnClickListener {
                    copyToClipboard(e.text)
                    Toast.makeText(this@MainActivity, "Copied", Toast.LENGTH_SHORT).show()
                }
                setOnLongClickListener {
                    startActivity(Intent.createChooser(
                        Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, e.text),
                        "Share dictation"))
                    true
                }
            }
            val metaRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
            val isIdea = e.kind == "kept"
            val chip = TextView(this).apply {
                text = if (isIdea) "idea" else "dictation"
                textSize = 10f
                setTypeface(null, Typeface.BOLD)
                letterSpacing = 0.06f
                setTextColor(if (isIdea) accent else textDim)
                background = roundBg(if (isIdea) Color.parseColor("#26E8A33D") else cardHi, 8)
                setPadding(dp(8), dp(2), dp(8), dp(3))
            }
            val time = TextView(this).apply {
                text = listOf(e.date, e.time).filter { it.isNotBlank() }.joinToString("  ")
                setTextColor(textDim)
                textSize = 11f
                setPadding(dp(8), 0, 0, 0)
            }
            metaRow.addView(chip)
            metaRow.addView(time)
            val body = TextView(this).apply {
                text = e.text
                setTextColor(textPrimary)
                textSize = 14f
                setPadding(0, dp(7), 0, 0)
                setLineSpacing(dpf(2), 1f)
            }
            row.addView(metaRow)
            row.addView(body)
            historyList.addView(row, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                bottomMargin = dp(10)
            })
        }
    }

    // ══════════════════════ assistant chat ══════════════════════

    private fun refreshChat() {
        if (!::chatList.isInitialized) return
        chatList.removeAllViews()
        val messages = store.chat()
        if (messages.isEmpty()) {
            chatList.addView(TextView(this).apply {
                text = "Ask by text, voice, or share a photo into Voice Flow."
                setTextColor(textDim)
                setPadding(dp(8), dp(24), dp(8), 0)
            })
        }
        for (m in messages) {
            val bubble = TextView(this).apply {
                text = m.text
                textSize = 14f
                setTextIsSelectable(true)
                setLineSpacing(dpf(2), 1f)
                setPadding(dp(14), dp(10), dp(14), dp(10))
                if (m.role == "user") {
                    setTextColor(Color.parseColor("#101014"))
                    background = roundBg(accent, 16)
                } else {
                    setTextColor(textPrimary)
                    background = roundBg(card, 16)
                }
            }
            val lp = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
            lp.bottomMargin = dp(8)
            lp.gravity = if (m.role == "user") Gravity.END else Gravity.START
            lp.marginStart = if (m.role == "user") dp(48) else 0
            lp.marginEnd = if (m.role == "user") 0 else dp(48)
            chatList.addView(bubble, lp)
        }
        chatScroll.post { chatScroll.fullScroll(View.FOCUS_DOWN) }
    }

    private fun sendChat() {
        val userText = chatInput.text.toString().trim()
        if (userText.isEmpty()) return
        val apiKey = keys.load(Keys.AGENT)
        if (apiKey.isNullOrBlank()) {
            Toast.makeText(this, "Waiting for keys from the Mac — sync first", Toast.LENGTH_SHORT).show()
            return
        }
        val image = pendingImageBase64
        pendingImageBase64 = null
        attachLabel.visibility = View.GONE
        chatInput.setText("")
        store.addChat(ChatMessage.now("user", userText))
        refreshChat()
        val thinking = TextView(this).apply {
            this.text = "…"
            setTextColor(textDim)
            setPadding(dp(14), dp(4), dp(14), dp(10))
        }
        chatList.addView(thinking)

        executor.execute {
            val history = store.chat().dropLast(1)
            val result = try {
                Assistant.reply(history, userText, image, apiKey, syncClient.agentModel())
            } catch (e: Exception) {
                "⚠ ${e.message?.take(200)}"
            }
            store.addChat(ChatMessage.now("assistant", result))
            main.post { refreshChat() }
            quietSync()
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_PICK_IMAGE && resultCode == RESULT_OK) {
            data?.data?.let { attachImage(it) }
        }
    }

    private fun attachImage(uri: Uri) {
        try {
            val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, opts) }
            var sample = 1
            while (maxOf(opts.outWidth, opts.outHeight) / sample > 1440) sample *= 2
            val decode = BitmapFactory.Options().apply { inSampleSize = sample }
            val bitmap = contentResolver.openInputStream(uri)?.use {
                BitmapFactory.decodeStream(it, null, decode)
            } ?: return
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG, 80, out)
            pendingImageBase64 = Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
            attachLabel.text = "photo attached (${bitmap.width}×${bitmap.height}) — tap to remove"
            attachLabel.visibility = View.VISIBLE
        } catch (e: Exception) {
            Toast.makeText(this, "Couldn't read image: ${e.message}", Toast.LENGTH_SHORT).show()
        }
    }

    // ══════════════════════ sync + connectivity ══════════════════════

    private fun quietSync() {
        val result = syncClient.sync()
        main.post {
            showOffline(syncClient.lastError != null && pairing.paired)
            if (syncClient.lastError == "unpaired") applyPairedState()
            if (result != null) refreshHistory()
        }
    }

    private fun watchConnectivity() {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        cm.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                executor.execute { processQueue(); quietSync() }
            }
        })
    }

    companion object {
        private const val REQ_MIC = 1
        private const val REQ_PICK_IMAGE = 2
    }
}
