import 'dart:convert';

import '../catalogue_install.dart';
import '../repositories/drift_food_repository.dart';
import 'ciqual_import.dart';
import 'insa_bdca_workbook.dart';
import 'open_food_facts_import.dart';
import 'source_import.dart';
import 'usda_fdc_import.dart';

/// The result of normalizing a raw source document into a candidate pack.
///
/// This is an inspection result only: the pack has not been installed,
/// activated, or granted a dataset/licence review. Callers must keep
/// [records] alongside [pack] so per-record diagnostics remain visible in the
/// import review instead of being reduced to a count. [sourceAudit] converts
/// them into the durable form accepted by `CatalogueInstallService.activate`;
/// supplying that audit still requires the confirmation, dataset review and
/// staged validation activation already enforces.
final class SourcePackImport {
  SourcePackImport({
    required this.pack,
    required List<FoodImportResult> records,
    List<FoodImportIssue> issues = const <FoodImportIssue>[],
  })  : records = List<FoodImportResult>.unmodifiable(records),
        issues = List<FoodImportIssue>.unmodifiable(issues);

  /// Candidate catalogue pack. `CatalogueInstallService` may preview it, but
  /// only an explicit activation with a matching `DatasetReview` may install
  /// it.
  final CataloguePack pack;

  /// One normalized result per input record, in document order, including all
  /// normalization issues, unmapped nutrients and retained source details.
  final List<FoodImportResult> records;

  /// Diagnostics about the source document as a whole rather than one record,
  /// such as a component column this build cannot map safely.
  ///
  /// They are shown with the preview and are never a dataset or licence
  /// approval. The durable [sourceAudit] keeps per-record diagnostics only; a
  /// caller must not activate while a document-level issue still needs review.
  final List<FoodImportIssue> issues;
}

extension SourcePackImportAudit on SourcePackImport {
  /// The caller-supplied audit of this import.
  ///
  /// It records the declared source metadata and every record's diagnostics,
  /// source details and SHA-256 snapshot fingerprint. It is asynchronous
  /// because each normalized food is hashed. Passing it to
  /// `CatalogueInstallService.activate` retains that audit with the installed
  /// foods and refuses it if the activated pack's food content differs; it is
  /// not a review and never grants dataset, licence or content approval by
  /// itself.
  Future<CatalogueSourceAudit> get sourceAudit async {
    final auditRecords = <CatalogueSourceRecordAudit>[];
    for (var index = 0; index < records.length; index++) {
      auditRecords.add(CatalogueSourceRecordAudit(
          foodId: records[index].food.id,
          foodFingerprint: await catalogueFoodFingerprint(records[index].food),
          ordinal: index,
          issues: records[index].issues,
          unmappedNutrients: records[index].unmappedNutrients,
          sourceDetails: records[index].sourceDetails));
    }
    return CatalogueSourceAudit(
      dataset: pack.dataset,
      version: pack.version,
      licence: pack.licence,
      attribution: pack.attribution,
      records: auditRecords,
    );
  }
}

/// Normalizes documented raw source documents into a candidate [CataloguePack]
/// and per-record diagnostics.
///
/// [importJson] accepts USDA FoodData Central and Open Food Facts JSON:
/// * A single USDA food object, as returned by `GET /v1/food/{fdcId}`.
/// * An array of USDA food objects, a `{"foods": [...]}` search response, or
///   the official Foundation Foods download's `{"FoundationFoods": [...]}`.
/// * A single Open Food Facts product object or API v2/v3 envelope
///   (`{"product": {...}}`).
/// * An array of Open Food Facts products, or a `{"products": [...]}` search
///   response envelope.
/// * A bare array of either source's food objects.
///
/// [importCiqual] accepts the official ANSES CIQUAL XML documents, as raw bytes
/// so each XML declaration selects UTF-8, Windows-1252 or ISO-8859-1.
///
/// [importInsaWorkbook] accepts the user-supplied official INSA TCA/BDCA
/// 7.1–2026 Excel workbook, after validating its pinned SHA-256 and workbook/
/// sheet identity.
///
/// Dataset version, licence and attribution are caller declarations for the
/// JSON and CIQUAL importers. The INSA importer instead uses the identity and
/// terms stated by the verified workbook. None of these methods verifies a
/// licence, infers an approval, selects a dataset release, or writes to the
/// database. Malformed, empty or mixed-source documents are rejected as a
/// whole: no record is silently omitted.
abstract final class SourcePackImporter {
  /// Largest official INSA workbook accepted, in bytes.
  ///
  /// The 7.1–2026 workbook is well below this bound; the limit keeps a
  /// malformed or substituted upload from consuming unbounded memory before
  /// its identity is checked. [InsaBdcaWorkbookAdapter] enforces its own
  /// ZIP/XML bounds as well.
  static const int maxInsaWorkbookBytes =
      InsaBdcaWorkbookAdapter.maxWorkbookBytes;

