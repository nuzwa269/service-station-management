import 'package:app_shared/app_shared.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:station_core/station_core.dart';

import '../main.dart';
import 'common.dart';
import 'export_data.dart';

/// SCR-019 / SCR-020 — plan, renewal, payments (REQ-007…010), export and close account (REQ-013).
class SubscriptionScreen extends StatefulWidget {
  const SubscriptionScreen({super.key});

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

const _featureNames = {
  Feature.core: 'Job cards, inventory, billing, customers',
  Feature.supplierLedger: 'Supplier ledger and dues',
  Feature.booking: 'Booking and customer app',
  Feature.whatsappAuto: 'Automatic WhatsApp',
  Feature.approvalsInbox: 'Approvals inbox',
  Feature.auditLogView: 'Audit log',
  Feature.payroll: 'Attendance and payroll',
  Feature.profitReports: 'Profit reports',
};

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  late Future<List<PlanInfo>> _plans;
  late Future<List<SubPayment>> _payments;
  late Future<Map<String, dynamic>> _quote;
  String _cycle = 'monthly';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  void _reload() {
    final s = SessionScope.of(context);
    final id = s.current!.stationId;
    setState(() {
      _plans = s.api.plans();
      _payments = s.api.subscriptionPayments(id);
      _quote = s.api.subscriptionQuote(id, s.entitlements!.planCode, _cycle);
    });
    s.refreshEntitlements();
  }

