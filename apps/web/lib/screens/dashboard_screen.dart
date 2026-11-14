import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:station_core/station_core.dart';

import '../main.dart';
import 'shell.dart';

part 'dashboard_side_cards.dart';

const _descriptions = <MenuItem, String>{
  MenuItem.bookings: 'Bays, slots and bookings',
  MenuItem.jobCards: 'Intake to quality check',
  MenuItem.customers: 'Customers and vehicles',
  MenuItem.inventory: 'Parts, oils and kits',
  MenuItem.purchases: 'Supplier bills and dues',
  MenuItem.approvals: 'Requests waiting for you',
  MenuItem.dayClosing: 'Match cash every day',
  MenuItem.reports: 'Sales, stock and dues',
  MenuItem.staff: 'Attendance and payroll',
  MenuItem.users: 'Team and roles',
  MenuItem.dataImport: 'Bring data from Excel',
  MenuItem.settings: 'Branding, tax, rules',
  MenuItem.auditLog: 'Every change recorded',
  MenuItem.subscription: 'Plan and payments',
};

class _SetupStep {
  const _SetupStep(this.title, this.subtitle, this.icon, this.done, this.target);
  final String title;
  final String subtitle;
  final IconData icon;
  final bool done;
  final MenuItem target;
}

class _DashData {
  const _DashData({required this.lowStock, required this.pending, this.setup = const [], this.activity = const [], this.names = const {}, this.team = const [], this.jobs = const {}, this.collected});
  final List<Map<String, dynamic>> lowStock;
  final List<ApprovalRequest> pending;
  final List<_SetupStep> setup;
  final List<AuditEntry> activity;
  final Map<String, String> names;
  final List<Member> team;
  final Map<JobStage, int> jobs;
  final DaySummary? collected;
}

/// SCR-003 — today at a glance. Balanced two-column layout: work on the left,
/// "needs attention" and plan on the right. Job and money figures fill in with Phases 3–4.
class DashboardHome extends StatefulWidget {
  const DashboardHome({super.key});

  @override
  State<DashboardHome> createState() => _DashboardHomeState();
}

