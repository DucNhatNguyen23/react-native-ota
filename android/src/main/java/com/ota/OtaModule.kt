package com.ota

import android.content.Context
import android.content.Intent
import android.util.Log
import com.facebook.react.module.annotations.ReactModule
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.zip.ZipInputStream
import okhttp3.*

@ReactModule(name = OtaModule.NAME)
class OtaModule(reactContext: ReactApplicationContext) : NativeOtaSpec(reactContext) {

    private val client = OkHttpClient()

    override fun getName(): String = NAME

    // ------------------ downloadBundle ------------------
    override fun downloadBundle(url: String, versionCode: Double, promise: Promise) {
        val request = Request.Builder().url(url).build()

        client.newCall(request).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                promise.reject("DOWNLOAD_FAILED", e)
            }

            override fun onResponse(call: Call, response: Response) {
                try {
                    if (!response.isSuccessful) {
                        promise.reject("HTTP_ERROR", "Code: ${response.code}")
                        return
                    }

                    val tempZip = File(reactApplicationContext.filesDir, "temp_bundle.zip")
                    response.body?.byteStream()?.use { input ->
                        FileOutputStream(tempZip).use { output ->
                            input.copyTo(output)
                        }
                    }

                    val bundleFile = File(reactApplicationContext.filesDir, "index.android.bundle")
                    unzipAndExtractBundle(tempZip, bundleFile)

                    if (!bundleFile.exists()) {
                        throw Exception("Bundle not found in ZIP")
                    }

                    tempZip.delete()

                    // Save version
                    val sharedPref = reactApplicationContext.getSharedPreferences("OTA_PREFS", Context.MODE_PRIVATE)
                    sharedPref.edit().putLong("ota_bundle_version", versionCode.toLong()).apply()

                    promise.resolve(true)
                } catch (e: Exception) {
                    promise.reject("PROCESS_FAILED", e)
                }
            }
        })
    }

    private fun unzipAndExtractBundle(zipFile: File, outputFile: File) {
        ZipInputStream(zipFile.inputStream()).use { zis ->
            var entry = zis.nextEntry
            while (entry != null) {
                if (entry.name == "index.android.bundle" && !entry.isDirectory) {
                    outputFile.parentFile?.mkdirs()
                    if (outputFile.exists()) outputFile.delete()
                    FileOutputStream(outputFile).use { fos -> zis.copyTo(fos) }
                    return
                }
                entry = zis.nextEntry
            }
            throw Exception("index.android.bundle not found in ZIP")
        }
    }

    // ------------------ reloadApp ------------------
    override fun reloadApp(promise: Promise) {
        val context: Context = reactApplicationContext
        try {
            val packageManager = context.packageManager
            val intent = packageManager.getLaunchIntentForPackage(context.packageName)
            intent?.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
            val mainIntent = Intent.makeRestartActivityTask(intent?.component)
            context.startActivity(mainIntent)
            promise.resolve("Reload triggered")
            Runtime.getRuntime().exit(0) // restart app
        } catch (e: Exception) {
            promise.reject("RELOAD_FAILED", e)
        }
    }

    // ------------------ getSavedVersion ------------------
    override fun getSavedVersion(): Double {
        val sharedPref = reactApplicationContext.getSharedPreferences("OTA_PREFS", Context.MODE_PRIVATE)
        val savedVersion = sharedPref.getLong("ota_bundle_version", 0L)
        return savedVersion.toDouble()
    }

    // ------------------ removeBundle ------------------
    override fun removeBundle(promise: Promise) {
        try {
            val bundleFile = File(reactApplicationContext.filesDir, "index.android.bundle")
            if (bundleFile.exists()) bundleFile.delete()

            val sharedPref = reactApplicationContext.getSharedPreferences("OTA_PREFS", Context.MODE_PRIVATE)
            sharedPref.edit().remove("ota_bundle_version").apply()

            promise.resolve(mapOf("status" to true, "message" to "OTA bundle removed successfully"))
        } catch (e: Exception) {
            promise.reject("REMOVE_FAILED", e)
        }
    }

    companion object {
        const val NAME = "Ota"
    }
}
