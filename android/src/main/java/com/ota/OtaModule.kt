package com.ota

import android.content.Context
import android.content.Intent
import com.facebook.react.module.annotations.ReactModule
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.WritableMap
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.ZipFile
import okhttp3.*

@ReactModule(name = OtaModule.NAME)
class OtaModule(reactContext: ReactApplicationContext) : NativeOtaSpec(reactContext) {

    private val client = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()

    // Downloads share the staging folder, so only one may run at a time
    private val downloading = AtomicBoolean(false)

    override fun getName(): String = NAME

    // ------------------ downloadBundle ------------------
    // The zip goes to filesDir (cacheDir can be wiped by the OS mid-download -> FileNotFoundException on unzip)
    // and is kept per version when the connection drops, so the next attempt resumes with an HTTP Range request.
    override fun downloadBundle(url: String, versionCode: Double, sha256: String?, promise: Promise) {
        val context = reactApplicationContext
        val partFile = File(context.filesDir, "$PART_PREFIX$versionCode$PART_SUFFIX")
        // Partial downloads of other versions are stale
        context.filesDir.listFiles()?.forEach {
            if (it.name.startsWith(PART_PREFIX) && it.name != partFile.name) it.delete()
        }
        val resumeFrom = if (partFile.isFile) partFile.length() else 0L

        val request = try {
            Request.Builder().url(url).apply {
                if (resumeFrom > 0) header("Range", "bytes=$resumeFrom-")
            }.build()
        } catch (e: IllegalArgumentException) {
            promise.reject("INVALID_URL", e)
            return
        }

        if (!downloading.compareAndSet(false, true)) {
            promise.reject("ALREADY_DOWNLOADING", "Another download is in progress")
            return
        }

        client.newCall(request).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                downloading.set(false)
                promise.reject("DOWNLOAD_FAILED", e)
            }