  Future<void> _pay(PlanInfo plan, {required String kind, required Money amount}) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => _PayDialog(plan: plan, cycle: _cycle, kind: kind, amount: amount));
    if (ok == true) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final s = SessionScope.of(context);
    final e = s.entitlements!;
    final isOwner = s.role == MemberRole.owner;
    return ListView(padding: const EdgeInsets.all(20), children: [
      FutureBuilder<Map<String, dynamic>>(
        future: _quote,
        builder: (context, snap) {
          final q = snap.data;
          final renewal = q?['renewal_date'] == null ? null : DateTime.parse(q!['renewal_date'] as String);
          final statusText = switch (e.status) {
            StationStatus.trial => 'Free trial — all Premium features',
            StationStatus.active => 'Active',
            StationStatus.grace => 'Payment due — grace period',
            StationStatus.readOnly => 'Read-only — renew to continue working',
            StationStatus.suspended => 'Suspended — contact support',
            StationStatus.closed => 'Closed — pay any plan to restore',
          };
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(color: Theme.of(context).colorScheme.primaryContainer, borderRadius: BorderRadius.circular(14)),
                  child: Icon(Icons.workspace_premium_rounded, color: Theme.of(context).colorScheme.primary),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(e.status == StationStatus.trial ? 'Free trial' : '${e.planCode[0].toUpperCase()}${e.planCode.substring(1)} plan',
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                    Text(statusText),
                    if (renewal != null)
                      Text('${e.status == StationStatus.trial ? 'Trial ends' : 'Renewal date'}: ${formatDateLong(renewal)}',
                          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    if (q?['pending_plan'] != null) Text('Changes to ${q!['pending_plan']} at the next renewal', style: const TextStyle(color: Color(0xFFF59E0B))),
                  ]),
                ),
                SegmentedButton<String>(
                  segments: const [ButtonSegment(value: 'monthly', label: Text('Monthly')), ButtonSegment(value: 'yearly', label: Text('Yearly · 2 months free'))],
                  selected: {_cycle},
                  onSelectionChanged: (v) {
                    _cycle = v.first;
                    _reload();
                  },
                ),
              ]),
            ),
          );
        },
      ),
      const SizedBox(height: 20),
      FutureBuilder<List<PlanInfo>>(
        future: _plans,
        builder: (context, snap) {
          final plans = snap.data ?? const <PlanInfo>[];
          return LayoutBuilder(builder: (context, c) {
            final cards = [
              for (final p in plans)
                _PlanCard(
                  plan: p,
                  cycle: _cycle,
                  current: e.status != StationStatus.trial && p.code == e.planCode,
                  onChoose: !isOwner
                      ? null
                      : () async {
                          final id = s.current!.stationId;
                          final q = await s.api.subscriptionQuote(id, p.code, _cycle);
                          if (!context.mounted) return;
                          final active = e.status == StationStatus.active && q['cycle'] == _cycle;
                          final current = plans.firstWhere((x) => x.code == e.planCode, orElse: () => p);
                          if (active && p.code != e.planCode && p.monthly < current.monthly) {
                            if (await runAction(context, () => s.api.scheduleDowngrade(id, p.code), success: 'Will change to ${p.name} at the next renewal')) _reload();
                            return;
                          }
                          final upgrade = active && p.code != e.planCode;
                          final amount = Money.paisa(((upgrade ? q['upgrade_amount'] : q['renewal_amount']) as num? ?? 0).toInt());
                          await _pay(p, kind: upgrade ? 'upgrade' : 'renewal', amount: amount);
                        },
                ),
            ];
            if (c.maxWidth < 900) return Column(children: [for (final w in cards) Padding(padding: const EdgeInsets.only(bottom: 12), child: w)]);
            return IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (var i = 0; i < cards.length; i++) ...[if (i > 0) const SizedBox(width: 16), Expanded(child: cards[i])],
              ]),
            );
          });
        },
      ),
      const SizedBox(height: 24),
      const Text('Payments', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      AsyncStateView<List<SubPayment>>(
        future: _payments,
        isEmpty: (l) => l.isEmpty,
        emptyText: 'No payments yet',
        builder: (context, list) => Column(children: [
          for (final p in list)
            ListTile(
              leading: Icon(switch (p.status) {
                'succeeded' => Icons.check_circle_rounded,
                'pending_verification' || 'pending' => Icons.hourglass_top_rounded,
                _ => Icons.cancel_rounded,
              }, color: switch (p.status) {
                'succeeded' => const Color(0xFF16A34A),
                'pending_verification' || 'pending' => const Color(0xFFF59E0B),
                _ => const Color(0xFFDC2626),
              }),
              title: Text('${p.plan[0].toUpperCase()}${p.plan.substring(1)} · ${p.cycle} · ${p.kind} · ${formatPkr(p.amount)}'),
              subtitle: Text([
                formatDate(p.createdAt.toLocal()),
                p.method,
                if (p.status == 'pending_verification') 'waiting for verification',
                if (p.receiptNo != null) 'receipt #${p.receiptNo}',
                if (p.periodTo != null) 'paid until ${formatDate(p.periodTo!)}',
                if (p.rejectReason != null) 'not accepted: ${p.rejectReason}',
              ].join(' · ')),
            ),
        ]),
      ),
      if (isOwner) ...[
        const Divider(height: 40),
        const Text('Your data', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Wrap(spacing: 12, runSpacing: 12, children: [
          OutlinedButton.icon(
            onPressed: () => exportStationData(context),
            icon: const Icon(Icons.download_rounded),
            label: const Text('Download full Excel export'),
          ),
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            onPressed: () async {
              final c = TextEditingController();
              final name = s.current!.stationName;
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Close account'),
                  content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Your data is kept for 90 days and can be restored by paying any plan. On day 90 it is deleted permanently. '
                        'Download your export first.'),
                    const SizedBox(height: 12),
                    Text('Type "$name" to confirm:'),
                    TextField(controller: c),
                  ]),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep my account')),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Close account'),
                    ),
                  ],
                ),
              );
              if (ok != true || !context.mounted) return;
              if (await runAction(context, () => s.api.closeAccount(s.current!.stationId, c.text), success: 'Account closed')) _reload();
            },
            icon: const Icon(Icons.no_accounts_rounded),
            label: const Text('Close account'),
          ),
        ]),
      ],
    ]);
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.plan, required this.cycle, required this.current, this.onChoose});
  final PlanInfo plan;
  final String cycle;
  final bool current;
  final VoidCallback? onChoose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final price = cycle == 'yearly' ? plan.yearly : plan.monthly;
    final highlight = plan.code == 'standard';
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: current || highlight ? scheme.primary : scheme.outlineVariant, width: current || highlight ? 2 : 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(plan.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const Spacer(),
            if (current) const Chip(label: Text('Current'), visualDensity: VisualDensity.compact) else if (highlight) const Chip(label: Text('Popular'), visualDensity: VisualDensity.compact),
          ]),
          const SizedBox(height: 8),
          Text(formatPkr(price), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          Text(cycle == 'yearly' ? 'per year' : 'per month', style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 14),
          for (final f in _featureNames.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                Icon(plan.features.contains(f.key) ? Icons.check_circle_rounded : Icons.remove_circle_outline_rounded,
                    size: 18, color: plan.features.contains(f.key) ? const Color(0xFF16A34A) : const Color(0xFFCBD5E1)),
                const SizedBox(width: 8),
                Expanded(child: Text(f.value, style: TextStyle(color: plan.features.contains(f.key) ? null : scheme.outline))),
              ]),
            ),
          const Spacer(),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(onPressed: onChoose, child: Text(current ? 'Renew' : 'Choose ${plan.name}')),
          ),
        ]),
      ),
    );
  }
}

