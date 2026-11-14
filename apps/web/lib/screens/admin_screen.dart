import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:station_core/station_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart';
import 'common.dart';

/// SCR-021…023 — platform super admin: tenants, payment verification, trials, suspension, plans.
/// Shows account and usage data only; station records need an owner's support grant (REQ-005, REQ-012).
class AdminHome extends StatefulWidget {
  const AdminHome({super.key});

  @override
  State<AdminHome> createState() => _AdminHomeState();
}

enum _TenantFilter { all, trialSoon, grace, readOnly, suspended, payments, closed }

const _filterLabels = {
  _TenantFilter.all: 'All',
  _TenantFilter.trialSoon: 'Trial ends in 7 days',
  _TenantFilter.grace: 'Grace',
  _TenantFilter.readOnly: 'Read-only',
  _TenantFilter.suspended: 'Suspended',
  _TenantFilter.payments: 'Payments to verify',
  _TenantFilter.closed: 'Closed',
};

bool _matches(_TenantFilter f, Tenant t) => switch (f) {
      _TenantFilter.all => true,
      _TenantFilter.trialSoon => t.status == StationStatus.trial && t.trialEndsAt != null && t.trialEndsAt!.isBefore(DateTime.now().add(const Duration(days: 7))),
      _TenantFilter.grace => t.status == StationStatus.grace,
      _TenantFilter.readOnly => t.status == StationStatus.readOnly,
      _TenantFilter.suspended => t.status == StationStatus.suspended,
      _TenantFilter.payments => t.pendingPayments > 0,
      _TenantFilter.closed => t.status == StationStatus.closed,
    };

const _statusColors = {
  StationStatus.trial: Color(0xFF6366F1),
  StationStatus.active: Color(0xFF16A34A),
  StationStatus.grace: Color(0xFFF59E0B),
  StationStatus.readOnly: Color(0xFFDC2626),
  StationStatus.suspended: Color(0xFF7C3AED),
  StationStatus.closed: Color(0xFF64748B),
};

String _statusLabel(StationStatus s) => switch (s) {
      StationStatus.trial => 'Trial',
      StationStatus.active => 'Active',
      StationStatus.grace => 'Grace',
      StationStatus.readOnly => 'Read-only',
      StationStatus.suspended => 'Suspended',
      StationStatus.closed => 'Closed',
    };

class _AdminHomeState extends State<AdminHome> {
  late Future<List<Tenant>> _tenants;
  _TenantFilter _filter = _TenantFilter.all;
  String _q = '';
  String? _selected;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  void _reload() => setState(() => _tenants = SessionScope.of(context).api.tenants());

  @override
  Widget build(BuildContext context) {
    final s = SessionScope.of(context);
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.white,
          title: const Row(children: [
            Icon(Icons.admin_panel_settings_rounded),
            SizedBox(width: 10),
            Text('Platform admin', style: TextStyle(fontWeight: FontWeight.w800)),
          ]),
          actions: [IconButton(tooltip: 'Log out', onPressed: s.signOut, icon: const Icon(Icons.logout_rounded))],
          bottom: const TabBar(tabs: [Tab(text: 'Tenants'), Tab(text: 'Plans'), Tab(text: 'Deleted')]),
        ),
        body: TabBarView(children: [
          _tenantsTab(context),
          const _PlansTab(),
          const _DeletedTab(),
        ]),
      ),
    );
  }

  Widget _tenantsTab(BuildContext context) => AsyncStateView<List<Tenant>>(
        future: _tenants,
        onRetry: _reload,
        builder: (context, all) {
          final shown = all
              .where((t) => _matches(_filter, t))
              .where((t) => _q.isEmpty || t.name.toLowerCase().contains(_q) || t.city.toLowerCase().contains(_q) || (t.ownerMobile ?? '').contains(_q))
              .toList();
          final selected = all.where((t) => t.stationId == _selected).firstOrNull;
          final list = Column(children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search), hintText: 'Station, city or owner mobile'),
                onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
              ),
            ),
            SizedBox(
              height: 40,
              child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
                for (final f in _TenantFilter.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text('${_filterLabels[f]} ${all.where((t) => _matches(f, t)).length}'),
                      selected: f == _filter,
                      onSelected: (_) => setState(() => _filter = f),
                    ),
                  ),
              ]),
            ),
            Expanded(
              child: shown.isEmpty
                  ? const Center(child: Text('No tenants match'))
                  : ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: shown.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        final t = shown[i];
                        final c = _statusColors[t.status]!;
                        return Card(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                            side: BorderSide(color: t.stationId == _selected ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outlineVariant),
                          ),
                          child: ListTile(
                            onTap: () => setState(() => _selected = t.stationId),
                            title: Text(t.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                            subtitle: Text('${t.city} · ${t.plan} · ${t.users} users · ${t.jobsThisMonth} jobs this month'),
                            trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
                                child: Text(_statusLabel(t.status), style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w700)),
                              ),
                              if (t.pendingPayments > 0)
                                Text('${t.pendingPayments} to verify', style: const TextStyle(fontSize: 11, color: Color(0xFFF59E0B), fontWeight: FontWeight.w700)),
                            ]),
                          ),
                        );
                      },
                    ),
            ),
          ]);
          final detail = selected == null
              ? const Center(child: Text('Select a tenant'))
              : _TenantDetail(key: ValueKey(selected.stationId), tenant: selected, onChanged: _reload);
          return LayoutBuilder(builder: (context, c) {
            if (c.maxWidth < 1000) {
              return selected == null
                  ? list
                  : Column(children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(onPressed: () => setState(() => _selected = null), icon: const Icon(Icons.arrow_back), label: const Text('Back')),
                      ),
                      Expanded(child: detail),
                    ]);
            }
            return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(width: 460, child: list),
              const VerticalDivider(width: 1),
              Expanded(child: detail),
            ]);
          });
        },
      );
}

