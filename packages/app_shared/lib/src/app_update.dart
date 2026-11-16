import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';

/// TASK-072 / REQ-045 — direct-APK updates: the newest build per app from `app_versions`.
class AppUpdate {
  const AppUpdate({required this.build, required this.version, required this.minBuild, required this.apkUrl, this.notes});

  factory AppUpdate.fromRow(Map<String, dynamic> r) => AppUpdate(
        build: r['build'] as int,
        version: r['version'] as String,
        minBuild: r['min_build'] as int,
        apkUrl: r['apk_url'] as String,
        notes: r['notes'] as String?,
      );

  final int build;
  final String version;
  final int minBuild;
  final String apkUrl;
  final String? notes;

  /// What the phone running [currentBuild] should do.
  UpdateNeed needFor(int currentBuild) => currentBuild >= build
      ? UpdateNeed.none
      : currentBuild < minBuild
          ? UpdateNeed.required
          : UpdateNeed.optional;
}

enum UpdateNeed { none, optional, required }

/// Per-phone-type APKs (--split-per-abi) add 1000 × ABI to Android's version code
/// (armv7 1003, arm64 2003 for build 3). The published build is the plain pubspec number.
int buildFromVersionCode(int versionCode) => versionCode % 1000;

extension UpdateApi on StationApi {
  Future<AppUpdate?> latestVersion(String app) => guard(() async {
        final r = await client.from('app_versions').select().eq('app', app).maybeSingle();
        return r == null ? null : AppUpdate.fromRow(r);
      });
}

/// Checks once after start; offers the download, and blocks the app when the build is too old.
Future<void> checkForAppUpdate(BuildContext context, StationApi api, String app) async {
  try {
    final latest = await api.latestVersion(app);
    if (latest == null || !context.mounted) return;
    final current = buildFromVersionCode(int.tryParse((await PackageInfo.fromPlatform()).buildNumber) ?? 0);
    final need = latest.needFor(current);
    if (need == UpdateNeed.none || !context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: need == UpdateNeed.optional,
      builder: (ctx) => PopScope(
        canPop: need == UpdateNeed.optional,
        child: AlertDialog(
          title: Text(need == UpdateNeed.required ? 'Update required' : 'Update available'),
          content: Text([
            'Version ${latest.version} is ready.',
            if (latest.notes != null) latest.notes!,
            'Tap Download, open the file and press Install. Your data stays on the server.',
          ].join('\n\n')),
          actions: [
            if (need == UpdateNeed.optional) TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Later')),
            FilledButton(
              onPressed: () => launchUrl(Uri.parse(latest.apkUrl), mode: LaunchMode.externalApplication),
              child: const Text('Download'),
            ),
          ],
        ),
      ),
    );
  } catch (_) {
    // No network or no row: try again next start.
  }
}