/// REQ-008 — bank transfer (reference + receipt) or cash; wallets and cards after the provider is set up.
class _PayDialog extends StatefulWidget {
  const _PayDialog({required this.plan, required this.cycle, required this.kind, required this.amount});
  final PlanInfo plan;
  final String cycle;
  final String kind;
  final Money amount;

  @override
  State<_PayDialog> createState() => _PayDialogState();
}

class _PayDialogState extends State<_PayDialog> {
  String _method = 'bank';
  final _ref = TextEditingController();
  String? _receipt;
  String? _receiptName;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final s = SessionScope.of(context);
    return AlertDialog(
      title: Text('${widget.kind == 'upgrade' ? 'Upgrade to' : 'Pay for'} ${widget.plan.name} (${widget.cycle})'),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Amount: ${formatPkr(widget.amount)}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          if (widget.kind == 'upgrade') const Text('Difference for the days left in your current period. Features unlock as soon as the payment is confirmed.'),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'bank', label: Text('Bank transfer')),
              ButtonSegment(value: 'cash', label: Text('Cash')),
              ButtonSegment(value: 'wallet', label: Text('JazzCash / Easypaisa / Card')),
            ],
            selected: {_method},
            onSelectionChanged: (v) => setState(() => _method = v.first),
          ),
          const SizedBox(height: 12),
          if (_method == 'wallet')
            const Text('Online payment opens once the payment provider is connected. Please use bank transfer or cash for now.')
          else ...[
            TextField(
              controller: _ref,
              decoration: InputDecoration(labelText: _method == 'bank' ? 'Bank reference / transaction number' : 'Who received the cash, and when'),
            ),
            if (_method == 'bank') ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['png', 'jpg', 'jpeg', 'pdf']);
                  if (f == null || !context.mounted) return;
                  final bytes = await f.readAsBytes();
                  if (!context.mounted) return;
                  await runAction(context, () async {
                    _receipt = await s.api.uploadReceipt(s.current!.stationId, bytes, f.name.split('.').last);
                    setState(() => _receiptName = f.name);
                  });
                },
                icon: const Icon(Icons.upload_file_rounded),
                label: Text(_receiptName ?? 'Upload receipt image'),
              ),
            ],
            const SizedBox(height: 8),
            const Text('The platform team verifies it, then your plan is active. You will get a notification.', style: TextStyle(fontSize: 12)),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy || _method == 'wallet'
              ? null
              : () async {
                  setState(() => _busy = true);
                  final ok = await runAction(
                    context,
                    () => s.api.submitManualPayment(s.current!.stationId,
                        kind: widget.kind, plan: widget.plan.code, cycle: widget.cycle, method: _method, reference: _ref.text, receiptPath: _receipt),
                    success: 'Sent for verification',
                  );
                  if (!context.mounted) return;
                  setState(() => _busy = false);
                  if (ok) Navigator.pop(context, true);
                },
          child: const Text('Submit'),
        ),
      ],
    );
  }
}
