/// Strict adapter for the user-supplied official INSA TCA/BDCA workbook.
///
/// The adapter does **not** bundle an INSA dataset, grant a licence, approve a
/// dataset or decide that Portuguese food data may be redistributed. It accepts
/// the exact user-supplied 7.1–2026 workbook, verifies its pinned SHA-256 and
/// workbook/sheet identity, and returns an in-memory preview. Nothing is
/// installed, activated or written to the database.
///
/// Source: Tabela da Composição de Alimentos / Base de Dados da Composição de
/// Alimentos, Instituto Nacional de Saúde Doutor Ricardo Jorge, I. P. (INSA),
/// version 7.1–2026, <https://portfir.insa.min-saude.pt/pt/>.
///
/// The workbook's own terms state copyright and require the exact attribution
/// in [InsaBdcaWorkbookAdapter.attribution] to be visible wherever its data are
/// shown. They do not document permission to redistribute or bundle the data.
/// [InsaBdcaWorkbookAdapter.terms] records that source statement; it is not an
/// open licence.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:salu_core/salu_core.dart';

import 'insa_xml.dart';
import 'insa_zip.dart';
import 'source_import.dart';

/// Normalizes the official INSA TCA/BDCA 7.1–2026 Excel workbook.
///
/// The workbook is interpreted only after [fromBytes] has verified:
///
/// * the raw byte size and exact SHA-256;
/// * that the container is a single, bounded, non-nested ZIP archive;
/// * the exact workbook sheet names and their worksheet relationships;
/// * the exact 53-column header row;
/// * the version/update/attribution text in the information sheet.
///
/// Values are per 100 g of edible portion, except rows whose FoodEx2 level 1 is
/// exactly `Bebidas alcoólicas`, which the source states per 100 ml. No density
/// is assumed to convert between the two bases.
///
/// All 48 constituent columns of the main sheet are retained as observations.
/// Their identities follow the workbook's own `Componentes-Correspondência`
/// sheet, which names each component and its EuroFIR Component Thesaurus code
/// and INFOODS tagname. Three source definitions are handled explicitly:
///
/// * INSA available carbohydrate excludes fibre but does not document polyol
///   inclusion, so it is retained and is not projected as EU available
///   carbohydrate.
/// * `Vitamina A` is total vitamin A as retinol equivalents (INFOODS `VITA`);
///   the provitamin A carotenoids are kept as separate components, not summed
///   into it a second time.
/// * `Sal` is the source's declared sodium x 2.5 derivative; it is kept as its
///   own constituent and never used to derive sodium.
///
/// Free sugars, polyols, sucrose, lactose and allergens are not published by the
/// 7.1 main sheet and are never inferred. Blank cells become unknown
/// observations, never zero.
final class InsaBdcaWorkbookAdapter {
  InsaBdcaWorkbookAdapter._({
    required this.sourceDigest,
    required List<_InsaRow> rows,
    required List<FoodImportIssue> issues,
  })  : _rows = List<_InsaRow>.unmodifiable(rows),
        _rowByCode = Map<String, _InsaRow>.unmodifiable(
            <String, _InsaRow>{for (final row in rows) row.code: row}),
        _issues = List<FoodImportIssue>.unmodifiable(issues);

  /// Dataset identifier used in [FoodSource.dataset] and local food ids.
  static const String dataset = 'insa-bdca';

  /// Exact dataset revision recorded in [FoodSource.datasetVersion].
  static const String version = '7.1-2026';

  /// Exact main worksheet name of the 7.1–2026 workbook.
  static const String sheetName = 'INSA - BDCA_v 7.1 - 2026';

  /// SHA-256 of the official 7.1–2026 workbook observed while building this
  /// adapter. The download URL itself is mutable and is never trusted.
  static const String workbookSha256 =
      '155d233b6e16e21848d766bb9a13c1965b8c990b6cd8e69e3f39f4df75c066ca';

  /// Exact visible attribution required by the workbook's terms.
  static const String attribution =
      'Fonte: Base de Dados da Composição de Alimentos. Instituto Nacional de '
      'Saúde Doutor Ricardo Jorge, I. P.- INSA. v 7.1 - 2026';

  /// The source's stated terms, not an open licence.
  ///
  /// The workbook requires visible attribution and states copyright; it does
  /// not document permission to redistribute or bundle the data. This string is
  /// the licence value carried by [FoodSource.licence] and `CataloguePack`.
  static const String terms =
      'Copyright INSA; TCA terms require visible attribution; redistribution '
      'review required (permission not documented)';

  /// Maximum accepted workbook size: 8 MiB (the official file is < 1 MiB).
  static const int maxWorkbookBytes = 8 * 1024 * 1024;

  /// Maximum accepted uncompressed size of one XML entry: 32 MiB.
  static const int maxEntryBytes = 32 * 1024 * 1024;

  /// Maximum total declared uncompressed size of the ZIP container: 64 MiB.
  static const int maxTotalUncompressedBytes =
      InsaZipLimits.maxTotalUncompressedBytes;

  /// Maximum number of data rows accepted after the header.
  static const int maxDataRows = 10000;

  /// Maximum shared string count accepted.
  static const int maxSharedStrings = 100000;

  /// Maximum XML element nesting accepted.
  static const int maxXmlDepth = 64;

  /// Exact header labels of the 7.1–2026 main sheet, in column order A..BA.
  static const List<String> headers = <String>[
    'Cod',
    'Nome do alimento',
    'Nível 1',
    'Nível 2',
    'Nível 3',
    'Energia [kcal]',
    'Energia [kJ]',
    'Lípidos [g]',
    'Ácidos gordos saturados [g]',
    'Ácidos gordos monoinsaturados [g]',
    'Ácidos gordos polinsaturados [g]',
    'Ácido linoleico [g]',
    'Ácidos gordos trans [g]',
    'Hidratos de carbono [g]',
    'Açúcares [g]',
    'Oligossacáridos [g]',
    'Amido [g]',
    'Sal [g]',
    'Fibra [g]',
    'Proteínas [g]',
    'Álcool [g]',
    'Água [g]',
    'Ácidos orgânicos [g]',
    'Colesterol [mg]',
    'Vitamina A [µg]',
    'Equivalentes de β-caroteno [µg]',
    'α-caroteno [µg]',
    'β-caroteno, total [µg]',
    'β-criptoxantina [µg]',
    'Licopeno [µg]',
    'Luteína [µg]',
    'Zeaxantina [µg]',
    'Vitamina D [µg]',
    'α-tocoferol [mg]',
    'Tiamina [mg]',
    'Riboflavina [mg]',
    'Niacina [mg]',
    'Equivalentes de niacina [mg]',
    'Triptofano/60 [mg]',
    'Vitamina B6 [mg]',
    'Vitamina B12 [µg]',
    'Vitamina C [mg]',
    'Folatos [µg]',
    'Cinza [g]',
    'Sódio [mg]',
    'Potássio [mg]',
    'Cálcio [mg]',
    'Fósforo [mg]',
    'Magnésio [mg]',
    'Ferro [mg]',
    'Zinco [mg]',
    'Selénio [µg]',
    'Iodo [µg]',
  ];

