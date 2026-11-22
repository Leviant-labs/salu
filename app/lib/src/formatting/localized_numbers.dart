import 'package:intl/intl.dart';

/// Parses a user-entered decimal number according to [locale]'s `intl` symbols.
///
/// Validates grouping separators explicitly:
/// - Rejects empty/whitespace-only strings, `NaN`, `Infinity`, and non-numeric
///   garbage.
/// - Allows at most one decimal separator matching the locale's decimal symbol.
/// - Validates that any grouping separators match the locale's group symbol and
///   only appear in valid 3-digit groups in the integer part (rejecting mixed
///   grouping like `1,23.45` or `1.23,45`).
double? parseLocalizedNumber(String input, String locale) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return null;
  final lower = trimmed.toLowerCase();
  if (lower == 'nan' ||
      lower == 'infinity' ||
      lower == '+infinity' ||
      lower == '-infinity' ||
      lower == 'inf' ||
      lower == '+inf' ||
      lower == '-inf') {
    return null;
  }

  final symbols = NumberFormat.decimalPattern(locale).symbols;
  final decimalSep = symbols.DECIMAL_SEP;
  final groupSep = symbols.GROUP_SEP;

  var working = trimmed;
  var sign = 1.0;
  if (working.startsWith('-')) {
    sign = -1.0;
    working = working.substring(1).trimLeft();
  } else if (working.startsWith('+')) {
    working = working.substring(1).trimLeft();
  }
  if (working.isEmpty) return null;

  // Normalize non-breaking spaces / narrow no-break spaces to regular spaces
  // when the locale uses a space-like grouping separator.
  final normalizedGroupSep = _isSpaceLike(groupSep) ? ' ' : groupSep;
  if (_isSpaceLike(groupSep)) {
    working = working.replaceAll('\u00A0', ' ').replaceAll('\u202F', ' ');
  }

  final parts = working.split(decimalSep);
  if (parts.length > 2) return null;

  final intPart = parts[0];
  final fracPart = parts.length == 2 ? parts[1] : null;

  if (fracPart != null) {
    if (fracPart.isEmpty || !_isAsciiDigits(fracPart)) return null;
  }

  String normalizedInt;
  if (intPart.isEmpty) {
    // Allow leading decimal like ".5" or ",5" only if fractional digits exist.
    if (fracPart == null) return null;
    normalizedInt = '0';
  } else if (intPart.contains(normalizedGroupSep)) {
    final groups = intPart.split(normalizedGroupSep);
    if (groups.first.isEmpty ||
        groups.first.length > 3 ||
        !_isAsciiDigits(groups.first)) {
      return null;
    }
    for (var i = 1; i < groups.length; i++) {
      if (groups[i].length != 3 || !_isAsciiDigits(groups[i])) {
        return null;
      }
    }
    normalizedInt = groups.join();
  } else {
    if (!_isAsciiDigits(intPart)) return null;
    normalizedInt = intPart;
  }

  final canonical =
      fracPart != null ? '$normalizedInt.$fracPart' : normalizedInt;
  final parsed = double.tryParse(canonical);
  if (parsed == null || parsed.isNaN || parsed.isInfinite) return null;
  final result = sign * parsed;
  return result == 0 ? 0.0 : result;
}

/// Formats [value] for display using [locale]'s `intl` decimal pattern.
String formatLocalizedNumber(
  num value,
  String locale, {
  int maximumFractionDigits = 2,
}) {
  if (value.isNaN || value.isInfinite) return '';
  final fmt = NumberFormat.decimalPattern(locale)
    ..minimumFractionDigits = 0
    ..maximumFractionDigits = maximumFractionDigits;
  return fmt.format(value);
}

bool _isSpaceLike(String s) => s == ' ' || s == '\u00A0' || s == '\u202F';

bool _isAsciiDigits(String s) {
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c < 0x30 || c > 0x39) return false;
  }
  return true;
}
