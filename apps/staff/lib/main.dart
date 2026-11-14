import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:station_core/station_core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'mechanic/mechanic_screens.dart';
import 'sync/own_sync_engine.dart';
import 'sync/sync_store.dart';

/// Opens the phone's SQLite store and the sync engine for a mechanic.
class MechanicLoader extends StatefulWidget {
  const MechanicLoader({super.key, required this.stationId, required this.stationName, required this.client, required this.onSignOut});
  final String stationId;
  final String stationName;
  final SupabaseClient client;
  final VoidCallback onSignOut;

  @override
  State<MechanicLoader> createState() => _MechanicLoaderState();
}

class _MechanicLoaderState extends State<MechanicLoader> {
  late final Future<OwnSyncEngine> _engine = () async {
    final store = await SqfliteSyncStore.open(name: 'sync_${widget.stationId}.db');
    return OwnSyncEngine(store: store, transport: SupabaseSyncTransport(widget.client, widget.stationId));
  }();

  @override
  Widget build(BuildContext context) => FutureBuilder<OwnSyncEngine>(
        future: _engine,
        builder: (context, snap) => snap.hasData
            ? MechanicHome(engine: snap.data!, stationName: widget.stationName, onSignOut: widget.onSignOut)
            : const Scaffold(body: Center(child: CircularProgressIndicator())),
      );
}

/// Staff app (Android 8+): mechanics' job work (offline from Phase 3) and a
/// quick dashboard for owner / manager / cashier.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initBackend();
  runApp(MaterialApp(
    title: 'Station Staff',
    theme: appTheme(),
    debugShowCheckedModeBanner: false,
    home: AppConfig.isConfigured ? StaffRoot(session: StationSession(StationApi(Supabase.instance.client))) : const MissingConfigScreen(),
  ));
}

class StaffRoot extends StatefulWidget {
  const StaffRoot({super.key, required this.session});
  final StationSession session;

  @override
  State<StaffRoot> createState() => _StaffRootState();
}

class _StaffRootState extends State<StaffRoot> {
  @override
  void initState() {
    super.initState();
    widget.session.api.client.auth.onAuthStateChange.listen((s) {
      if (s.session != null && (s.event == AuthChangeEvent.signedIn || s.event == AuthChangeEvent.initialSession)) {
        widget.session.load();
      }
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.session,
        builder: (context, _) {
          final s = widget.session;
          if (s.api.client.auth.currentSession == null) {
            return Scaffold(
              body: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(child: StaffLoginForm(title: 'Staff log in', onSubmit: s.api.signInStaff)),
                ),
              ),
            );
          }
          if (s.loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
          if (s.current == null || s.entitlements == null) {
            return Scaffold(
              body: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(s.error?.message ?? 'Your account is not active in any station.'),
                  TextButton(onPressed: s.signOut, child: const Text('Log out')),
                ]),
              ),
            );
          }
          if (s.current!.role == MemberRole.mechanic) {
            return MechanicLoader(
              key: ValueKey(s.current!.stationId),
              stationId: s.current!.stationId,
              stationName: s.current!.stationName,
              client: s.api.client,
              onSignOut: s.signOut,
            );
          }
          return StaffHome(
            stationName: s.current!.stationName,
            role: s.current!.role,
            entitlements: s.entitlements!,
            onSignOut: s.signOut,
          );
        },
      );
}

/// SCR-031 (mechanic) or SCR-035 (owner / manager / cashier).
class StaffHome extends StatelessWidget {
  const StaffHome({super.key, required this.stationName, required this.role, required this.entitlements, required this.onSignOut});
  final String stationName;
  final MemberRole role;
  final Entitlements entitlements;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final mechanic = role == MemberRole.mechanic;
    return Scaffold(
      appBar: AppBar(
        title: Text(mechanic ? 'My jobs' : stationName),
        actions: [IconButton(tooltip: 'Log out', onPressed: onSignOut, icon: const Icon(Icons.logout))],
      ),
      body: Column(children: [
        SubscriptionBanner(entitlements: entitlements),
        Expanded(
          child: mechanic
              ? const PlannedScreen(title: 'Assigned jobs (works offline)', phase: 'Phase 3 (TASK-035)')
              : const PlannedScreen(title: 'Quick dashboard & approvals', phase: 'Phase 2 / Phase 8'),
        ),
      ]),
    );
  }
}
