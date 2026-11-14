import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:station_core/station_core.dart';

import '../main.dart';

const moduleIcons = <MenuItem, IconData>{
  MenuItem.dashboard: Icons.space_dashboard_rounded,
  MenuItem.bookings: Icons.event_available_rounded,
  MenuItem.jobCards: Icons.assignment_rounded,
  MenuItem.customers: Icons.people_alt_rounded,
  MenuItem.inventory: Icons.inventory_2_rounded,
  MenuItem.purchases: Icons.local_shipping_rounded,
  MenuItem.approvals: Icons.fact_check_rounded,
  MenuItem.dayClosing: Icons.point_of_sale_rounded,
  MenuItem.reports: Icons.insights_rounded,
  MenuItem.staff: Icons.badge_rounded,
  MenuItem.users: Icons.manage_accounts_rounded,
  MenuItem.dataImport: Icons.upload_file_rounded,
  MenuItem.settings: Icons.settings_rounded,
  MenuItem.auditLog: Icons.history_rounded,
  MenuItem.subscription: Icons.workspace_premium_rounded,
};

/// Accent colour per module, used for icon badges on the dashboard.
const moduleColors = <MenuItem, Color>{
  MenuItem.bookings: Color(0xFF6366F1),
  MenuItem.jobCards: Color(0xFF0EA5E9),
  MenuItem.customers: Color(0xFF14B8A6),
  MenuItem.inventory: Color(0xFFF59E0B),
  MenuItem.purchases: Color(0xFF8B5CF6),
  MenuItem.approvals: Color(0xFFEC4899),
  MenuItem.dayClosing: Color(0xFF22C55E),
  MenuItem.reports: Color(0xFF3B82F6),
  MenuItem.staff: Color(0xFFEF4444),
  MenuItem.users: Color(0xFF64748B),
  MenuItem.dataImport: Color(0xFF64748B),
  MenuItem.settings: Color(0xFF64748B),
  MenuItem.auditLog: Color(0xFF64748B),
  MenuItem.subscription: Color(0xFF64748B),
};

/// Role-based modules (REQ-002) with plan gating (REQ-006) and the
/// trial / grace / read-only banner (REQ-007, REQ-009).
class StationShell extends StatelessWidget {
  const StationShell({super.key, required this.location, required this.child});
  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final membership = session.current;
    final ent = session.entitlements;
    if (membership == null || ent == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return StationShellView(
      stationName: membership.stationName,
      role: membership.role,
      entitlements: ent,
      location: location,
      onNavigate: (path) => context.go(path),
      onSignOut: session.signOut,
      child: child,
    );
  }
}

const _maxContentWidth = 1280.0;

/// No side menu: a clean header with one row of tabs. Owner tools sit as
/// icon buttons at the top right. The chosen module opens below. Pure view.
class StationShellView extends StatelessWidget {
  const StationShellView({
    super.key,
    required this.stationName,
    required this.role,
    required this.entitlements,
    required this.location,
    required this.onNavigate,
    required this.onSignOut,
    required this.child,
  });

  final String stationName;
  final MemberRole role;
  final Entitlements entitlements;
  final String location;
  final void Function(String path) onNavigate;
  final VoidCallback onSignOut;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final items = menuFor(role);
    final tabs = items.where((m) => !adminItems.contains(m)).toList();
    final tools = items.where(adminItems.contains).toList();
    final current = items.where((m) => location == '/${m.name}').firstOrNull;
    final locked = current?.feature != null && !entitlements.has(current!.feature!);
    final scheme = Theme.of(context).colorScheme;
    final narrow = MediaQuery.sizeOf(context).width < 760;

    final Widget content = current == null
        ? const ErrorStateView(message: 'You do not have access to this page.')
        : locked
            ? LockedFeatureCard(
                feature: current.feature!,
                title: current.label,
                onUpgrade: role == MemberRole.owner ? () => onNavigate('/${MenuItem.subscription.name}') : null,
              )
            : child;

    return Scaffold(
      body: Column(children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6))),
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _maxContentWidth),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(children: [
                  SizedBox(
                    height: 64,
                    child: Row(children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: [scheme.primary, scheme.tertiary]),
                          borderRadius: BorderRadius.circular(11),
                        ),
                        alignment: Alignment.center,
                        child: const Icon(Icons.car_repair_rounded, color: Colors.white, size: 22),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(stationName,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: -0.2)),
                          Text(role.label, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                        ]),
                      ),
                      if (!narrow)
                        for (final t in tools)
                          _ToolButton(
                            key: Key('menu-${t.name}'),
                            icon: moduleIcons[t]!,
                            tooltip: t.label,
                            selected: t == current,
                            onTap: () => onNavigate('/${t.name}'),
                          ),
                      if (narrow && tools.isNotEmpty)
                        PopupMenuButton<MenuItem>(
                          tooltip: 'Owner tools',
                          icon: const Icon(Icons.more_horiz_rounded),
                          onSelected: (m) => onNavigate('/${m.name}'),
                          itemBuilder: (_) => [
                            for (final t in tools)
                              PopupMenuItem(
                                key: Key('menu-${t.name}'),
                                value: t,
                                child: Row(children: [Icon(moduleIcons[t], size: 18), const SizedBox(width: 10), Text(t.label)]),
                              ),
                          ],
                        ),
                      const SizedBox(width: 6),
                      _ToolButton(icon: Icons.logout_rounded, tooltip: 'Log out', onTap: onSignOut),
                    ]),
                  ),
                  SizedBox(
                    height: 46,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final m in tabs)
                          _NavTab(
                            key: Key('menu-${m.name}'),
                            label: m.label,
                            icon: moduleIcons[m]!,
                            selected: m == current,
                            locked: m.feature != null && !entitlements.has(m.feature!),
                            onTap: () => onNavigate('/${m.name}'),
                          ),
                      ],
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
        SubscriptionBanner(entitlements: entitlements),
        Expanded(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: _maxContentWidth), child: content),
          ),
        ),
      ]),
    );
  }
}

/// Underlined text tab, like modern SaaS dashboards.
class _NavTab extends StatelessWidget {
  const _NavTab({super.key, required this.label, required this.icon, required this.selected, required this.locked, required this.onTap});
  final String label;
  final IconData icon;
  final bool selected;
  final bool locked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: selected ? scheme.primary : Colors.transparent, width: 2.5)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 17, color: color),
          const SizedBox(width: 7),
          Text(label, style: TextStyle(fontSize: 13.5, color: color, fontWeight: selected ? FontWeight.w600 : FontWeight.w500)),
          if (locked) ...[const SizedBox(width: 4), Icon(Icons.lock_rounded, size: 12, color: scheme.outline)],
        ]),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({super.key, required this.icon, required this.tooltip, required this.onTap, this.selected = false});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: IconButton(
        tooltip: tooltip,
        onPressed: onTap,
        style: IconButton.styleFrom(
          backgroundColor: selected ? scheme.primaryContainer : const Color(0xFFF1F5F9),
          foregroundColor: selected ? scheme.primary : scheme.onSurfaceVariant,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        icon: Icon(icon, size: 20),
      ),
    );
  }
}