  /// Actual SHA-256 of the bytes this adapter was built from.
  ///
  /// In production it equals [workbookSha256]. Synthetic tests that intentionally
  /// override that digest retain their own value here for audit.
  final String sourceDigest;

  final List<_InsaRow> _rows;
  final Map<String, _InsaRow> _rowByCode;
  final List<FoodImportIssue> _issues;

  /// Workbook-level diagnostics, safe to read after [adaptAll].
  ///
  /// These explain components this build cannot safely map, the carbohydrate
  /// definition gap, missing free sugars/polyols/allergens and the basis rule.
  /// They are not a licence or dataset review.
  List<FoodImportIssue> get issues => _issues;

  /// Builds an adapter from raw workbook bytes after validating their identity.
  ///
  /// The SHA-256 is always the pinned [workbookSha256]; callers cannot supply a
  /// replacement digest. Synthetic parser tests use [InsaBdcaWorkbookParser],
  /// whose unverified records cannot be mistaken for this production dataset.
  ///
  /// Throws [FormatException] for empty/oversized bytes, a hash mismatch,
  /// malformed or unsafe ZIP/XML, a wrong sheet/version/header identity, an
  /// invalid or duplicate food code, or an unsupported nutrient cell.
  static Future<InsaBdcaWorkbookAdapter> fromBytes({
    required List<int> workbookBytes,
  }) async {
    _validateWorkbookSize(workbookBytes);
    final actual = await _sha256Hex(workbookBytes);
    if (actual != workbookSha256) {
      throw const FormatException(
          'INSA workbook SHA-256 does not match the pinned 7.1-2026 release');
    }
    final parsed = _parseWorkbookBytes(workbookBytes);
    return InsaBdcaWorkbookAdapter._(
      sourceDigest: actual,
      rows: parsed.rows,
      issues: parsed.issues,
    );
  }

  static void _validateWorkbookSize(List<int> workbookBytes) {
    if (workbookBytes.isEmpty) {
      throw const FormatException('INSA workbook is empty');
    }
    if (workbookBytes.length > maxWorkbookBytes) {
      throw FormatException('INSA workbook exceeds the '
          '${maxWorkbookBytes ~/ (1024 * 1024)} MiB limit');
    }
  }

  static _ParsedWorkbook _parseWorkbookBytes(List<int> workbookBytes) {
    final archive = InsaZipArchive.parse(Uint8List.fromList(workbookBytes));
    final sheets =
        _parseWorkbookSheets(_readXml(archive, 'xl/workbook.xml'));
    final relationships = _parseRelationships(
        _readXml(archive, 'xl/_rels/workbook.xml.rels'));

    const expectedSheetNames = <String>{
      sheetName,
      _componentSheetName,
      _informationSheetName,
    };
    final sheetNames = sheets.map((sheet) => sheet.name).toSet();
    if (sheets.length != 3 ||
        sheetNames.length != 3 ||
        !sheetNames.containsAll(expectedSheetNames)) {
      throw const FormatException(
          'INSA workbook sheet/version identity does not match 7.1-2026');
    }

    final dataPath = _sheetPath(
        archive, _sheetNamed(sheets, sheetName), relationships);
    final informationPath = _sheetPath(
        archive, _sheetNamed(sheets, _informationSheetName), relationships);
    final componentPath = _sheetPath(
        archive, _sheetNamed(sheets, _componentSheetName), relationships);

    final sharedRelationships = relationships.values
        .where((relationship) =>
            relationship.type.endsWith('/sharedStrings'))
        .toList(growable: false);
    if (sharedRelationships.length != 1) {
      throw const FormatException(
          'INSA workbook is missing the shared string table');
    }
    final sharedStringsPath = _resolveRelationshipTarget(
        'xl', sharedRelationships.single.target);
    if (!archive.contains(sharedStringsPath)) {
      throw const FormatException(
          'INSA workbook is missing the shared string table');
    }
    if (<String>{dataPath, informationPath, componentPath, sharedStringsPath}
            .length !=
        4) {
      throw const FormatException(
          'INSA workbook sheet/version identity does not match 7.1-2026');
    }

    final sharedStrings =
        _parseSharedStrings(_readXml(archive, sharedStringsPath));

    final information = _parseSheet(
      _readXml(archive, informationPath),
      sharedStrings,
      entry: informationPath,
    );
    _verifyVersionText(_sheetText(information));

    final data = _parseSheet(
      _readXml(archive, dataPath),
      sharedStrings,
      entry: dataPath,
    );
    _verifyHeaders(data);
    _verifyBasisNote(data);
    final rows = _readDataRows(data);

    return _ParsedWorkbook(rows: rows, issues: _documentIssues());
  }

  /// Normalizes every food row in workbook order.
  ///
  /// Throws [FormatException] instead of skipping a row if any record cannot be
  /// represented. The returned list is immutable.
  List<FoodImportResult> adaptAll() => List<FoodImportResult>.unmodifiable(
        _rows.map(_adaptRow),
      );

  /// Normalizes one row by its official `Cod`.
  ///
  /// Throws [ArgumentError] for an unknown code and [FormatException] when the
  /// record cannot be represented.
  FoodImportResult adapt(String code) {
    final row = _rowByCode[code.trim()];
    if (row == null) {
      throw ArgumentError.value(code, 'code', 'Unknown INSA food code');
    }
    return _adaptRow(row);
  }

  FoodImportResult _adaptRow(_InsaRow row) => _adaptInsaRow(
        row,
        dataset: dataset,
        sourceDigest: sourceDigest,
        identityVerified: true,
      );

  static String _readXml(InsaZipArchive archive, String name) {
    final bytes = archive.read(name);
    if (bytes.length > maxEntryBytes) {
      throw FormatException(
          'INSA workbook XML entry "$name" exceeds the '
          '${maxEntryBytes ~/ (1024 * 1024)} MiB limit');
    }
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException catch (error) {
      throw FormatException(
          'INSA workbook XML entry "$name" is not valid UTF-8: '
          '${error.message}');
    }
  }

