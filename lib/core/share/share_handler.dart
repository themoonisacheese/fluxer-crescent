import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fluxer_app/core/router/fluxer_router.dart';
import 'package:fluxer_app/core/router/route_names.dart';
import 'package:fluxer_app/core/talker.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'share_handler.g.dart';

/// Simple data class representing a share payload received from Android.
class SharePayload {
  const SharePayload({this.text, this.streamUri});

  final String? text;
  final String? streamUri;

  bool get isEmpty => (text == null || text!.isEmpty) && (streamUri == null || streamUri!.isEmpty);

  @override
  String toString() {
    final t = text;
    if (t == null) return 'SharePayload(streamUri: $streamUri)';
    final preview = t.length > 50 ? '${t.substring(0, 50)}…' : t;
    return 'SharePayload(text: $preview, streamUri: $streamUri)';
  }
}

/// Receives ACTION_SEND intents from Android via a native [EventChannel]
/// and [MethodChannel], and navigates to the share screen.
///
/// On non-Android platforms this is a no-op.
@Riverpod(keepAlive: true)
class ShareHandler extends _$ShareHandler {
  static const _eventChannel = EventChannel('fluxer_app/share_intent_events');
  static const _methodChannel = MethodChannel('fluxer_app/share_intent');

  StreamSubscription<dynamic>? _subscription;

  @override
  SharePayload? build() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      _subscription = _eventChannel.receiveBroadcastStream().listen(
        _onShareEvent,
        onError: (Object error) {
          talker.error('[ShareHandler] EventChannel error: $error');
        },
      );
      ref.onDispose(() => _subscription?.cancel());
      unawaited(_checkInitialShareIntent());
    }
    return null;
  }

  Future<void> _checkInitialShareIntent() async {
    try {
      final result = await _methodChannel.invokeMethod<Map>('getInitialShareIntent');
      if (result != null) {
        final payload = _parsePayload(result.cast<String, dynamic>());
        if (!payload.isEmpty) {
          talker.info('[ShareHandler] Initial share intent: $payload');
          state = payload;
        }
      }
    } on PlatformException catch (e) {
      talker.warning('[ShareHandler] Failed to get initial share intent: $e');
    } on MissingPluginException {
      // Bridge not yet registered — app may be running on non-Android.
    }
  }

  void _onShareEvent(dynamic event) {
    if (event is! Map) {
      return;
    }
    final payload = _parsePayload(event.cast<String, dynamic>());
    if (payload.isEmpty) {
      return;
    }
    talker.info('[ShareHandler] Share event: $payload');
    state = payload;
  }

  SharePayload _parsePayload(Map<String, dynamic> map) {
    return SharePayload(
      text: map['text'] as String?,
      streamUri: map['streamUri'] as String?,
    );
  }

  /// Routes to the share screen if there's a pending payload and the user
  /// is authenticated. Called from [AppStartupProvider] after auth completes.
  void processPendingShare() {
    final payload = state;
    if (payload == null || payload.isEmpty) {
      return;
    }
    final router = ref.read(fluxerRouterProvider);
    router.go(RoutePaths.share);
  }

  /// Clears the current payload (e.g. after the share screen consumes it).
  void clear() {
    state = null;
  }
}
