import 'package:app_shared/app_shared.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

/// Push (FCM, REQ-055/056): registers this phone's token after login and removes it on
/// sign-out. Off until the Firebase ids are in the build config (FIREBASE_*).
abstract final class Push {
  static const _app = 'customer';
  static String? _token;

  static bool get enabled =>
      AppConfig.firebaseApiKey.isNotEmpty && AppConfig.firebaseProjectId.isNotEmpty && AppConfig.firebaseCustomerAppId.isNotEmpty;

  static Future<void> register(StationApi api) async {
    if (!enabled) return;
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: const FirebaseOptions(
            apiKey: AppConfig.firebaseApiKey,
            appId: AppConfig.firebaseCustomerAppId,
            messagingSenderId: AppConfig.firebaseSenderId,
            projectId: AppConfig.firebaseProjectId,
          ),
        );
      }
      final fm = FirebaseMessaging.instance;
      await fm.requestPermission();
      // The registration token is what the dispatcher's FCM HTTP v1 call targets; the newer
      // installation-id API (register/onRegistered) is not used by the server yet.
      // ignore: deprecated_member_use
      _token = await fm.getToken();
      if (_token != null) await api.registerDevice(_token!, app: _app);
      // ignore: deprecated_member_use
      fm.onTokenRefresh.listen((t) {
        _token = t;
        api.registerDevice(t, app: _app).ignore();
      });
    } catch (_) {
      // Push is a convenience: the app works the same without it.
    }
  }

  static Future<void> unregister(StationApi api) async {
    final t = _token;
    if (t == null) return;
    try {
      await api.unregisterDevice(t);
    } catch (_) {}
    _token = null;
  }
}
