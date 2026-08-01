import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:fluxer_fcm/fcm_background_display_hooks.dart';
import 'package:fluxer_fcm/fcm_push_message.dart';

bool shouldDisplayFcmBackgroundLocalNotification(
  RemoteMessage message,
  FcmPushMessage mapped,
) {
  if (FcmBackgroundDisplayHooks.shouldDisplayLocalNotification(mapped)) {
    return true;
  }
  // When the app uses a custom FirebaseMessagingReceiver (which removes the
  // default FlutterFirebaseMessagingService), the Android system tray does NOT
  // auto-display notifications with a `notification` payload. We must show a
  // local notification ourselves for hybrid (notification + data) messages.
  // Data-only messages are also shown here (message.notification == null).
  return true;
}
