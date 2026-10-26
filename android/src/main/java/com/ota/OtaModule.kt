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
    override fun downloadBundle(url: String, versionCode: Double, sha256: String?, promise: Promise) {
        val request = try {
            Request.Builder().url(url).build()
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
                val context = reactApplicationContext
                val tempZip = File(context.cacheDir, "ota_download.zip")
                val stagingDir = OtaHelper.stagingDir(context)
                try {
                    val digest = MessageDigest.getInstance("SHA-256")
                    response.use {
                        if (!it.isSuccessful) {
                            promise.reject("HTTP_ERROR", "Code: ${it.code}")
                            return
                        }
                        val body = it.body ?: throw IOException("Empty response body")
                        val progress = ProgressEmitter("download", body.contentLength())
                        body.byteStream().use { input ->
                            FileOutputStream(tempZip).use { output ->
                                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                                var received = 0L
                                var read = input.read(buffer)
                                while (read >= 0) {
                                    output.write(buffer, 0, read)
                                    digest.update(buffer, 0, read)
                                    received += read
                                    progress.update(received)
                                    read = input.read(buffer)
                                }
                                progress.finish(received)
                            }
                        }
                    }

                    if (!sha256.isNullOrEmpty()) {
                        val actual = digest.digest().joinToString("") { "%02x".format(it) }
                        if (!actual.equals(sha256, ignoreCase = true)) {
                            promise.reject("CHECKSUM_MISMATCH", "Expected sha256 $sha256, got $actual")
                            return
                        }
                    }

                    // Extract into staging first so a broken zip never replaces a working bundle
                    stagingDir.deleteRecursively()
                    unzip(tempZip, stagingDir)

                    if (!File(stagingDir, OtaHelper.OTA_BUNDLE_NAME).isFile) {
                        throw IOException("${OtaHelper.OTA_BUNDLE_NAME} not found in ZIP")
                    }

                    OtaHelper.install(context, stagingDir, versionCode)

                    promise.resolve(result(true, "Download and unzip successfully"))
                } catch (e: Exception) {
                    promise.reject("PROCESS_FAILED", e)
                } finally {
                    stagingDir.deleteRecursively()
                    tempZip.delete()
                    downloading.set(false)
                }
            }
        })
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
    }
}