  static List<_WorkbookSheet> _parseWorkbookSheets(String xml) {
    final sheets = <_WorkbookSheet>[];
    var rootSeen = false;
    var inSheets = false;
    var sheetsDepth = 0;
    InsaXmlReader(xml, entry: 'xl/workbook.xml', maxDepth: maxXmlDepth)
        .read((event) {
      if (event is InsaXmlStart) {
        final local = insaXmlLocalName(event.name);
        if (event.depth == 1) {
          if (rootSeen || local != 'workbook') {
            throw const FormatException(
                'INSA workbook workbook.xml has an unexpected root element');
          }
          rootSeen = true;
        }
        if (local == 'sheets') {
          if (inSheets) {
            throw const FormatException(
                'INSA workbook workbook.xml contains more than one sheets '
                'element');
          }
          inSheets = true;
          sheetsDepth = event.depth;
        } else if (local == 'sheet') {
          if (!inSheets || event.depth != sheetsDepth + 1) {
            throw const FormatException(
                'INSA workbook workbook.xml contains a sheet outside sheets');
          }
          final name = event.attributes['name'];
          final relationshipId = _attributeByLocalName(
              event.attributes, 'id', 'workbook.xml');
          if (name == null ||
              name.isEmpty ||
              relationshipId == null ||
              relationshipId.isEmpty) {
            throw const FormatException(
                'INSA workbook workbook.xml contains an incomplete sheet '
                'declaration');
          }
          sheets.add(_WorkbookSheet(name, relationshipId));
        }
      } else if (event is InsaXmlEnd) {
        if (insaXmlLocalName(event.name) == 'sheets') inSheets = false;
      }
    });
    if (!rootSeen || sheets.isEmpty) {
      throw const FormatException(
          'INSA workbook workbook.xml is missing sheet declarations');
    }
    return List<_WorkbookSheet>.unmodifiable(sheets);
  }

  static Map<String, _Relationship> _parseRelationships(String xml) {
    final relationships = <String, _Relationship>{};
    var rootSeen = false;
    InsaXmlReader(xml,
            entry: 'xl/_rels/workbook.xml.rels', maxDepth: maxXmlDepth)
        .read((event) {
      if (event is! InsaXmlStart) return;
      final local = insaXmlLocalName(event.name);
      if (event.depth == 1) {
        if (rootSeen || local != 'Relationships') {
          throw const FormatException(
              'INSA workbook workbook.xml.rels has an unexpected root element');
        }
        rootSeen = true;
      }
      if (local != 'Relationship') return;
      final id = event.attributes['Id'];
      final type = event.attributes['Type'];
      final target = event.attributes['Target'];
      if (id == null ||
          id.isEmpty ||
          type == null ||
          type.isEmpty ||
          target == null ||
          target.isEmpty) {
        throw const FormatException(
            'INSA workbook workbook.xml.rels contains an incomplete '
            'relationship');
      }
      if (relationships.containsKey(id)) {
        throw FormatException(
            'INSA workbook workbook.xml.rels duplicates relationship "$id"');
      }
      relationships[id] = _Relationship(type, target);
    });
    if (!rootSeen) {
      throw const FormatException(
          'INSA workbook workbook.xml.rels has no Relationships root');
    }
    return Map<String, _Relationship>.unmodifiable(relationships);
  }

  static List<String> _parseSharedStrings(String xml) {
    final values = <String>[];
    var rootSeen = false;
    var inSi = false;
    var phoneticDepth = 0;
    final buffer = StringBuffer();
    InsaXmlReader(xml, entry: 'xl/sharedStrings.xml', maxDepth: maxXmlDepth)
        .read((event) {
      if (event is InsaXmlStart) {
        final local = insaXmlLocalName(event.name);
        if (event.depth == 1) {
          if (rootSeen || local != 'sst') {
            throw const FormatException(
                'INSA workbook sharedStrings.xml has an unexpected root '
                'element');
          }
          rootSeen = true;
        }
        if (local == 'si') {
          if (inSi) {
            throw const FormatException(
                'INSA workbook sharedStrings.xml contains nested si elements');
          }
          inSi = true;
          buffer.clear();
        } else if (inSi && local == 'rPh') {
          phoneticDepth++;
        }
      } else if (event is InsaXmlText) {
        if (inSi && phoneticDepth == 0) {
          if (buffer.length + event.text.length > _maxSharedStringLength) {
            throw const FormatException(
                'INSA workbook shared string exceeds the length limit');
          }
          buffer.write(event.text);
        }
      } else if (event is InsaXmlEnd) {
        final local = insaXmlLocalName(event.name);
        if (local == 'si') {
          if (!inSi) {
            throw const FormatException(
                'INSA workbook sharedStrings.xml closes an si that was not '
                'open');
          }
          values.add(buffer.toString());
          inSi = false;
          if (values.length > maxSharedStrings) {
            throw const FormatException(
                'INSA workbook sharedStrings.xml exceeds the string limit');
          }
        } else if (inSi && local == 'rPh') {
          if (phoneticDepth == 0) {
            throw const FormatException(
                'INSA workbook sharedStrings.xml closes an rPh that was not '
                'open');
          }
          phoneticDepth--;
        }
      }
    });
    if (!rootSeen || inSi || phoneticDepth != 0) {
      throw const FormatException(
          'INSA workbook sharedStrings.xml is incomplete');
    }
    return List<String>.unmodifiable(values);
  }

