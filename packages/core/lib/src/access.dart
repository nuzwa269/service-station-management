/// Roles, plans and role-based menus (REQ-002, REQ-006, PRD §3 matrix).
enum MemberRole {
  owner('Owner'),
  manager('Manager'),
  cashier('Cashier / Service advisor'),
  mechanic('Mechanic');

  const MemberRole(this.label);
  final String label;

  static MemberRole parse(String v) => MemberRole.values.byName(v);
}

enum StationStatus { trial, active, grace, readOnly, suspended, closed }

StationStatus parseStationStatus(String v) => switch (v) {
      'trial' => StationStatus.trial,
      'active' => StationStatus.active,
      'grace' => StationStatus.grace,
      'read_only' => StationStatus.readOnly,
      'suspended' => StationStatus.suspended,
      'closed' => StationStatus.closed,
      _ => throw ArgumentError('unknown status $v'),
    };

/// Feature codes match public.features in the database.
abstract final class Feature {
  static const core = 'core';
  static const supplierLedger = 'supplier_ledger';
  static const booking = 'booking';
  static const whatsappAuto = 'whatsapp_auto';
  static const approvalsInbox = 'approvals_inbox';
  static const auditLogView = 'audit_log_view';
  static const payroll = 'payroll';
  static const profitReports = 'profit_reports';
}

/// Plans that include each feature, for the locked-feature card (REQ-006).
const featurePlans = <String, List<String>>{
  Feature.supplierLedger: ['Standard', 'Premium'],
  Feature.booking: ['Standard', 'Premium'],
  Feature.whatsappAuto: ['Standard', 'Premium'],
  Feature.approvalsInbox: ['Standard', 'Premium'],
  Feature.auditLogView: ['Standard', 'Premium'],
  Feature.payroll: ['Premium'],
  Feature.profitReports: ['Premium'],
};

/// "Available on Standard and Premium".
String lockedFeatureText(String feature) {
  final plans = featurePlans[feature] ?? const ['Premium'];
  return 'Available on ${plans.join(' and ')}';
}

class Entitlements {
  const Entitlements({
    required this.planCode,
    required this.effectivePlan,
    required this.status,
    required this.features,
    this.renewsAt,
  });

  factory Entitlements.fromRow(Map<String, dynamic> row) => Entitlements(
        planCode: row['plan_code'] as String,
        effectivePlan: row['effective_plan'] as String,
        status: parseStationStatus(row['status'] as String),
        features: Set<String>.from(row['features'] as List),
        renewsAt: row['renews_at'] == null ? null : DateTime.parse(row['renews_at'] as String),
      );

  final String planCode;
  final String effectivePlan;
  final StationStatus status;
  final Set<String> features;
  final DateTime? renewsAt;

  bool has(String feature) => features.contains(feature);
  bool get isReadOnly =>
      status == StationStatus.readOnly || status == StationStatus.suspended || status == StationStatus.closed;
}

/// Menu entries of the web dashboard (screen IDs from PRD §9).
enum MenuItem {
  dashboard('SCR-003', 'Dashboard', null),
  bookings('SCR-004', 'Bookings', Feature.booking),
  jobCards('SCR-005', 'Job cards', null),
  customers('SCR-008', 'Customers', null),
  inventory('SCR-009', 'Inventory', null),
  purchases('SCR-010', 'Purchases', null),
  approvals('SCR-012', 'Approvals', Feature.approvalsInbox),
  dayClosing('SCR-013', 'Day closing', null),
  reports('SCR-014', 'Reports', null),
  staff('SCR-015', 'Staff', Feature.payroll),
  users('SCR-017', 'Users', null),
  dataImport('SCR-020', 'Import', null),
  settings('SCR-017', 'Settings', null),
  auditLog('SCR-018', 'Audit log', Feature.auditLogView),
  subscription('SCR-019', 'Subscription', null);

  const MenuItem(this.screenId, this.label, this.feature);
  final String screenId;
  final String label;

  /// Plan feature needed; null = all plans. Items outside the plan still show,
  /// but open a locked card (REQ-006).
  final String? feature;
}

/// Owner/admin tools shown as icon buttons at the top right, so the main
/// tab row stays short. Everything else is a main tab.
const adminItems = {MenuItem.users, MenuItem.dataImport, MenuItem.settings, MenuItem.auditLog, MenuItem.subscription};

/// Which menu items a role sees (PRD §3 permissions matrix).
List<MenuItem> menuFor(MemberRole role) => switch (role) {
      MemberRole.owner => MenuItem.values,
      MemberRole.manager => const [
          MenuItem.dashboard,
          MenuItem.bookings,
          MenuItem.jobCards,
          MenuItem.customers,
          MenuItem.inventory,
          MenuItem.purchases,
          MenuItem.approvals,
          MenuItem.dayClosing,
          MenuItem.reports,
          MenuItem.staff,
          MenuItem.users,
          MenuItem.settings,
        ],
      MemberRole.cashier => const [
          MenuItem.dashboard,
          MenuItem.bookings,
          MenuItem.jobCards,
          MenuItem.customers,
          MenuItem.inventory,
          MenuItem.dayClosing,
        ],
      // Mechanics use the Staff app only (assigned jobs).
      MemberRole.mechanic => const [],
    };
