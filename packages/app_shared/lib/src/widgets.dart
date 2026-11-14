import 'package:flutter/material.dart';
import 'package:station_core/station_core.dart';

/// Neutral provisional theme (no brand assets supplied yet).
ThemeData appTheme() {
  const seed = Color(0xFF0E7490);
  final scheme = ColorScheme.fromSeed(seedColor: seed, surface: Colors.white);
  final radius = BorderRadius.circular(12);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: const Color(0xFFF4F6F9),
    visualDensity: VisualDensity.standard,
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: scheme.outlineVariant)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(borderRadius: radius),
      enabledBorder: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: scheme.outlineVariant)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: radius), padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: radius), padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14)),
    ),
    dialogTheme: DialogThemeData(backgroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
    dataTableTheme: DataTableThemeData(
      headingRowColor: WidgetStatePropertyAll(scheme.surfaceContainerHighest.withValues(alpha: 0.5)),
      headingTextStyle: const TextStyle(fontWeight: FontWeight.w600),
    ),
    chipTheme: ChipThemeData(shape: RoundedRectangleBorder(borderRadius: radius)),
  );
}

/// REQ-006: shown instead of a screen the plan does not include.
class LockedFeatureCard extends StatelessWidget {
  const LockedFeatureCard({super.key, required this.feature, required this.title, this.onUpgrade});
  final String feature;
  final String title;
  final VoidCallback? onUpgrade;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Card(
        margin: const EdgeInsets.all(24),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.lock_outline, size: 40),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(lockedFeatureText(feature)),
            if (onUpgrade != null) ...[
              const SizedBox(height: 16),
              FilledButton(onPressed: onUpgrade, child: const Text('Upgrade plan')),
            ],
          ]),
        ),
      ),
    );
  }
}

/// REQ-007/REQ-009: trial, grace and read-only banners.
class SubscriptionBanner extends StatelessWidget {
  const SubscriptionBanner({super.key, required this.entitlements, this.now});
  final Entitlements entitlements;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final at = now ?? DateTime.now();
    final renews = entitlements.renewsAt;
    String? text;
    Color? color;
    switch (entitlements.status) {
      case StationStatus.trial:
        // Shown only in the last 3 days; otherwise the dashboard plan card carries it.
        final days = renews == null ? null : renews.difference(at).inDays + 1;
        if (days == null || days > 3) return const SizedBox.shrink();
        text = 'Free trial — $days days left';
        color = scheme.secondaryContainer;
      case StationStatus.grace:
        final left = renews == null ? null : renews.add(const Duration(days: 7)).difference(at).inDays + 1;
        text = 'Payment due — ${left ?? 7} days left before read-only';
        color = scheme.tertiaryContainer;
      case StationStatus.readOnly:
        text = AppErrorCode.readOnly.defaultMessage;
        color = scheme.errorContainer;
      case StationStatus.suspended:
      case StationStatus.closed:
        text = AppErrorCode.stationSuspended.defaultMessage;
        color = scheme.errorContainer;
      case StationStatus.active:
        return const SizedBox.shrink();
    }
    return Material(
      color: color,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(children: [
          const Icon(Icons.info_outline, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ]),
      ),
    );
  }
}

/// Common loading / error-with-retry / empty states (PRD §9).
class AsyncStateView<T> extends StatelessWidget {
  const AsyncStateView({
    super.key,
    required this.future,
    required this.builder,
    this.isEmpty,
    this.emptyText = 'Nothing here yet',
    this.onRetry,
  });

  final Future<T> future;
  final Widget Function(BuildContext, T) builder;
  final bool Function(T)? isEmpty;
  final String emptyText;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          final e = snap.error;
          return ErrorStateView(message: e is AppError ? e.message : AppErrorCode.unknown.defaultMessage, onRetry: onRetry);
        }
        final data = snap.data as T;
        if (isEmpty?.call(data) ?? false) return Center(child: Text(emptyText));
        return builder(context, data);
      },
    );
  }
}

class ErrorStateView extends StatelessWidget {
  const ErrorStateView({super.key, required this.message, this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center),
          if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('Retry')),
        ]),
      );
}

/// Placeholder for screens scheduled in later phases, so navigation is complete
/// without implying the feature exists.
class PlannedScreen extends StatelessWidget {
  const PlannedScreen({super.key, required this.title, required this.phase});
  final String title;
  final String phase;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.construction_outlined, size: 40),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('Planned for $phase — not built yet'),
        ]),
      );
}

/// Shown when the apps were built without a backend config.
class MissingConfigScreen extends StatelessWidget {
  const MissingConfigScreen({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Backend not configured.\nRun with --dart-define-from-file=config/staging.json',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
}

void showError(BuildContext context, Object e) {
  final msg = e is AppError ? e.message : AppErrorCode.unknown.defaultMessage;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}