  /// Imports the official INSA TCA/BDCA v7.1–2026 Excel workbook.
  ///
  /// [workbookBytes] must be the exact bytes of the user-supplied official
  /// `insa_tca.xlsx` download. [InsaBdcaWorkbookAdapter] validates its SHA-256,
  /// exact workbook/sheet identity and ZIP/XML structure before interpreting a
  /// single record, so a mutable download URL or a different release cannot be
  /// imported silently. Components are read per 100 g of edible portion, and
  /// per 100 ml only where the source states that basis for alcoholic drinks;
  /// a blank cell stays unknown and is never zero, and no density, polyol, free
  /// sugar or allergen value is inferred.
  ///
  /// The pack carries the source's stated terms, not an open licence:
  /// redistribution permission is not documented, the visible attribution
  /// string is mandatory wherever these records are shown, and a dataset or
  /// licence review is still required before any activation. This method only
  /// previews; it never installs, activates or writes to the database.
  ///
  /// Throws [FormatException] for empty or oversized bytes, a hash/version/
  /// sheet mismatch, an unsafe or malformed archive/document, a duplicate food
  /// identifier, or a record that fails repository validation. Every record is
  /// normalized or the whole import fails; no partial pack is returned.
  static Future<SourcePackImport> importInsaWorkbook({
    required List<int> workbookBytes,
  }) async {
    if (workbookBytes.isEmpty) {
      throw const FormatException('INSA workbook is empty');
    }
    if (workbookBytes.length > maxInsaWorkbookBytes) {
      throw FormatException('INSA workbook exceeds the '
          '${maxInsaWorkbookBytes ~/ (1024 * 1024)} MiB limit');
    }
    final adapter =
        await InsaBdcaWorkbookAdapter.fromBytes(workbookBytes: workbookBytes);
    final results = adapter.adaptAll();
    if (results.isEmpty) {
      throw const FormatException('INSA workbook contains no food records');
    }
    _rejectDuplicateFoodIds(results, 'INSA BDCA');
    for (final result in results) {
      try {
        DriftFoodRepository.validateFoods([result.food]);
      } on FormatException catch (error) {
        throw FormatException(
            'INSA BDCA ${result.food.source.datasetId}: ${error.message}');
      }
    }

    final pack = CataloguePack(
        dataset: InsaBdcaWorkbookAdapter.dataset,
        version: InsaBdcaWorkbookAdapter.version,
        licence: InsaBdcaWorkbookAdapter.terms,
        attribution: InsaBdcaWorkbookAdapter.attribution,
        foods: [for (final result in results) result.food]);
    return SourcePackImport(
        pack: pack, records: results, issues: adapter.issues);
  }

  /// Imports [jsonText] and returns the candidate pack with every record's
  /// diagnostics.
  ///
  /// [source] must be [UsdaFdcFoodAdapter.dataset] or
  /// [OpenFoodFactsFoodAdapter.dataset]. [datasetVersion], [licence] and
  /// [attribution] are trimmed and must be non-empty; they are recorded in the
  /// pack and its foods and do not imply review approval.
  ///
  /// Throws [ArgumentError] for an unknown source or blank declared metadata,
  /// and [FormatException] for invalid JSON, an empty document, a malformed
  /// record, a mixed-source document or duplicate food identifiers.
  static SourcePackImport importJson({
    required String source,
    required String jsonText,
    required String datasetVersion,
    required String licence,
    required String attribution,
  }) {
    final dataset = _validateSource(source);
    final version = _requiredMetadata(datasetVersion, 'datasetVersion');
    final licenceId = _requiredMetadata(licence, 'licence');
    final credit = _requiredMetadata(attribution, 'attribution');

    final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on FormatException catch (error) {
      throw FormatException(
          'Source JSON is not valid JSON: ${error.message}',
          error.source,
          error.offset);
    }

    final inputs = _recordsFrom(decoded, dataset);
    final results = <FoodImportResult>[];
    if (dataset == UsdaFdcFoodAdapter.dataset) {
      final adapter = UsdaFdcFoodAdapter(
          datasetVersion: version, licence: licenceId);
      for (final input in inputs) {
        results.add(_adapt(input, adapter.adapt));
      }
    } else {
      final adapter = OpenFoodFactsFoodAdapter(
          datasetVersion: version, licence: licenceId);
      for (final input in inputs) {
        results.add(_adapt(input, adapter.adapt));
      }
    }

    _rejectDuplicateIds(inputs, results);
    for (var index = 0; index < results.length; index++) {
      try {
        DriftFoodRepository.validateFoods([results[index].food]);
      } on FormatException catch (error) {
        throw FormatException('${inputs[index].path}: ${error.message}');
      }
    }

    final pack = CataloguePack(
        dataset: dataset,
        version: version,
        licence: licenceId,
        attribution: credit,
        foods: [for (final result in results) result.food]);
    return SourcePackImport(pack: pack, records: results);
  }