class _DashboardHomeState extends State<DashboardHome> {
  late Future<_DashData> _data;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _data = _load();
    }
  }

  Future<_DashData> _load() async {
    final s = SessionScope.of(context);
    final id = s.current!.stationId;
    final low = await s.api.client.from('low_stock_items').select('name, unit, on_hand, min_stock, negative').eq('station_id', id).order('on_hand').limit(50);
    final pending = s.entitlements!.has(Feature.approvalsInbox) && menuFor(s.role!).contains(MenuItem.approvals)
        ? await s.api.approvals(id, pendingOnly: true)
        : <ApprovalRequest>[];
    final role = s.role!;
    var setup = <_SetupStep>[];
    var activity = <AuditEntry>[];
    var team = <Member>[];
    if (role == MemberRole.owner || role == MemberRole.manager) {
      team = await s.api.members(id);
    }
    if (role == MemberRole.owner) {
      final st = await s.api.station(id);
      final anyItem = await s.api.client.from('items').select('id').eq('station_id', id).limit(1);
      final anyCustomer = await s.api.client.from('customers').select('id').eq('station_id', id).limit(1);
      setup = [
        _SetupStep('Add logo and tax details', 'Shown on invoices and messages', Icons.storefront_rounded,
            st['logo_path'] != null && st['address'] != null, MenuItem.settings),
        _SetupStep('Add your team', 'Managers, cashiers and mechanics', Icons.group_add_rounded, team.length > 1, MenuItem.users),
        _SetupStep('Add parts and oils', 'Or import them from Excel', Icons.inventory_2_rounded, anyItem.isNotEmpty, MenuItem.inventory),
        _SetupStep('Add customers', 'With their vehicles', Icons.directions_car_rounded, anyCustomer.isNotEmpty, MenuItem.customers),
        _SetupStep('Choose a plan', 'Keep working after the trial', Icons.workspace_premium_rounded,
            s.entitlements!.status != StationStatus.trial, MenuItem.subscription),
      ];
      if (s.entitlements!.has(Feature.auditLogView)) {
        activity = await s.api.auditLog(id, limit: 6);
      }
    }
    return _DashData(
      lowStock: List<Map<String, dynamic>>.from(low),
      pending: pending,
      setup: setup,
      activity: activity,
      team: team,
      names: {for (final m in team) m.userId: m.name},
      jobs: await s.api.jobCounts(id),
      collected: await s.api.daySummary(id, DateTime.now()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = SessionScope.of(context);
    final role = s.role!;
    final modules = menuFor(role).where((m) => m != MenuItem.dashboard).toList();

    return FutureBuilder<_DashData>(
      future: _data,
      builder: (context, snap) {
        final d = snap.data;
        return LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth >= 1000;
          final left = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _QuickActions(role: role),
            const SizedBox(height: 20),
            _ModulesCard(modules: modules, entitlements: s.entitlements!, width: wide ? c.maxWidth * 2 / 3 : c.maxWidth),
            if (d != null && d.activity.isNotEmpty) ...[const SizedBox(height: 20), _ActivityCard(entries: d.activity, names: d.names)],
          ]);
          final right = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _AttentionCard(data: d, loading: snap.connectionState != ConnectionState.done),
            const SizedBox(height: 20),
            _PlanCard(entitlements: s.entitlements!, showPlan: role == MemberRole.owner),
            if (d != null && d.setup.any((x) => !x.done)) ...[const SizedBox(height: 20), _SetupCard(steps: d.setup)],
            if (d != null && d.team.isNotEmpty) ...[const SizedBox(height: 20), _TeamCard(team: d.team)],
          ]);
          return ListView(padding: const EdgeInsets.fromLTRB(20, 24, 20, 32), children: [
            Text('Today', style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary)),
            const SizedBox(height: 2),
            Text(formatDateLong(DateTime.now()), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
            const SizedBox(height: 20),
            _KpiRow(data: d, columns: c.maxWidth >= 900 ? 4 : 2),
            const SizedBox(height: 20),
            if (wide)
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 2, child: left),
                const SizedBox(width: 20),
                Expanded(child: right),
              ])
            else ...[right, const SizedBox(height: 20), left],
          ]);
        });
      },
    );
  }
}

/// Section card with a title row; every dashboard block uses it so edges and spacing line up.
class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
              ?trailing,
            ]),
            const SizedBox(height: 16),
            child,
          ]),
        ),
      );
}

class _KpiRow extends StatelessWidget {
  const _KpiRow({required this.data, required this.columns});
  final _DashData? data;
  final int columns;

