import 'package:supabase_flutter/supabase_flutter.dart';

/// Values come from `--dart-define-from-file=config/<env>.json` (see config/example.json).
/// Apps hold only the public URL and publishable key; RLS enforces access (ARCHITECTURE §6).
abstract final class AppConfig {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
  static const environment = String.fromEnvironment('APP_ENV', defaultValue: 'local');

  static bool get isConfigured => supabaseUrl.isNotEmpty && supabaseKey.isNotEmpty;
}

Future<void> initBackend() async {
  if (!AppConfig.isConfigured) return;
  await Supabase.initialize(url: AppConfig.supabaseUrl, publishableKey: AppConfig.supabaseKey);
}
