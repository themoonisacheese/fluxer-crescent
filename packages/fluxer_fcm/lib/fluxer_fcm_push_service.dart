import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:fluxer_fcm/fcm_message_mapper.dart';
import 'package:fluxer_fcm/fcm_push_message.dart';
import 'package:fluxer_fcm/fcm_tap_payload_cache_hooks.dart';

class FluxerFcmPushService {
  factory FluxerFcmPushService() => instance;

  FluxerFcmPushService._();

  static final FluxerFcmPushService instance = FluxerFcmPushService._();

  final StreamController<FcmPushMessage> _messages =
      StreamController<FcmPushMessage>.broadcast();
  final StreamController<String> _tokenRefresh =
      StreamController<String>.broadcast();

  bool _initialized = false;
  String? _lastError;
  String? _currentToken;
  final Completer<void> _initCompleter = Completer<void>();
  void Function(Map<String, String> payload)? _onNotificationTap;
  Map<String, String>? _pendingNotificationTapPayload;
  StreamSubscription<RemoteMessage>? _onMessageSubscription;
  StreamSubscription<RemoteMessage>? _onMessageOpenedAppSubscription;
  StreamSubscription<String>? _onTokenRefreshSubscription;

  /// Optional hook to restore navigation fields stripped from hybrid FCM taps.
  Future<Map<String, String>> Function(
    RemoteMessage message,
    Map<String, String> mappedPayload,
  )?
  tapPayloadEnricher;

  bool Function(FcmPushMessage message)? _foregroundMessageFilter;

  Stream<String> get tokenRefreshStream => _tokenRefresh.stream;

  void setForegroundMessageFilter(
    bool Function(FcmPushMessage message)? filter,
  ) {
    _foregroundMessageFilter = filter;
  }

  @visibleForTesting
  bool Function(FcmPushMessage message)?
  get foregroundMessageFilterForTesting => _foregroundMessageFilter;

  @visibleForTesting
  bool shouldProcessForegroundMessage(FcmPushMessage message) {
    final bool Function(FcmPushMessage message)? filter =
        _foregroundMessageFilter;
    if (filter == null) {
      return true;
    }
    return filter(message);
  }

  void setNotificationTapCallback(
    void Function(Map<String, String> payload)? callback,
  ) {
    _onNotificationTap = callback;
    if (callback == null) {
      return;
    }
    final Map<String, String>? pendingPayload = _pendingNotificationTapPayload;
    if (pendingPayload == null) {
      return;
    }
    _pendingNotificationTapPayload = null;
    callback(pendingPayload);
  }

  Future<void> requestPermissions() async {
    final NotificationSettings settings = await FirebaseMessaging.instance
        .requestPermission();
    if (kDebugMode) {
      debugPrint(
        '[FluxerFcmPushService] permission: ${settings.authorizationStatus}',
      );
    }
  }

  Future<void> initialize({FirebaseOptions? firebaseOptions}) async {
    if (_initialized) {
      return;
    }
    try {
      // If dynamic options are provided but Firebase was already initialized
      // (e.g. by FirebaseInitProvider or a previous call), reinitialize with the
      // server's credentials so the correct messagingSenderId is used.
      if (firebaseOptions != null && Firebase.apps.isNotEmpty) {
        debugPrint('[FluxerFcmPushService] deleting existing Firebase app to reinit with dynamic credentials');
        await Firebase.app().delete();
      }
      if (Firebase.apps.isEmpty) {
        debugPrint('[FluxerFcmPushService] initializing Firebase with ${firebaseOptions != null ? "dynamic" : "default"} options, projectId=${firebaseOptions?.projectId}, senderId=${firebaseOptions?.messagingSenderId}');
        await Firebase.initializeApp(options: firebaseOptions);
        debugPrint('[FluxerFcmPushService] Firebase.initializeApp succeeded, apps=${Firebase.apps.length}');
      }
      await FirebaseMessaging.instance
          .setForegroundNotificationPresentationOptions(
            alert: true,
            badge: true,
            sound: true,
          );
      _onMessageSubscription = FirebaseMessaging.onMessage.listen(
        _onForegroundMessage,
      );
      _onMessageOpenedAppSubscription = FirebaseMessaging.onMessageOpenedApp
          .listen(_onMessageOpenedApp);
      _onTokenRefreshSubscription = FirebaseMessaging.instance.onTokenRefresh
          .listen((String token) {
            debugPrint('[FluxerFcmPushService] onTokenRefresh: $token');
            _currentToken = token;
            if (token.isNotEmpty) {
              _tokenRefresh.add(token);
            }
          });
      final RemoteMessage? initialMessage = await FirebaseMessaging.instance
          .getInitialMessage();
      if (initialMessage != null) {
        debugPrint(
          '[FluxerFcmPushService] getInitialMessage '
          'id=${initialMessage.messageId} data=${initialMessage.data}',
        );
        await _dispatchTap(initialMessage);
      }
      _initialized = true;
      _lastError = null;
      debugPrint('[FluxerFcmPushService] initialized');
    } on Object catch (error, stackTrace) {
      _lastError = error.toString();
      debugPrint('[FluxerFcmPushService] initialize FAILED: $error\n$stackTrace');
      rethrow;
    } finally {
      if (!_initCompleter.isCompleted) {
        _initCompleter.complete();
      }
    }
  }

