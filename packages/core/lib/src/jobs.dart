/// Job card rules shared by the web dashboard and the Staff app (REQ-018…024).
enum JobStage {
  intake('Intake'),
  awaitingApproval('Awaiting approval'),
  approved('Approved'),
  inProgress('In progress'),
  qualityCheck('Quality check'),
  ready('Ready'),
  delivered('Delivered'),
  cancelled('Cancelled');

  const JobStage(this.label);
  final String label;

  /// Database value, e.g. "awaiting_approval".
  String get code => name.replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]!.toLowerCase()}');

  static JobStage parse(String v) => values.firstWhere((s) => s.code == v);

  bool get isOpen => this != delivered && this != cancelled;

  /// Mechanic moves (REQ-021): Approved → In progress → Quality check; QC can be reopened.
  JobStage? get mechanicNext => switch (this) {
        approved => inProgress,
        inProgress => qualityCheck,
        _ => null,
      };
}

enum FuelLevel {
  empty('E', 'E'),
  quarter('Q1', '¼'),
  half('H', '½'),
  threeQuarter('Q3', '¾'),
  full('F', 'F');

  const FuelLevel(this.code, this.label);
  final String code;
  final String label;

  static FuelLevel parse(String v) => values.firstWhere((f) => f.code == v);
}

enum LineKind {
  part('part', 'Part'),
  labour('labour', 'Labour'),
  fee('fee', 'Fee'),
  customerPart('customer_part', 'Customer part');

  const LineKind(this.code, this.label);
  final String code;
  final String label;

  static LineKind parse(String v) => values.firstWhere((k) => k.code == v);
}

enum LineStatus {
  estimate('estimate', 'Estimate'),
  approved('approved', 'Approved'),
  extraPending('extra_pending', 'Awaiting customer approval'),
  rejected('rejected', 'Rejected'),
  removed('removed', 'Removed');

  const LineStatus(this.code, this.label);
  final String code;
  final String label;

  static LineStatus parse(String v) => values.firstWhere((s) => s.code == v);

  /// Lines that count towards the estimate / bill.
  bool get counts => this == estimate || this == approved || this == extraPending;
}

enum CheckStatus {
  notChecked('not_checked', 'Not checked'),
  ok('ok', 'OK'),
  attention('attention', 'Needs attention');

  const CheckStatus(this.code, this.label);
  final String code;
  final String label;

  static CheckStatus parse(String v) => values.firstWhere((s) => s.code == v);
}

/// Total of lines that count, in paisa (qty may have decimals for litres).
int linesTotalPaisa(Iterable<({num qty, int unitPrice, LineStatus status})> lines) =>
    lines.where((l) => l.status.counts).fold(0, (sum, l) => sum + (l.qty * l.unitPrice).round());