class _TenantDetail extends StatefulWidget {
  const _TenantDetail({super.key, required this.tenant, required this.onChanged});
  final Tenant tenant;
  final VoidCallback onChanged;

  @override
  State<_TenantDetail> createState() => _TenantDetailState();
}

class _TenantDetailState extends State<_TenantDetail> {
  late Future<List<SubPayment>> _payments;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _payments = SessionScope.of(context).api.subscriptionPayments(widget.tenant.stationId);
  }

  Future<void> _act(Future<void> Function() a, String ok) async {
    if (await runAction(context, a, success: ok)) {
      setState(() => _payments = SessionScope.of(context).api.subscriptionPayments(widget.tenant.stationId));
      widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = SessionScope.of(context).api;
    final t = widget.tenant;
    Widget kv(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [SizedBox(width: 170, child: Text(k, style: const TextStyle(color: Color(0xFF64748B)))), Expanded(child: Text(v, style: const TextStyle(fontWeight: FontWeight.w600)))]),
        );
    return ListView(padding: const EdgeInsets.all(20), children: [
      Text(t.name, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
      Text('${t.city} · joined ${formatDate(t.createdAt.toLocal())}'),
      const SizedBox(height: 16),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            kv('Status', _statusLabel(t.status)),
            kv('Plan', t.plan),
            if (t.trialEndsAt != null && t.status == StationStatus.trial) kv('Trial ends', formatDateLong(t.trialEndsAt!.toLocal())),
            if (t.renewsAt != null && t.status != StationStatus.trial) kv('Renewal', formatDateLong(t.renewsAt!.toLocal())),
            if (t.deletionDueAt != null) kv('Deletion on', formatDateLong(t.deletionDueAt!.toLocal())),
            kv('Owner', '${t.ownerName ?? '—'} · ${t.ownerMobile == null ? '' : formatPkMobile(t.ownerMobile!)}'),
            kv('Users', '${t.users}'),
            kv('Job cards this month', '${t.jobsThisMonth}'),
            kv('WhatsApp connected', t.whatsappConnected ? 'Yes' : 'No'),
            kv('Support access', t.supportActive ? 'Granted by owner' : 'Not granted'),
          ]),
        ),
      ),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (t.status == StationStatus.trial)
          OutlinedButton.icon(
            onPressed: () async {
              final d = await askReason(context, title: 'Extend trial by how many days?', label: 'Days (1–60)');
              final n = int.tryParse(d ?? '');
              if (n != null) await _act(() => api.extendTrial(t.stationId, n), 'Trial extended');
            },
            icon: const Icon(Icons.more_time_rounded),
            label: const Text('Extend trial'),
          ),
        OutlinedButton.icon(
          onPressed: () async {
            final suspend = t.status != StationStatus.suspended;
            final reason = await askReason(context, title: suspend ? 'Suspend ${t.name}' : 'Unsuspend ${t.name}');
            if (reason != null) await _act(() => api.setSuspended(t.stationId, suspend, reason), suspend ? 'Suspended' : 'Unsuspended');
          },
          icon: Icon(t.status == StationStatus.suspended ? Icons.play_circle_rounded : Icons.pause_circle_rounded),
          label: Text(t.status == StationStatus.suspended ? 'Unsuspend' : 'Suspend'),
        ),
        if (t.supportActive)
          OutlinedButton.icon(
            onPressed: () => _act(() => api.openSupportSession(t.stationId), 'Support session logged — read-only'),
            icon: const Icon(Icons.support_agent_rounded),
            label: const Text('Open support session'),
          ),
      ]),
      const SizedBox(height: 20),
      const Text('Subscription payments', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      AsyncStateView<List<SubPayment>>(
        future: _payments,
        isEmpty: (l) => l.isEmpty,
        emptyText: 'No payments',
        builder: (context, list) => Column(children: [
          for (final p in list)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${p.plan} · ${p.cycle} · ${p.kind} · ${formatPkr(p.amount)} · ${p.method}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text('${formatDate(p.createdAt.toLocal())} · ${p.status.replaceAll('_', ' ')}${p.reference == null ? '' : ' · ref ${p.reference}'}'
                      '${p.rejectReason == null ? '' : ' · ${p.rejectReason}'}'),
                  if (p.status == 'pending_verification') ...[
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, children: [
                      if (p.receiptPath != null)
                        TextButton.icon(
                          onPressed: () async {
                            final url = await api.receiptUrl(p.receiptPath!);
                            await launchUrl(Uri.parse(url));
                          },
                          icon: const Icon(Icons.receipt_rounded),
                          label: const Text('View receipt'),
                        ),
                      FilledButton(onPressed: () => _act(() => api.verifyPayment(p.id, approve: true), 'Verified — plan active'), child: const Text('Verify')),
                      OutlinedButton(
                        onPressed: () async {
                          final reason = await askReason(context, title: 'Reject payment', label: 'Reason for the owner');
                          if (reason != null) await _act(() => api.verifyPayment(p.id, approve: false, reason: reason), 'Rejected');
                        },
                        child: const Text('Reject'),
                      ),
                    ]),
                  ],
                ]),
              ),
            ),
        ]),
      ),
    ]);
  }
}

