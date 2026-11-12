import 'dart:typed_data';

import 'package:station_core/station_core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class Membership {
  const Membership({
    required this.id,
    required this.stationId,
    required this.stationName,
    required this.stationCode,
    required this.role,
    required this.active,
  });

  factory Membership.fromRow(Map<String, dynamic> r) {
    final s = r['station'] as Map<String, dynamic>? ?? const {};
    return Membership(
      id: r['id'] as String,
      stationId: r['station_id'] as String,
      stationName: s['name'] as String? ?? '',
      stationCode: s['station_code'] as String? ?? '',
      role: MemberRole.parse(r['role'] as String),
      active: r['active'] as bool,
    );
  }

  final String id;
  final String stationId;
  final String stationName;
  final String stationCode;
  final MemberRole role;
  final bool active;
}

class Member {
  const Member({required this.id, required this.userId, required this.name, required this.mobile, required this.role, required this.active});

  factory Member.fromRow(Map<String, dynamic> r) {
    final p = r['profile'] as Map<String, dynamic>? ?? const {};
    return Member(
      id: r['id'] as String,
      userId: r['user_id'] as String,
      name: p['full_name'] as String? ?? '',
      mobile: p['mobile'] as String? ?? '',
      role: MemberRole.parse(r['role'] as String),
      active: r['active'] as bool,
    );
  }

  final String id;
  final String userId;
  final String name;
  final String mobile;
  final MemberRole role;
  final bool active;
}

class AuditEntry {
  const AuditEntry({required this.at, required this.table, required this.action, required this.actor, required this.changes});

  factory AuditEntry.fromRow(Map<String, dynamic> r) => AuditEntry(
        at: DateTime.parse(r['created_at'] as String),
        table: r['table_name'] as String,
        action: r['action'] as String,
        actor: r['actor_id'] as String?,
        changes: Map<String, dynamic>.from(r['changes'] as Map? ?? const {}),
      );

  final DateTime at;
  final String table;
  final String action;
  final String? actor;
  final Map<String, dynamic> changes;
}

/// Thin wrapper over Supabase. All writes go through named database functions;
/// errors come back as [AppError] with readable messages.
class StationApi {
  StationApi(this.client);
  final SupabaseClient client;

