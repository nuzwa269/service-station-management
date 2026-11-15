import 'package:supabase_flutter/supabase_flutter.dart';

/// Values come from `--dart-define-from-file=config/<env>.json` (see config/example.json).
/// Apps hold only the public URL and publishable key; RLS enforces access (ARCHITECTURE §6).
abstract final class AppConfig {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
  static const environment = String.fromEnvironment('APP_ENV', defaultValue: 'local');

  static bool get isConfigured => supabaseUrl.isNotEmpty && supabaseKey.isNotEmpty;

  /// Meta app (Tech Provider, TASK-004) for "Connect WhatsApp" — public ids only.
  static const metaAppId = String.fromEnvironment('META_APP_ID');
  static const metaConfigId = String.fromEnvironment('META_CONFIG_ID');
  static bool get whatsAppSignupReady => metaAppId.isNotEmpty && metaConfigId.isNotEmpty;

  /// Firebase (push) — public client ids only; push is off when they are empty.
  static const firebaseApiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const firebaseProjectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const firebaseSenderId = String.fromEnvironment('FIREBASE_SENDER_ID');
  static const firebaseStaffAppId = String.fromEnvironment('FIREBASE_STAFF_APP_ID');
  static const firebaseCustomerAppId = String.fromEnvironment('FIREBASE_CUSTOMER_APP_ID');
}

Future<void> initBackend() async {
  if (!AppConfig.isConfigured) return;
  await Supabase.initialize(url: AppConfig.supabaseUrl, publishableKey: AppConfig.supabaseKey);
}
