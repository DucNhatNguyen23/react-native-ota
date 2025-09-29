package com.ota

import android.content.Context
import android.util.Log
import java.io.File

object OtaHelper {

  private const val OTA_BUNDLE_NAME = "index.android.bundle"
  private const val PREFS_NAME = "OTA_PREFS"
  private const val KEY_LAST_VERSION = "last_version"
  private const val TAG = "OtaHelper"

  fun getBundleFile(context: Context): File? {
    val file = File(context.filesDir, OTA_BUNDLE_NAME)

    val sharedPref = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    val lastVersion = sharedPref.getString(KEY_LAST_VERSION, null)
    val currentVersion = context.packageManager.getPackageInfo(context.packageName, 0).versionName

    if (lastVersion == null || lastVersion != currentVersion) {
      if (file.exists()) {
        Log.i(TAG, "App updated → Xóa OTA bundle cũ: ${file.absolutePath}")
        file.delete()
      }
      sharedPref.edit().putString(KEY_LAST_VERSION, currentVersion).apply()
    }

    return if (file.exists()) {
      Log.i(TAG, "Đang sử dụng OTA bundle: ${file.absolutePath}")
      file
    } else {
      Log.i(TAG, "Không tìm thấy OTA bundle, fallback về bundle mặc định trong assets")
      null
    }
  }
}
