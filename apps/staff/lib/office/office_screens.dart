import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:station_core/station_core.dart';
import 'package:url_launcher/url_launcher.dart';

/// SCR-035 (owner / manager / cashier on the phone): REQ-062 "Messages to send" with
/// "Send on WhatsApp" (opens the WhatsApp app), and REQ-056 staff notifications.
class StaffMessagesTab extends StatefulWidget {
  const StaffMessagesTab({super.key, required this.api, required this.stationId});
  final StationApi api;
  final String stationId;

  @override
  State<StaffMessagesTab> createState() => _StaffMessagesTabState();
}

class _StaffMessagesTabState extends State<StaffMessagesTab> {
  late Future<List<OutboxMessage>> _list = widget.api.messagesToSend(widget.stationId);

  Future<void> _reload() async {
    final f = widget.api.messagesToSend(widget.stationId);
    setState(() { _list = f; });
    await f;
  }

  Future<void> _send(OutboxMessage m) async {
    final url = m.whatsAppUrl;
    if (url == null) return;
    final opened = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!opened) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('WhatsApp is not installed on this phone')));
      return;
    }
    if (m.status == MessageStatus.manual) {
      try {
        await widget.api.markMessage(m.id, 'opened');
      } catch (_) {}
    }
    _reload();
  }

  Future<void> _mark(OutboxMessage m, String action) async {
    try {
      await widget.api.markMessage(m.id, action);
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
        onRefresh: _reload,
        child: FutureBuilder<List<OutboxMessage>>(
          future: _list,
          builder: (context, snap) {
            if (snap.hasError) {
              return ListView(children: [ErrorStateView(message: 'Could not load messages', onRetry: _reload)]);
            }
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final list = snap.data!;
            if (list.isEmpty) {
              return ListView(children: const [
                SizedBox(height: 120),
                Icon(Icons.mark_chat_read_outlined, size: 48),
                SizedBox(height: 12),
                Center(child: Text('Nothing to send — all caught up')),
              ]);
            }
            return ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: list.length,
              itemBuilder: (context, i) {
                final m = list[i];
                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Text('${m.title}${m.customerName != null ? ' · ${m.customerName}' : ''}', style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text(
                        '${m.toMobile != null ? formatPkMobile(m.toMobile!) : 'No WhatsApp number'} · ${m.status.label}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: 6),
                      Text(m.body),
                      if (m.manualReason != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(m.manualReason!, style: const TextStyle(fontSize: 12, color: Color(0xFFB45309))),
                        ),
                      const SizedBox(height: 8),
                      Row(children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: m.whatsAppUrl == null ? null : () => _send(m),
                            icon: const Icon(Icons.chat, size: 18),
                            label: const Text('Send on WhatsApp'),
                            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF16A34A)),
                          ),
                        ),
                        PopupMenuButton<String>(
                          tooltip: 'More',
                          onSelected: (a) => _mark(m, a),
                          itemBuilder: (_) => [
                            if (m.whatsAppUrl != null) const PopupMenuItem(value: 'sent', child: Text('Mark sent')),
                            const PopupMenuItem(value: 'skipped', child: Text('Skip')),
                          ],
                        ),
                      ]),
                    ]),
                  ),
                );
              },
            );
          },
        ),
      );
}

class StaffAlertsTab extends StatefulWidget {
  const StaffAlertsTab({super.key, required this.api, required this.stationId});
  final StationApi api;
  final String stationId;

  @override
  State<StaffAlertsTab> createState() => _StaffAlertsTabState();
}

class _StaffAlertsTabState extends State<StaffAlertsTab> {
  late Future<List<StaffNotification>> _list = _load();

  Future<List<StaffNotification>> _load() async {
    final list = await widget.api.notifications(widget.stationId);
    if (list.any((n) => !n.read)) widget.api.markStaffNotificationsRead(widget.stationId).ignore();
    return list;
  }

  Future<void> _reload() async {
    final f = _load();
    setState(() { _list = f; });
    await f;
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
        onRefresh: _reload,
        child: FutureBuilder<List<StaffNotification>>(
          future: _list,
          builder: (context, snap) {
            if (snap.hasError) return ListView(children: [ErrorStateView(message: 'Could not load notifications', onRetry: _reload)]);
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final list = snap.data!;
            if (list.isEmpty) return ListView(children: const [SizedBox(height: 120), Center(child: Text('No notifications yet'))]);
            return ListView.separated(
              itemCount: list.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final n = list[i];
                return ListTile(
                  leading: Icon(n.read ? Icons.notifications_none : Icons.notifications_active, color: n.read ? null : Theme.of(context).colorScheme.primary),
                  title: Text(n.title, style: TextStyle(fontWeight: n.read ? FontWeight.w400 : FontWeight.w700)),
                  subtitle: Text([if (n.body != null && n.body!.isNotEmpty) n.body!, '${formatDate(toPkt(n.createdAt))} ${formatTime(toPkt(n.createdAt))}'].join('\n')),
                );
              },
            );
          },
        ),
      );
}
