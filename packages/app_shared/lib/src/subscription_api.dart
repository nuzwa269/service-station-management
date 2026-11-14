import 'dart:typed_data';

import 'package:station_core/station_core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'api.dart';

class PlanInfo {
  const PlanInfo({required this.code, required this.name, required this.monthly, required this.yearly, required this.features});
  final String code;
  final String name;
  final Money monthly;
  final Money yearly;
  final Set<String> features;
}

class SubPayment {
  const SubPayment({
    required this.id,
    required this.stationId,
    required this.kind,
    required this.plan,
    required this.cycle,
    required this.method,
    required this.amount,
    required this.status,
    required this.createdAt,
    this.reference,
    this.receiptPath,
    this.rejectReason,
    this.periodTo,
    this.receiptNo,
  });

  factory SubPayment.fromRow(Map<String, dynamic> r) => SubPayment(
        id: r['id'] as String,
        stationId: r['station_id'] as String,
        kind: r['kind'] as String,
        plan: r['plan_code'] as String,
        cycle: r['billing_cycle'] as String,
        method: r['method'] as String,
        amount: Money.paisa((r['amount_paisa'] as num).toInt()),
        status: r['status'] as String,
        createdAt: DateTime.parse(r['created_at'] as String),
        reference: r['reference'] as String?,
        receiptPath: r['receipt_path'] as String?,
        rejectReason: r['reject_reason'] as String?,
        periodTo: r['period_to'] == null ? null : DateTime.parse(r['period_to'] as String),
        receiptNo: (r['receipt_no'] as num?)?.toInt(),
      );

  final String id;
  final String stationId;
  final String kind;
  final String plan;
  final String cycle;
  final String method;
  final Money amount;
  final String status;
  final DateTime createdAt;
  final String? reference;
  final String? receiptPath;
  final String? rejectReason;
  final DateTime? periodTo;
  final int? receiptNo;
}

class Tenant {
  const Tenant({
    required this.stationId,
    required this.name,
    required this.city,
    required this.createdAt,
    required this.plan,
    required this.status,
    required this.users,
    required this.jobsThisMonth,
    required this.whatsappConnected,
    required this.pendingPayments,
    required this.supportActive,
    this.trialEndsAt,
    this.renewsAt,
    this.ownerName,
    this.ownerMobile,
    this.deletionDueAt,
  });

  factory Tenant.fromRow(Map<String, dynamic> r) {
    DateTime? d(String k) => r[k] == null ? null : DateTime.parse(r[k] as String);
    return Tenant(
      stationId: r['station_id'] as String,
      name: r['name'] as String,
      city: r['city'] as String? ?? '',
      createdAt: DateTime.parse(r['created_at'] as String),
      plan: r['plan_code'] as String,
      status: parseStationStatus(r['status'] as String),
      trialEndsAt: d('trial_ends_at'),
      renewsAt: d('renews_at'),
      users: r['users'] as int,
      jobsThisMonth: r['jobs_this_month'] as int,
      whatsappConnected: r['whatsapp_connected'] as bool,
      pendingPayments: r['pending_payments'] as int,
      ownerName: r['owner_name'] as String?,
      ownerMobile: r['owner_mobile'] as String?,
      supportActive: r['support_active'] as bool,
      deletionDueAt: d('deletion_due_at'),
    );
  }

  final String stationId;
  final String name;
  final String city;
  final DateTime createdAt;
  final String plan;
  final StationStatus status;
  final DateTime? trialEndsAt;
  final DateTime? renewsAt;
  final int users;
  final int jobsThisMonth;
  final bool whatsappConnected;
  final int pendingPayments;
  final String? ownerName;
  final String? ownerMobile;
  final bool supportActive;
  final DateTime? deletionDueAt;
}