  static _Sheet _parseSheet(
    String xml,
    List<String> sharedStrings, {
    required String entry,
  }) {
    final rows = <_SheetRow>[];
    var rootSeen = false;
    var sheetDataSeen = false;
    var inSheetData = false;
    var rowNumber = 0;
    Map<int, String>? cells;
    var previousColumn = 0;
    int? cellColumn;
    var cellType = 'n';
    final cellText = StringBuffer();
    var capture = _Capture.none;

    Never fail(String message) => throw FormatException(
        'INSA workbook sheet "$entry" is malformed: $message');

    InsaXmlReader(xml, entry: entry, maxDepth: maxXmlDepth).read((event) {
      if (event is InsaXmlStart) {
        final local = insaXmlLocalName(event.name);
        if (event.depth == 1) {
          if (rootSeen || local != 'worksheet') {
            fail('unexpected root element');
          }
          rootSeen = true;
        }
        if (local == 'sheetData') {
          if (sheetDataSeen) fail('more than one sheetData element');
          sheetDataSeen = true;
          inSheetData = true;
          return;
        }
        if (local == 'row') {
          if (!inSheetData) fail('row outside sheetData');
          if (cells != null) fail('nested row');
          final reference = event.attributes['r'];
          if (reference == null) fail('row without an r attribute');
          final parsed = int.tryParse(reference);
          if (parsed == null || parsed <= 0 || parsed > _maxSheetRows) {
            fail('invalid row number');
          }
          if (rowNumber != 0 && parsed <= rowNumber) {
            fail('row numbers are not increasing');
          }
          rowNumber = parsed;
          cells = <int, String>{};
          previousColumn = 0;
          return;
        }
        if (local == 'c') {
          if (cells == null) fail('cell outside a row');
          if (cellColumn != null) fail('nested cell');
          final reference = event.attributes['r'];
          if (reference == null) fail('cell without an r attribute');
          final match = _cellReference.firstMatch(reference);
          if (match == null) fail('invalid cell reference');
          final column = _columnNumber(match.group(1)!);
          final row = int.parse(match.group(2)!);
          if (row != rowNumber) fail('cell reference is in another row');
          if (column <= previousColumn) {
            fail('cell columns are not increasing');
          }
          if (column > _maxColumns) {
            fail('cell column exceeds the supported range');
          }
          previousColumn = column;
          cellColumn = column;
          cellType = event.attributes['t'] ?? 'n';
          if (!_supportedCellTypes.contains(cellType)) {
            fail('unsupported cell type "$cellType"');
          }
          cellText.clear();
          capture = _Capture.none;
          return;
        }
        if (local == 'v') {
          if (cellColumn == null) fail('value outside a cell');
          capture = _Capture.value;
          return;
        }
        if (local == 'is') {
          if (cellColumn == null) fail('inline text outside a cell');
          capture = _Capture.inline;
          return;
        }
        if (local == 'f') {
          if (cellColumn != null) capture = _Capture.formula;
          return;
        }
        return;
      }

      if (event is InsaXmlText) {
        if (cellColumn != null &&
            (capture == _Capture.value || capture == _Capture.inline)) {
          if (cellText.length + event.text.length > _maxCellText) {
            fail('cell text exceeds the length limit');
          }
          cellText.write(event.text);
        }
        return;
      }

      if (event is! InsaXmlEnd) return;
      final local = insaXmlLocalName(event.name);
      if (local == 'v') {
        if (capture == _Capture.value) capture = _Capture.none;
        return;
      }
      if (local == 'is') {
        if (capture == _Capture.inline) capture = _Capture.none;
        return;
      }
      if (local == 'f') {
        if (capture == _Capture.formula) capture = _Capture.none;
        return;
      }
      if (local == 'c') {
        final rowCells = cells;
        final column = cellColumn;
        if (rowCells == null || column == null) {
          fail('cell end without a cell');
        }
        final value =
            _resolveCellValue(cellType, cellText, sharedStrings, entry);
        if (value.isNotEmpty) rowCells[column] = value;
        cellColumn = null;
        cellType = 'n';
        cellText.clear();
        capture = _Capture.none;
        return;
      }
      if (local == 'row') {
        final rowCells = cells;
        if (rowCells == null) fail('row end without a row');
        rows.add(_SheetRow(rowNumber, rowCells));
        cells = null;
        rowNumber = 0;
        previousColumn = 0;
        return;
      }
      if (local == 'sheetData') {
        inSheetData = false;
        return;
      }
    });

    if (!rootSeen || !sheetDataSeen || cells != null || cellColumn != null) {
      fail('incomplete worksheet structure');
    }
    return _Sheet(rows);
  }

  static String _resolveCellValue(
    String type,
    StringBuffer buffer,
    List<String> sharedStrings,
    String entry,
  ) {
    final raw = buffer.toString();
    switch (type) {
      case 's':
        final text = raw.trim();
        if (text.isEmpty) {
          throw FormatException(
              'INSA workbook sheet "$entry" has an empty shared string index');
        }
        final index = int.tryParse(text);
        if (index == null ||
            index < 0 ||
            index >= sharedStrings.length ||
            '$index' != text) {
          throw FormatException(
              'INSA workbook sheet "$entry" has an invalid shared string '
              'index');
        }
        return sharedStrings[index];
      case 'inlineStr':
      case 'str':
        return raw;
      case 'n':
        return raw.trim();
      default:
        throw FormatException(
            'INSA workbook sheet "$entry" has unsupported cell type "$type"');
    }
  }

  static void _verifyVersionText(String text) {
    final normalized = _normalizeWhitespace(text);
    if (!normalized.contains(attribution) ||
        !normalized.contains('Atualizado em 03-03-2026') ||
        !normalized.contains('v 7.1 - 2026')) {
      throw const FormatException(
          'INSA workbook sheet/version identity does not match 7.1-2026');
    }
  }

  static void _verifyBasisNote(_Sheet sheet) {
    final note = _normalizeWhitespace(sheet.byNumber[1]?.cells[6] ?? '');
    if (!note.contains('100 g de parte edível') ||
        !note.contains('Bebidas alcoólicas') ||
        !note.contains('100 ml de parte edível')) {
      throw const FormatException(
          'INSA workbook sheet/version identity does not match 7.1-2026');
    }
  }

  static void _verifyHeaders(_Sheet sheet) {
    final headerRow = sheet.byNumber[2];
    if (headerRow == null) {
      throw FormatException(
          'INSA workbook sheet "$sheetName" is missing its header row');
    }
    if (headerRow.cells.keys.any((column) => column > headers.length)) {
      throw FormatException(
          'INSA workbook sheet "$sheetName" has unexpected headers');
    }
    for (var column = 1; column <= headers.length; column++) {
      final actual = _normalizeHeader(headerRow.cells[column] ?? '');
      if (actual != _normalizedHeaders[column - 1]) {
        throw FormatException(
            'INSA workbook sheet "$sheetName" has unexpected headers');
      }
    }
  }

  static List<_InsaRow> _readDataRows(_Sheet sheet) {
    for (final row in sheet.rows) {
      if (row.cells.keys.any((column) => column > headers.length)) {
        throw FormatException(
            'INSA workbook row ${row.number} has unexpected columns');
      }
    }
    final rows = <_InsaRow>[];
    var expectedRow = 3;
    for (final row in sheet.rows) {
      if (row.number < 3) continue;
      if (row.number != expectedRow) {
        throw FormatException(
            'INSA workbook row ${row.number} is out of sequence; expected '
            '$expectedRow');
      }
      expectedRow++;
      if (rows.length >= maxDataRows) {
        throw FormatException(
            'INSA workbook has more than $maxDataRows data rows');
      }
      if (row.cells.isEmpty) {
        throw FormatException('INSA workbook row ${row.number} is empty');
      }
      rows.add(_readDataRow(row));
    }
    if (rows.isEmpty) {
      throw const FormatException('INSA workbook contains no food records');
    }
    final codes = <String>{};
    for (final row in rows) {
      if (!codes.add(row.code)) {
        throw FormatException(
            'INSA workbook duplicates food code "${row.code}"');
      }
    }
    return rows;
  }

