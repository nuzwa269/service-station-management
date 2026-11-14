import 'package:station_core/station_core.dart';

import 'api.dart';

class JobSummary {
  const JobSummary({
    required this.id,
    required this.jobNo,
    required this.kind,
    required this.stage,
    required this.customerName,
    required this.plate,
    required this.createdAt,
    this.vehicleName,
    this.complaints,
    this.mechanics = const [],
  });

  factory JobSummary.fromRow(Map<String, dynamic> r) {
    final c = r['customer'] as Map<String, dynamic>? ?? const {};
    final v = r['vehicle'] as Map<String, dynamic>? ?? const {};
    final assigned = (r['job_assignments'] as List? ?? const []).cast<Map<String, dynamic>>();
    return JobSummary(
      id: r['id'] as String,
      jobNo: r['job_no'] as int,
      kind: r['kind'] as String,
      stage: JobStage.parse(r['stage'] as String),
      customerName: c['name'] as String? ?? '',
      plate: v['plate'] as String? ?? '',
      vehicleName: [v['make'], v['model']].whereType<String>().join(' '),
      complaints: r['complaints'] as String?,
      createdAt: DateTime.parse(r['created_at'] as String),
      mechanics: [for (final a in assigned) ((a['profile'] as Map?)?['full_name'] as String?) ?? ''],
    );
  }

  final String id;
  final int jobNo;
  final String kind;
  final JobStage stage;
  final String customerName;
  final String plate;
  final String? vehicleName;
  final String? complaints;
  final DateTime createdAt;
  final List<String> mechanics;
}

class JobLine {
  const JobLine({
    required this.id,
    required this.kind,
    required this.description,
    required this.qty,
    required this.unitPrice,
    required this.status,
    required this.warrantyDays,
    this.itemId,
  });

  factory JobLine.fromRow(Map<String, dynamic> r) => JobLine(
        id: r['id'] as String,
        kind: LineKind.parse(r['kind'] as String),
        itemId: r['item_id'] as String?,
        description: r['description'] as String,
        qty: r['qty'] as num,
        unitPrice: Money.paisa((r['unit_price_paisa'] as num).toInt()),
        status: LineStatus.parse(r['status'] as String),
        warrantyDays: r['warranty_days'] as int? ?? 0,
      );

  final String id;
  final LineKind kind;
  final String? itemId;
  final String description;
  final num qty;
  final Money unitPrice;
  final LineStatus status;
  final int warrantyDays;

  Money get total => Money.paisa((qty * unitPrice.paisa).round());
}

class CheckItem {
  const CheckItem({required this.id, required this.name, required this.status, this.note});
  factory CheckItem.fromRow(Map<String, dynamic> r) =>
      CheckItem(id: r['id'] as String, name: r['name'] as String, status: CheckStatus.parse(r['status'] as String), note: r['note'] as String?);
  final String id;
  final String name;
  final CheckStatus status;
  final String? note;
}

class JobDetail {
  const JobDetail({
    required this.job,
    required this.customerId,
    required this.customerMobile,
    required this.vehicleId,
    required this.odometerKm,
    required this.fuel,
    required this.checklist,
    required this.lines,
    required this.mechanicIds,
    required this.history,
    this.expectedDelivery,
    this.approvedVia,
    this.approvedByName,
    this.approvedAt,
    this.qcNote,
    this.cancelReason,
    this.parentJobId,
    this.partsFree = false,
  });

  final JobSummary job;
  final String customerId;
  final String customerMobile;
  final String vehicleId;
  final int odometerKm;
  final FuelLevel fuel;
  final DateTime? expectedDelivery;
  final String? approvedVia;
  final String? approvedByName;
  final DateTime? approvedAt;
  final String? qcNote;
  final String? cancelReason;
  final String? parentJobId;
  final bool partsFree;
  final List<CheckItem> checklist;
  final List<JobLine> lines;
  final List<String> mechanicIds;
  final List<Map<String, dynamic>> history;

