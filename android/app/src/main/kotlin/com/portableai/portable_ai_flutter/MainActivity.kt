package com.portableai.portable_ai_flutter

import android.app.ActivityManager
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
            if (call.method == "getTotalRam") {
                try {
                    val am = getSystemService(ACTIVITY_SERVICE) as ActivityManager
                    result.success(am.memoryInfo.totalMem)
                } catch (e: Exception) {
                    result.error("RAM_UNAVAILABLE", e.message, null)
                }
            } else {
                result.notImplemented()
            }
        }
    }
}
