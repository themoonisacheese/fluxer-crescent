import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Caches and retrieves dynamic FCM credentials (android_fcm from well-known)
/// so they're available across isolates (main + background FCM handler).
class FcmCredentialsCache {
  FcmCredentialsCache._();

  static const String _prefsKey = 'fcm_android_credentials';

  /// Save credentials from the well-known discovery response.
  static Future<void> save({
    required String appId,
    required String projectId,
    required String apiKey,
    required String senderId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode({
        'app_id': appId,
        'project_id': projectId,
        'api_key': apiKey,
        'sender_id': senderId,
      }),
    );
  }

  /// Load saved credentials as [FirebaseOptions], or null if none cached.
  static Future<FirebaseOptions?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final Map<String, dynamic> data =
          jsonDecode(raw) as Map<String, dynamic>;
      final String? appId = data['app_id'] as String?;
      final String? projectId = data['project_id'] as String?;
      final String? apiKey = data['api_key'] as String?;
      final String? senderId = data['sender_id'] as String?;
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

  /// Clear cached credentials (e.g. on logout).
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }
}
