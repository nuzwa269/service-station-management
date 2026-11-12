import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:station_core/station_core.dart';

import '../main.dart';

/// SCR-019 — plan and status. Payment (REQ-008) arrives in Phase 5.
class SubscriptionScreen extends StatelessWidget {
  const SubscriptionScreen({super.key});

  static const _statusText = {
    StationStatus.trial: 'Free trial',
    StationStatus.active: 'Active',
    StationStatus.grace: 'Payment due (grace period)',
    StationStatus.readOnly: 'Read-only',
    StationStatus.suspended: 'Suspended',
    StationStatus.closed: 'Closed',
  };

  @override
  Widget build(BuildContext context) {
    final e = SessionScope.of(context).entitlements!;
    final plan = e.status == StationStatus.trial ? 'Trial (all Premium features)' : e.planCode[0].toUpperCase() + e.planCode.substring(1);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('Subscription', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      ListTile(title: const Text('Plan'), trailing: Text(plan)),
      ListTile(title: const Text('Status'), trailing: Text(_statusText[e.status]!)),
      if (e.renewsAt != null)
        ListTile(
          title: Text(e.status == StationStatus.trial ? 'Trial ends' : 'Renewal date'),
          trailing: Text(formatDateLong(e.renewsAt!.toLocal())),
        ),
      const SizedBox(height: 8),
      const Text('Plans: Basic Rs 2,500 · Standard Rs 5,000 · Premium Rs 8,000 per month. Yearly = 10 months\' price.'),
      const SizedBox(height: 24),
      const PlannedScreen(title: 'Pay and upgrade', phase: 'Phase 5 (TASK-048)'),
    ]);
  }
}