  static _InsaRow _readDataRow(_SheetRow row) {
    final code = row.cells[1]?.trim() ?? '';
    if (!_foodCode.hasMatch(code)) {
      throw FormatException(
          'INSA workbook row ${row.number} has an invalid food code');
    }
    final name = _cleanOptional(row.cells[2], row.number, 'Nome do alimento');
    if (name == null) {
      throw FormatException(
          'INSA workbook row ${row.number} is missing Nome do alimento');
    }
    final level1 = _cleanOptional(row.cells[3], row.number, 'Nível 1');
    final level2 = _cleanOptional(row.cells[4], row.number, 'Nível 2');
    final level3 = _cleanOptional(row.cells[5], row.number, 'Nível 3');
    final amounts = <int, Exact>{};
    for (final spec in _specs) {
      final raw = row.cells[spec.column];
      if (raw == null || raw.trim().isEmpty) continue;
      amounts[spec.column] = _parseAmount(raw, row.number, spec.header);
    }
    return _InsaRow(
      number: row.number,
      cells: row.cells,
      amounts: Map<int, Exact>.unmodifiable(amounts),
      code: code,
      name: name,
      level1: level1,
      level2: level2,
      level3: level3,
    );
  }

  static String? _cleanOptional(String? raw, int rowNumber, String label) {
    final text = _normalizeWhitespace(raw ?? '');
    if (text.isEmpty) return null;
    if (text.length > _maxTextValueLength) {
      throw FormatException(
          'INSA workbook row $rowNumber has an overlong $label');
    }
    if (_controlCharacters.hasMatch(text)) {
      throw FormatException(
          'INSA workbook row $rowNumber has a control character in $label');
    }
    return text;
  }

  static Exact _parseAmount(String raw, int rowNumber, String header) {
    final text = raw.trim();
    if (text.length > 128 || !_number.hasMatch(text)) {
      throw FormatException(
          'INSA workbook row $rowNumber column "$header" has an unsupported '
          'value');
    }
    final Exact value;
    try {
      value = Exact.parse(text);
    } on FormatException {
      throw FormatException(
          'INSA workbook row $rowNumber column "$header" has an unsupported '
          'value');
    }
    if (value.compareTo(Exact.zero) < 0) {
      throw FormatException(
          'INSA workbook row $rowNumber column "$header" has a negative '
          'amount');
    }
    return value;
  }

  static String _sheetText(_Sheet sheet) {
    final parts = <String>[];
    for (final row in sheet.rows) {
      final columns = row.cells.keys.toList()..sort();
      for (final column in columns) {
        parts.add(row.cells[column]!);
      }
    }
    return _normalizeWhitespace(parts.join(' '));
  }

  static String _normalizeWhitespace(String value) =>
      value.replaceAll(_whitespace, ' ').trim();

  static String _normalizeHeader(String value) =>
      _normalizeWhitespace(value);

  static String _sheetPath(
    InsaZipArchive archive,
    _WorkbookSheet sheet,
    Map<String, _Relationship> relationships,
  ) {
    final relationship = relationships[sheet.relationshipId];
    if (relationship == null) {
      throw FormatException(
          'INSA workbook is missing the relationship for sheet '
          '"${sheet.name}"');
    }
    if (!relationship.type.endsWith('/worksheet')) {
      throw FormatException(
          'INSA workbook sheet "${sheet.name}" has a non-worksheet '
          'relationship');
    }
    final path = _resolveRelationshipTarget('xl', relationship.target);
    if (!archive.contains(path)) {
      throw FormatException(
          'INSA workbook is missing sheet "${sheet.name}"');
    }
    return path;
  }

  static String _resolveRelationshipTarget(String base, String target) {
    var value = target.trim();
    if (value.isEmpty ||
        value.contains(':') ||
        value.contains('\\') ||
        value.contains('?') ||
        value.contains('#')) {
      throw const FormatException(
          'INSA workbook has an unsafe relationship target');
    }
    if (value.startsWith('/')) {
      value = value.substring(1);
    } else {
      value = '$base/$value';
    }
    final segments = <String>[];
    for (final segment in value.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (segments.isEmpty) {
          throw const FormatException(
              'INSA workbook relationship target escapes the archive');
        }
        segments.removeLast();
      } else {
        segments.add(segment);
      }
    }
    if (segments.isEmpty) {
      throw const FormatException(
          'INSA workbook has an unsafe relationship target');
    }
    return segments.join('/');
  }

  static _WorkbookSheet _sheetNamed(
      List<_WorkbookSheet> sheets, String name) {
    for (final sheet in sheets) {
      if (sheet.name == name) return sheet;
    }
    throw const FormatException(
        'INSA workbook sheet/version identity does not match 7.1-2026');
  }

  static String? _attributeByLocalName(
    Map<String, String> attributes,
    String localName,
    String context,
  ) {
    String? found;
    for (final entry in attributes.entries) {
      if (insaXmlLocalName(entry.key) != localName) continue;
      if (found != null) {
        throw FormatException(
            'INSA workbook $context contains duplicate "$localName" '
            'attributes');
      }
      found = entry.value;
    }
    return found;
  }

  static List<FoodImportIssue> _documentIssues() {
    final issues = <FoodImportIssue>[];
    for (final header in headers) {
      if (_metadataHeaders.contains(header) ||
          _mappedHeaders.contains(header)) {
        continue;
      }
      issues.add(FoodImportIssue(
        'unmapped-component',
        'INSA component "$header" has no reviewed mapping in this build; its '
        'values are not copied into Food.',
        field: header,
      ));
    }
    issues
      ..add(const FoodImportIssue(
        'ambiguous-component',
        'INSA available carbohydrate excludes fibre, but polyol inclusion is '
        'not documented; it is retained as an observation and not projected as '
        'EU available carbohydrate.',
        field: 'Hidratos de carbono [g]',
      ))
      ..add(const FoodImportIssue(
        'derived-component',
        'INSA calculates salt as sodium x 2.5 (Regulation (EU) 1169/2011); the '
        'declared salt value is retained as its own constituent and is never '
        'used to derive sodium or vice versa.',
        field: 'Sal [g]',
      ))
      ..add(const FoodImportIssue(
        'definition-note',
        'Vitamina A is total vitamin A as retinol equivalents: retinoids plus '
        'the provitamin A carotenoids, which are also published separately. The '
        'carotenoid columns are distinct components and are never summed into '
        'vitamin A by this build.',
        field: 'Vitamina A [µg]',
      ))
      ..add(const FoodImportIssue(
        'definition-note',
        'Niacina, equivalentes de niacina and triptofano/60 are distinct source '
        'components; equivalentes de niacina already includes niacin and '
        'tryptophan/60, so this build never sums the three.',
        field: 'Niacina [mg]',
      ))
      ..add(const FoodImportIssue(
        'not-provided',
        'INSA 7.1 does not provide free sugars; freeSugarsG stays unknown.',
        field: 'Açúcares livres',
      ))
      ..add(const FoodImportIssue(
        'not-provided',
        'INSA 7.1 does not document polyols separately; no polyol amount is '
        'inferred.',
        field: 'Polióis',
      ))
      ..add(const FoodImportIssue(
        'not-provided',
        'The component correspondence sheet lists sucrose and lactose, but the '
        '7.1 main sheet publishes neither column; no value is inferred.',
        field: 'Sacarose, Lactose',
      ))
      ..add(const FoodImportIssue(
        'not-provided',
        'INSA 7.1 declares no allergens; imported allergen status stays '
        'unknown (null).',
        field: 'Alergénios',
      ))
      ..add(const FoodImportIssue(
        'basis-rule',
        'INSA values are per 100 g edible portion, except rows whose FoodEx2 '
        'level 1 is "Bebidas alcoólicas", which the source states per 100 ml.',
        field: 'base',
      ));
    return List<FoodImportIssue>.unmodifiable(issues);
  }

  static Future<String> _sha256Hex(List<int> bytes) async {
    final digest = await Sha256().hash(bytes);
    return digest.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}

