package com.fluxer

import android.content.Intent
import android.net.Uri
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/// Bridges Android ACTION_SEND intents to Flutter.
///
/// Exposes the shared text (and optional stream-Uri) via an [EventChannel]
/// so the Dart side can react to both the initial launch intent and
/// subsequent shares while the app is running (singleInstance → onNewIntent).
class ShareIntentBridge {

    companion object {
        private const val METHOD_CHANNEL = "fluxer_app/share_intent"
        private const val EVENT_CHANNEL = "fluxer_app/share_intent_events"
        private const val METHOD_GET_INITIAL = "getInitialShareIntent"
        private const val KEY_TEXT = "text"
        private const val KEY_STREAM_URI = "streamUri"
    }

    private var eventSink: EventChannel.EventSink? = null
    private var pendingEvent: Map<String, String?>? = null

    fun register(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            METHOD_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                METHOD_GET_INITIAL -> {
                    val initial = _lastIntentMap
                    result.success(initial)
                    _lastIntentMap = null
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EVENT_CHANNEL,
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                eventSink = sink
                pendingEvent?.let { event ->
                    sink.success(event)
                    pendingEvent = null
                }
            }
            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }

    /// Called from [MainActivity.onCreate] / [MainActivity.onNewIntent].
    @Suppress("DEPRECATION")
    fun handleIntent(intent: Intent?) {
        if (intent == null || intent.action != Intent.ACTION_SEND) {
            return
        }
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        val streamUri: Uri? = intent.getParcelableExtra(Intent.EXTRA_STREAM)
        if (text.isNullOrEmpty() && streamUri == null) {
            return
        }
        val event = mapOf(
            KEY_TEXT to (text ?: ""),
            KEY_STREAM_URI to (streamUri?.toString() ?: ""),
        ).filterValues { it?.isNotEmpty() == true }
        _lastIntentMap = event
        val sink = eventSink
        if (sink != null) {
            sink.success(event)
            _lastIntentMap = null
        } else {
            pendingEvent = event
        }
    }

    private var _lastIntentMap: Map<String, String?>? = null
}
