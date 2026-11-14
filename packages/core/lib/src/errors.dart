/// Error codes raised by the database functions (private.fail) and Edge Functions,
/// mapped to readable English messages (UI language is English at launch).
enum AppErrorCode {
  unauthenticated('UNAUTHENTICATED', 'Please log in again.'),
  forbidden('FORBIDDEN', 'You do not have permission for this action.'),
  notFound('NOT_FOUND', 'Record not found.'),
  validation('VALIDATION', 'Please check the entered details.'),
  readOnly('READ_ONLY', 'Subscription expired — read-only. Ask the owner to renew.'),
  featureLocked('FEATURE_LOCKED', 'This feature is not included in your plan.'),
  stationSuspended('STATION_SUSPENDED', 'This station account is suspended. Contact support.'),
  phoneNotVerified('PHONE_NOT_VERIFIED', 'Please verify your mobile number first.'),
  alreadyRegistered('ALREADY_REGISTERED', 'This mobile number is already registered with a station.'),
  mobileInUse('MOBILE_IN_USE', 'This mobile number is already in use.'),
  hasOpenJobs('HAS_OPEN_JOBS', 'Reassign this user\'s open jobs first.'),
  auditImmutable('AUDIT_IMMUTABLE', 'Audit entries cannot be changed.'),
  appendOnly('APPEND_ONLY', 'Saved entries cannot be changed. Reverse them with a reason.'),
  ownerOnly('OWNER_ONLY', 'On the Basic plan only the owner can do this. Ask the owner to log in.'),
  odometerLower('ODOMETER_LOWER', 'Odometer is lower than the last visit — confirm?'),
  warrantyExpired('WARRANTY_EXPIRED', 'Warranty has expired.'),
  network('NETWORK', 'No internet connection. Please try again.'),
  unknown('UNKNOWN', 'Something went wrong. Please try again.');

  const AppErrorCode(this.code, this.defaultMessage);
  final String code;
  final String defaultMessage;

  static AppErrorCode fromCode(String? code) =>
      values.firstWhere((e) => e.code == code, orElse: () => AppErrorCode.unknown);
}

class AppError implements Exception {
  const AppError(this.code, [this.detail]);

  /// Builds from a Postgres error: message = code, details = readable text.
  factory AppError.fromDatabase(String? message, String? details) {
    final code = AppErrorCode.fromCode(message);
    final useDetail = details != null && details.isNotEmpty && details != message;
    return AppError(code, useDetail ? details : null);
  }

  final AppErrorCode code;
  final String? detail;

  /// Validation details are written for users; other codes use the fixed message.
  String get message => (code == AppErrorCode.validation ||
              code == AppErrorCode.readOnly ||
              code == AppErrorCode.notFound ||
              code == AppErrorCode.forbidden ||
              code == AppErrorCode.odometerLower ||
              code == AppErrorCode.warrantyExpired) &&
          detail != null
      ? detail!
      : code.defaultMessage;

  @override
  String toString() => 'AppError(${code.code}${detail == null ? '' : ': $detail'})';
}
