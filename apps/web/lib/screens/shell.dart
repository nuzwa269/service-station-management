import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:station_core/station_core.dart';

import '../main.dart';

const _icons = <MenuItem, IconData>{
  MenuItem.dashboard: Icons.dashboard_outlined,
  MenuItem.bookings: Icons.event_outlined,
  MenuItem.jobCards: Icons.assignment_outlined,
  MenuItem.customers: Icons.people_outline,
  MenuItem.inventory: Icons.inventory_2_outlined,
  MenuItem.purchases: Icons.local_shipping_outlined,
  MenuItem.approvals: Icons.fact_check_outlined,
  MenuItem.dayClosing: Icons.point_of_sale_outlined,
  MenuItem.reports: Icons.bar_chart_outlined,
  MenuItem.staff: Icons.badge_outlined,
  MenuItem.settings: Icons.settings_outlined,
  MenuItem.auditLog: Icons.history_outlined,
  MenuItem.subscription: Icons.receipt_long_outlined,
};

/// Role-based navigation (REQ-002) with plan gating (REQ-006) and the
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

/// Pure view, testable without a backend.
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
    final current = items.where((m) => location == '/${m.name}').firstOrNull;
    final locked = current?.feature != null && !entitlements.has(current!.feature!);
    final allowed = current != null ||
        (location == '/users' && (role == MemberRole.owner || role == MemberRole.manager)) ||
        (location == '/import' && role == MemberRole.owner);
    final wide = MediaQuery.sizeOf(context).width >= 900;

    final body = Column(children: [
      SubscriptionBanner(entitlements: entitlements),
      Expanded(
        child: !allowed
            ? const ErrorStateView(message: 'You do not have access to this page.')
            : locked
                ? LockedFeatureCard(
                    feature: current.feature!,
                    title: current.label,
                    onUpgrade: role == MemberRole.owner ? () => onNavigate('/${MenuItem.subscription.name}') : null,
                  )
                : child,
      ),
    ]);

    final menu = ListView(children: [
      for (final m in items)
        ListTile(
          key: Key('menu-${m.name}'),
          leading: Icon(_icons[m]),
          title: Text(m.label),
          trailing: m.feature != null && !entitlements.has(m.feature!) ? const Icon(Icons.lock_outline, size: 16) : null,
          selected: m == current,
          onTap: () => onNavigate('/${m.name}'),
        ),
    ]);

    final appBar = AppBar(
      title: Text(stationName),
      actions: [
        Center(child: Text(role.label)),
        IconButton(tooltip: 'Log out', icon: const Icon(Icons.logout), onPressed: onSignOut),
      ],
    );

    if (wide) {
      return Scaffold(
        appBar: appBar,
        body: Row(children: [
          SizedBox(width: 250, child: Material(elevation: 1, child: menu)),
          Expanded(child: body),
        ]),
      );
    }
    return Scaffold(appBar: appBar, drawer: Drawer(child: SafeArea(child: menu)), body: body);
  }
}
