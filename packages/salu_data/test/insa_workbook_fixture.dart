/// Synthetic XLSX fixtures for the INSA workbook adapter tests.
///
/// These builders create only invented, obviously synthetic rows. They do not
/// contain INSA data, grant a licence or represent a real release.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:salu_data/src/import/insa_bdca_workbook.dart';

/// A synthetic workbook container.
final class SyntheticInsaWorkbook {
  SyntheticInsaWorkbook(this.bytes);

  final List<int> bytes;
}

/// One entry in a synthetic ZIP container.
final class SyntheticZipEntry {
  const SyntheticZipEntry(
    this.name,
    this.bytes, {
    this.method = 8,
    this.declaredUncompressedSize,
  });

  final String name;
  final List<int> bytes;
  final int method;
  final int? declaredUncompressedSize;
}

/// Default invented rows used when no rows are supplied.
const List<Map<String, String?>> defaultSyntheticRows =
    <Map<String, String?>>[
  <String, String?>{
    'Cod': '1001',
    'Nome do alimento': 'Synthetic food A',
    'Nível 1': 'Pratos compostos',
    'Nível 2': 'Synthetic group',
    'Nível 3': 'Synthetic subgroup',
    'Energia [kcal]': '100',
    'Energia [kJ]': '418.4',
    'Lípidos [g]': '2',
    'Ácidos gordos saturados [g]': '0.5',
    'Hidratos de carbono [g]': '10',
    'Açúcares [g]': '3',
    'Fibra [g]': '1',
    'Proteínas [g]': '4',
    'Vitamina D [µg]': '0',
    'Vitamina C [mg]': '5',
    'Sódio [mg]': '200',
    'Cálcio [mg]': '30',
    'Ferro [mg]': '1.2',
    'Potássio [mg]': '50',
  },
  <String, String?>{
    'Cod': '2001',
    'Nome do alimento': 'Synthetic beverage B',
    'Nível 1': 'Bebidas alcoólicas',
    'Nível 2': 'Synthetic drinks',
    'Nível 3': 'Synthetic drink',
    'Energia [kcal]': '50',
    'Energia [kJ]': '209.2',
    'Lípidos [g]': '0',
    'Ácidos gordos saturados [g]': '0',
    'Hidratos de carbono [g]': '4',
    'Açúcares [g]': '1',
    'Fibra [g]': '0',
    'Proteínas [g]': '0.2',
    'Sódio [mg]': '5',
    'Cálcio [mg]': '2',
    'Ferro [mg]': '0.1',
    'Iodo [µg]': '2',
  },
];

const String _defaultBasisNote =
    'Valores sintéticos por 100 g de parte edível, com exceção do grupo '
    'Bebidas alcoólicas (nível 1), cujos valores são expressos por 100 ml de '
    'parte edível';

const String _defaultInfoText =
    'Ao descarregar o ficheiro está a concordar com as condições de utilização, '
    'de acordo com a legislação que rege os direitos de autor, devendo constar '
    'de forma visível, no sítio onde os dados da Tabela forem inseridos, a sua '
    'fonte (Ex. - ${InsaBdcaWorkbookAdapter.attribution}). '
    'Atualizado em 03-03-2026';