  /// Imports the official ANSES CIQUAL XML documents and returns the candidate
  /// pack with every food's diagnostics.
  ///
  /// [foodsBytes], [constituentsBytes] and [compositionsBytes] are the raw bytes
  /// of the matching `alim_*.xml`, `const_*.xml` and `compo_*.xml` documents;
  /// [foodGroupsBytes] and [sourcesBytes] are the optional `alim_grp_*.xml` and
  /// `sources_*.xml` documents. Each document's XML declaration selects UTF-8,
  /// Windows-1252 or ISO-8859-1, and each is limited to
  /// [CiqualFoodAdapter.maxDocumentBytes].
  ///
  /// [datasetVersion], [licence] and [attribution] are trimmed and must be
  /// non-empty; they are recorded in the pack and its foods and do not imply
  /// review approval. The importer never verifies a licence, selects a dataset
  /// release, installs or activates the pack, or writes to the database.
  ///
  /// Throws [ArgumentError] for blank declared metadata, and [FormatException]
  /// when a document is empty, malformed, oversized, duplicated, references an
  /// unknown food, constituent or source code, or normalizes to a food that
  /// fails repository validation. Every food is normalized or the whole import
  /// fails; no record is silently omitted.
  static SourcePackImport importCiqual({
    required String datasetVersion,
    required String licence,
    required String attribution,
    required List<int> foodsBytes,
    required List<int> constituentsBytes,
    required List<int> compositionsBytes,
    List<int>? foodGroupsBytes,
    List<int>? sourcesBytes,
  }) {
    final version = _requiredMetadata(datasetVersion, 'datasetVersion');
    final licenceId = _requiredMetadata(licence, 'licence');
    final credit = _requiredMetadata(attribution, 'attribution');

    final adapter = CiqualFoodAdapter.fromBytes(
      datasetVersion: version,
      licence: licenceId,
      foods: foodsBytes,
      constituents: constituentsBytes,
      compositions: compositionsBytes,
      foodGroups: foodGroupsBytes,
      sources: sourcesBytes,
    );
    final results = adapter.adaptAll();
    for (final result in results) {
      try {
        DriftFoodRepository.validateFoods([result.food]);
      } on FormatException catch (error) {
        throw FormatException(
            'CIQUAL alim_code ${result.food.source.datasetId}: '
            '${error.message}');
      }
    }

    final pack = CataloguePack(
        dataset: CiqualFoodAdapter.dataset,
        version: version,
        licence: licenceId,
        attribution: credit,
        foods: [for (final result in results) result.food]);
    return SourcePackImport(pack: pack, records: results);
  }

  static FoodImportResult _adapt(
      _SourceRecord input, FoodImportResult Function(Map<String, Object?>) adapt) {
    try {
      return adapt(input.record);
    } on FormatException catch (error) {
      throw FormatException('${input.path}: ${error.message}');
    }
  }

  static String _validateSource(String source) {
    final value = source.trim();
    if (value == UsdaFdcFoodAdapter.dataset ||
        value == OpenFoodFactsFoodAdapter.dataset) {
      return value;
    }
    throw ArgumentError.value(
        source,
        'source',
        'Expected "${UsdaFdcFoodAdapter.dataset}" or '
            '"${OpenFoodFactsFoodAdapter.dataset}"');
  }

  static String _requiredMetadata(String value, String name) {
    final text = value.trim();
    if (text.isEmpty) {
      throw ArgumentError.value(
          value, name, 'Declared source metadata must not be empty');
    }
    return text;
  }

