import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:station_core/station_core.dart';

/// SCR-035 — REQ-060 quick dashboard on the phone: jobs per stage, today's collections by
/// method, customer dues, low stock, WhatsApp waiting, and the approvals inbox (REQ-057)
/// for owners / managers who can decide.
class StaffDashboardTab extends StatefulWidget {
  const StaffDashboardTab({super.key, required this.api, required this.stationId, required this.role, required this.entitlements});
  final StationApi api;
  final String stationId;
  final MemberRole role;
  final Entitlements entitlements;

  @override
  State<StaffDashboardTab> createState() => _StaffDashboardTabState();
}

class _Dash {
  const _Dash(this.totals, this.today, this.approvals);
  final Map<String, dynamic> totals;
  final DaySummary today;
  final List<ApprovalRequest> approvals;
}

class _StaffDashboardTabState extends State<StaffDashboardTab> {
  late Future<_Dash> _data = _load();

  bool get _approver =>
      (widget.role == MemberRole.owner || widget.role == MemberRole.manager) && widget.entitlements.has(Feature.approvalsInbox);

  Future<_Dash> _load() async => _Dash(
        await widget.api.dashboardTotals(widget.stationId),
        await widget.api.daySummary(widget.stationId, DateTime.now()),
        _approver ? await widget.api.approvals(widget.stationId, pendingOnly: true) : const [],
      );

  Future<void> _reload() async {
    final f = _load();
    setState(() => _data = f);
    await f;
  }

  Future<void> _decide(ApprovalRequest r, bool approve) async {
    try {
      await widget.api.decideApproval(r.id, approve);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(approve ? 'Approved' : 'Rejected')));
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
        onRefresh: _reload,
        child: FutureBuilder<_Dash>(
          future: _data,
          builder: (context, snap) {
            if (snap.hasError) return ListView(children: [ErrorStateView(message: 'Could not load the dashboard', onRetry: _reload)]);
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final d = snap.data!;
            final stages = Map<String, dynamic>.from(d.totals['jobs_by_stage'] as Map? ?? const {});
            int stage(String s) => (stages[s] as num?)?.toInt() ?? 0;
            final collected = d.today.expected.values.fold(Money.zero, (a, b) => a + b);
            Widget tile(String label, String value, IconData icon, Color color) => Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(children: [
                      CircleAvatar(radius: 18, backgroundColor: color.withValues(alpha: 0.12), child: Icon(icon, color: color, size: 20)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                          Text(label, style: const TextStyle(fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                        ]),
                      ),
                    ]),
                  ),
                );
            final tiles = [
              tile('In progress', '${stage('in_progress')}', Icons.build_rounded, const Color(0xFF0EA5E9)),
              tile('Ready', '${stage('ready')}', Icons.directions_car_filled_rounded, const Color(0xFF16A34A)),
              tile('Waiting approval', '${stage('awaiting_approval')}', Icons.hourglass_top_rounded, const Color(0xFFF59E0B)),
              tile('Quality check', '${stage('quality_check')}', Icons.verified_outlined, const Color(0xFF8B5CF6)),
              tile('Collected today', formatPkr(collected), Icons.payments_rounded, const Color(0xFF22C55E)),
              tile('Customer dues', formatPkr(Money.paisa(((d.totals['dues_paisa'] as num?) ?? 0).round())),
                  Icons.account_balance_wallet_rounded, const Color(0xFF8B5CF6)),
              tile('Low stock', '${d.totals['low_stock'] ?? 0}', Icons.inventory_2_rounded, const Color(0xFFF59E0B)),
              tile('WhatsApp to send', '${d.totals['messages_to_send'] ?? 0}', Icons.chat_rounded, const Color(0xFF16A34A)),
            ];
            return ListView(padding: const EdgeInsets.all(12), children: [
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 2.3,
                children: tiles,
              ),
              const SizedBox(height: 12),
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    const Text('Collected today by method', style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    if (d.today.expected.isEmpty) const Text('Nothing yet'),
                    for (final e in d.today.expected.entries)
                      Row(children: [Expanded(child: Text(e.key.label)), Text(formatPkr(e.value), style: const TextStyle(fontWeight: FontWeight.w700))]),
                    if (d.today.closed) const Padding(padding: EdgeInsets.only(top: 6), child: Text('Day closed', style: TextStyle(fontSize: 12))),
                  ]),
                ),
              ),
              if (_approver) ...[
                const SizedBox(height: 12),
                Text('Approvals (${d.approvals.length})', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                if (d.approvals.isEmpty) const Text('Nothing waiting'),
                for (final r in d.approvals)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Text(
                          '${r.type[0].toUpperCase()}${r.type.substring(1).replaceAll('_', ' ')}'
                          '${r.amount != null ? ' · ${formatPkr(r.amount!)}' : ''}${r.itemName != null ? ' · ${r.itemName}' : ''}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        Text('${r.reason} — ${r.requestedByName}', style: const TextStyle(fontSize: 12)),
                        const SizedBox(height: 6),
                        Row(children: [
                          Expanded(child: OutlinedButton(onPressed: () => _decide(r, false), child: const Text('Reject'))),
                          const SizedBox(width: 8),
                          Expanded(child: FilledButton(onPressed: () => _decide(r, true), child: const Text('Approve'))),
                        ]),
                      ]),
                    ),
                  ),
              ],
            ]);
          },
        ),
      );
}
