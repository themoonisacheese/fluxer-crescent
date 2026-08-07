import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fluxer_app/core/providers/gateway_ready_provider.dart';
import 'package:fluxer_app/core/providers/gateway_reconnect_provider.dart';
import 'package:fluxer_app/core/router/fluxer_router.dart';
import 'package:fluxer_app/core/router/route_names.dart';
import 'package:fluxer_app/core/talker.dart';
import 'package:fluxer_app/features/auth/providers/login_view_model.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'share_handler.g.dart';

/// Simple data class representing a share payload received from Android.
class SharePayload {
  const SharePayload({this.text, this.streamUri});

  final String? text;
  final String? streamUri;

  bool get isEmpty =>
      (text == null || text!.isEmpty) &&
      (streamUri == null || streamUri!.isEmpty);

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
/// Navigation is deferred until the app is authenticated, the gateway is
/// ready, and there's no connection failure — mirroring the approach used
/// by [PendingPushNotificationPath] so the router redirect doesn't send
/// us back to /loading or /me.
///
/// On non-Android platforms this is a no-op.
@Riverpod(keepAlive: true)
class ShareHandler extends _$ShareHandler {
  static const _eventChannel = EventChannel('fluxer_app/share_intent_events');
  static const _methodChannel = MethodChannel('fluxer_app/share_intent');

  StreamSubscription<dynamic>? _subscription;

  /// Tracks whether the initial share intent check has finished.
  Completer<void>? _initialCheckComplete;

  @override
  SharePayload? build() {
    _initialCheckComplete = Completer<void>();

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      _subscription = _eventChannel.receiveBroadcastStream().listen(
        _onShareEvent,
        onError: (Object error) {
          talker.error('[ShareHandler] EventChannel error: $error');
        },
      );
      ref.onDispose(() => _subscription?.cancel());
      unawaited(_checkInitialShareIntent());
    } else {
      _initialCheckComplete!.complete();
    }

    // Listen to the same conditions the router redirect checks, so we
    // only navigate when the router will actually allow /share to stay.
    ref
      ..listen<bool>(authStateProvider, (_, bool next) {
        if (next) _tryNavigate();
      })
      ..listen<bool>(gatewayReadyProvider, (_, bool next) {
        if (next) _tryNavigate();
      })
      ..listen<bool>(gatewayConnectionFailedProvider, (_, bool next) {
        if (!next) _tryNavigate();
      });

    return null;
  }

  Future<void> _checkInitialShareIntent() async {
    try {
      final result =
          await _methodChannel.invokeMethod<Map>('getInitialShareIntent');
      if (result != null) {
        final payload = _parsePayload(result.cast<String, dynamic>());
        if (!payload.isEmpty) {
          talker.info('[ShareHandler] Initial share intent: $payload');
          state = payload;
          _tryNavigate();
        }
      }
    } on PlatformException catch (e) {
      talker.warning('[ShareHandler] Failed to get initial share intent: $e');
    } on MissingPluginException {
      // Bridge not yet registered — app may be running on non-Android.
    } finally {
      _initialCheckComplete?.complete();
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
    _tryNavigate();
  }

  SharePayload _parsePayload(Map<String, dynamic> map) {
    return SharePayload(
      text: map['text'] as String?,
      streamUri: map['streamUri'] as String?,
    );
  }

  /// Returns `true` if the router redirect would allow /share to stay.
  bool _canNavigate() {
    final isAuthenticated = ref.read(authStateProvider);
    final isGatewayReady = ref.read(gatewayReadyProvider);
    final isConnectionFailed = ref.read(gatewayConnectionFailedProvider);
    return isAuthenticated && isGatewayReady && !isConnectionFailed;
  }

  /// Attempts to navigate to /share if there's a pending payload and the
  /// app is in a state where the router will allow it.
  void _tryNavigate() {
    final payload = state;
    if (payload == null || payload.isEmpty) {
      return;
    }
    if (!_canNavigate()) {
      talker.info('[ShareHandler] Deferring navigation — app not ready');
      return;
    }
    talker.info('[ShareHandler] Navigating to share screen');
    final router = ref.read(fluxerRouterProvider);
    router.go(RoutePaths.share);
  }

  /// Called from [AppStartupProvider] after auth completes. Awaits the
  /// initial share-intent check, then attempts navigation (which may be
  /// deferred if the gateway isn't ready yet).
  Future<void> processPendingShare() async {
    await _initialCheckComplete?.future;
    _tryNavigate();
  }

  /// Clears the current payload (e.g. after the share screen consumes it).
  void clear() {
    state = null;
  }
}