  static List<_SourceRecord> _recordsFrom(Object? decoded, String dataset) {
    if (decoded is List<Object?>) {
      return _listRecords(decoded, dataset, 'document');
    }
    if (decoded is Map<Object?, Object?>) {
      final document = _stringMap(decoded);
      final hasFoods = document.containsKey('foods');
      final hasFoundationFoods = document.containsKey('FoundationFoods');
      final hasProducts = document.containsKey('products');
      if (hasFoods && hasProducts) {
        throw const FormatException(
            'Document mixes "foods" and "products" envelopes');
      }
      if (hasFoundationFoods && (hasFoods || hasProducts)) {
        throw const FormatException('Document mixes source envelopes');
      }
      if (hasFoods) {
        if (dataset != UsdaFdcFoodAdapter.dataset) {
          throw FormatException(
              'Document is a USDA "foods" envelope but source is "$dataset"');
        }
        return _listRecords(
            _requireList(document['foods'], 'foods'), dataset, 'foods');
      }
      if (hasFoundationFoods) {
        if (dataset != UsdaFdcFoodAdapter.dataset) {
          throw FormatException(
              'Document is a USDA "FoundationFoods" envelope but source is "$dataset"');
        }
        return _listRecords(_requireList(document['FoundationFoods'], 'FoundationFoods'),
            dataset, 'FoundationFoods');
      }
      if (hasProducts) {
        if (dataset != OpenFoodFactsFoodAdapter.dataset) {
          throw FormatException(
              'Document is an Open Food Facts "products" envelope but '
              'source is "$dataset"');
        }
        return _listRecords(
            _requireList(document['products'], 'products'), dataset, 'products');
      }
      if (document.isEmpty) {
        throw const FormatException('Document contains no food records');
      }
      return [_singleRecord(document, dataset, 'record 1')];
    }
    throw const FormatException(
        'Source JSON must be a food object or an array of food objects');
  }

  static List<Object?> _requireList(Object? value, String field) {
    if (value is! List<Object?>) {
      throw FormatException('"$field" must be a JSON array of food objects');
    }
    return value;
  }

  static List<_SourceRecord> _listRecords(
      List<Object?> values, String dataset, String field) {
    if (values.isEmpty) {
      throw FormatException('"$field" contains no food records');
    }
    final records = <_SourceRecord>[];
    for (var index = 0; index < values.length; index++) {
      final path = '$field[$index]';
      final value = values[index];
      if (value is! Map<Object?, Object?>) {
        throw FormatException('$path must be a JSON object');
      }
      records.add(_singleRecord(_stringMap(value), dataset, path));
    }
    return records;
  }

  static _SourceRecord _singleRecord(
      Map<String, Object?> record, String dataset, String path) {
    if (record.isEmpty) {
      throw FormatException('$path is an empty object');
    }
    _rejectMixedSource(record, dataset, path);
    return _SourceRecord(record, path);
  }

  /// Rejects an unambiguous record from the other supported source before it is
  /// handed to an adapter, so a mixed document never becomes a partial pack.
  static void _rejectMixedSource(
      Map<String, Object?> record, String dataset, String path) {
    final hasUsdaIdentity = record.containsKey('fdcId') ||
        record.containsKey('foodNutrients') ||
        record.containsKey('labelNutrients');
    final hasOpenFoodFactsIdentity = _hasOpenFoodFactsIdentity(record);
    if (dataset == UsdaFdcFoodAdapter.dataset) {
      if (hasOpenFoodFactsIdentity && !record.containsKey('fdcId')) {
        throw FormatException(
            '$path contains Open Food Facts fields but source is '
            '"${UsdaFdcFoodAdapter.dataset}"');
      }
    } else if (hasUsdaIdentity && !hasOpenFoodFactsIdentity) {
      throw FormatException(
          '$path contains USDA fields but source is '
          '"${OpenFoodFactsFoodAdapter.dataset}"');
    }
  }

  static bool _hasOpenFoodFactsIdentity(Map<String, Object?> record) =>
      record.containsKey('product') ||
      record.containsKey('product_name') ||
      record.containsKey('nutriments') ||
      record.containsKey('allergens_tags');

  static Map<String, Object?> _stringMap(Map<Object?, Object?> value) {
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) {
        throw const FormatException('JSON object keys must be strings');
      }
      result[key] = entry.value;
    }
    return result;
  }

  static void _rejectDuplicateIds(
      List<_SourceRecord> inputs, List<FoodImportResult> results) {
    final paths = <String, String>{};
    for (var index = 0; index < results.length; index++) {
      final id = results[index].food.id;
      final previous = paths[id];
      if (previous != null) {
        throw FormatException(
            '${inputs[index].path} repeats food identifier "$id" from '
            '$previous');
      }
      paths[id] = inputs[index].path;
    }
  }

  static void _rejectDuplicateFoodIds(
      List<FoodImportResult> results, String label) {
    final firstRecords = <String, int>{};
    for (var index = 0; index < results.length; index++) {
      final id = results[index].food.id;
      final first = firstRecords[id];
      if (first != null) {
        throw FormatException(
            '$label record ${index + 1} repeats food identifier "$id" from '
            'record ${first + 1}');
      }
      firstRecords[id] = index;
    }
  }
}

final class _SourceRecord {
  const _SourceRecord(this.record, this.path);

  final Map<String, Object?> record;
  final String path;
}
