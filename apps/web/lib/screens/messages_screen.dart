import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:station_core/station_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart';
import 'common.dart';

/// SCR-045 — REQ-062 "Messages to send": customer messages that staff send from WhatsApp
/// (all plans; automatic sending falls back here), plus recently sent ones.
class MessagesScreen extends StatefulWidget {
  const MessagesScreen({super.key});

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesData {
  const _MessagesData(this.toSend, this.recent, this.account);
  final List<OutboxMessage> toSend;
  final List<OutboxMessage> recent;
  final WhatsAppAccount? account;
}

class _MessagesScreenState extends State<MessagesScreen> {
  late Future<_MessagesData> _data;
  bool _showSent = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  void _reload() {
    final s = SessionScope.of(context);
    final station = s.current!.stationId;
    final canSeeAccount = s.role == MemberRole.owner || s.role == MemberRole.manager;
    setState(() { _data = () async {
          final r = await Future.wait([
            s.api.messagesToSend(station),
            s.api.recentMessages(station),
            if (canSeeAccount) s.api.whatsAppAccount(station),
          ]);
          return _MessagesData(r[0] as List<OutboxMessage>, r[1] as List<OutboxMessage>, canSeeAccount ? r[2] as WhatsAppAccount : null);
        }(); });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_MessagesData>(
      future: _data,
      builder: (context, snap) {
        final header = PageHeader(title: 'Messages', actions: [
          SegmentedButton<bool>(
            segments: const [ButtonSegment(value: false, label: Text('To send')), ButtonSegment(value: true, label: Text('All recent'))],
            selected: {_showSent},
            onSelectionChanged: (v) => setState(() { _showSent = v.first; }),
          ),
          IconButton(tooltip: 'Refresh', onPressed: _reload, icon: const Icon(Icons.refresh)),
        ]);
        if (snap.hasError) return Column(children: [header, Expanded(child: ErrorStateView(message: snap.error is AppError ? (snap.error as AppError).message : 'Could not load messages', onRetry: _reload))]);
        if (!snap.hasData) return Column(children: [header, const Expanded(child: Center(child: CircularProgressIndicator()))]);
        final d = snap.data!;
        final list = _showSent ? d.recent : d.toSend;
        // embedded: inside the phone layout's single page list (no scrolling of its own).
        Widget mainList({bool embedded = false}) => list.isEmpty
            ? Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.mark_chat_read_outlined, size: 48),
                  const SizedBox(height: 12),
                  Text(_showSent ? 'No messages yet' : 'Nothing to send — all caught up'),
                ]),
              )
            : ListView(
                shrinkWrap: embedded,
                physics: embedded ? const NeverScrollableScrollPhysics() : null,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [for (final m in list) MessageTile(message: m, onChanged: _reload)],
              );
        final side = _MessagesSide(data: d);
        return LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth >= 1000;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            header,
            Expanded(
              child: wide
                  ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: mainList()), SizedBox(width: 360, child: side)])
                  : ListView(children: [
                      if (list.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 32), child: mainList()) else mainList(embedded: true),
                      _MessagesSide(data: d, embedded: true),
                    ]),
            ),
          ]);
        });
      },
    );
  }
}

const _eventIcons = <String, IconData>{
  'booking_confirmed': Icons.event_available,
  'booking_changed': Icons.event_repeat,
  'booking_cancelled': Icons.event_busy,
  'estimate_ready': Icons.request_quote_outlined,
  'extra_work': Icons.build_circle_outlined,
  'vehicle_ready': Icons.directions_car_filled_outlined,
  'invoice_issued': Icons.receipt_long_outlined,
  'dues_reminder': Icons.account_balance_wallet_outlined,
  'service_reminder': Icons.alarm,
  'storage_started': Icons.local_parking,
};

/// One customer message with "Send on WhatsApp", "Mark sent" and "Skip" (REQ-062).
/// Used in the Messages page and on the job card.
class MessageTile extends StatelessWidget {
  const MessageTile({super.key, required this.message, required this.onChanged, this.dense = false});
  final OutboxMessage message;
  final VoidCallback onChanged;
  final bool dense;

  Future<void> _open(BuildContext context) async {
    final url = message.whatsAppUrl;
    if (url == null) return;
    final api = SessionScope.of(context).api;
    await launchUrl(Uri.parse(url), webOnlyWindowName: '_blank');
    if (message.status == MessageStatus.manual) {
      try {
        await api.markMessage(message.id, 'opened');
      } catch (_) {/* the list refreshes anyway */}
    }
    onChanged();
  }