  @override
  Widget build(BuildContext context) {
    final low = data?.lowStock.length;
    final pending = data?.pending.length;
    final cards = [
      _Kpi(
        icon: Icons.assignment_rounded,
        color: const Color(0xFF0EA5E9),
        label: 'Open job cards',
        value: data == null ? '…' : '${data!.jobs.values.fold(0, (a, b) => a + b)}',
        hint: data == null ? '' : '${data!.jobs[JobStage.inProgress] ?? 0} in progress · ${data!.jobs[JobStage.ready] ?? 0} ready',
        onTap: () => context.go('/${MenuItem.jobCards.name}'),
      ),
      _Kpi(
        icon: Icons.payments_rounded,
        color: const Color(0xFF22C55E),
        label: 'Collected today',
        value: data?.collected == null ? '…' : formatPkr(data!.collected!.expected.values.fold(Money.zero, (a, b) => a + b)),
        hint: data?.collected == null ? '' : (data!.collected!.closed ? 'Day closed' : 'Cash ${formatPkr(data!.collected!.expectedCash)}'),
        onTap: () => context.go('/${MenuItem.dayClosing.name}'),
      ),
      _Kpi(
        icon: Icons.inventory_2_rounded,
        color: const Color(0xFFF59E0B),
        label: 'Low stock items',
        value: low == null ? '…' : '$low',
        hint: low == 0 ? 'All good' : 'Need reorder',
        onTap: () => context.go('/${MenuItem.inventory.name}'),
      ),
      _Kpi(
        icon: Icons.fact_check_rounded,
        color: const Color(0xFFEC4899),
        label: 'Pending approvals',
        value: pending == null ? '…' : '$pending',
        hint: pending == 0 ? 'Nothing waiting' : 'Waiting for decision',
        onTap: () => context.go('/${MenuItem.approvals.name}'),
      ),
    ];
    final rows = <Widget>[];
    for (var i = 0; i < cards.length; i += columns) {
      final slice = cards.sublist(i, (i + columns).clamp(0, cards.length));
      rows.add(IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var j = 0; j < slice.length; j++) ...[
            if (j > 0) const SizedBox(width: 16),
            Expanded(child: slice[j]),
          ],
        ]),
      ));
      if (i + columns < cards.length) rows.add(const SizedBox(height: 16));
    }
    return Column(children: rows);
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi({required this.icon, required this.color, required this.label, required this.value, required this.hint, this.onTap});
  final IconData icon;
  final Color color;
  final String label;
  final String value;
  final String hint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Card(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(label, style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant))),
                _Badge(icon: icon, color: color, size: 34),
              ]),
              const SizedBox(height: 8),
              Text(value, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
              const SizedBox(height: 2),
              Text(hint, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      );
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.color, this.size = 40});
  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(size * 0.3)),
        alignment: Alignment.center,
        child: Icon(icon, color: color, size: size * 0.52),
      );
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({required this.role});
  final MemberRole role;

  @override
  Widget build(BuildContext context) {
    final actions = [
      (MenuItem.jobCards, 'New job card', Icons.add_task_rounded),
      (MenuItem.customers, 'Add customer', Icons.person_add_alt_1_rounded),
      (MenuItem.inventory, 'Add item', Icons.add_box_rounded),
      if (role == MemberRole.owner || role == MemberRole.manager) (MenuItem.purchases, 'Enter supplier bill', Icons.receipt_long_rounded),
    ].where((a) => menuFor(role).contains(a.$1)).toList();
    return _Panel(
      title: 'Quick actions',
      child: Row(children: [
        for (var i = 0; i < actions.length; i++) ...[
          if (i > 0) const SizedBox(width: 12),
          Expanded(
            child: _ActionButton(
              icon: actions[i].$3,
              label: actions[i].$2,
              color: moduleColors[actions[i].$1]!,
              onTap: () => context.go('/${actions[i].$1.name}'),
            ),
          ),
        ],
      ]),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.icon, required this.label, required this.color, required this.onTap});
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            height: 92,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, color: color, size: 26),
              const SizedBox(height: 8),
              Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      );
}

class _ModulesCard extends StatelessWidget {
  const _ModulesCard({required this.modules, required this.entitlements, required this.width});
  final List<MenuItem> modules;
  final Entitlements entitlements;
  final double width;

