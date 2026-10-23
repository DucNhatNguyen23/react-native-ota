package com.ota

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.util.Log
import java.io.File
import java.io.IOException

/**
 * Owns the OTA bundle state. Layout:
 *   filesDir/ota/<version>_<timestamp>/index.android.bundle + drawable-* / raw (one folder per install)
 *   filesDir/ota/staging/  (download in progress)
 *
 * A new bundle starts as "pending". The first launch marks it as launched; if JS does not call
 * notifyAppReady() before the next launch, the bundle is considered broken and rolled back.
 */
object OtaHelper {

  internal const val OTA_BUNDLE_NAME = "index.android.bundle"
  private const val ROOT_DIR = "ota"
  private const val STAGING_DIR = "staging"
  private const val TAG = "OtaHelper"

  private const val PREFS_NAME = "OTA_PREFS"
  private const val KEY_LAST_VERSION = "last_version"
  private const val KEY_VERSION = "ota_bundle_version"
  private const val KEY_DIR = "ota_current_dir"
  private const val KEY_PREVIOUS_VERSION = "ota_previous_version"
  private const val KEY_PREVIOUS_DIR = "ota_previous_dir"
  private const val KEY_PENDING = "ota_pending"
  private const val KEY_PENDING_LAUNCHED = "ota_pending_launched"
  private const val KEY_FAILED_VERSION = "ota_failed_version"

  // ReactHost reads getJSBundleFile() on every access but only uses the first value,
  // so resolve once per process
  private var resolved = false
  private var runningBundle: File? = null
  private var runningDir: String? = null

  @Synchronized
  fun getBundleFile(context: Context): File? {
    if (resolved) return runningBundle
    resolved = true

    val prefs = prefs(context)
    val nativeVersion = getNativeVersion(context)
    if (prefs.getString(KEY_LAST_VERSION, null) != nativeVersion) {
      Log.i(TAG, "Native version changed to $nativeVersion, removing OTA bundles")
      prefs.edit().clear().putString(KEY_LAST_VERSION, nativeVersion).commit()
      // Legacy location (<= 1.0.1)
      File(context.filesDir, OTA_BUNDLE_NAME).delete()
    }

    if (prefs.getBoolean(KEY_PENDING, false)) {
      if (prefs.getBoolean(KEY_PENDING_LAUNCHED, false)) {
        Log.w(TAG, "OTA bundle ${prefs.getLong(KEY_VERSION, 0)} did not call notifyAppReady, rolling back")
        rollback(prefs)
      } else {
        // commit() so the flag survives a crash right after this
        prefs.edit().putBoolean(KEY_PENDING_LAUNCHED, true).commit()
      }
    }

    var bundle = currentBundle(context, prefs)
    if (bundle == null && prefs.getString(KEY_DIR, null) != null) {
      Log.w(TAG, "OTA bundle files missing, rolling back")
      rollback(prefs)
      bundle = currentBundle(context, prefs)
      if (bundle == null) {
        prefs.edit().remove(KEY_DIR).remove(KEY_VERSION).commit()
      }
    }

    runningBundle = bundle
    runningDir = bundle?.let { prefs.getString(KEY_DIR, null) }
    cleanup(context, prefs)

    Log.i(TAG, if (bundle != null) "Using OTA bundle: ${bundle.absolutePath}" else "Using embedded bundle")
    return bundle
  }

  internal fun stagingDir(context: Context): File = File(rootDir(context), STAGING_DIR)

  @Synchronized
  internal fun install(context: Context, staging: File, version: Long) {
    val name = "${version}_${System.currentTimeMillis()}"
    if (!staging.renameTo(File(rootDir(context), name))) {
      throw IOException("Failed to move OTA bundle into place")
    }

    val prefs = prefs(context)
    val editor = prefs.edit()
    if (!prefs.getBoolean(KEY_PENDING, false)) {
      // The current bundle is confirmed (or embedded), it becomes the rollback target.
      // Otherwise it was never confirmed, so keep the last known good one.
      editor.putString(KEY_PREVIOUS_DIR, prefs.getString(KEY_DIR, null))
        .putLong(KEY_PREVIOUS_VERSION, prefs.getLong(KEY_VERSION, 0))
    }
    editor.putString(KEY_DIR, name)
      .putLong(KEY_VERSION, version)
      .putBoolean(KEY_PENDING, true)
      .putBoolean(KEY_PENDING_LAUNCHED, false)
      .commit()

    cleanup(context, prefs)
  }

  @Synchronized
  internal fun notifyAppReady(context: Context) {
    val prefs = prefs(context)
    if (!prefs.getBoolean(KEY_PENDING, false)) return
    // A bundle downloaded during this session is not running yet, it must not be confirmed
    if (runningDir == null || runningDir != prefs.getString(KEY_DIR, null)) return

    prefs.edit()
      .remove(KEY_PENDING)
      .remove(KEY_PENDING_LAUNCHED)
      .remove(KEY_PREVIOUS_DIR)
      .remove(KEY_PREVIOUS_VERSION)
      .commit()
    cleanup(context, prefs)
  }

  @Synchronized
  internal fun clear(context: Context) {
    val prefs = prefs(context)
    val nativeVersion = prefs.getString(KEY_LAST_VERSION, null)
    prefs.edit().clear().putString(KEY_LAST_VERSION, nativeVersion).commit()
    cleanup(context, prefs)
  }

  internal fun savedVersion(context: Context): Long = prefs(context).getLong(KEY_VERSION, 0)

  internal fun failedVersion(context: Context): Long = prefs(context).getLong(KEY_FAILED_VERSION, 0)

  // versionName alone is not enough: a store build can bump only versionCode
  internal fun getNativeVersion(context: Context): String {
    val info = context.packageManager.getPackageInfo(context.packageName, 0)
    val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
      info.longVersionCode
    } else {
      @Suppress("DEPRECATION")
      info.versionCode.toLong()
    }
    return "${info.versionName}($code)"
  }

  private fun rollback(prefs: SharedPreferences) {
    prefs.edit()
      .putLong(KEY_FAILED_VERSION, prefs.getLong(KEY_VERSION, 0))
      .putString(KEY_DIR, prefs.getString(KEY_PREVIOUS_DIR, null))
      .putLong(KEY_VERSION, prefs.getLong(KEY_PREVIOUS_VERSION, 0))
      .remove(KEY_PREVIOUS_DIR)
      .remove(KEY_PREVIOUS_VERSION)
      .remove(KEY_PENDING)
      .remove(KEY_PENDING_LAUNCHED)
      .commit()
  }

  private fun currentBundle(context: Context, prefs: SharedPreferences): File? {
    val dir = prefs.getString(KEY_DIR, null) ?: return null
    return File(File(rootDir(context), dir), OTA_BUNDLE_NAME).takeIf { it.isFile }
  }

  // Deletes every install folder that is not current, previous, running or being downloaded
  private fun cleanup(context: Context, prefs: SharedPreferences) {
    val keep = setOf(
      prefs.getString(KEY_DIR, null),
      prefs.getString(KEY_PREVIOUS_DIR, null),
      runningDir,
      STAGING_DIR
    )
    rootDir(context).listFiles()?.forEach {
      if (it.name !in keep) it.deleteRecursively()
    }
  }

  private fun rootDir(context: Context): File = File(context.filesDir, ROOT_DIR)

  private fun prefs(context: Context): SharedPreferences =
    context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
}