/// Builds an invented XLSX that passes the adapter's structural identity.
///
/// [rows] maps the exact [InsaBdcaWorkbookAdapter.headers] labels to cell text.
/// Null or empty values are omitted, which the adapter treats as unknown. The
/// data rows are numbered from 3, with the header on row 2.
SyntheticInsaWorkbook buildSyntheticInsaWorkbook({
  String sheetName = InsaBdcaWorkbookAdapter.sheetName,
  String infoText = _defaultInfoText,
  List<Map<String, String?>>? rows,
  List<String>? headers,
  bool deflate = true,
  bool includeBasisNote = true,
  Map<String, String> xmlOverrides = const <String, String>{},
}) {
  final headerLabels = headers ?? InsaBdcaWorkbookAdapter.headers;
  final dataRows = rows ?? defaultSyntheticRows;
  final strings = <String>[];
  final stringIndex = <String, int>{};

  int shared(String value) {
    final existing = stringIndex[value];
    if (existing != null) return existing;
    final index = strings.length;
    strings.add(value);
    stringIndex[value] = index;
    return index;
  }

  final dataSheet = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    ..write('<worksheet xmlns="http://schemas.openxmlformats.org/')
    ..write('spreadsheetml/2006/main"><sheetData>')
    ..write('<row r="1"><c r="C1" t="s"><v>')
    ..write(shared('Synthetic title'))
    ..write('</v></c>');
  if (includeBasisNote) {
    dataSheet
      ..write('<c r="F1" t="s"><v>')
      ..write(shared(_defaultBasisNote))
      ..write('</v></c>');
  }
  dataSheet
    ..write('</row>')
    ..write('<row r="2">');
  for (var index = 0; index < headerLabels.length; index++) {
    dataSheet
      ..write('<c r="${_columnName(index + 1)}2" t="s"><v>')
      ..write(shared(headerLabels[index]))
      ..write('</v></c>');
  }
  dataSheet.write('</row>');
  for (var rowIndex = 0; rowIndex < dataRows.length; rowIndex++) {
    final values = dataRows[rowIndex];
    final rowNumber = rowIndex + 3;
    final cells = <int, String>{};
    for (final entry in values.entries) {
      final column = headerLabels.indexOf(entry.key);
      if (column < 0) continue;
      final value = entry.value;
      if (value == null || value.isEmpty) continue;
      cells[column + 1] = value;
    }
    dataSheet.write('<row r="$rowNumber">');
    final columns = cells.keys.toList()..sort();
    for (final column in columns) {
      final value = cells[column]!;
      final reference = '${_columnName(column)}$rowNumber';
      if (column > 5 && _number.hasMatch(value)) {
        dataSheet.write('<c r="$reference"><v>$value</v></c>');
      } else {
        dataSheet
          ..write('<c r="$reference" t="s"><v>')
          ..write(shared(value))
          ..write('</v></c>');
      }
    }
    dataSheet.write('</row>');
  }
  dataSheet.write('</sheetData></worksheet>');

  final informationSheet = _simpleSheet([shared(infoText)]);
  final componentSheet = _simpleSheet([shared('Componentes')]);

  final sharedStrings = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    ..write('<sst xmlns="http://schemas.openxmlformats.org/')
    ..write('spreadsheetml/2006/main" count="${strings.length}" ')
    ..write('uniqueCount="${strings.length}">');
  for (final value in strings) {
    sharedStrings
      ..write('<si><t xml:space="preserve">')
      ..write(_escapeText(value))
      ..write('</t></si>');
  }
  sharedStrings.write('</sst>');

  final workbook = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    ..write('<workbook xmlns="http://schemas.openxmlformats.org/')
    ..write('spreadsheetml/2006/main" xmlns:r="http://schemas.')
    ..write('openxmlformats.org/officeDocument/2006/relationships">')
    ..write('<sheets>')
    ..write('<sheet name="${_escapeAttribute(sheetName)}" sheetId="1" ')
    ..write('r:id="rId1"/>')
    ..write('<sheet name="Componentes-Correspondência" sheetId="2" ')
    ..write('r:id="rId2"/>')
    ..write('<sheet name="Informação adicional" sheetId="3" r:id="rId3"/>')
    ..write('</sheets></workbook>');

  const relationships = '<?xml version="1.0" encoding="UTF-8" '
      'standalone="yes"?><Relationships xmlns="http://schemas.'
      'openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/'
      'officeDocument/2006/relationships/worksheet" '
      'Target="worksheets/sheet1.xml"/>'
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/'
      'officeDocument/2006/relationships/worksheet" '
      'Target="worksheets/sheet2.xml"/>'
      '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/'
      'officeDocument/2006/relationships/worksheet" '
      'Target="worksheets/sheet3.xml"/>'
      '<Relationship Id="rId4" Type="http://schemas.openxmlformats.org/'
      'officeDocument/2006/relationships/sharedStrings" '
      'Target="sharedStrings.xml"/></Relationships>';

  const contentTypes = '<?xml version="1.0" encoding="UTF-8" '
      'standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/'
      'package/2006/content-types">'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/xl/workbook.xml" ContentType="application/'
      'vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
      '<Override PartName="/xl/sharedStrings.xml" ContentType="application/'
      'vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>'
      '<Override PartName="/xl/worksheets/sheet1.xml" ContentType='
      '"application/vnd.openxmlformats-officedocument.spreadsheetml.'
      'worksheet+xml"/></Types>';

  final files = <String, List<int>>{
    '[Content_Types].xml': utf8.encode(contentTypes),
    'xl/workbook.xml': utf8.encode(workbook.toString()),
    'xl/_rels/workbook.xml.rels': utf8.encode(relationships),
    'xl/sharedStrings.xml': utf8.encode(sharedStrings.toString()),
    'xl/worksheets/sheet1.xml': utf8.encode(dataSheet.toString()),
    'xl/worksheets/sheet2.xml': utf8.encode(componentSheet),
    'xl/worksheets/sheet3.xml': utf8.encode(informationSheet),
  };
  for (final replacement in xmlOverrides.entries) {
    if (!files.containsKey(replacement.key)) continue;
    files[replacement.key] = utf8.encode(replacement.value);
  }

  final entries = <SyntheticZipEntry>[
    for (final file in files.entries) SyntheticZipEntry(file.key, file.value),
  ];
  return SyntheticInsaWorkbook(buildSyntheticZip(entries, deflate: deflate));
}

