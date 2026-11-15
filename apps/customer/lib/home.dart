import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:station_core/station_core.dart';

import 'station_screens.dart';

/// SCR-041 — linked stations, add a station by its code, notifications.
class CustomerHome extends StatefulWidget {
  const CustomerHome({super.key, required this.api});
  final StationApi api;

  @override
  State<CustomerHome> createState() => _CustomerHomeState();
}

class _CustomerHomeState extends State<CustomerHome> {
  late Future<List<LinkedStation>> _stations;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() => setState(() => _stations = widget.api.myStations());

  Future<void> _link() async {
    final ok = await showDialog<bool>(context: context, builder: (_) => LinkStationDialog(api: widget.api));
    if (ok == true) _reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('My vehicles & stations'),
          actions: [
            IconButton(
              tooltip: 'Notifications',
              icon: const Icon(Icons.notifications_outlined),
              onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => NotificationsScreen(api: widget.api))),
            ),
            IconButton(tooltip: 'Log out', onPressed: widget.api.signOut, icon: const Icon(Icons.logout)),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(onPressed: _link, icon: const Icon(Icons.add_business_outlined), label: const Text('Add station')),
        body: RefreshIndicator(
          onRefresh: () async => _reload(),
          child: AsyncStateView<List<LinkedStation>>(
            future: _stations,
            onRetry: _reload,
            isEmpty: (l) => l.isEmpty,
            emptyText: 'No station linked yet.\nAsk your station for its code — Add station',
            builder: (context, list) => ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
              for (final s in list)
                Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(14),
                    leading: const CircleAvatar(child: Icon(Icons.car_repair)),
                    title: Text(s.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text([
                      s.city,
                      if (s.phone != null) s.phone!,
                      if (s.blocked) 'Booking blocked — please call the station',
                      if (s.readOnly) 'Online booking unavailable',
                    ].join(' · ')),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => StationHome(api: widget.api, station: s)))
                        .then((_) => _reload()),
                  ),
                ),
            ]),
          ),
        ),
      );
}

class LinkStationDialog extends StatefulWidget {
  const LinkStationDialog({super.key, required this.api});
  final StationApi api;

  @override
  State<LinkStationDialog> createState() => _LinkStationDialogState();
}

class _LinkStationDialogState extends State<LinkStationDialog> {
  final _code = TextEditingController();
  final _name = TextEditingController();
  bool _needName = false;
  bool _busy = false;

  Future<void> _go() async {
    setState(() => _busy = true);
    try {
      await widget.api.linkStation(_code.text, name: _name.text.trim().isEmpty ? null : _name.text);
      if (mounted) Navigator.pop(context, true);
    } on AppError catch (e) {
      if (!mounted) return;
      // First visit at this station: we need the customer's name to create the record.
      if (e.code == AppErrorCode.validation && !_needName) {
        setState(() => _needName = true);
      } else if (e.code == AppErrorCode.featureLocked) {
        showError(context, const AppError(AppErrorCode.validation, "This station doesn't offer the app yet"));
      } else {
        showError(context, e);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Add station'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _code,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: 'Station code', hintText: '6 letters, e.g. K7P2QX'),
          ),
          if (_needName) ...[
            const SizedBox(height: 12),
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'Your name')),
          ],
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: _busy ? null : _go, child: const Text('Add')),
        ],
      );
}

/// SCR-045 — messages from all linked stations.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key, required this.api});
  final StationApi api;

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  late final Future<List<Map<String, dynamic>>> _list = widget.api.myNotifications();

  @override
  void initState() {
    super.initState();
    widget.api.markNotificationsRead().catchError((_) {});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Notifications')),
        body: AsyncStateView<List<Map<String, dynamic>>>(
          future: _list,
          isEmpty: (l) => l.isEmpty,
          emptyText: 'No messages yet',
          builder: (context, rows) => ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final n = rows[i];
              return ListTile(
                leading: Icon(switch (n['kind']) {
                  'estimate' || 'extra_work' => Icons.request_quote_outlined,
                  'reminder' => Icons.alarm,
                  _ => Icons.event_note_outlined,
                }),
                title: Text(n['title'] as String, style: TextStyle(fontWeight: n['read_at'] == null ? FontWeight.w700 : FontWeight.normal)),
                subtitle: Text([n['station_name'], n['body'], formatDate(DateTime.parse(n['created_at'] as String).toLocal())].whereType<String>().join(' · ')),
              );
            },
          ),
        ),
      );
}
