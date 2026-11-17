package com.mooeen.moo_monitor_flutter

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import org.json.JSONObject

/**
 * Minimal native bridge: wraps the default uncaught exception handler to append
 * a pending record, then replays pending records when Dart asks. NDK signals and
 * ANR watchdog are TODO (see docs) and must not be claimed as covered.
 */
class MooMonitorFlutterPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "moo_monitor/native")
        channel.setMethodCallHandler(this)
        installHandler()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "flushPending") {
            flushPending()
            result.success(null)
        } else {
            result.notImplemented()
        }
    }

    private fun pendingFile() = File(context.filesDir, "moo_monitor_native_pending.jsonl")

    private fun installHandler() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                val record = JSONObject()
                    .put("kind", "crash")
                    .put("name", error.javaClass.name)
                    .put("message", error.message ?: "Native error")
                    .put("source", "native_forward")
                    .put("ts", System.currentTimeMillis())
                pendingFile().appendText(record.toString() + "\n")
            } catch (_: Throwable) {
                // Never interfere with the host's crash handling.
            }
            previous?.uncaughtException(thread, error)
        }
    }

    private fun flushPending() {
        val file = pendingFile()
        if (!file.exists()) return
        val lines = try {
            file.readLines().also { file.delete() }
        } catch (_: Throwable) {
            return
        }
        for (line in lines) {
            try {
                val obj = JSONObject(line)
                val args = mapOf(
                    "kind" to obj.optString("kind", "crash"),
                    "name" to obj.optString("name", "Native"),
                    "message" to obj.optString("message", "Native error"),
                    "source" to "native_forward"
                )
                channel.invokeMethod("captureNative", args)
            } catch (_: Throwable) {
                // Skip malformed pending records.
            }
        }
    }
}