  Money get total => Money.paisa(linesTotalPaisa(lines.map((l) => (qty: l.qty, unitPrice: l.unitPrice.paisa, status: l.status))));
  bool get hasExtraPending => lines.any((l) => l.status == LineStatus.extraPending);
}

const _summarySelect =
    'id, job_no, kind, stage, complaints, created_at, customer:customers(name), vehicle:vehicles(plate, make, model), '
    'job_assignments(profile:profiles(full_name))';

/// Phase 3 job-card calls (TASK-029…037). All changes go through database functions.
extension JobsApi on StationApi {
  Future<List<JobSummary>> jobs(String stationId, {Set<JobStage>? stages, int limit = 200}) => guard(() async {
        var q = client.from('job_cards').select(_summarySelect).eq('station_id', stationId);
        if (stages != null) q = q.inFilter('stage', stages.map((s) => s.code).toList());
        final rows = await q.order('job_no', ascending: false).limit(limit);
        return rows.map(JobSummary.fromRow).toList();
      });

  Future<Map<JobStage, int>> jobCounts(String stationId) => guard(() async {
        final rows = await client.from('job_cards').select('stage').eq('station_id', stationId).not('stage', 'in', '(delivered,cancelled)');
        final out = <JobStage, int>{};
        for (final r in rows) {
          final s = JobStage.parse(r['stage'] as String);
          out[s] = (out[s] ?? 0) + 1;
        }
        return out;
      });

  Future<JobDetail> job(String jobId) => guard(() async {
        final r = await client
            .from('job_cards')
            .select('*, customer:customers(name, mobile), vehicle:vehicles(plate, make, model), job_assignments(user_id, profile:profiles(full_name))')
            .eq('id', jobId)
            .single();
        final checklist = await client.from('job_checklist_items').select().eq('job_id', jobId).order('sort_order', ascending: true);
        final lines = await client.from('job_lines').select().eq('job_id', jobId).order('created_at', ascending: true);
        final history = await client.from('job_history').select().eq('job_id', jobId).order('created_at', ascending: false).limit(100);
        return JobDetail(
          job: JobSummary.fromRow(r),
          customerId: r['customer_id'] as String,
          customerMobile: (r['customer'] as Map)['mobile'] as String,
          vehicleId: r['vehicle_id'] as String,
          odometerKm: r['odometer_km'] as int,
          fuel: FuelLevel.parse(r['fuel_level'] as String),
          expectedDelivery: r['expected_delivery'] == null ? null : DateTime.parse(r['expected_delivery'] as String),
          approvedVia: r['approved_via'] as String?,
          approvedByName: r['approved_by_name'] as String?,
          approvedAt: r['approved_at'] == null ? null : DateTime.parse(r['approved_at'] as String),
          qcNote: r['qc_note'] as String?,
          cancelReason: r['cancel_reason'] as String?,
          parentJobId: r['parent_job_id'] as String?,
          partsFree: r['parts_free'] as bool? ?? false,
          checklist: checklist.map(CheckItem.fromRow).toList(),
          lines: lines.map(JobLine.fromRow).toList(),
          mechanicIds: [for (final a in (r['job_assignments'] as List).cast<Map<String, dynamic>>()) a['user_id'] as String],
          history: List<Map<String, dynamic>>.from(history),
        );
      });

  Future<String> createJob(String stationId,
          {required String customerId,
          required String vehicleId,
          required int odometer,
          required FuelLevel fuel,
          String? complaints,
          DateTime? expectedDelivery,
          bool confirmOdometer = false}) =>
      guard(() async => await client.rpc('station_create_job', params: {
            'p_station': stationId,
            'p_customer': customerId,
            'p_vehicle': vehicleId,
            'p_odometer': odometer,
            'p_fuel': fuel.code,
            'p_complaints': complaints,
            'p_expected': expectedDelivery?.toUtc().toIso8601String(),
            'p_confirm_odometer': confirmOdometer,
          }) as String);

