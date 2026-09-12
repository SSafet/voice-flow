package com.voiceflow.mobile

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import org.json.JSONObject

/** Native SQLite: portable local values and immutable operations share a FULL
 * synchronous transaction. JSON compatibility files are never cloud authority. */
class CloudDatabase private constructor(context: Context) : SQLiteOpenHelper(context, "cloud-sync.sqlite", null, 1), CloudPersistence {
    companion object {
        @Volatile private var instance: CloudDatabase? = null
        fun get(context: Context): CloudDatabase = instance ?: synchronized(Store.lock) {
            instance ?: CloudDatabase(context.applicationContext).also { instance = it }
        }
    }
    private val committed = mutableMapOf<String, CloudAccountState>()
    init { setWriteAheadLoggingEnabled(true) }
    override fun onConfigure(db: SQLiteDatabase) { db.execSQL("PRAGMA synchronous=FULL"); db.rawQuery("PRAGMA busy_timeout=5000", null).use { it.moveToFirst() } }
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE cloud_accounts (partition TEXT PRIMARY KEY, version INTEGER NOT NULL CHECK(version=1), state TEXT NOT NULL)")
        db.execSQL("CREATE TABLE cloud_source_owners (record_key TEXT PRIMARY KEY, partition TEXT NOT NULL)")
        db.execSQL("CREATE TABLE cloud_import_ids (source_key TEXT PRIMARY KEY, record_id TEXT NOT NULL)")
    }
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) { throw CloudFailure.UpdateRequired() }
    override fun <T> transaction(body: (CloudTransaction) -> T): T = synchronized(Store.lock) {
        val db = writableDatabase
        db.beginTransaction()
        val snapshots = mutableMapOf<String, CloudAccountState>()
        var succeeded = false
        try {
            val tx = object : CloudTransaction {
                override fun read(partition: String): CloudAccountState {
                    (snapshots[partition] ?: committed[partition])?.let { return it.detached() }
                    val length = db.rawQuery("SELECT version,length(state) FROM cloud_accounts WHERE partition=?", arrayOf(partition)).use { cursor ->
                        if (!cursor.moveToFirst()) return CloudAccountState()
                        if (cursor.getInt(0) != 1) throw CloudFailure.UpdateRequired()
                        cursor.getInt(1)
                    }
                    // CursorWindow has a device-dependent row ceiling. Read
                    // bounded text slices so a large retained history never
                    // becomes unreadable merely because it exceeds that row.
                    val text = StringBuilder(length)
                    var offset = 1
                    while (offset <= length) {
                        db.rawQuery("SELECT substr(state,?,131072) FROM cloud_accounts WHERE partition=?", arrayOf(offset.toString(), partition)).use { cursor ->
                            if (!cursor.moveToFirst()) throw CloudFailure.Storage()
                            text.append(cursor.getString(0))
                        }
                        offset += 131072
                    }
                    return CloudAccountState.parse(JSONObject(text.toString())).also { snapshots[partition] = it.detached() }
                }
                override fun write(partition: String, state: CloudAccountState) {
                    snapshots[partition] = state.detached()
                    db.insertWithOnConflict("cloud_accounts", null, ContentValues().apply { put("partition", partition); put("version", 1); put("state", state.json().toString()) }, SQLiteDatabase.CONFLICT_REPLACE).also { if (it < 0) throw CloudFailure.Storage() }
                }
                override fun sourceOwner(key: String): String? = db.rawQuery("SELECT partition FROM cloud_source_owners WHERE record_key=?", arrayOf(key)).use { if (it.moveToFirst()) it.getString(0) else null }
                override fun claim(key: String, partition: String) { db.execSQL("INSERT OR IGNORE INTO cloud_source_owners(record_key,partition) VALUES(?,?)", arrayOf(key, partition)) }
            }
            val result = body(tx); db.setTransactionSuccessful(); succeeded = true; result
        } finally {
            db.endTransaction()
            if (succeeded) committed.putAll(snapshots)
        }
    }
    /** Mapping commits before a legacy import can enter the outbox. */
    fun importedId(sourceKey: String): String = synchronized(Store.lock) {
        val db = writableDatabase
        db.beginTransaction()
        try {
            db.execSQL("INSERT OR IGNORE INTO cloud_import_ids(source_key,record_id) VALUES(?,?)", arrayOf(sourceKey, java.util.UUID.randomUUID().toString()))
            val id = db.rawQuery("SELECT record_id FROM cloud_import_ids WHERE source_key=?", arrayOf(sourceKey)).use { if (!it.moveToFirst()) throw CloudFailure.Storage(); it.getString(0) }
            db.setTransactionSuccessful(); id
        } finally { db.endTransaction() }
    }
}
