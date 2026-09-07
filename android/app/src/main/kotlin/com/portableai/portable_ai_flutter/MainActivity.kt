package com.portableai.portable_ai_flutter

import android.app.ActivityManager
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "rankrocket/device",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getTotalRam" -> {
                    try {
                        val am = getSystemService(ACTIVITY_SERVICE) as ActivityManager
                        val memInfo = ActivityManager.MemoryInfo()
                        am.getMemoryInfo(memInfo)
                        result.success(memInfo.totalMem)
                    } catch (e: Exception) {
                        result.error("RAM_UNAVAILABLE", e.message, null)
                    }
                }
                "getStableDeviceId" -> {
                    try {
                        val id = Settings.Secure.getString(
                            contentResolver,
                            Settings.Secure.ANDROID_ID,
                        )
                        result.success(id)
                    } catch (e: Exception) {
                        result.error("DEVICE_ID_UNAVAILABLE", e.message, null)
                    }
                }
                "getDeviceModel" -> result.success(Build.MODEL)
                "getOsVersion" -> result.success(Build.VERSION.RELEASE)
                "getAppVersion" -> {
                    try {
                        val pkgInfo = packageManager.getPackageInfo(packageName, 0)
                        result.success(pkgInfo.versionName)
                    } catch (e: Exception) {
                        result.error("VERSION_UNAVAILABLE", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