  /// Wait for [initialize] to complete (success or failure).
  Future<void> get initialized => _initCompleter.future;

  Future<String?> getToken() async {
    try {
      // Ensure initialize() has completed before requesting a token.
      await _initCompleter.future;
      final String? token = await FirebaseMessaging.instance.getToken();
      _currentToken = token;
      debugPrint('[FluxerFcmPushService] getToken() => ${token != null ? "${token.substring(0, 20)}..." : "null"}');
      if (token == null || token.isEmpty) {
        // Force a token refresh — sometimes the SDK needs a nudge after
        // dynamic initialization.
        debugPrint('[FluxerFcmPushService] token was null, forcing deleteToken+getToken');
        await FirebaseMessaging.instance.deleteToken();
        final String? refreshed = await FirebaseMessaging.instance.getToken();
        _currentToken = refreshed;
        debugPrint('[FluxerFcmPushService] after refresh => ${refreshed != null ? "${refreshed.substring(0, 20)}..." : "null"}');
        return refreshed;
      }
      return token;
    } on Object catch (error, stackTrace) {
      _lastError = error.toString();
      debugPrint('[FluxerFcmPushService] getToken FAILED: $error\n$stackTrace');
      return null;
    }
  }

  Stream<FcmPushMessage> watchMessages() => _messages.stream;

  void _onForegroundMessage(RemoteMessage message) {
    final FcmPushMessage mapped = mapRemoteMessage(message);
    if (!shouldProcessForegroundMessage(mapped)) {
      return;
    }
    if (kDebugMode) {
      debugPrint('[FluxerFcmPushService] foreground id=${mapped.id}');
    }
    unawaited(_cacheTapPayloadIfNeeded(message, mapped.payload));
    _messages.add(mapped);
  }

  Future<void> _cacheTapPayloadIfNeeded(
    RemoteMessage message,
    Map<String, String> payload,
  ) async {
    if (!FcmTapPayloadCacheHooks.shouldSaveTapPayloadCache(payload)) {
      return;
    }
    await FcmTapPayloadCacheHooks.saveTapPayloadCache(
      payload: payload,
      gcmMessageId: message.messageId,
    );
  }

  void _onMessageOpenedApp(RemoteMessage message) {
    if (kDebugMode) {
      debugPrint(
        '[FluxerFcmPushService] onMessageOpenedApp '
        'id=${message.messageId} data=${message.data}',
      );
    }
    unawaited(_dispatchTap(message));
  }

  Future<void> _dispatchTap(RemoteMessage message) async {
    final FcmPushMessage mapped = mapRemoteMessage(message);
    Map<String, String> payload = mapped.payload;
    final Future<Map<String, String>> Function(
      RemoteMessage message,
      Map<String, String> mappedPayload,
    )?
    enricher = tapPayloadEnricher;
    if (enricher != null) {
      payload = await enricher(message, payload);
    }
    if (kDebugMode) {
      debugPrint('[FluxerFcmPushService] tap payload=$payload');
    }
    _dispatchTapPayload(payload);
  }

  void _dispatchTapPayload(Map<String, String> payload) {
    final void Function(Map<String, String> payload)? callback =
        _onNotificationTap;
    if (callback != null) {
      callback(payload);
      return;
    }
    _pendingNotificationTapPayload = Map<String, String>.unmodifiable(payload);
  }

  /// Diagnostic info for troubleshooting.
  String get diagnosticInfo {
    return 'init=$_initialized, token=${_currentToken != null ? "${_currentToken!.substring(0, 20)}..." : "null"}, error=${_lastError ?? "none"}, apps=${Firebase.apps.length}';
  }

  @visibleForTesting
  void dispatchTapPayloadForTesting(Map<String, String> payload) {
    _dispatchTapPayload(payload);
  }

  @visibleForTesting
  void resetForTesting() {
    _initialized = false;
    _onNotificationTap = null;
    _pendingNotificationTapPayload = null;
    unawaited(_onMessageSubscription?.cancel());
    unawaited(_onMessageOpenedAppSubscription?.cancel());
    unawaited(_onTokenRefreshSubscription?.cancel());
    _onMessageSubscription = null;
    _onMessageOpenedAppSubscription = null;
    _onTokenRefreshSubscription = null;
    _foregroundMessageFilter = null;
    tapPayloadEnricher = null;
    FcmTapPayloadCacheHooks.resetForTesting();
  }
}