String _simpleSheet(List<int> values) {
  final buffer = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    ..write('<worksheet xmlns="http://schemas.openxmlformats.org/')
    ..write('spreadsheetml/2006/main"><sheetData><row r="1">');
  for (var index = 0; index < values.length; index++) {
    buffer
      ..write('<c r="${_columnName(index + 1)}1" t="s"><v>')
      ..write(values[index])
      ..write('</v></c>');
  }
  buffer.write('</row></sheetData></worksheet>');
  return buffer.toString();
}

/// Builds a ZIP container with the local and central records aligned.
List<int> buildSyntheticZip(
  List<SyntheticZipEntry> entries, {
  bool deflate = true,
}) {
  final output = BytesBuilder(copy: false);
  final central = BytesBuilder(copy: false);
  var localOffset = 0;

  for (final entry in entries) {
    final nameBytes = utf8.encode(entry.name);
    final method = deflate ? entry.method : 0;
    final compressed = method == 8
        ? ZLibEncoder(raw: true).convert(entry.bytes)
        : entry.bytes;
    final uncompressedSize =
        entry.declaredUncompressedSize ?? entry.bytes.length;
    final crc = _crc32(entry.bytes);

    output.add(_u32(0x04034B50));
    output.add(_u16(20));
    output.add(_u16(0));
    output.add(_u16(method));
    output.add(_u16(0));
    output.add(_u16(0));
    output.add(_u32(crc));
    output.add(_u32(compressed.length));
    output.add(_u32(uncompressedSize));
    output.add(_u16(nameBytes.length));
    output.add(_u16(0));
    output.add(nameBytes);
    output.add(compressed);

    central.add(_u32(0x02014B50));
    central.add(_u16(20));
    central.add(_u16(20));
    central.add(_u16(0));
    central.add(_u16(method));
    central.add(_u16(0));
    central.add(_u16(0));
    central.add(_u32(crc));
    central.add(_u32(compressed.length));
    central.add(_u32(uncompressedSize));
    central.add(_u16(nameBytes.length));
    central.add(_u16(0));
    central.add(_u16(0));
    central.add(_u16(0));
    central.add(_u16(0));
    central.add(_u32(0));
    central.add(_u32(localOffset));
    central.add(nameBytes);

    localOffset += 30 + nameBytes.length + compressed.length;
  }

  final centralBytes = central.takeBytes();
  final centralOffset = localOffset;
  output.add(centralBytes);
  output.add(_u32(0x06054B50));
  output.add(_u16(0));
  output.add(_u16(0));
  output.add(_u16(entries.length));
  output.add(_u16(entries.length));
  output.add(_u32(centralBytes.length));
  output.add(_u32(centralOffset));
  output.add(_u16(0));
  return output.takeBytes();
}

final RegExp _number = RegExp(r'^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$');

String _columnName(int column) {
  final letters = <int>[];
  var value = column;
  while (value > 0) {
    final remainder = (value - 1) % 26;
    letters.add(0x41 + remainder);
    value = (value - 1) ~/ 26;
  }
  return String.fromCharCodes(letters.reversed);
}

String _escapeText(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String _escapeAttribute(String value) => _escapeText(value)
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

List<int> _u16(int value) => <int>[value & 0xFF, (value >> 8) & 0xFF];

List<int> _u32(int value) => <int>[
      value & 0xFF,
      (value >> 8) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 24) & 0xFF,
    ];

final List<int> _crcTable = List<int>.generate(256, (int value) {
  var crc = value;
  for (var bit = 0; bit < 8; bit++) {
    crc = (crc & 1) != 0 ? 0xEDB88320 ^ (crc >> 1) : crc >> 1;
  }
  return crc;
}, growable: false);

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc = _crcTable[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