  Future<void> addLine(String jobId, LineKind kind, {String? itemId, String? description, required num qty, Money? price}) =>
      guard(() async => client.rpc('job_add_line', params: {
            'p_job': jobId,
            'p_kind': kind.code,
            'p_item': itemId,
            'p_description': description,
            'p_qty': qty,
            'p_price_paisa': price?.paisa,
          }));

  Future<void> removeLine(String lineId) => guard(() async => client.rpc('job_remove_line', params: {'p_line': lineId}));

  Future<void> setCheck(String checkId, CheckStatus status, {String? note}) =>
      guard(() async => client.rpc('job_set_check', params: {'p_check': checkId, 'p_status': status.code, 'p_note': note}));

  Future<void> checkToEstimate(String checkId, {String? itemId, String? description, Money? price}) =>
      guard(() async => client.rpc('job_check_to_estimate',
          params: {'p_check': checkId, 'p_item': itemId, 'p_description': description, 'p_price_paisa': price?.paisa}));

  Future<void> sendEstimate(String jobId) => guard(() async => client.rpc('job_send_estimate', params: {'p_job': jobId}));

  Future<void> recordApproval(String jobId, {required bool approve, required String via, required String byName, bool extra = false}) =>
      guard(() async => client.rpc('job_record_approval',
          params: {'p_job': jobId, 'p_approve': approve, 'p_via': via, 'p_by_name': byName, 'p_extra': extra}));

  Future<void> assignMechanics(String jobId, List<String> userIds) =>
      guard(() async => client.rpc('job_assign', params: {'p_job': jobId, 'p_mechanics': userIds}));

  Future<void> setStage(String jobId, JobStage stage, {String? note}) =>
      guard(() async => client.rpc('job_set_stage', params: {'p_job': jobId, 'p_stage': stage.code, 'p_note': note}));

  Future<void> qualityCheck(String jobId, {required bool pass, String? note}) =>
      guard(() async => client.rpc('job_quality_check', params: {'p_job': jobId, 'p_pass': pass, 'p_note': note}));

  Future<void> cancelJob(String jobId, String reason) => guard(() async => client.rpc('job_cancel', params: {'p_job': jobId, 'p_reason': reason}));

  Future<String> createRework(String parentId, {required bool partsFree, required int odometer, required FuelLevel fuel, required String complaints}) =>
      guard(() async => await client.rpc('station_create_rework', params: {
            'p_parent': parentId,
            'p_parts_free': partsFree,
            'p_odometer': odometer,
            'p_fuel': fuel.code,
            'p_complaints': complaints,
          }) as String);

  Future<Map<String, dynamic>> warrantyStatus(String lineId) =>
      guard(() async => await client.rpc('station_warranty_status', params: {'p_line': lineId}) as Map<String, dynamic>);

  Future<String> createWarrantyClaim(String lineId, {required int odometer, required FuelLevel fuel, String? complaints, String? returnSupplierId}) =>
      guard(() async => await client.rpc('station_create_warranty_claim', params: {
            'p_line': lineId,
            'p_odometer': odometer,
            'p_fuel': fuel.code,
            'p_complaints': complaints,
            'p_return_supplier': returnSupplierId,
          }) as String);

  // Settings (REQ-019, REQ-025)
  Future<List<String>> checklistTemplate(String stationId) => guard(() async {
        final rows = await client.from('checklist_templates').select('name').eq('station_id', stationId).eq('active', true).order('sort_order', ascending: true);
        return [for (final r in rows) r['name'] as String];
      });

  Future<void> saveChecklistTemplate(String stationId, List<String> names) =>
      guard(() async => client.rpc('station_save_checklist_template', params: {'p_station': stationId, 'p_names': names}));

  Future<void> setInspectionFee(String stationId, Money fee) =>
      guard(() async => client.rpc('station_set_inspection_fee', params: {'p_station': stationId, 'p_fee_paisa': fee.paisa}));
}
