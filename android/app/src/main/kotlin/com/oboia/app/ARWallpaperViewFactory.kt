package com.oboia.app

import android.content.Context
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

/**
 * Platform view factory — registered in MainActivity.
 */
class ARWallpaperViewFactory(
    private val messenger: BinaryMessenger
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val params = args as? Map<String?, Any?>
        return ARWallpaperView(context, messenger, viewId, params)
    }
}

/**
 * Disk + in-memory texture cache. Mirrors the iOS TextureCache.
 *
 * Files are downloaded from Firebase Storage URLs and stored on the app cache dir.
 * Cache is trimmed to 200 MB.
 */
class AndroidTextureCache(private val context: Context) {

    companion object {
        private const val TAG = "AndroidTextureCache"
        private const val MAX_BYTES = 200L * 1024L * 1024L
        private const val TIMEOUT_MS = 30_000
    }

    private val cacheDir: File by lazy {
        File(context.cacheDir, "oboia_pbr_textures").apply { mkdirs() }
    }
    private val inflight = ConcurrentHashMap<String, Mutex>()
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    fun isCached(url: String): Boolean {
        if (url.isEmpty()) return false
        val f = fileFor(url)
        return f.exists() && f.length() > 0
    }

    fun localPathSync(url: String): String? {
        val f = fileFor(url)
        return if (f.exists() && f.length() > 0) f.absolutePath else null
    }

    suspend fun loadLocalPath(url: String): String? {
        if (url.isEmpty()) return null
        val f = fileFor(url)
        if (f.exists() && f.length() > 0) return f.absolutePath

        // Coalesce duplicate downloads with a per-URL mutex
        val lock = inflight.getOrPut(url) { Mutex() }
        lock.withLock {
            if (f.exists() && f.length() > 0) return f.absolutePath
            val ok = downloadTo(url, f)
            if (!ok) return null
        }
        inflight.remove(url)
        trimAsync()
        return if (f.exists()) f.absolutePath else null
    }

    private suspend fun downloadTo(urlStr: String, dest: File): Boolean = withContext(Dispatchers.IO) {
        var conn: HttpURLConnection? = null
        val tmp = File(dest.absolutePath + ".tmp")
        try {
            val url = URL(urlStr)
            conn = (url.openConnection() as HttpURLConnection).apply {
                connectTimeout = TIMEOUT_MS
                readTimeout = TIMEOUT_MS
                requestMethod = "GET"
                doInput = true
            }
            conn.connect()
            if (conn.responseCode !in 200..299) {
                Log.w(TAG, "HTTP ${conn.responseCode} for $urlStr")
                return@withContext false
            }
            conn.inputStream.use { input ->
                tmp.outputStream().use { out -> input.copyTo(out, 32 * 1024) }
            }
            if (!tmp.renameTo(dest)) {
                tmp.copyTo(dest, overwrite = true); tmp.delete()
            }
            true
        } catch (t: Throwable) {
            Log.e(TAG, "Download failed for $urlStr", t)
            tmp.delete()
            false
        } finally {
            conn?.disconnect()
        }
    }

    private fun fileFor(url: String): File {
        val md = MessageDigest.getInstance("SHA-256").digest(url.toByteArray())
        val name = md.joinToString("") { "%02x".format(it) }
        return File(cacheDir, name)
    }

    private var lastTrim: Long = 0
    private fun trimAsync() {
        val now = System.currentTimeMillis()
        if (now - lastTrim < 30_000) return
        lastTrim = now
        scope.launch(Dispatchers.IO) {
            val files = cacheDir.listFiles()?.toList().orEmpty()
            var total = files.sumOf { it.length() }
            if (total <= MAX_BYTES) return@launch
            val sorted = files.sortedBy { it.lastModified() }
            for (f in sorted) {
                if (total <= MAX_BYTES) break
                val len = f.length()
                if (f.delete()) total -= len
            }
        }
    }

    private fun CoroutineScope.launch(
        dispatcher: kotlinx.coroutines.CoroutineDispatcher,
        block: suspend CoroutineScope.() -> Unit
    ) {
        kotlinx.coroutines.launch(dispatcher, block = block)
    }
}
