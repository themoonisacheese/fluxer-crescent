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
  try {
    WidgetsFlutterBinding.ensureInitialized();
    if (Firebase.apps.isEmpty) {
      // Try cached dynamic FCM credentials first, fall back to build-time default.
      await Firebase.initializeApp(
        options: await _loadCachedFirebaseOptions()
            ?? DefaultFirebaseOptions.currentPlatform,
      );
    }
    if (kDebugMode) {
      debugPrint(
        '[FCM] background message id=${message.messageId} '
        'hasNotification=${message.notification != null} '
        'data=${message.data}',
      );
    }
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
    if (kDebugMode) {
      debugPrint('[FCM] background handler failed: $error\n$stackTrace');
    }
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