  String? get userId => client.auth.currentUser?.id;

  Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on PostgrestException catch (e) {
      throw AppError.fromDatabase(e.message, e.details?.toString());
    } on AuthException catch (e) {
      throw AppError(AppErrorCode.validation, e.message);
    } on FunctionException catch (e) {
      final d = e.details;
      final code = d is Map ? d['error'] as String? : null;
      final msg = d is Map ? d['message'] as String? : null;
      throw AppError(AppErrorCode.fromCode(code), msg);
    } on AppError {
      rethrow;
    } catch (_) {
      throw const AppError(AppErrorCode.network);
    }
  }

  // ---- Auth --------------------------------------------------------------
  Future<void> signInStaff(String mobile, String password) => _guard(() async {
        final m = normalizePkMobile(mobile);
        if (m == null) throw const AppError(AppErrorCode.validation, 'Enter a mobile like 0300-1234567');
        await client.auth.signInWithPassword(phone: toE164(m), password: password);
      });

  /// Station owner sign-up (REQ-001): creates the auth user; an SMS code follows.
  Future<void> signUpOwner(String mobile, String password) => _guard(() async {
        final m = normalizePkMobile(mobile);
        if (m == null) throw const AppError(AppErrorCode.validation, 'Enter a mobile like 0300-1234567');
        if (password.length < 8) throw const AppError(AppErrorCode.validation, 'Password must be at least 8 characters');
        await client.auth.signUp(phone: toE164(m), password: password);
      });

  Future<void> verifySignupCode(String mobile, String code) => _guard(() async {
        await client.auth.verifyOTP(phone: toE164(normalizePkMobile(mobile)!), token: code.trim(), type: OtpType.sms);
      });

  /// Customer login by one-time code (REQ-047).
  Future<void> sendCustomerCode(String mobile) => _guard(() async {
        final m = normalizePkMobile(mobile);
        if (m == null) throw const AppError(AppErrorCode.validation, 'Enter a mobile like 0300-1234567');
        await client.auth.signInWithOtp(phone: toE164(m));
      });

  Future<void> verifyCustomerCode(String mobile, String code) => _guard(() async {
        await client.auth.verifyOTP(phone: toE164(normalizePkMobile(mobile)!), token: code.trim(), type: OtpType.sms);
      });

  Future<void> signOut() => client.auth.signOut();

  // ---- Station context -------------------------------------------------------
  Future<String> createStation({required String stationName, required String city, required String ownerName, String? email}) =>
      _guard(() async => await client.rpc('station_signup', params: {
            'p_station_name': stationName,
            'p_city': city,
            'p_full_name': ownerName,
            'p_email': email,
          }) as String);

  Future<List<Membership>> myMemberships() => _guard(() async {
        final rows = await client
            .from('station_members')
            .select('id, station_id, role, active, station:stations(name, station_code)')
            .eq('user_id', userId!)
            .eq('active', true);
        return rows.map(Membership.fromRow).toList();
      });

  Future<bool> isSuperAdmin() => _guard(() async {
        final row = await client.from('profiles').select('is_super_admin').eq('id', userId!).maybeSingle();
        return row?['is_super_admin'] == true;
      });

  Future<Entitlements> entitlements(String stationId) => _guard(() async {
        final row = await client.from('station_entitlements').select().eq('station_id', stationId).single();
        return Entitlements.fromRow(row);
      });

  Future<Map<String, dynamic>> station(String stationId) =>
      _guard(() async => await client.from('stations').select().eq('id', stationId).single());

  Future<void> updateProfile(String stationId, Map<String, Object?> v) => _guard(() async {
        await client.rpc('station_update_profile', params: {
          'p_station': stationId,
          'p_name': v['name'],
          'p_address': v['address'],
          'p_phone': v['phone'],
          'p_ntn': v['ntn'],
          'p_strn': v['strn'],
          'p_sales_tax_enabled': v['sales_tax_enabled'],
          'p_parts_tax_pct': v['parts_tax_pct'],
          'p_services_tax_pct': v['services_tax_pct'],
          'p_logo_path': v['logo_path'],
        });
      });

  /// Uploads a PNG/JPG logo (max 2 MB, REQ-004) and returns its storage path.
  Future<String> uploadLogo(String stationId, Uint8List bytes, String extension) => _guard(() async {
        if (bytes.length > 2 * 1024 * 1024) throw const AppError(AppErrorCode.validation, 'Logo must be 2 MB or smaller');
        final ext = extension.toLowerCase() == 'png' ? 'png' : 'jpg';
        final path = '$stationId/logo.$ext';
        await client.storage.from('station-logos').uploadBinary(
              path,
              bytes,
              fileOptions: FileOptions(upsert: true, contentType: ext == 'png' ? 'image/png' : 'image/jpeg'),
            );
        return path;
      });

  String logoUrl(String path) => client.storage.from('station-logos').getPublicUrl(path);

  // ---- Users and roles (REQ-002) -------------------------------------------
  Future<List<Member>> members(String stationId) => _guard(() async {
        final rows = await client
            .from('station_members')
            .select('id, user_id, role, active, profile:profiles(full_name, mobile)')
            .eq('station_id', stationId)
            .order('created_at');
        return rows.map(Member.fromRow).toList();
      });

  Future<void> inviteMember(String stationId, {required String name, required String mobile, required MemberRole role, required String password}) =>
      _guard(() async {
        await client.functions.invoke('invite-member', body: {
          'station_id': stationId,
          'full_name': name,
          'mobile': mobile,
          'role': role.name,
          'password': password,
        });
      });

  Future<void> setMemberRole(String memberId, MemberRole role) =>
      _guard(() async => client.rpc('station_set_member_role', params: {'p_member': memberId, 'p_role': role.name}));

  Future<void> setMemberActive(String memberId, bool active) =>
      _guard(() async => client.rpc('station_set_member_active', params: {'p_member': memberId, 'p_active': active}));

  // ---- Support access (REQ-005) and audit log (REQ-058) ----------------------
  Future<List<Map<String, dynamic>>> supportGrants(String stationId) => _guard(() async =>
      await client.from('support_grants').select().eq('station_id', stationId).order('starts_at', ascending: false).limit(10));

  Future<void> grantSupport(String stationId, int hours) =>
      _guard(() async => client.rpc('station_grant_support', params: {'p_station': stationId, 'p_hours': hours}));

  Future<void> revokeSupport(String grantId) =>
      _guard(() async => client.rpc('station_revoke_support', params: {'p_grant': grantId}));

  Future<List<AuditEntry>> auditLog(String stationId, {String? table, int limit = 100}) => _guard(() async {
        var q = client.from('audit_log').select().eq('station_id', stationId);
        if (table != null) q = q.eq('table_name', table);
        final rows = await q.order('created_at', ascending: false).limit(limit);
        return rows.map(AuditEntry.fromRow).toList();
      });
}
