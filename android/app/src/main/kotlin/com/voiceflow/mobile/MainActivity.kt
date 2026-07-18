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
import android.net.ConnectivityManager
import android.net.Network
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.util.Base64
import android.view.Gravity
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class MainActivity : Activity() {
    // ── palette (Mac Theme parity: dark, amber accent) ──
    private val bg = Color.parseColor("#141414")
    private val card = Color.parseColor("#1E1E1E")
    private val accent = Color.parseColor("#E8A33D")
    private val textPrimary = Color.parseColor("#ECECEC")
    private val textDim = Color.parseColor("#9A9A9A")
    private val red = Color.parseColor("#D9534F")

    private lateinit var store: Store
    private lateinit var keys: Keys
    private lateinit var syncClient: SyncClient
    private val recorder = Recorder()
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val prefs by lazy { getSharedPreferences("app", Context.MODE_PRIVATE) }

    // pages
    private lateinit var pages: FrameLayout
    private lateinit var recordPage: LinearLayout
    private lateinit var historyPage: LinearLayout
    private lateinit var chatPage: LinearLayout
    private lateinit var setupPage: ScrollView
    private lateinit var tabButtons: List<TextView>

    // record page widgets
    private lateinit var recordButton: TextView
    private lateinit var modeDictate: TextView
    private lateinit var modeIdea: TextView
    private lateinit var recordStatus: TextView
    private lateinit var lastTranscript: TextView
    private var ideaMode = false
    private var chatVoiceCapture = false   // mic pressed from the chat page

    // history / chat widgets
    private lateinit var historyList: LinearLayout
    private lateinit var chatList: LinearLayout
    private lateinit var chatScroll: ScrollView
    private lateinit var chatInput: EditText
    private lateinit var attachLabel: TextView
    private var pendingImageBase64: String? = null

    // setup widgets
    private lateinit var openAIField: EditText
    private lateinit var openRouterField: EditText
    private lateinit var syncHostField: EditText
    private lateinit var syncPortField: EditText
    private lateinit var syncTokenField: EditText
    private lateinit var cleanupCheck: CheckBox
    private lateinit var setupStatus: TextView

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = Store(this)
        keys = Keys(this)
        syncClient = SyncClient(this, store, keys)
        buildUI()
        showTab(0)
        handleIntent(intent)
        watchConnectivity()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        refreshHistory()
        refreshChat()
        refreshSetupStatus()
        executor.execute { processQueue(); quietSync() }
    }

    override fun onPause() {
        super.onPause()
        if (recorder.isRecording) stopRecording()
    }

    private fun handleIntent(intent: Intent?) {
        intent ?: return
        if (intent.getBooleanExtra("start_recording", false)) {
            intent.removeExtra("start_recording")
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

    // ══════════════════════ UI construction ══════════════════════

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
        setupPage = buildSetupPage()
        listOf(recordPage, historyPage, chatPage, setupPage).forEach {
            pages.addView(it, FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        }

        val tabBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setBackgroundColor(card)
        }
        tabButtons = listOf("Record", "History", "Chat", "Setup").mapIndexed { i, label ->
            TextView(this).apply {
                text = label
                gravity = Gravity.CENTER
                textSize = 14f
                setPadding(0, dp(14), 0, dp(14))
                setOnClickListener { showTab(i) }
            }.also { tabBar.addView(it, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)) }
        }
        root.addView(tabBar, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        setContentView(root)
    }

    private fun showTab(index: Int) {
        listOf(recordPage, historyPage, chatPage, setupPage).forEachIndexed { i, page ->
            page.visibility = if (i == index) View.VISIBLE else View.GONE
        }
        tabButtons.forEachIndexed { i, b ->
            b.setTextColor(if (i == index) accent else textDim)
            b.setTypeface(null, if (i == index) Typeface.BOLD else Typeface.NORMAL)
        }
        when (index) {
            1 -> refreshHistory()
            2 -> refreshChat()
            3 -> refreshSetupStatus()
        }
    }

    private fun pill(color: Int, radius: Int = 24): GradientDrawable =
        GradientDrawable().apply { setColor(color); cornerRadius = dp(radius).toFloat() }

    private fun buildRecordPage(): LinearLayout {
        val page = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(24), dp(24), dp(24), dp(24))
        }

        val modeRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        modeDictate = TextView(this).apply {
            text = "Dictate"
            setPadding(dp(20), dp(8), dp(20), dp(8))
            setOnClickListener { ideaMode = false; styleModeRow() }
        }
        modeIdea = TextView(this).apply {
            text = "Idea"
            setPadding(dp(20), dp(8), dp(20), dp(8))
            setOnClickListener { ideaMode = true; styleModeRow() }
        }
        modeRow.addView(modeDictate)
        modeRow.addView(modeIdea)
        page.addView(modeRow)
        styleModeRow()

        recordButton = TextView(this).apply {
            text = "●"
            textSize = 54f
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
            background = pill(accent, 70)
            setOnClickListener { toggleRecording() }
        }
        val size = dp(140)
        page.addView(recordButton, LinearLayout.LayoutParams(size, size).apply {
            topMargin = dp(32); bottomMargin = dp(24); gravity = Gravity.CENTER_HORIZONTAL
        })

        recordStatus = TextView(this).apply {
            text = "tap to record"
            setTextColor(textDim)
            gravity = Gravity.CENTER
            textSize = 15f
        }
        page.addView(recordStatus)

        lastTranscript = TextView(this).apply {
            setTextColor(textPrimary)
            textSize = 15f
            setPadding(dp(16), dp(12), dp(16), dp(12))
            background = pill(card, 12)
            visibility = View.GONE
            setOnClickListener {
                copyToClipboard(text.toString())
                Toast.makeText(this@MainActivity, "Copied", Toast.LENGTH_SHORT).show()
            }
        }
        page.addView(lastTranscript, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(24)
        })
        return page
    }

    private fun styleModeRow() {
        modeDictate.background = pill(if (!ideaMode) accent else card)
        modeDictate.setTextColor(if (!ideaMode) Color.BLACK else textDim)
        modeIdea.background = pill(if (ideaMode) accent else card)
        modeIdea.setTextColor(if (ideaMode) Color.BLACK else textDim)
    }

    private fun buildHistoryPage(): LinearLayout {
        val page = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val title = TextView(this).apply {
            text = "History"
            setTextColor(textPrimary); textSize = 18f; setTypeface(null, Typeface.BOLD)
            setPadding(dp(16), dp(16), dp(16), dp(8))
        }
        page.addView(title)
        val scroll = ScrollView(this)
        historyList = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), 0, dp(12), dp(12))
        }
        scroll.addView(historyList)
        page.addView(scroll, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        return page
    }

    private fun buildChatPage(): LinearLayout {
        val page = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        chatScroll = ScrollView(this)
        chatList = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), dp(12), dp(12), dp(12))
        }
        chatScroll.addView(chatList)
        page.addView(chatScroll, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))

        attachLabel = TextView(this).apply {
            setTextColor(accent); textSize = 12f
            setPadding(dp(16), 0, dp(16), dp(4))
            visibility = View.GONE
            setOnClickListener {
                pendingImageBase64 = null
                visibility = View.GONE
            }
        }
        page.addView(attachLabel)

        val inputRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8), dp(4), dp(8), dp(8))
        }
        val attach = TextView(this).apply {
            text = "+"; textSize = 26f; setTextColor(textDim)
            setPadding(dp(10), 0, dp(10), dp(4))
            setOnClickListener {
                startActivityForResult(
                    Intent(Intent.ACTION_GET_CONTENT).setType("image/*"), REQ_PICK_IMAGE)
            }
        }
        val mic = TextView(this).apply {
            text = "●"; textSize = 20f; setTextColor(accent)
            setPadding(dp(10), 0, dp(10), 0)
            setOnClickListener { chatMicTapped(this) }
        }
        chatInput = EditText(this).apply {
            hint = "Ask the assistant"
            setHintTextColor(textDim)
            setTextColor(textPrimary)
            textSize = 15f
            background = pill(card, 20)
            setPadding(dp(16), dp(10), dp(16), dp(10))
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES or
                InputType.TYPE_TEXT_FLAG_MULTI_LINE
            maxLines = 4
        }
        val send = TextView(this).apply {
            text = "➤"; textSize = 20f; setTextColor(accent)
            setPadding(dp(12), 0, dp(12), 0)
            setOnClickListener { sendChat() }
        }
        inputRow.addView(attach)
        inputRow.addView(mic)
        inputRow.addView(chatInput, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        inputRow.addView(send)
        page.addView(inputRow)
        return page
    }

    private fun buildSetupPage(): ScrollView {
        val scroll = ScrollView(this)
        val page = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(16), dp(20), dp(24))
        }
        scroll.addView(page)

        fun label(text: String) = page.addView(TextView(this).apply {
            this.text = text
            setTextColor(textDim); textSize = 12f
            setPadding(0, dp(14), 0, dp(4))
        })

        fun field(hint: String, secret: Boolean): EditText {
            val f = EditText(this).apply {
                this.hint = hint
                setHintTextColor(Color.parseColor("#555555"))
                setTextColor(textPrimary)
                textSize = 14f
                background = pill(card, 10)
                setPadding(dp(14), dp(10), dp(14), dp(10))
                inputType = if (secret)
                    InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
                else InputType.TYPE_CLASS_TEXT
            }
            page.addView(f)
            return f
        }

        page.addView(TextView(this).apply {
            text = "Setup"
            setTextColor(textPrimary); textSize = 18f; setTypeface(null, Typeface.BOLD)
        })

        label("OpenAI API key (transcription)")
        openAIField = field("sk-…", true)
        label("OpenRouter API key (assistant + cleanup)")
        openRouterField = field("sk-or-…", true)

        cleanupCheck = CheckBox(this).apply {
            text = "LLM cleanup of dictations"
            setTextColor(textPrimary)
            isChecked = prefs.getBoolean("cleanup_enabled", true)
        }
        page.addView(cleanupCheck, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(12)
        })

        label("Mac sync host (Tailscale IP; 10.0.2.2 on emulator)")
        syncHostField = field("100.x.y.z", false)
        label("Sync port")
        syncPortField = field("8793", false)
        label("Sync token (~/.config/voice-flow/sync-token on the Mac)")
        syncTokenField = field("token", true)

        val save = Button(this).apply {
            text = "Save"
            setTextColor(Color.BLACK)
            background = pill(accent, 10)
            setOnClickListener { saveSetup() }
        }
        page.addView(save, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(20)
        })

        val syncNow = Button(this).apply {
            text = "Sync now"
            setTextColor(textPrimary)
            background = pill(card, 10)
            setOnClickListener {
                setupStatus.text = "syncing…"
                executor.execute {
                    processQueue()
                    val result = syncClient.sync()
                    main.post {
                        setupStatus.text = result ?: (syncClient.lastError ?: "sync not configured")
                        refreshHistory()
                    }
                }
            }
        }
        page.addView(syncNow, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(10)
        })

        setupStatus = TextView(this).apply {
            setTextColor(textDim); textSize = 13f
            setPadding(0, dp(16), 0, 0)
        }
        page.addView(setupStatus)

        // load persisted values
        openAIField.setText(keys.load(Keys.OPENAI) ?: "")
        openRouterField.setText(keys.load(Keys.AGENT) ?: "")
        syncTokenField.setText(keys.load(Keys.SYNC_TOKEN) ?: "")
        syncHostField.setText(prefs.getString("sync_host", ""))
        syncPortField.setText(prefs.getString("sync_port", "8793"))
        return scroll
    }

    private fun saveSetup() {
        keys.save(Keys.OPENAI, openAIField.text.toString().trim())
        keys.save(Keys.AGENT, openRouterField.text.toString().trim())
        keys.save(Keys.SYNC_TOKEN, syncTokenField.text.toString().trim())
        prefs.edit()
            .putString("sync_host", syncHostField.text.toString().trim())
            .putString("sync_port", syncPortField.text.toString().trim())
            .putBoolean("cleanup_enabled", cleanupCheck.isChecked)
            .apply()
        Toast.makeText(this, "Saved", Toast.LENGTH_SHORT).show()
        refreshSetupStatus()
    }

    private fun refreshSetupStatus() {
        if (!::setupStatus.isInitialized) return
        val parts = mutableListOf<String>()
        parts.add(if (keys.load(Keys.OPENAI).isNullOrBlank()) "OpenAI key: missing" else "OpenAI key: set")
        parts.add(if (keys.load(Keys.AGENT).isNullOrBlank()) "OpenRouter key: missing" else "OpenRouter key: set")
        parts.add("model: ${syncClient.agentModel()}")
        val vocab = syncClient.vocabulary()
        if (vocab.isNotEmpty()) parts.add("vocabulary: ${vocab.size} terms")
        val pending = store.queue().size
        if (pending > 0) parts.add("$pending recording(s) queued")
        syncClient.lastError?.let { parts.add("last sync error: $it") }
        setupStatus.text = parts.joinToString("\n")
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
            recordButton.background = pill(red, 70)
            recordStatus.text = if (chatVoiceCapture) "recording for the assistant… tap to stop"
                else if (ideaMode) "recording idea… tap to stop" else "recording… tap to stop"
        } catch (e: Exception) {
            recordStatus.text = "mic error: ${e.message}"
        }
    }

    override fun onRequestPermissionsResult(code: Int, permissions: Array<String>, results: IntArray) {
        if (code == REQ_MIC && results.firstOrNull() == PackageManager.PERMISSION_GRANTED) toggleRecording()
    }

    private fun stopRecording() {
        val file = recorder.stop()
        recordButton.background = pill(accent, 70)
        val forChat = chatVoiceCapture
        chatVoiceCapture = false
        if (file == null) { recordStatus.text = "too short — nothing captured"; return }
        val mode = if (forChat) "assistant" else if (ideaMode) "kept" else "pasted"
        store.enqueue(QueueItem(file.name, file.absolutePath, mode, System.currentTimeMillis()))
        recordStatus.text = "transcribing…"
        executor.execute { processQueue(); quietSync() }
    }

    private fun chatMicTapped(mic: TextView) {
        if (recorder.isRecording) {
            stopRecording()
            mic.setTextColor(accent)
            return
        }
        chatVoiceCapture = true
        toggleRecording()
        if (recorder.isRecording) mic.setTextColor(red)
    }

    /// Drains the pending-audio queue: transcribe → clean → route. Network
    /// failure leaves the item queued (store-and-forward); empty transcripts
    /// are dropped. Runs on the background executor.
    private fun processQueue() {
        if (store.queue().isEmpty()) return
        val openAIKey = keys.load(Keys.OPENAI)
        if (openAIKey.isNullOrBlank()) {
            main.post { recordStatus.text = "add your OpenAI key in Setup (or sync from the Mac)" }
            return
        }
        for (item in store.queue()) {
            val file = java.io.File(item.file)
            if (!file.exists()) { store.dequeue(item.id); continue }
            val raw = try {
                Transcriber.transcribe(file, openAIKey, syncClient.vocabulary())
            } catch (e: Net.HttpError) {
                // The API rejected this recording (bad audio, bad key) —
                // surface it; only drop the item for non-auth errors.
                main.post { recordStatus.text = "transcription failed: ${e.message}" }
                if (e.code == 401 || e.code == 429) return
                store.dequeue(item.id); continue
            } catch (e: Exception) {
                main.post { recordStatus.text = "offline — ${store.queue().size} recording(s) queued" }
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
                    store.addDictation(DictationEntry.now(cleaned, item.mode))
                    main.post {
                        if (item.mode == "pasted") {
                            copyToClipboard(cleaned)
                            recordStatus.text = "on your clipboard"
                        } else {
                            recordStatus.text = "idea captured"
                        }
                        lastTranscript.text = cleaned
                        lastTranscript.visibility = View.VISIBLE
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

    // ══════════════════════ history ══════════════════════

    private fun refreshHistory() {
        if (!::historyList.isInitialized) return
        historyList.removeAllViews()
        val entries = store.dictations().take(100)
        if (entries.isEmpty()) {
            historyList.addView(TextView(this).apply {
                text = "No dictations yet"
                setTextColor(textDim)
                setPadding(dp(8), dp(24), dp(8), 0)
            })
            return
        }
        for (e in entries) {
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                background = pill(card, 10)
                setPadding(dp(12), dp(10), dp(12), dp(10))
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
            val meta = TextView(this).apply {
                val kind = when (e.kind) { "kept" -> "idea"; "assistant" -> "assistant"; else -> "dictation" }
                val syncMark = if (e.synced) "✓" else "•"
                text = listOf(e.date, e.time, kind, syncMark).filter { it.isNotBlank() }.joinToString("  ")
                setTextColor(if (e.kind == "kept") accent else textDim)
                textSize = 11f
            }
            val body = TextView(this).apply {
                text = e.text
                setTextColor(textPrimary)
                textSize = 14f
            }
            row.addView(meta)
            row.addView(body)
            historyList.addView(row, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                bottomMargin = dp(8)
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
                text = "Ask by text, voice (●), or share a photo into Voice Flow."
                setTextColor(textDim)
                setPadding(dp(8), dp(24), dp(8), 0)
            })
        }
        for (m in messages) {
            val bubble = TextView(this).apply {
                text = m.text
                textSize = 14f
                setTextIsSelectable(true)
                setPadding(dp(14), dp(10), dp(14), dp(10))
                if (m.role == "user") {
                    setTextColor(Color.BLACK)
                    background = pill(accent, 14)
                } else {
                    setTextColor(textPrimary)
                    background = pill(card, 14)
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
        val text = chatInput.text.toString().trim()
        if (text.isEmpty()) return
        val apiKey = keys.load(Keys.AGENT)
        if (apiKey.isNullOrBlank()) {
            Toast.makeText(this, "Add your OpenRouter key in Setup", Toast.LENGTH_SHORT).show()
            showTab(3)
            return
        }
        val image = pendingImageBase64
        pendingImageBase64 = null
        attachLabel.visibility = View.GONE
        chatInput.setText("")
        store.addChat(ChatMessage.now("user", text))
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
                Assistant.reply(history, text, image, apiKey, syncClient.agentModel())
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
        if (result != null) main.post { refreshHistory(); refreshSetupStatus() }
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
