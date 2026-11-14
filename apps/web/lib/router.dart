import 'dart:async';

import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:station_core/station_core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'screens/approvals_screen.dart';
import 'screens/audit_screen.dart';
import 'screens/auth_screens.dart';
import 'screens/customers_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/day_closing_screen.dart';
import 'screens/import_screen.dart';
import 'screens/inventory_screen.dart';
import 'screens/jobs_screen.dart';
import 'screens/purchases_screen.dart';
import 'screens/shell.dart';
import 'screens/settings_screen.dart';
import 'screens/subscription_screen.dart';
import 'screens/users_screen.dart';

/// Route path for each menu item.
String pathFor(MenuItem m) => '/${m.name}';

class AppRouter {
  AppRouter(this.session) {
    final auth = session.api.client.auth;
    _authSub = auth.onAuthStateChange.listen((s) {
      if (s.event == AuthChangeEvent.signedIn || s.event == AuthChangeEvent.initialSession) {
        if (s.session != null) session.load();
      }
    });
    config = GoRouter(
      initialLocation: '/${MenuItem.dashboard.name}',
      refreshListenable: session,
      redirect: _redirect,
      routes: [
        GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
        GoRoute(path: '/signup', builder: (_, _) => const SignupScreen()),
        GoRoute(path: '/onboarding', builder: (_, _) => const OnboardingScreen()),
        GoRoute(path: '/no-station', builder: (_, _) => const NoStationScreen()),
        GoRoute(
          path: '/admin',
          builder: (_, _) => const Scaffold(body: PlannedScreen(title: 'Super admin — tenants', phase: 'Phase 5 (TASK-051)')),
        ),
        ShellRoute(
          builder: (context, state, child) => StationShell(location: state.uri.path, child: child),
          routes: [
            for (final m in MenuItem.values) GoRoute(path: pathFor(m), builder: (_, _) => screenFor(m)),
          ],
        ),
      ],
    );
  }

  final StationSession session;
  late final GoRouter config;
  late final StreamSubscription<AuthState> _authSub;

  static const _public = {'/login', '/signup'};

  String? _redirect(BuildContext context, GoRouterState state) {
    final loggedIn = session.api.client.auth.currentSession != null;
    final path = state.uri.path;
    if (!loggedIn) return _public.contains(path) ? null : '/login';
    if (path == '/signup') return null; // sign-up continues after the code is verified
    if (session.loading) return null;
    if (session.isSuperAdmin && !session.hasStation) return path == '/admin' ? null : '/admin';
    if (!session.hasStation) return path == '/no-station' ? null : '/no-station';
    if (_public.contains(path) || path == '/no-station') return pathFor(MenuItem.dashboard);
    return null;
  }

  void dispose() {
    _authSub.cancel();
    config.dispose();
  }
}

/// Screen for each menu item. Items from later phases show what is planned.
Widget screenFor(MenuItem m) => switch (m) {
      MenuItem.settings => const SettingsScreen(),
      MenuItem.auditLog => const AuditLogScreen(),
      MenuItem.subscription => const SubscriptionScreen(),
      MenuItem.dashboard => const DashboardHome(),
      MenuItem.users => const UsersScreen(),
      MenuItem.dataImport => const ImportScreen(),
      MenuItem.bookings => const PlannedScreen(title: 'Bookings', phase: 'Phase 6 (TASK-056)'),
      MenuItem.jobCards => const JobCardsScreen(),
      MenuItem.customers => const CustomersScreen(),
      MenuItem.inventory => const InventoryScreen(),
      MenuItem.purchases => const PurchasesScreen(),
      MenuItem.approvals => const ApprovalsScreen(),
      MenuItem.dayClosing => const DayClosingScreen(),
      MenuItem.reports => const PlannedScreen(title: 'Reports', phase: 'Phase 8 (TASK-063)'),
      MenuItem.staff => const PlannedScreen(title: 'Staff & attendance', phase: 'Phase 8 (TASK-065)'),
    };