  @override
  Widget build(BuildContext context) {
    final cols = width >= 760 ? 3 : width >= 480 ? 2 : 1;
    return _Panel(
      title: 'All modules',
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: modules.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          mainAxisExtent: 76,
        ),
        itemBuilder: (context, i) {
          final m = modules[i];
          final locked = m.feature != null && !entitlements.has(m.feature!);
          return Material(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => context.go('/${m.name}'),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(children: [
                  _Badge(icon: moduleIcons[m]!, color: locked ? const Color(0xFF94A3B8) : moduleColors[m]!),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(m.label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      Text(locked ? lockedFeatureText(m.feature!) : _descriptions[m] ?? '',
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    ]),
                  ),
                  Icon(locked ? Icons.lock_rounded : Icons.chevron_right_rounded, size: 18, color: const Color(0xFF94A3B8)),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _AttentionCard extends StatelessWidget {
  const _AttentionCard({required this.data, required this.loading});
  final _DashData? data;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final low = data?.lowStock ?? const [];
    final pending = data?.pending ?? const <ApprovalRequest>[];
    final rows = <Widget>[
      for (final p in pending.take(3))
        _AttentionRow(
          icon: Icons.fact_check_rounded,
          color: const Color(0xFFEC4899),
          title: p.typeLabel,
          subtitle: '${p.requestedByName} · ${p.summary}',
          onTap: () => context.go('/${MenuItem.approvals.name}'),
        ),
      for (final l in low.take(5))
        _AttentionRow(
          icon: l['negative'] == true ? Icons.error_rounded : Icons.inventory_2_rounded,
          color: l['negative'] == true ? scheme.error : const Color(0xFFF59E0B),
          title: l['name'] as String,
          subtitle: 'Stock ${formatQty(l['on_hand'] as num, ItemUnit.parse(l['unit'] as String))}'
              ' · min ${formatQty(l['min_stock'] as num, ItemUnit.parse(l['unit'] as String))}',
          onTap: () => context.go('/${MenuItem.inventory.name}'),
        ),
    ];
    return _Panel(
      title: 'Needs attention',
      trailing: rows.isEmpty ? null : _CountPill(count: pending.length + low.length),
      child: loading
          ? const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
          : rows.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(children: [
                    const _Badge(icon: Icons.check_circle_rounded, color: Color(0xFF22C55E)),
                    const SizedBox(width: 12),
                    Expanded(child: Text('All clear — nothing needs you right now.', style: TextStyle(color: scheme.onSurfaceVariant))),
                  ]),
                )
              : Column(children: [
                  for (var i = 0; i < rows.length; i++) ...[if (i > 0) const Divider(height: 1), rows[i]],
                ]),
    );
  }
}

class _CountPill extends StatelessWidget {
  const _CountPill({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.errorContainer, borderRadius: BorderRadius.circular(20)),
        child: Text('$count', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.onErrorContainer)),
      );
}

class _AttentionRow extends StatelessWidget {
  const _AttentionRow({required this.icon, required this.color, required this.title, required this.subtitle, required this.onTap});
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(children: [
            _Badge(icon: icon, color: color, size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ]),
            ),
            const Icon(Icons.chevron_right_rounded, size: 18, color: Color(0xFF94A3B8)),
          ]),
        ),
      );
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.entitlements, required this.showPlan});
  final Entitlements entitlements;
  final bool showPlan;

  @override
  Widget build(BuildContext context) {
    final e = entitlements;
    final scheme = Theme.of(context).colorScheme;
    final renews = e.renewsAt?.toLocal();
    final trial = e.status == StationStatus.trial;
    final daysLeft = renews == null ? null : renews.difference(DateTime.now()).inDays + 1;
    final plan = trial ? 'Free trial' : '${e.planCode[0].toUpperCase()}${e.planCode.substring(1)} plan';
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [scheme.primary, Color.lerp(scheme.primary, scheme.tertiary, 0.7)!], begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.workspace_premium_rounded, color: Colors.white),
          const SizedBox(width: 8),
          Text(plan, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 12),
        if (trial && daysLeft != null) ...[
          Text('$daysLeft of 14 days left · all Premium features',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontSize: 13)),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: (daysLeft / 14).clamp(0, 1).toDouble(),
              minHeight: 6,
              backgroundColor: Colors.white24,
              valueColor: const AlwaysStoppedAnimation(Colors.white),
            ),
          ),
        ] else if (renews != null)
          Text('Renews on ${formatDateLong(renews)}', style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontSize: 13)),
        if (showPlan) ...[
          const SizedBox(height: 16),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: scheme.primary),
            onPressed: () => context.go('/${MenuItem.subscription.name}'),
            child: Text(trial ? 'Choose a plan' : 'Manage plan'),
          ),
        ],
      ]),
    );
  }
}
