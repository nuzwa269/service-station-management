import 'dart:async';

import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:station_core/station_core.dart';

import '../main.dart';

const _kindIcons = <String, IconData>{
  'assigned': Icons.assignment_ind_outlined,
  'qc_fail': Icons.report_gmailerrorred_outlined,
  'approval_request': Icons.fact_check_outlined,
  'approval_decision': Icons.task_alt,
  'conflict': Icons.sync_problem,
  'negative_stock': Icons.inventory_2_outlined,
  'low_stock': Icons.inventory_2_outlined,
  'subscription': Icons.workspace_premium_outlined,
  'booking': Icons.event_available_outlined,
  'storage': Icons.local_parking,
  'uncollected': Icons.directions_car_outlined,
  'customer_decision': Icons.thumb_up_alt_outlined,
};

/// Header bell: staff notifications (REQ-056) with the unread count, refreshed every minute.
class NotificationsButton extends StatefulWidget {
  const NotificationsButton({super.key, required this.stationId});
  final String stationId;

  @override
  State<NotificationsButton> createState() => _NotificationsButtonState();
}

class _NotificationsButtonState extends State<NotificationsButton> {
  List<StaffNotification> _items = const [];
  Timer? _timer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_timer == null) {
      _load();
      _timer = Timer.periodic(const Duration(minutes: 1), (_) => _load());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await SessionScope.of(context).api.notifications(widget.stationId);
      if (mounted) setState(() { _items = list; });
    } catch (_) {/* the bell stays as it was */}
  }

  Future<void> _open() async {
    final api = SessionScope.of(context).api;
    final items = _items;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Notifications'),
        contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        content: SizedBox(
          width: 420,
          height: 460,
          child: items.isEmpty
              ? const Center(child: Text('No notifications yet'))
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final n = items[i];
                    return ListTile(
                      leading: Icon(_kindIcons[n.kind] ?? Icons.notifications_none, color: n.read ? null : Theme.of(ctx).colorScheme.primary),
                      title: Text(n.title, style: TextStyle(fontWeight: n.read ? FontWeight.w400 : FontWeight.w700)),
                      subtitle: Text([if (n.body != null && n.body!.isNotEmpty) n.body!, '${formatDate(toPkt(n.createdAt))} ${formatTime(toPkt(n.createdAt))}'].join('\n')),
                    );
                  },
                ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
    if (items.any((n) => !n.read)) {
      try {
        await api.markStaffNotificationsRead(widget.stationId);
      } catch (_) {}
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final unread = _items.where((n) => !n.read).length;
    return IconButton(
      key: const Key('notifications'),
      tooltip: 'Notifications',
      onPressed: _open,
      icon: Badge(
        isLabelVisible: unread > 0,
        label: Text(unread > 9 ? '9+' : '$unread'),
        child: const Icon(Icons.notifications_none_rounded),
      ),
    );
  }
}