class _PlansTab extends StatefulWidget {
  const _PlansTab();

  @override
  State<_PlansTab> createState() => _PlansTabState();
}

class _PlansTabState extends State<_PlansTab> {
  late Future<List<PlanInfo>> _plans;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _plans = SessionScope.of(context).api.plans();
  }

  @override
  Widget build(BuildContext context) {
    final api = SessionScope.of(context).api;
    return AsyncStateView<List<PlanInfo>>(
      future: _plans,
      builder: (context, plans) => ListView(padding: const EdgeInsets.all(20), children: [
        const Text('New prices apply to each station from its next renewal.'),
        const SizedBox(height: 12),
        for (final p in plans)
          Card(
            child: ListTile(
              title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text('${formatPkr(p.monthly)} / month · ${formatPkr(p.yearly)} / year'),
              trailing: TextButton(
                onPressed: () async {
                  final m = TextEditingController(text: '${p.monthly.wholeRupees}');
                  final y = TextEditingController(text: '${p.yearly.wholeRupees}');
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: Text('${p.name} prices'),
                      content: Column(mainAxisSize: MainAxisSize.min, children: [
                        TextField(controller: m, decoration: const InputDecoration(labelText: 'Monthly (Rs)')),
                        const SizedBox(height: 12),
                        TextField(controller: y, decoration: const InputDecoration(labelText: 'Yearly (Rs)')),
                      ]),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
                      ],
                    ),
                  );
                  final mm = int.tryParse(m.text.replaceAll(',', ''));
                  final yy = int.tryParse(y.text.replaceAll(',', ''));
                  if (ok != true || mm == null || yy == null || !context.mounted) return;
                  if (await runAction(context, () => api.updatePlan(p.code, mm, yy), success: 'Prices saved')) {
                    setState(() => _plans = api.plans());
                  }
                },
                child: const Text('Edit prices'),
              ),
            ),
          ),
      ]),
    );
  }
}

class _DeletedTab extends StatelessWidget {
  const _DeletedTab();

  @override
  Widget build(BuildContext context) => AsyncStateView<List<Map<String, dynamic>>>(
        future: SessionScope.of(context).api.deletedTenants(),
        isEmpty: (l) => l.isEmpty,
        emptyText: 'No deleted tenants',
        builder: (context, rows) => ListView(padding: const EdgeInsets.all(20), children: [
          for (final r in rows)
            ListTile(
              leading: const Icon(Icons.delete_forever_rounded),
              title: Text(r['name'] as String),
              subtitle: Text('Closed — deleted on ${formatDate(DateTime.parse(r['deleted_at'] as String).toLocal())}'),
            ),
        ]),
      );
}
