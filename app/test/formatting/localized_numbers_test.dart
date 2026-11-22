import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/formatting/localized_numbers.dart';
import 'package:salu/src/l10n/l10n_helper.dart';

void main() {
  group('parseLocalizedNumber', () {
    test('parses pt_PT comma decimals and en dot decimals', () {
      expect(parseLocalizedNumber('75,5', 'pt_PT'), 75.5);
      expect(parseLocalizedNumber('75.5', 'en'), 75.5);
      expect(parseLocalizedNumber('  75,5  ', 'pt_PT'), 75.5);
      expect(parseLocalizedNumber('  75.5  ', 'en'), 75.5);
      expect(parseLocalizedNumber('-12,25', 'pt_PT'), -12.25);
    });

    test('validates locale grouping separators and rejects mixed grouping', () {
      expect(parseLocalizedNumber('1,234.56', 'en'), 1234.56);
      expect(parseLocalizedNumber('1 234,56', 'pt_PT'), 1234.56);
      expect(parseLocalizedNumber('1\u00A0234,56', 'pt_PT'), 1234.56);

      // Invalid mixed or malformed grouping
      expect(parseLocalizedNumber('1,23.45', 'en'), isNull);
      expect(parseLocalizedNumber('1.23,45', 'pt_PT'), isNull);
      expect(parseLocalizedNumber('1,23,456', 'en'), isNull);
      expect(parseLocalizedNumber('75.5', 'pt_PT'), isNull);
      expect(parseLocalizedNumber('75,5', 'en'), isNull);
    });

    test('rejects NaN, Infinity, and empty input', () {
      expect(parseLocalizedNumber('', 'en'), isNull);
      expect(parseLocalizedNumber('   ', 'pt_PT'), isNull);
      expect(parseLocalizedNumber('NaN', 'en'), isNull);
      expect(parseLocalizedNumber('Infinity', 'en'), isNull);
      expect(parseLocalizedNumber('-Infinity', 'pt_PT'), isNull);
      expect(parseLocalizedNumber('abc', 'en'), isNull);
    });

    test('round-trips formatted numbers cleanly', () {
      final pt = formatLocalizedNumber(1234.5, 'pt_PT');
      expect(parseLocalizedNumber(pt, 'pt_PT'), 1234.5);

      final en = formatLocalizedNumber(1234.5, 'en');
      expect(parseLocalizedNumber(en, 'en'), 1234.5);
    });
  });

  group('localizedProviderName', () {
    test('returns safe display names and strips URLs or secrets', () {
      expect(localizedProviderName('OpenAI'), 'OpenAI');
      expect(localizedProviderName('  Anthropic  '), 'Anthropic');
      expect(localizedProviderName('https://api.example.com?key=123'), '');
      expect(localizedProviderName('Bearer sk-secret'), '');
      expect(localizedProviderName(null), '');
    });
  });
}