  Future<void> _mark(BuildContext context, String action) async {
    final api = SessionScope.of(context).api;
    if (await runAction(context, () => api.markMessage(message.id, action), success: action == 'sent' ? 'Marked as sent' : 'Skipped')) {
      onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final m = message;
    final staff = m.status.needsStaff;
    final color = switch (m.status) {
      MessageStatus.sent => const Color(0xFF16A34A),
      MessageStatus.skipped || MessageStatus.failed => const Color(0xFF6B7280),
      MessageStatus.opened => const Color(0xFF2563EB),
      MessageStatus.queued || MessageStatus.sending => const Color(0xFF7C3AED),
      MessageStatus.manual => const Color(0xFFF59E0B),
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: EdgeInsets.all(dense ? 10 : 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: color.withValues(alpha: 0.12),
              child: Icon(_eventIcons[m.event] ?? Icons.chat_outlined, size: 18, color: color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${m.title}${m.customerName != null ? ' · ${m.customerName}' : ''}', style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(
                  [
                    m.toMobile != null ? formatPkMobile(m.toMobile!) : 'No WhatsApp number',
                    '${formatDate(toPkt(m.createdAt))} ${formatTime(toPkt(m.createdAt))}',
                  ].join(' · '),
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ]),
            ),
            Chip(
              label: Text(m.status.label, style: TextStyle(fontSize: 11, color: color)),
              backgroundColor: color.withValues(alpha: 0.08),
              side: BorderSide.none,
              visualDensity: VisualDensity.compact,
            ),
          ]),
          const SizedBox(height: 8),
          Text(m.body),
          if (m.manualReason != null) ...[
            const SizedBox(height: 6),
            Text(m.manualReason!, style: const TextStyle(fontSize: 12, color: Color(0xFFB45309))),
          ],
          if (staff) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 6, children: [
              FilledButton.icon(
                onPressed: m.whatsAppUrl == null ? null : () => _open(context),
                icon: const Icon(Icons.chat, size: 18),
                label: const Text('Send on WhatsApp'),
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFF16A34A)),
              ),
              if (m.whatsAppUrl != null) OutlinedButton(onPressed: () => _mark(context, 'sent'), child: const Text('Mark sent')),
              TextButton(onPressed: () => _mark(context, 'skipped'), child: const Text('Skip')),
            ]),
          ],
        ]),
      ),
    );
  }
}

class _MessagesSide extends StatelessWidget {
  const _MessagesSide({required this.data, this.embedded = false});
  final _MessagesData data;

  /// Inside another scrolling list (narrow screens): no scrolling of its own.
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final s = SessionScope.of(context);
    final today = toPkt(DateTime.now());
    bool isToday(OutboxMessage m) {
      final t = toPkt(m.createdAt);
      return t.year == today.year && t.month == today.month && t.day == today.day;
    }

    final auto = data.recent.where((m) => isToday(m) && m.status == MessageStatus.sent && m.manualReason == null).length;
    final byStaff = data.recent.where((m) => isToday(m) && m.status == MessageStatus.opened).length;
    Widget card(String title, Widget child) => Card(
          margin: const EdgeInsets.fromLTRB(0, 0, 16, 12),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              child,
            ]),
          ),
        );
    final account = data.account;
    final autoPlan = s.entitlements?.has(Feature.whatsappAuto) ?? false;
    return ListView(shrinkWrap: embedded, physics: embedded ? const NeverScrollableScrollPhysics() : null, children: [
      card(
        'Today',
        Wrap(spacing: 20, runSpacing: 8, children: [
          _Stat('To send', '${data.toSend.length}'),
          _Stat('Sent', '$auto'),
          _Stat('Opened', '$byStaff'),
        ]),
      ),
      card(
        'Automatic WhatsApp',
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (!autoPlan)
            const Text('On Basic, messages are sent from your own phone: tap "Send on WhatsApp", check the text and press Send. '
                'Standard and Premium can send them automatically from the station\'s own WhatsApp number.')
          else if (account == null)
            const Text('Messages go out automatically when the owner has connected the station\'s WhatsApp.')
          else ...[
            Row(children: [
              Icon(account.status.sendsAutomatically ? Icons.check_circle : Icons.info_outline,
                  color: account.status.sendsAutomatically ? const Color(0xFF16A34A) : const Color(0xFFF59E0B), size: 20),
              const SizedBox(width: 8),
              Text(account.status.label, style: const TextStyle(fontWeight: FontWeight.w700)),
            ]),
            if (account.reason != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(account.reason!, style: const TextStyle(fontSize: 12))),
            if (s.role == MemberRole.owner)
              TextButton(onPressed: () => context.go('/${MenuItem.settings.name}'), child: const Text('WhatsApp settings')),
          ],
        ]),
      ),
      card(
        'How it works',
        const Text('A message is added here when an event happens (booking, estimate, vehicle ready, invoice, dues, reminders) '
            'and it was not sent automatically. WhatsApp opens with the customer\'s number and the text ready; '
            'you press Send yourself. The owner can switch each message on or off in Settings.',
            style: TextStyle(fontSize: 13)),
      ),
    ]);
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        Text(label, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ]);
}
