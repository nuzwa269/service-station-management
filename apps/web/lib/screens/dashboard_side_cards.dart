part of 'dashboard_screen.dart';

/// Getting-started checklist for a new station; hides itself when every step is done.
class _SetupCard extends StatelessWidget {
  const _SetupCard({required this.steps});
  final List<_SetupStep> steps;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final done = steps.where((s) => s.done).length;
    return _Panel(
      title: 'Get started',
      trailing: Text('$done of ${steps.length}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: scheme.primary)),
      child: Column(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(value: done / steps.length, minHeight: 6, backgroundColor: const Color(0xFFE2E8F0)),
        ),
        const SizedBox(height: 8),
        for (final s in steps)
          InkWell(
            onTap: s.done ? null : () => context.go('/${s.target.name}'),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 9),
              child: Row(children: [
                Icon(s.done ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                    size: 22, color: s.done ? const Color(0xFF22C55E) : const Color(0xFFCBD5E1)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.title,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: s.done ? scheme.onSurfaceVariant : scheme.onSurface,
                          decoration: s.done ? TextDecoration.lineThrough : null,
                        )),
                    Text(s.subtitle, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                  ]),
                ),
                if (!s.done) const Icon(Icons.chevron_right_rounded, size: 18, color: Color(0xFF94A3B8)),
              ]),
            ),
          ),
      ]),
    );
  }
}

/// Owner: the latest changes from the audit log, in plain words.
class _ActivityCard extends StatelessWidget {
  const _ActivityCard({required this.entries, required this.names});
  final List<AuditEntry> entries;
  final Map<String, String> names;

  static (String, IconData, Color) _describe(AuditEntry e) {
    final insert = e.action == 'insert';
    return switch (e.table) {
      'stations' => ('Station settings updated', Icons.storefront_rounded, const Color(0xFF64748B)),
      'station_members' => (insert ? 'Team member added' : 'Team member changed', Icons.group_rounded, const Color(0xFF6366F1)),
      'items' => (insert ? 'Item added' : 'Item updated', Icons.inventory_2_rounded, const Color(0xFFF59E0B)),
      'item_costs' => ('Item cost changed', Icons.price_change_rounded, const Color(0xFFF59E0B)),
      'stock_movements' => ('Stock changed', Icons.swap_vert_rounded, const Color(0xFFF59E0B)),
      'purchases' => (insert ? 'Supplier bill entered' : 'Supplier bill reversed', Icons.receipt_long_rounded, const Color(0xFF8B5CF6)),
      'supplier_ledger' => ('Supplier ledger entry', Icons.account_balance_wallet_rounded, const Color(0xFF8B5CF6)),
      'approval_requests' => (insert ? 'Approval requested' : 'Approval decided', Icons.fact_check_rounded, const Color(0xFFEC4899)),
      'customers' => (insert ? 'Customer added' : 'Customer updated', Icons.person_rounded, const Color(0xFF14B8A6)),
      'vehicles' => (insert ? 'Vehicle added' : 'Vehicle updated', Icons.directions_car_rounded, const Color(0xFF14B8A6)),
      'support_grants' => ('Support access changed', Icons.support_agent_rounded, const Color(0xFF64748B)),
      'subscriptions' => ('Subscription changed', Icons.workspace_premium_rounded, const Color(0xFF64748B)),
      _ => ('${e.table} ${e.action}', Icons.history_rounded, const Color(0xFF64748B)),
    };
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return formatDate(t.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _Panel(
      title: 'Recent activity',
      trailing: TextButton(onPressed: () => context.go('/${MenuItem.auditLog.name}'), child: const Text('View all')),
      child: Column(children: [
        for (var i = 0; i < entries.length; i++) _row(entries[i], i == entries.length - 1, scheme),
      ]),
    );
  }

  Widget _row(AuditEntry e, bool last, ColorScheme scheme) {
    final (text, icon, color) = _describe(e);
    final who = e.actor == null ? 'System' : (names[e.actor] ?? 'Platform team');
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Column(children: [
          _Badge(icon: icon, color: color, size: 30),
          if (!last) Expanded(child: Container(width: 2, color: const Color(0xFFE2E8F0))),
        ]),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 14, top: 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(text, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
              Text('$who · ${_ago(e.at)}', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// Manager (or owner without the audit view): who is on the team.
class _TeamCard extends StatelessWidget {
  const _TeamCard({required this.team});
  final List<Member> team;

  @override
  Widget build(BuildContext context) {
    final active = team.where((m) => m.active).toList();
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return _Panel(
      title: 'Team',
      trailing: Text('${active.length} active', style: TextStyle(fontSize: 12, color: muted)),
      child: Column(children: [
        for (final m in active.take(6))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: const Color(0xFFE0F2FE),
                child: Text(m.name.isEmpty ? '?' : m.name[0].toUpperCase(),
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF0369A1))),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(m.name, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600))),
              Text(m.role.label.split(' ').first, style: TextStyle(fontSize: 12, color: muted)),
            ]),
          ),
      ]),
    );
  }
}
