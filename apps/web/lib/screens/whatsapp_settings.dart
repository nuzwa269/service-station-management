import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:station_core/station_core.dart';

import '../main.dart';
import '../whatsapp_signup.dart';
import 'common.dart';

/// SCR-017 — REQ-061 connect the station's own WhatsApp Business account (Standard, Premium)
/// and REQ-055 switch each customer message on or off (owner).
class WhatsAppSettingsSection extends StatefulWidget {
  const WhatsAppSettingsSection({super.key});

  @override
  State<WhatsAppSettingsSection> createState() => _WhatsAppSettingsSectionState();
}

class _WhatsAppSettingsSectionState extends State<WhatsAppSettingsSection> {
  late Future<(WhatsAppAccount, List<MessageEventSetting>)> _data;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  void _reload() {
    final s = SessionScope.of(context);
    final id = s.current!.stationId;
    Future<(WhatsAppAccount, List<MessageEventSetting>)> load() async => (await s.api.whatsAppAccount(id), await s.api.messageEvents(id));
    setState(() { _data = load(); });
  }

  Future<void> _connect() async {
    final s = SessionScope.of(context);
    setState(() { _busy = true; });
    try {
      final r = await startWhatsAppSignup(AppConfig.metaAppId, AppConfig.metaConfigId);
      if (r == null || !mounted) return;
      await runAction(
        context,
        () => s.api.connectWhatsApp(s.current!.stationId, code: r.code, wabaId: r.wabaId, phoneNumberId: r.phoneNumberId),
        success: 'WhatsApp connected — templates are in review at Meta',
      );
    } finally {
      if (mounted) {
        setState(() { _busy = false; });
        _reload();
      }
    }
  }

  Future<void> _disconnect() async {
    final s = SessionScope.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disconnect WhatsApp?'),
        content: const Text('Customer messages will no longer go out automatically. They will wait in "Messages" for staff to send.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Disconnect')),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    if (await runAction(context, () => s.api.disconnectWhatsApp(s.current!.stationId), success: 'Disconnected')) _reload();
  }

  Future<void> _toggle(MessageEventSetting e, bool on) async {
    final s = SessionScope.of(context);
    if (await runAction(context, () => s.api.setMessageEvents(s.current!.stationId, {e.code: on}))) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final s = SessionScope.of(context);
    final autoPlan = s.entitlements?.has(Feature.whatsappAuto) ?? false;
    return FutureBuilder<(WhatsAppAccount, List<MessageEventSetting>)>(
      future: _data,
      builder: (context, snap) {
        if (snap.hasError) return Text('Could not load WhatsApp settings: ${snap.error}');
        if (!snap.hasData) return const LinearProgressIndicator();
        final (account, events) = snap.data!;
        final st = account.status;
        final color = switch (st) {
          WhatsAppStatus.connected => const Color(0xFF16A34A),
          WhatsAppStatus.pending => const Color(0xFF2563EB),
          WhatsAppStatus.paymentProblem => const Color(0xFFDC2626),
          _ => const Color(0xFF6B7280),
        };
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Customer messages (WhatsApp)', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text('Messages go to customers by push in the customer app and on WhatsApp. Without a connected account, '
              'staff send them from "Messages" with one tap.'),
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(Icons.chat_rounded, color: color),
                  const SizedBox(width: 8),
                  Text('Station WhatsApp: ${st.label}', style: TextStyle(fontWeight: FontWeight.w700, color: color)),
                  if (account.displayPhone != null) Text('  ·  ${account.displayPhone}'),
                ]),
                if (account.reason != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(account.reason!)),
                if (account.totalTemplates > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('Message templates approved by Meta: ${account.approvedTemplates} of ${account.totalTemplates}',
                        style: const TextStyle(fontSize: 12)),
                  ),
                const SizedBox(height: 10),
                if (!autoPlan)
                  const Text('Automatic WhatsApp from your own number is available on Standard and Premium.', style: TextStyle(fontSize: 12))
                else
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    if (st != WhatsAppStatus.connected)
                      FilledButton.icon(
                        onPressed: _busy || !AppConfig.whatsAppSignupReady ? null : _connect,
                        icon: const Icon(Icons.link),
                        label: Text(st == WhatsAppStatus.pending ? 'Continue sign-up' : 'Connect WhatsApp'),
                      ),
                    if (st == WhatsAppStatus.connected || st == WhatsAppStatus.pending || st == WhatsAppStatus.paymentProblem)
                      OutlinedButton(onPressed: _busy ? null : _disconnect, child: const Text('Disconnect')),
                  ]),
                if (autoPlan && !AppConfig.whatsAppSignupReady && st != WhatsAppStatus.connected)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text('Connecting is not open yet on this platform. Messages are sent from "Messages" meanwhile.',
                        style: TextStyle(fontSize: 12)),
                  ),
                if (autoPlan)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('You choose or create the WhatsApp Business account and number in Meta\'s window and add a payment method there. '
                        'Meta bills the station directly for its messages.', style: TextStyle(fontSize: 12)),
                  ),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            child: Column(children: [
              for (final e in events)
                SwitchListTile(
                  dense: true,
                  title: Text(e.label),
                  value: e.enabled,
                  onChanged: (v) => _toggle(e, v),
                ),
            ]),
          ),
        ]);
      },
    );
  }
}