FoodImportResult _adaptInsaRow(
  _InsaRow row, {
  required String dataset,
  required String? sourceDigest,
  required bool identityVerified,
}) {
  final builder = ImportedFoodBuilder(
    dataset: dataset,
    datasetVersion: InsaBdcaWorkbookAdapter.version,
    licence: InsaBdcaWorkbookAdapter.terms,
  );
  final basis = FoodAmount('100', row.basisUnit);
  builder.detail('sourceSheet', InsaBdcaWorkbookAdapter.sheetName);
  builder.detail('sourceRow', row.number);
  builder.detail('identityVerified', identityVerified);
  if (sourceDigest != null) {
    builder.detail('workbookSha256', sourceDigest);
  }
  builder.detail('attribution', InsaBdcaWorkbookAdapter.attribution);
  builder.detail('basis', row.basisLabel);
  builder.detail('foodEx2Level1', row.level1);
  builder.detail('foodEx2Level2', row.level2);
  builder.detail('foodEx2Level3', row.level3);
  builder.detail(
      'allergenStatus', 'unknown; the INSA workbook declares no allergens');
  builder.detail('proteinDefinition', 'N x 6.25');
  builder.detail('carbohydrateDefinition',
      'available carbohydrate excluding fibre; polyol inclusion not documented');
  builder.detail('vitaminADefinition',
      'total vitamin A as retinol equivalents; the provitamin A carotenoids are '
      'separate source components');
  builder.detail('saltDefinition',
      'declared sodium x 2.5 (Regulation (EU) 1169/2011); not used to derive '
      'sodium');

  for (final spec in _specs) {
    final amount = row.amounts[spec.column];
    final added = builder.addObservation(
      key: spec.key,
      amount: amount,
      sourceUnit: spec.unit,
      basis: basis,
      sourceId: row.code,
      origin: '${InsaBdcaWorkbookAdapter.sheetName}!'
          '${_columnLetters(spec.column)}${row.number}',
      definition: spec.definition ?? spec.key.wire,
      qualifier: amount == null
          ? ObservationQualifier.unknown
          : amount == Exact.zero
              ? ObservationQualifier.reportedZero
              : ObservationQualifier.reported,
    );
    if (!added) {
      throw FormatException(
          'INSA workbook row ${row.number} could not retain ${spec.header}');
    }
  }

  if (row.amounts[_carbohydrateSpec.column] != null) {
    builder.issue(
      'ambiguous-definition',
      'INSA available carbohydrate excludes fibre but does not document '
      'polyol inclusion; it is retained as an INSA observation and not '
      'projected as EU available carbohydrate.',
      field: _carbohydrateSpec.header,
    );
  }

  for (final entry in row.cells.entries) {
    if (entry.key <= 5 || _mappedColumns.contains(entry.key)) continue;
    if (entry.value.trim().isEmpty) continue;
    builder.unmapped(InsaBdcaWorkbookAdapter.headers[entry.key - 1]);
  }

  return builder.build(
    id: '$dataset:${row.code}',
    name: row.name,
    sourceId: row.code,
    basisUnit: row.basisUnit,
    basisValue: '100',
  );
}

/// Test-only structural parser for synthetic workbooks.
///
/// This surface deliberately does not verify
/// [InsaBdcaWorkbookAdapter.workbookSha256]. It exists only for tests that need
/// invented rows. Its records use [unverifiedDataset] and are marked
/// `identityVerified: false`, so they cannot be passed to the production INSA
/// importer as trusted 7.1–2026 data.
abstract final class InsaBdcaWorkbookParser {
  /// Dataset id used by [InsaBdcaWorkbookPreview] records.
  static const String unverifiedDataset = 'insa-bdca-unverified';

  /// Parses [workbookBytes] structurally without a hash identity check.
  static InsaBdcaWorkbookPreview parse({required List<int> workbookBytes}) {
    InsaBdcaWorkbookAdapter._validateWorkbookSize(workbookBytes);
    final parsed = InsaBdcaWorkbookAdapter._parseWorkbookBytes(workbookBytes);
    return InsaBdcaWorkbookPreview._(rows: parsed.rows);
  }
}

/// Unverified records produced by [InsaBdcaWorkbookParser] for tests.
final class InsaBdcaWorkbookPreview {
  InsaBdcaWorkbookPreview._({required List<_InsaRow> rows})
      : _rows = List<_InsaRow>.unmodifiable(rows),
        _rowByCode = Map<String, _InsaRow>.unmodifiable(
            <String, _InsaRow>{for (final row in rows) row.code: row}),
        issues = List<FoodImportIssue>.unmodifiable(<FoodImportIssue>[
          const FoodImportIssue(
            'identity-unverified',
            'Structural parser used without the pinned SHA-256; these records '
            'are not trusted INSA 7.1-2026 data.',
            field: 'SHA-256',
          ),
          ...InsaBdcaWorkbookAdapter._documentIssues(),
        ]);

