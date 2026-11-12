import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'router.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initBackend();
  if (!AppConfig.isConfigured) {
    runApp(MaterialApp(theme: appTheme(), home: const MissingConfigScreen()));
    return;
  }
  final session = StationSession(StationApi(Supabase.instance.client));
  runApp(StationWebApp(session: session));
}

class StationWebApp extends StatefulWidget {
  const StationWebApp({super.key, required this.session});
  final StationSession session;

  @override
  State<StationWebApp> createState() => _StationWebAppState();
}

class _StationWebAppState extends State<StationWebApp> {
  late final AppRouter _router = AppRouter(widget.session);

  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SessionScope(
        session: widget.session,
        child: MaterialApp.router(
          title: 'Service Station',
          theme: appTheme(),
          debugShowCheckedModeBanner: false,
          routerConfig: _router.config,
        ),
      );
}

/// Makes the session available to every screen.
class SessionScope extends InheritedNotifier<StationSession> {
  const SessionScope({super.key, required StationSession session, required super.child}) : super(notifier: session);

  static StationSession of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SessionScope>()!.notifier!;
}
