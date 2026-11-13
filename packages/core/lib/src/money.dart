/// Money is held as integer paisa (1 rupee = 100 paisa) — never floating point
/// (ARCHITECTURE §5). Invoices show whole rupees (DEC-027).
class Money implements Comparable<Money> {
  const Money.paisa(this.paisa);
  Money.rupees(int rupees) : paisa = rupees * 100;
  static const zero = Money.paisa(0);

  final int paisa;

  Money operator +(Money o) => Money.paisa(paisa + o.paisa);
  Money operator -(Money o) => Money.paisa(paisa - o.paisa);
  Money operator -() => Money.paisa(-paisa);
  bool get isNegative => paisa < 0;
  bool operator <(Money o) => paisa < o.paisa;
  bool operator >(Money o) => paisa > o.paisa;
  bool operator <=(Money o) => paisa <= o.paisa;
  bool operator >=(Money o) => paisa >= o.paisa;

  /// Percentage with half-up rounding to the nearest paisa. [pctTimes100] is the
  /// percentage × 100 (e.g. 17.5% = 1750) so tax rates with 2 decimals stay exact.
  Money percent(int pctTimes100) {
    final raw = paisa * pctTimes100;
    final q = raw ~/ 10000;
    final r = (raw % 10000).abs();
    return Money.paisa(r * 2 >= 10000 ? q + (raw.isNegative ? -1 : 1) : q);
  }

  /// Rounds half-up to whole rupees, as printed on invoices.
  int get wholeRupees {
    final q = paisa ~/ 100;
    final r = (paisa % 100).abs();
    return r >= 50 ? q + (paisa.isNegative ? -1 : 1) : q;
  }

  @override
  int compareTo(Money other) => paisa.compareTo(other.paisa);
  @override
  bool operator ==(Object other) => other is Money && other.paisa == paisa;
  @override
  int get hashCode => paisa.hashCode;
  @override
  String toString() => formatPkr(this);
}

/// "Rs 1,234,567" — Pakistani invoices use Western thousands grouping.
String formatPkr(Money m, {bool showPaisa = false}) {
  final neg = m.isNegative;
  final abs = m.paisa.abs();
  final rupees = showPaisa ? abs ~/ 100 : Money.paisa(abs).wholeRupees;
  final grouped = _group(rupees.toString());
  final paisaPart = showPaisa ? '.${(abs % 100).toString().padLeft(2, '0')}' : '';
  return '${neg ? '-' : ''}Rs $grouped$paisaPart';
}

String _group(String digits) {
  final b = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) b.write(',');
    b.write(digits[i]);
  }
  return b.toString();
}

/// Parses user input like "1,250" or "1250.50" into paisa. Returns null if invalid.
Money? parsePkr(String input) {
  final s = input.replaceAll(RegExp(r'[,\s]|Rs\.?', caseSensitive: false), '');
  final m = RegExp(r'^(-?)(\d+)(?:\.(\d{1,2}))?$').firstMatch(s);
  if (m == null) return null;
  final rupees = int.parse(m[2]!);
  final paisa = int.parse((m[3] ?? '0').padRight(2, '0'));
  final total = rupees * 100 + paisa;
  return Money.paisa(m[1] == '-' ? -total : total);
}