            override fun onResponse(call: Call, response: Response) {
                val stagingDir = OtaHelper.stagingDir(context)
                // Keep the partial file only when the transfer itself was interrupted
                var keepPart = false
                try {
                    response.use {
                        if (it.code == 416) {
                            // Partial file no longer matches the remote one: start over next time
                            promise.reject("HTTP_ERROR", "Code: 416")
                            return
                        }
                        if (!it.isSuccessful) {
                            keepPart = true
                            promise.reject("HTTP_ERROR", "Code: ${it.code}")
                            return
                        }
                        val body = it.body ?: throw IOException("Empty response body")
                        // 206 = server continues where we stopped; 200 = full file, overwrite
                        val append = it.code == 206 && resumeFrom > 0
                        val already = if (append) resumeFrom else 0L
                        val total = if (body.contentLength() > 0) already + body.contentLength() else -1L

                        // zip + extracted copy + previous bundle kept for rollback, plus a margin
                        if (total > 0 && context.filesDir.usableSpace < total * 3 + FREE_SPACE_MARGIN) {
                            keepPart = true
                            promise.reject("INSUFFICIENT_SPACE", "Not enough free space for the OTA bundle")
                            return
                        }

                        val progress = ProgressEmitter("download", total)
                        keepPart = true
                        body.byteStream().use { input ->
                            FileOutputStream(partFile, append).use { output ->
                                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                                var received = already
                                var read = input.read(buffer)
                                while (read >= 0) {
                                    output.write(buffer, 0, read)
                                    received += read
                                    progress.update(received)
                                    read = input.read(buffer)
                                }
                                progress.finish(received)
                            }
                        }
                        keepPart = false
                    }

                    if (!sha256.isNullOrEmpty()) {
                        val actual = sha256Of(partFile)
                        if (!actual.equals(sha256, ignoreCase = true)) {
                            promise.reject("CHECKSUM_MISMATCH", "Expected sha256 $sha256, got $actual")
                            return
                        }
                    }

                    // Extract into staging first so a broken zip never replaces a working bundle
                    stagingDir.deleteRecursively()
                    unzip(partFile, stagingDir)

                    if (!File(stagingDir, OtaHelper.OTA_BUNDLE_NAME).isFile) {
                        throw IOException("${OtaHelper.OTA_BUNDLE_NAME} not found in ZIP")
                    }

                    OtaHelper.install(context, stagingDir, versionCode)

                    promise.resolve(result(true, "Download and unzip successfully"))
                } catch (e: Exception) {
                    promise.reject(if (keepPart) "DOWNLOAD_FAILED" else "PROCESS_FAILED", e)
                } finally {
                    stagingDir.deleteRecursively()
                    if (!keepPart) partFile.delete()
                    downloading.set(false)
                }
            }
        })
    }

    private fun sha256Of(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            var read = input.read(buffer)
            while (read >= 0) {
                digest.update(buffer, 0, read)
                read = input.read(buffer)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    // Extracts the whole archive (bundle + drawable-*/raw assets), guarding against zip slip
    private fun unzip(zipFile: File, destDir: File) {
        val destPath = destDir.canonicalPath + File.separator
        ZipFile(zipFile).use { zip ->
            val progress = ProgressEmitter("unzip", zip.size().toLong())
            var done = 0L
            for (entry in zip.entries()) {
                val outFile = File(destDir, entry.name)
                if (!outFile.canonicalPath.startsWith(destPath)) {
                    throw IOException("Invalid zip entry: ${entry.name}")
                }
                if (entry.isDirectory) {
                    outFile.mkdirs()
                } else {
                    outFile.parentFile?.mkdirs()
                    zip.getInputStream(entry).use { input ->
                        FileOutputStream(outFile).use { output -> input.copyTo(output) }
                    }
                }
                progress.update(++done)
            }
            progress.finish(done)
        }
    }

    // Emits onProgress only when the integer percent changes (at most ~100 events per phase),
    // or every PROGRESS_INTERVAL_MS when the total size is unknown
    private inner class ProgressEmitter(private val phase: String, private val total: Long) {
        private var lastPercent = -1
        private var lastEmitAt = 0L

        fun update(received: Long) {
            if (total > 0) {
                val percent = (received * 100 / total).toInt()
                if (percent == lastPercent) return
                lastPercent = percent
                emit(received, percent)
            } else {
                val now = System.currentTimeMillis()
                if (now - lastEmitAt < PROGRESS_INTERVAL_MS) return
                lastEmitAt = now
                emit(received, -1)
            }
        }

        fun finish(received: Long) {
            if (lastPercent != 100) emit(received, 100)
        }

        private fun emit(received: Long, percent: Int) {
            emitOnProgress(Arguments.createMap().apply {
                putString("phase", phase)
                putInt("progress", percent)
                putDouble("received", received.toDouble())
                putDouble("total", total.toDouble())
            })
        }
    }

    // ------------------ reloadApp ------------------
    override fun reloadApp(promise: Promise) {
        val context: Context = reactApplicationContext
        try {
            val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?: throw IllegalStateException("Launch intent not found")
            val mainIntent = Intent.makeRestartActivityTask(intent.component)
            context.startActivity(mainIntent)
            promise.resolve("Reload triggered")
            // The bundle path is read once when ReactHost is created, so a full process restart is required
            Runtime.getRuntime().exit(0)
        } catch (e: Exception) {
            promise.reject("RELOAD_FAILED", e)
        }
    }

    // ------------------ versions ------------------
    override fun getSavedVersion(): Double =
        OtaHelper.savedVersion(reactApplicationContext)

    override fun getFailedVersion(): Double =
        OtaHelper.failedVersion(reactApplicationContext)

    override fun getNativeVersion(): String =
        OtaHelper.getNativeVersion(reactApplicationContext)

    // ------------------ notifyAppReady ------------------
    override fun notifyAppReady() {
        OtaHelper.notifyAppReady(reactApplicationContext)
    }

    // ------------------ removeBundle ------------------
    override fun removeBundle(promise: Promise) {
        try {
            OtaHelper.clear(reactApplicationContext)
            promise.resolve(result(true, "OTA bundle removed successfully"))
        } catch (e: Exception) {
            promise.reject("REMOVE_FAILED", e)
        }
    }

    private fun result(status: Boolean, message: String): WritableMap =
        Arguments.createMap().apply {
            putBoolean("status", status)
            putString("message", message)
        }

    companion object {
        const val NAME = "Ota"
        private const val PROGRESS_INTERVAL_MS = 100L
        private const val PART_PREFIX = "ota_download_"
        private const val PART_SUFFIX = ".part"
        private const val FREE_SPACE_MARGIN = 50L * 1024 * 1024
    }
}
