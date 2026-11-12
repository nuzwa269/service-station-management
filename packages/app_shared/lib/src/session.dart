import 'package:flutter/foundation.dart';
import 'package:station_core/station_core.dart';

import 'api.dart';

/// Who is logged in and which station they are working in.
class StationSession extends ChangeNotifier {
  StationSession(this.api);
  final StationApi api;

  bool loading = false;
  AppError? error;
  bool isSuperAdmin = false;
  List<Membership> memberships = const [];
  Membership? current;
  Entitlements? entitlements;

  bool get hasStation => current != null;
  MemberRole? get role => current?.role;

  Future<void> load() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      isSuperAdmin = await api.isSuperAdmin();
      memberships = await api.myMemberships();
      current = memberships.isEmpty ? null : memberships.first;
      entitlements = current == null ? null : await api.entitlements(current!.stationId);
    } on AppError catch (e) {
      error = e;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> refreshEntitlements() async {
    if (current == null) return;
    entitlements = await api.entitlements(current!.stationId);
    notifyListeners();
  }

  Future<void> signOut() async {
    await api.signOut();
    memberships = const [];
    current = null;
    entitlements = null;
    isSuperAdmin = false;
    notifyListeners();
  }
}