/// Phase 5 calls (TASK-047…052).
extension SubscriptionApi on StationApi {
  Future<List<PlanInfo>> plans() => guard(() async {
        final rows = await client.from('plans').select('code, name, monthly_price_pkr, yearly_price_pkr, plan_features(feature_code)').order('sort_order', ascending: true);
        return [
          for (final r in rows)
            PlanInfo(
              code: r['code'] as String,
              name: r['name'] as String,
              monthly: Money.rupees(r['monthly_price_pkr'] as int),
              yearly: Money.rupees(r['yearly_price_pkr'] as int),
              features: {for (final f in (r['plan_features'] as List).cast<Map<String, dynamic>>()) f['feature_code'] as String},
            ),
        ];
      });

  Future<Map<String, dynamic>> subscriptionQuote(String stationId, String plan, String cycle) => guard(() async =>
      Map<String, dynamic>.from(await client.rpc('station_subscription_quote', params: {'p_station': stationId, 'p_plan': plan, 'p_cycle': cycle}) as Map));

  Future<List<SubPayment>> subscriptionPayments(String stationId) => guard(() async {
        final rows = await client.from('subscription_payments').select().eq('station_id', stationId).order('created_at', ascending: false).limit(50);
        return rows.map(SubPayment.fromRow).toList();
      });

  Future<String> uploadReceipt(String stationId, Uint8List bytes, String extension) => guard(() async {
        if (bytes.length > 5 * 1024 * 1024) throw const AppError(AppErrorCode.validation, 'Receipt must be 5 MB or smaller');
        final ext = extension.toLowerCase();
        final type = ext == 'pdf' ? 'application/pdf' : (ext == 'png' ? 'image/png' : 'image/jpeg');
        final path = '$stationId/receipt-${DateTime.now().millisecondsSinceEpoch}.$ext';
        await client.storage.from('payment-receipts').uploadBinary(path, bytes, fileOptions: FileOptions(contentType: type));
        return path;
      });

  Future<String> receiptUrl(String path) => guard(() async => await client.storage.from('payment-receipts').createSignedUrl(path, 600));

  Future<void> submitManualPayment(String stationId,
          {required String kind, required String plan, required String cycle, required String method, required String reference, String? receiptPath}) =>
      guard(() async => client.rpc('station_submit_manual_payment', params: {
            'p_station': stationId,
            'p_kind': kind,
            'p_plan': plan,
            'p_cycle': cycle,
            'p_method': method,
            'p_reference': reference,
            'p_receipt_path': receiptPath,
          }));

  Future<void> scheduleDowngrade(String stationId, String plan) =>
      guard(() async => client.rpc('station_schedule_downgrade', params: {'p_station': stationId, 'p_plan': plan}));

  Future<void> closeAccount(String stationId, String confirm) =>
      guard(() async => client.rpc('station_close_account', params: {'p_station': stationId, 'p_confirm': confirm}));

  // Super admin
  Future<List<Tenant>> tenants() => guard(() async {
        final rows = await client.rpc('admin_tenants') as List;
        return rows.cast<Map<String, dynamic>>().map(Tenant.fromRow).toList();
      });

  Future<List<Map<String, dynamic>>> deletedTenants() =>
      guard(() async => await client.from('deleted_stations').select().order('deleted_at', ascending: false).limit(50));

  Future<void> verifyPayment(String paymentId, {required bool approve, String? reason}) =>
      guard(() async => client.rpc('admin_verify_payment', params: {'p_payment': paymentId, 'p_approve': approve, 'p_reason': reason}));

  Future<void> extendTrial(String stationId, int days) => guard(() async => client.rpc('admin_extend_trial', params: {'p_station': stationId, 'p_days': days}));

  Future<void> setSuspended(String stationId, bool suspend, String reason) =>
      guard(() async => client.rpc('admin_set_suspended', params: {'p_station': stationId, 'p_suspend': suspend, 'p_reason': reason}));

  Future<void> updatePlan(String code, int monthly, int yearly) =>
      guard(() async => client.rpc('admin_update_plan', params: {'p_code': code, 'p_monthly': monthly, 'p_yearly': yearly}));

  Future<void> openSupportSession(String stationId) => guard(() async => client.rpc('admin_open_support_session', params: {'p_station': stationId}));
}