  final List<_InsaRow> _rows;
  final Map<String, _InsaRow> _rowByCode;

  /// Diagnostics, including `identity-unverified`.
  final List<FoodImportIssue> issues;

  /// Normalizes every parsed row with the unverified synthetic dataset id.
  List<FoodImportResult> adaptAll() => List<FoodImportResult>.unmodifiable(
        _rows.map(_previewRow),
      );

  /// Normalizes one unverified row by its official `Cod`.
  FoodImportResult adapt(String code) {
    final row = _rowByCode[code.trim()];
    if (row == null) {
      throw ArgumentError.value(code, 'code', 'Unknown INSA food code');
    }
    return _previewRow(row);
  }

  FoodImportResult _previewRow(_InsaRow row) => _adaptInsaRow(
        row,
        dataset: InsaBdcaWorkbookParser.unverifiedDataset,
        sourceDigest: null,
        identityVerified: false,
      );
}

final class _ParsedWorkbook {
  _ParsedWorkbook({
    required List<_InsaRow> rows,
    required List<FoodImportIssue> issues,
  })  : rows = List<_InsaRow>.unmodifiable(rows),
        issues = List<FoodImportIssue>.unmodifiable(issues);

  final List<_InsaRow> rows;
  final List<FoodImportIssue> issues;
}

final class _WorkbookSheet {
  const _WorkbookSheet(this.name, this.relationshipId);

  final String name;
  final String relationshipId;
}

final class _Relationship {
  const _Relationship(this.type, this.target);

  final String type;
  final String target;
}

final class _Sheet {
  _Sheet(List<_SheetRow> rows)
      : rows = List<_SheetRow>.unmodifiable(rows),
        byNumber = Map<int, _SheetRow>.unmodifiable(
            <int, _SheetRow>{for (final row in rows) row.number: row});

  final List<_SheetRow> rows;
  final Map<int, _SheetRow> byNumber;
}

final class _SheetRow {
  _SheetRow(this.number, Map<int, String> cells)
      : cells = Map<int, String>.unmodifiable(cells);

  final int number;
  final Map<int, String> cells;
}

final class _InsaRow {
  const _InsaRow({
    required this.number,
    required this.cells,
    required this.amounts,
    required this.code,
    required this.name,
    required this.level1,
    required this.level2,
    required this.level3,
  });

  final int number;
  final Map<int, String> cells;
  final Map<int, Exact> amounts;
  final String code;
  final String name;
  final String? level1;
  final String? level2;
  final String? level3;

  bool get isAlcohol => level1 == 'Bebidas alcoólicas';

  FoodUnit get basisUnit => isAlcohol ? FoodUnit.ml : FoodUnit.g;

  String get basisLabel => isAlcohol ? 'per 100 ml' : 'per 100 g edible portion';
}

enum _Capture { none, value, inline, formula }

final class _NutrientSpec {
  const _NutrientSpec({
    required this.column,
    required this.header,
    required this.key,
    this.definition,
  });

  final int column;
  final String header;
  final NutrientKey key;

  /// Source definition when it differs from the key's own wire identity.
  final String? definition;

  String get unit => key.unit;
}

const String _insaAvailableCarbohydrateDefinition =
    'insa_available_carbohydrate_excluding_fibre';

