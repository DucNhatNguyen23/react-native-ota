package com.ota

import android.util.Log
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.annotations.ReactModule
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.zip.ZipInputStream

import android.content.Context
import android.content.Intent

@ReactModule(name = OtaModule.NAME)
class OtaModule(reactContext: ReactApplicationContext) :
  NativeOtaSpec(reactContext) {

  override fun getName(): String {
    return NAME
  }
  private val client = OkHttpClient()


  override fun downloadBundle(url: String, promise: Promise) {

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
          response.body?.byteStream()?.copyTo(tempZip.outputStream())

          val bundleFile = File(reactApplicationContext.filesDir, "index.android.bundle")
          unzipAndExtractBundle(tempZip, bundleFile)

          if (!bundleFile.exists()) {
            throw Exception("Bundle not found in ZIP")
          }

          tempZip.delete()
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


override fun reloadApp(promise: Promise) {
  val context: Context = reactApplicationContext
  Log.d("OtaModule", "reloadApp() called in package: ${context.packageName}")

  try {
    val packageManager = context.packageManager
    val intent = packageManager.getLaunchIntentForPackage(context.packageName)
    intent?.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)

    val mainIntent = Intent.makeRestartActivityTask(intent?.component)
    context.startActivity(mainIntent)

    promise.resolve("Reload triggered") // ✅ Trả về React Native trước khi exit

    // Kill process để đảm bảo app restart lại từ đầu
    Runtime.getRuntime().exit(0)
  } catch (e: Exception) {
    promise.reject("RELOAD_FAILED", e)
  }
}

  companion object {
    const val NAME = "Ota"
  }
}
