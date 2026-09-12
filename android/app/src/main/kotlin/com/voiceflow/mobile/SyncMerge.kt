package com.voiceflow.mobile

import org.json.JSONObject

/** Merge only the acknowledged versions; captures made during the request stay pending. */
object SyncMerge {
    fun apply(dictations: MutableList<DictationEntry>, chat: MutableList<ChatMessage>,
              uploadedDictations: List<DictationEntry>, uploadedChat: List<ChatMessage>,
              response: JSONObject): Int {
        val sent = uploadedDictations.associateBy { it.id }
        dictations.forEach { local ->
            val uploaded = sent[local.id]
            if (uploaded != null && local.copy(synced = false) == uploaded.copy(synced = false)) local.synced = true
        }
        val sentChat = uploadedChat.associateBy { it.id }
        chat.forEach { local ->
            val uploaded = sentChat[local.id]
            if (uploaded != null && local.copy(synced = false) == uploaded.copy(synced = false)) local.synced = true
        }

        // Merge the Mac's history into ours. Entries match by stable id
        // first (ticket #36): a known id with changed text is a Mac-side
        // update (Continue-append) adopted in place — unless our copy has
        // unsynced local edits, which win until pushed. Id-less entries keep
        // the old time+text dedupe; new ones adopt the Mac's id so later
        // continues sync as updates, not duplicates.
        val seen = dictations.map { it.time + "" + it.text }.toHashSet()
        var pulled = 0
        response.optJSONArray("dictations")?.let { arr ->
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                val text = o.optString("text")
                if (text.isBlank()) continue
                val macId = o.optString("id")
                if (macId.isNotBlank()) {
                    val idx = dictations.indexOfFirst { it.id == macId }
                    if (idx >= 0) {
                        val local = dictations[idx]
                        // The upload wins this round even with an older Mac build
                        // returning its pre-upload snapshot.
                        if (local.synced && local.id !in sent && local.text != text) {
                            dictations.removeAt(idx)
                            dictations.add(0, local.copy(
                                text = text,
                                time = o.optString("time"),
                                date = o.optString("timestamp").take(10),
                                synced = true,
                            ))
                            pulled++
                        }
                        continue
                    }
                }
                val key = o.optString("time") + "" + text
                if (key in seen) continue
                seen.add(key)
                dictations.add(DictationEntry(
                    macId.ifBlank { java.util.UUID.randomUUID().toString() },
                    o.optString("time"), o.optString("timestamp").take(10),
                    text,
                    o.optString("destination", "pasted"),
                    true,
                ))
                pulled++
            }
        }
        // Remote arrivals must appear with recent captures, not at the bottom
        // where the history cap can discard them immediately.
        dictations.sortWith(compareByDescending<DictationEntry> { it.date }.thenByDescending { it.time })
        return pulled
    }
}