/// Every constituent column of the 7.1–2026 main sheet, mapped from the
/// workbook's own `Componentes-Correspondência` sheet.
///
/// That sheet names each component and its EuroFIR Component Thesaurus code and
/// INFOODS tagname; the comments below record the INFOODS tag the workbook
/// declares for the column. Columns that the sheet lists but the main sheet does
/// not publish (sucrose and lactose) are not invented here.
const List<_NutrientSpec> _specs = <_NutrientSpec>[
  _NutrientSpec(
      column: 6,
      header: 'Energia [kcal]',
      key: NutrientKey.energyKcal,
      definition: NutrientDefinitions.declaredEnergy), // ENERC
  _NutrientSpec(
      column: 7,
      header: 'Energia [kJ]',
      key: NutrientKey.energyKj,
      definition: NutrientDefinitions.declaredEnergy), // ENERC
  _NutrientSpec(
      column: 8, header: 'Lípidos [g]', key: NutrientKey.fatG), // FAT
  _NutrientSpec(
      column: 9,
      header: 'Ácidos gordos saturados [g]',
      key: NutrientKey.saturatedFatG), // FASAT
  _NutrientSpec(
      column: 10,
      header: 'Ácidos gordos monoinsaturados [g]',
      key: NutrientKey.monounsaturatedFatG), // FAMS
  _NutrientSpec(
      column: 11,
      header: 'Ácidos gordos polinsaturados [g]',
      key: NutrientKey.polyunsaturatedFatG), // FAPU
  _NutrientSpec(
      column: 12,
      header: 'Ácido linoleico [g]',
      key: NutrientKey.linoleicAcidG), // F18:2CN6 / F18D2CN6
  _NutrientSpec(
      column: 13,
      header: 'Ácidos gordos trans [g]',
      key: NutrientKey.transFatG), // FATRS / FATRN
  _NutrientSpec(
      column: 14,
      header: 'Hidratos de carbono [g]',
      key: NutrientKey.carbohydrateG,
      definition: _insaAvailableCarbohydrateDefinition), // CHO / CHOAVL
  _NutrientSpec(
      column: 15, header: 'Açúcares [g]', key: NutrientKey.sugarsG), // SUGAR
  _NutrientSpec(
      column: 16,
      header: 'Oligossacáridos [g]',
      key: NutrientKey.oligosaccharidesG), // OLSAC
  _NutrientSpec(
      column: 17, header: 'Amido [g]', key: NutrientKey.starchG), // STARCH
  _NutrientSpec(
      column: 18, header: 'Sal [g]', key: NutrientKey.saltG), // NACL
  _NutrientSpec(
      column: 19, header: 'Fibra [g]', key: NutrientKey.fiberG), // FIBT/FIBTG
  _NutrientSpec(
      column: 20,
      header: 'Proteínas [g]',
      key: NutrientKey.proteinG), // PROT / PROCNT
  _NutrientSpec(
      column: 21, header: 'Álcool [g]', key: NutrientKey.alcoholG), // ALC
  _NutrientSpec(
      column: 22, header: 'Água [g]', key: NutrientKey.waterG), // WATER
  _NutrientSpec(
      column: 23,
      header: 'Ácidos orgânicos [g]',
      key: NutrientKey.organicAcidsG), // OA
  _NutrientSpec(
      column: 24,
      header: 'Colesterol [mg]',
      key: NutrientKey.cholesterolMg), // CHORL / CHOLE
  _NutrientSpec(
      column: 25,
      header: 'Vitamina A [µg]',
      key: NutrientKey.vitaminAUg,
      definition: NutrientDefinitions.retinolEquivalents), // VITA
  _NutrientSpec(
      column: 26,
      header: 'Equivalentes de β-caroteno [µg]',
      key: NutrientKey.betaCaroteneEquivalentUg), // CARTBEQ
  _NutrientSpec(
      column: 27,
      header: 'α-caroteno [µg]',
      key: NutrientKey.alphaCaroteneUg), // CARTA
  _NutrientSpec(
      column: 28,
      header: 'β-caroteno, total [µg]',
      key: NutrientKey.betaCaroteneUg), // CARTBTOT
  _NutrientSpec(
      column: 29,
      header: 'β-criptoxantina [µg]',
      key: NutrientKey.betaCryptoxanthinUg), // CRYPXB
  _NutrientSpec(
      column: 30,
      header: 'Licopeno [µg]',
      key: NutrientKey.lycopeneUg), // LYCPN
  _NutrientSpec(
      column: 31,
      header: 'Luteína [µg]',
      key: NutrientKey.luteinUg), // LUTN
  _NutrientSpec(
      column: 32,
      header: 'Zeaxantina [µg]',
      key: NutrientKey.zeaxanthinUg), // ZEA
  _NutrientSpec(
      column: 33,
      header: 'Vitamina D [µg]',
      key: NutrientKey.vitaminDUg), // VITD
  _NutrientSpec(
      column: 34,
      header: 'α-tocoferol [mg]',
      key: NutrientKey.vitaminEMg), // TOCPHA
  _NutrientSpec(
      column: 35, header: 'Tiamina [mg]', key: NutrientKey.thiaminMg), // THIA
  _NutrientSpec(
      column: 36,
      header: 'Riboflavina [mg]',
      key: NutrientKey.riboflavinMg), // RIBF
  _NutrientSpec(
      column: 37, header: 'Niacina [mg]', key: NutrientKey.niacinMg), // NIA
  _NutrientSpec(
      column: 38,
      header: 'Equivalentes de niacina [mg]',
      key: NutrientKey.niacinEquivalentMg), // NIAEQ
  _NutrientSpec(
      column: 39,
      header: 'Triptofano/60 [mg]',
      key: NutrientKey.tryptophan60Mg), // NIATRP
  _NutrientSpec(
      column: 40,
      header: 'Vitamina B6 [mg]',
      key: NutrientKey.vitaminB6Mg), // VITB6 / VITB6A
  _NutrientSpec(
      column: 41,
      header: 'Vitamina B12 [µg]',
      key: NutrientKey.vitaminB12Ug), // VITB12
  _NutrientSpec(
      column: 42,
      header: 'Vitamina C [mg]',
      key: NutrientKey.vitaminCMg), // VITC
  _NutrientSpec(
      column: 43, header: 'Folatos [µg]', key: NutrientKey.folateUg), // FOL
  _NutrientSpec(
      column: 44, header: 'Cinza [g]', key: NutrientKey.ashG), // ASH
  _NutrientSpec(
      column: 45, header: 'Sódio [mg]', key: NutrientKey.sodiumMg), // NA
  _NutrientSpec(
      column: 46,
      header: 'Potássio [mg]',
      key: NutrientKey.potassiumMg), // K
  _NutrientSpec(
      column: 47, header: 'Cálcio [mg]', key: NutrientKey.calciumMg), // CA
  _NutrientSpec(
      column: 48,
      header: 'Fósforo [mg]',
      key: NutrientKey.phosphorusMg), // P
  _NutrientSpec(
      column: 49,
      header: 'Magnésio [mg]',
      key: NutrientKey.magnesiumMg), // MG
  _NutrientSpec(
      column: 50, header: 'Ferro [mg]', key: NutrientKey.ironMg), // FE
  _NutrientSpec(
      column: 51, header: 'Zinco [mg]', key: NutrientKey.zincMg), // ZN
  _NutrientSpec(
      column: 52,
      header: 'Selénio [µg]',
      key: NutrientKey.seleniumUg), // SE
  _NutrientSpec(
      column: 53, header: 'Iodo [µg]', key: NutrientKey.iodineUg), // ID
];

const _NutrientSpec _carbohydrateSpec = _NutrientSpec(
  column: 14,
  header: 'Hidratos de carbono [g]',
  key: NutrientKey.carbohydrateG,
  definition: _insaAvailableCarbohydrateDefinition,
);

const String _componentSheetName = 'Componentes-Correspondência';
const String _informationSheetName = 'Informação adicional';

const Set<String> _metadataHeaders = <String>{
  'Cod',
  'Nome do alimento',
  'Nível 1',
  'Nível 2',
  'Nível 3',
};

final Set<int> _mappedColumns =
    Set<int>.unmodifiable(<int>{for (final spec in _specs) spec.column});

final Set<String> _mappedHeaders =
    Set<String>.unmodifiable(<String>{for (final spec in _specs) spec.header});

final List<String> _normalizedHeaders = List<String>.unmodifiable(
    InsaBdcaWorkbookAdapter.headers
        .map(InsaBdcaWorkbookAdapter._normalizeHeader));

final RegExp _whitespace = RegExp(r'[\s\u00A0]+');
final RegExp _foodCode = RegExp(r'^[0-9]{1,18}$');
final RegExp _number = RegExp(r'^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$');
final RegExp _cellReference = RegExp(r'^([A-Z]{1,3})([1-9][0-9]{0,6})$');
final RegExp _controlCharacters =
    RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F]');

const Set<String> _supportedCellTypes = <String>{'n', 's', 'str', 'inlineStr'};
const int _maxColumns = 64;
const int _maxSheetRows = 20000;
const int _maxCellText = 4096;
const int _maxSharedStringLength = 32767;
const int _maxTextValueLength = 512;

int _columnNumber(String letters) {
  var value = 0;
  for (final code in letters.codeUnits) {
    value = value * 26 + (code - 0x40);
  }
  return value;
}

String _columnLetters(int column) {
  final letters = <int>[];
  var value = column;
  while (value > 0) {
    final remainder = (value - 1) % 26;
    letters.add(0x41 + remainder);
    value = (value - 1) ~/ 26;
  }
  return String.fromCharCodes(letters.reversed);
}
