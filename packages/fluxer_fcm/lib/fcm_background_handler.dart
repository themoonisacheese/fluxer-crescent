import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:fluxer_fcm/fcm_background_handler_policy.dart';
import 'package:fluxer_fcm/fcm_background_local_notifications.dart';
import 'package:fluxer_fcm/fcm_message_mapper.dart';
import 'package:fluxer_fcm/fcm_push_message.dart';
import 'package:fluxer_fcm/firebase_options.dart';
import 'package:fluxer_fcm/fluxer_fcm_bootstrap.dart';
import 'package:shared_preferences/shared_preferences.dart';

@pragma('vm:entry-point')
Future<void> fcmBackgroundMessageHandler(RemoteMessage message) async {
  // Ensure Flutter bindings are initialized for plugin access.
  try {
    WidgetsFlutterBinding.ensureInitialized();
  } on Object catch (error, stackTrace) {
    debugPrint('[FCM] WidgetsFlutterBinding failed: $error\n$stackTrace');
  }

  // Initialize Firebase in a non-fatal way. The background handler runs in a
  // separate isolate where Firebase.apps is always empty, so it must
  // re-initialize. However, notification display (via
  // flutter_local_notifications) does NOT depend on Firebase being available.
  // If initialization fails (e.g. cached dynamic credentials are missing or
  // DefaultFirebaseOptions has placeholder values), we still show the
  // notification.
  if (Firebase.apps.isEmpty) {
    try {
      await Firebase.initializeApp(
        options: await _loadCachedFirebaseOptions()
            ?? DefaultFirebaseOptions.currentPlatform,
      );
    } on Object catch (error, stackTrace) {
      debugPrint(
        '[FCM] Firebase.initializeApp failed (non-fatal, continuing): '
        '$error\n$stackTrace',
      );
    }
  }

  debugPrint(
    '[FCM] background message id=${message.messageId} '
    'hasNotification=${message.notification != null} '
    'data=${message.data}',
  );

  try {
    final FcmPushMessage mapped = mapRemoteMessage(message);
    if (FluxerFcmBootstrap.shouldSaveTapPayloadCache(mapped.payload)) {
      await FluxerFcmBootstrap.saveTapPayloadCache(
        payload: mapped.payload,
        gcmMessageId: message.messageId,
      );
    }
    if (shouldDisplayFcmBackgroundLocalNotification(message, mapped)) {
      await showFcmBackgroundNotification(mapped);
    }
  } on Object catch (error, stackTrace) {
    debugPrint('[FCM] notification display failed: $error\n$stackTrace');
  }
}

/// Load cached FCM credentials from SharedPreferences.
/// Returns null if no dynamic credentials have been cached yet.
Future<FirebaseOptions?> _loadCachedFirebaseOptions() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString('fcm_android_credentials');
    if (raw == null || raw.isEmpty) return null;
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final appId = data['app_id'] as String?;
    final projectId = data['project_id'] as String?;
    final apiKey = data['api_key'] as String?;
    final senderId = data['sender_id'] as String?;
    if (appId == null || projectId == null || apiKey == null || senderId == null) {
      return null;
    }
    return FirebaseOptions(
      appId: appId,
      projectId: projectId,
      apiKey: apiKey,
      messagingSenderId: senderId,
    );
  } catch (_) {
    return null;
  }
}
