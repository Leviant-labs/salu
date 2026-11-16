import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart' show Value, Variable;
import 'package:salu_core/salu_core.dart';
import 'database/app_database.dart';
import 'import/insa_bdca_workbook.dart';
import 'import/source_import.dart';
import 'repositories/drift_food_repository.dart';
import 'snapshot_codec.dart';

/// Normalized, versioned pack. Raw source adapters must retain nutrient definitions
/// in the food observations before constructing this pack. No inference is used.
final class CataloguePack {
  CataloguePack(
      {required this.dataset,
      required this.version,
      required this.licence,
      required this.attribution,
      required List<Food> foods})
      : foods = List.unmodifiable(foods) {
    if ([dataset, version, licence, attribution].any((v) => v.trim().isEmpty) ||
        foods.isEmpty) {
      throw const FormatException('Incomplete catalogue manifest');
    }
    if (dataset.startsWith('custom') || dataset == 'dev-fixture') {
      throw const FormatException(
          'User and development catalogues cannot be replaced by a dataset pack');
    }
    if (foods.map((f) => f.id).toSet().length != foods.length) {
      throw const FormatException('Duplicate source identifiers');
    }
    for (final f in foods) {
      if (f.source.dataset != dataset ||
          f.source.datasetVersion != version ||
          f.source.licence != licence ||
          !f.id.startsWith('$dataset:')) {
        throw const FormatException('Food provenance differs from manifest');
      }
    }
  }
  final String dataset, version, licence, attribution;
  final List<Food> foods;
  factory CataloguePack.decode(String text) {
    if (text.length > 50 * 1024 * 1024) {
      throw const FormatException('Catalogue pack too large');
    }
    final j = Map<String, Object?>.from(jsonDecode(text) as Map);
    if (j['format'] != 'salu-catalogue' || j['version'] != 1) {
      throw const FormatException('Unsupported catalogue pack');
    }
    final m = Map<String, Object?>.from(j['manifest']! as Map);
    return CataloguePack(
        dataset: m['dataset']! as String,
        version: m['version']! as String,
        licence: m['licence']! as String,
        attribution: m['attribution']! as String,
        foods: [
          for (final f in j['foods']! as List)
            foodFromSnapshot(Map<String, Object?>.from(f as Map))
        ]);
  }
  String encode() => jsonEncode({
        'format': 'salu-catalogue',
        'version': 1,
        'manifest': {
          'dataset': dataset,
          'version': version,
          'licence': licence,
          'attribution': attribution
        },
        'foods': foods.map(foodSnapshot).toList()
      });
}

/// An explicit, non-reviewed approval for a catalogue bundled into this build.
///
/// This is deliberately **not** a `DatasetReview`: it records that the build
/// author chose to include an exact, pinned source file for a private,
/// non-distributed family-testing installation. It grants no redistribution
/// right, asserts no independent licence verification and approves no clinical
/// or dataset quality. [CatalogueInstallService.activate] never accepts it;
/// only [CatalogueInstallService.activateBuiltIn] does, and only for the exact
/// dataset, version, licence, attribution and source digest it names.
final class BuiltInCatalogueApproval {
  const BuiltInCatalogueApproval({
    required this.approvalId,
    required this.dataset,
    required this.version,
    required this.licence,
    required this.attribution,
    required this.sourceSha256,
  }) : assert(approvalId != ''),
       assert(dataset != ''),
       assert(version != ''),
       assert(licence != ''),
       assert(attribution != ''),
       assert(sourceSha256 != '');

  /// Prefix that identifies the built-in family-test path in the manifest.
  ///
  /// The stored value is the manifest's `reviewId` column, but it is not a
  /// review identifier; it records which explicit built-in approval installed
  /// the rows.
  static const String idPrefix = 'built-in-family-test:';

  /// The INSA BDCA 7.1–2026 workbook bundled with this private build.
  ///
  /// The digest is the adapter's pinned official workbook SHA-256. The licence
  /// string is the source's own copyright/attribution statement, not an open
  /// licence and not a statement that redistribution is permitted.
  static const BuiltInCatalogueApproval insaBdca = BuiltInCatalogueApproval(
      approvalId: '${idPrefix}insa-bdca@7.1-2026',
      dataset: InsaBdcaWorkbookAdapter.dataset,
      version: InsaBdcaWorkbookAdapter.version,
      licence: InsaBdcaWorkbookAdapter.terms,
      attribution: InsaBdcaWorkbookAdapter.attribution,
      sourceSha256: InsaBdcaWorkbookAdapter.workbookSha256);

  /// Manifest value recording which built-in approval installed the dataset.
  final String approvalId;

  /// Dataset identifier, exact version, stated terms and required attribution.
  final String dataset, version, licence, attribution;

  /// SHA-256 of the exact bundled source file.
  final String sourceSha256;

  /// Whether [pack] carries exactly the provenance this approval names.
  bool describes(CataloguePack pack) =>
      pack.dataset == dataset &&
      pack.version == version &&
      pack.licence == licence &&
      pack.attribution == attribution;
}

/// The installed manifest of one catalogue dataset.
///
/// [approvalId] is the row's `reviewId` value. A reviewed activation stores a
/// `DatasetReview` identifier; a built-in activation stores
/// [BuiltInCatalogueApproval.approvalId]. Neither value is interpreted as
/// nutrient or clinical approval.
final class InstalledCatalogueManifest {
  const InstalledCatalogueManifest({
    required this.dataset,
    required this.version,
    required this.licence,
    required this.attribution,
    required this.approvalId,
    required this.foodCount,
  });

  final String dataset, version, licence, attribution, approvalId;
  final int foodCount;
}

/// A read-only description of the identifiers affected by an activation.
///
/// Replaced identifiers may have changed content; this is not a nutrient diff.
/// The preview can become stale if another operation changes the catalogue.
final class CatalogueActivationPreview {
  CatalogueActivationPreview({
    required this.installedVersion,
    required List<String> addedIds,
    required List<String> replacedIds,
    required List<String> retiredIds,
    required List<String> conflictingIds,
  })  : addedIds = List.unmodifiable(addedIds),
        replacedIds = List.unmodifiable(replacedIds),
        retiredIds = List.unmodifiable(retiredIds),
        conflictingIds = List.unmodifiable(conflictingIds);

  final String? installedVersion;
  final List<String> addedIds, replacedIds, retiredIds, conflictingIds;
}

/// Retained source details and diagnostics for one normalized record.
///
/// This is the durable form of a `FoodImportResult` without the food itself,
/// which the catalogue already stores. [foodFingerprint] binds it to the exact
/// normalized snapshot so an audit built for different nutrient values cannot
/// be attached to this record. It is versioned so a future reader can refuse a
/// shape it does not understand instead of guessing. Diagnostics are retained;
/// they never grant dataset or licence approval.
final class CatalogueSourceRecordAudit {
  CatalogueSourceRecordAudit({
    required this.foodId,
    required this.foodFingerprint,
    required this.ordinal,
    required List<FoodImportIssue> issues,
    required List<String> unmappedNutrients,
    required Map<String, Object?> sourceDetails,
  })  : issues = List<FoodImportIssue>.unmodifiable(issues),
        unmappedNutrients = List<String>.unmodifiable(unmappedNutrients),
        sourceDetails = Map<String, Object?>.unmodifiable(sourceDetails) {
    if (foodId.trim().isEmpty) {
      throw ArgumentError.value(
          foodId, 'foodId', 'Audit record needs a food identifier');
    }
    if (foodFingerprint.trim().isEmpty) {
      throw ArgumentError.value(foodFingerprint, 'foodFingerprint',
          'Audit record needs a food snapshot fingerprint');
    }
    if (ordinal < 0) {
      throw ArgumentError.value(
          ordinal, 'ordinal', 'Audit record position cannot be negative');
    }
  }

  static const format = 'salu-source-record-audit';

  /// Version 2 adds the required [foodFingerprint], the SHA-256 digest of the
  /// normalized snapshot.
  ///
  /// Version 1 records predate snapshot binding and are refused rather than
  /// trusted with unknown provenance; the audit feature shipped no released
  /// version-1 data.
  static const version = 2;

  /// Catalogue food identifier this record was normalized into.
  final String foodId;

  /// SHA-256 hex digest of the normalized food snapshot this record describes;
  /// see [catalogueFoodFingerprint].
  final String foodFingerprint;

  /// Original document position, retained so review order survives a restart.
  final int ordinal;

  /// Normalization problems for this record.
  final List<FoodImportIssue> issues;

  /// Source nutrient identifiers this build has no reviewed mapping for.
  final List<String> unmappedNutrients;

  /// Source fields that [Food] does not model.
  final Map<String, Object?> sourceDetails;

  Map<String, Object?> toJson() => {
        'format': format,
        'version': version,
        'foodId': foodId,
        'foodFingerprint': foodFingerprint,
        'ordinal': ordinal,
        'issues': [
          for (final issue in issues)
            {
              'code': issue.code,
              'message': issue.message,
              if (issue.field != null) 'field': issue.field
            }
        ],
        'unmappedNutrients': unmappedNutrients,
        'sourceDetails': sourceDetails
      };

  factory CatalogueSourceRecordAudit.fromJson(Map<String, Object?> json) {
    if (json['format'] != format || json['version'] != version) {
      throw const FormatException('Unsupported source audit record');
    }
    final foodId = json['foodId'];
    final foodFingerprint = json['foodFingerprint'];
    final ordinal = json['ordinal'];
    final rawIssues = json['issues'];
    final rawUnmapped = json['unmappedNutrients'];
    final rawDetails = json['sourceDetails'];
    if (foodId is! String ||
        foodId.trim().isEmpty ||
        foodFingerprint is! String ||
        foodFingerprint.trim().isEmpty ||
        ordinal is! int ||
        ordinal < 0 ||
        rawIssues is! List ||
        rawUnmapped is! List ||
        rawDetails is! Map) {
      throw const FormatException('Invalid source audit record');
    }
    final issues = <FoodImportIssue>[];
    for (final value in rawIssues) {
      if (value is! Map) {
        throw const FormatException('Invalid source audit issue');
      }
      final issue = _auditObject(value, 'issue');
      final code = issue['code'];
      final message = issue['message'];
      final field = issue['field'];
      if (code is! String ||
          code.trim().isEmpty ||
          message is! String ||
          (field != null && field is! String)) {
        throw const FormatException('Invalid source audit issue');
      }
      issues.add(FoodImportIssue(code, message,
          field: field is String ? field : null));
    }
    final unmappedNutrients = <String>[];
    for (final value in rawUnmapped) {
      if (value is! String || value.trim().isEmpty) {
        throw const FormatException('Invalid source audit nutrient list');
      }
      unmappedNutrients.add(value);
    }
    return CatalogueSourceRecordAudit(
        foodId: foodId,
        foodFingerprint: foodFingerprint,
        ordinal: ordinal,
        issues: issues,
        unmappedNutrients: unmappedNutrients,
        sourceDetails: _auditObject(rawDetails, 'source details'));
  }
}

/// Caller-supplied audit of a normalized source pack.
///
/// Build it from a source import with `SourcePackImport.sourceAudit` and pass
/// it to [CatalogueInstallService.activate]. Supplying an audit makes the
/// per-record diagnostics durable; it is not a [DatasetReview], does not
/// confirm an activation, and does not verify a licence or attribution. Each
/// record must carry the [catalogueFoodFingerprint] of the food it describes;
/// activation revalidates every fingerprint against the pack so a stale audit
/// cannot misattribute review.
final class CatalogueSourceAudit {
  CatalogueSourceAudit({
    required this.dataset,
    required this.version,
    required this.licence,
    required this.attribution,
    required List<CatalogueSourceRecordAudit> records,
  }) : records = List<CatalogueSourceRecordAudit>.unmodifiable(records) {
    if ([dataset, version, licence, attribution].any((v) => v.trim().isEmpty)) {
      throw ArgumentError('Source audit metadata cannot be empty');
    }
    if (records.isEmpty) {
      throw ArgumentError('Source audit has no records');
    }
    final ids = records.map((record) => record.foodId).toSet();
    if (ids.length != records.length) {
      throw ArgumentError('Source audit repeats a food identifier');
    }
  }

  /// Declared provenance, matching the pack the audit describes.
  final String dataset, version, licence, attribution;

  /// One entry per normalized record, in no required order; [ordinal] restores
  /// the source document order.
  final List<CatalogueSourceRecordAudit> records;
}

/// Content fingerprint binding an audit record to a normalized food snapshot.
///
/// SHA-256 over the same JSON snapshot the catalogue persists, with
/// set-derived allergen and dietary-tag lists sorted so declaration order does
/// not matter. It detects a record attached to different identifiers,
/// nutrients, portions or source metadata, including after archive and
/// restore. It is a provenance binding, not an approval.
Future<String> catalogueFoodFingerprint(Food food) =>
    _snapshotFingerprint(foodSnapshot(food));

final _sha256 = Sha256();

Future<String> _snapshotFingerprint(Map<String, Object?> snapshot) async {
  final canonical = Map<String, Object?>.of(snapshot);
  for (final key in const ['allergens', 'dietaryTags']) {
    final value = canonical[key];
    if (value is List && value.every((item) => item is String)) {
      canonical[key] = (value.cast<String>().toList()..sort());
    }
  }
  final digest = await _sha256.hash(utf8.encode(jsonEncode(canonical)));
  return _hex(digest.bytes);
}

String _hex(List<int> bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// Reserved key inside `catalog_foods.details_json`.
///
/// The durable per-record audit lives in the same blob the archive already
/// exports and validates, so no table, column or archive version is added and
/// older archives restore without inventing an audit.
const _auditDetailsKey = 'importAudit';

Map<String, Object?> _auditObject(Object? value, String field) {
  if (value is! Map) {
    throw FormatException('Invalid source audit $field');
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is! String) {
      throw FormatException('Invalid source audit $field');
    }
    result[key] = entry.value;
  }
  return result;
}

final class CatalogueInstallService {
  CatalogueInstallService(this.db,
      {List<DatasetReview> approvedReviews = const []})
      : approvedReviews = List.unmodifiable(approvedReviews);
  final AppDatabase db;
  final List<DatasetReview> approvedReviews;

  /// Describe the proposed replacement without modifying or approving it.
  /// Licence review and staged validation still occur during activation.
  Future<CatalogueActivationPreview> preview(CataloguePack pack) async {
    final installed = await (db.select(db.catalogDatasets)
          ..where((t) => t.id.equals(pack.dataset)))
        .getSingleOrNull();
    final current = await (db.select(db.catalogFoods)
          ..where((t) => t.source.equals(pack.dataset)))
        .get();
    final existingIds = current.map((row) => row.id).toSet();
    final incomingIds = pack.foods.map((food) => food.id).toSet();
    final conflicts = <String>[];
    final ids = incomingIds.toList();
    // Chunk the lookup so large catalogues do not exceed SQLite's bind limit.
    for (var offset = 0; offset < ids.length; offset += 500) {
      final end = (offset + 500 < ids.length) ? offset + 500 : ids.length;
      final rows = await (db.select(db.catalogFoods)
            ..where((t) => t.id.isIn(ids.sublist(offset, end))))
          .get();
      conflicts.addAll(
          rows.where((row) => row.source != pack.dataset).map((row) => row.id));
    }
    List<String> sorted(Iterable<String> values) => values.toList()..sort();
    return CatalogueActivationPreview(
        installedVersion: installed?.version,
        addedIds: sorted(
            incomingIds.difference(existingIds).difference(conflicts.toSet())),
        replacedIds: sorted(incomingIds.intersection(existingIds)),
        retiredIds: sorted(existingIds.difference(incomingIds)),
        conflictingIds: sorted(conflicts));
  }

  /// Install [pack] after the explicit confirmation and dataset review gates.
  ///
  /// [sourceAudit], when supplied, is the caller's record-level import audit,
  /// normally `SourcePackImport.sourceAudit`. Each record carries the
  /// fingerprint of its exact normalized food snapshot; the audit is written
  /// with the installed foods in the same transaction and read back by
  /// [readSourceAudit], so diagnostics and source details survive archive and
  /// restore. An audit whose metadata, record identifiers or food snapshots do
  /// not describe [pack] refuses the activation before any write.
  ///
  /// Supplying an audit never substitutes for [approvedReviews] or
  /// [confirmed]: it records what a caller already normalized, not that a
  /// dataset, licence or attribution was reviewed.
  Future<void> activate(CataloguePack pack,
      {required bool confirmed,
      CatalogueSourceAudit? sourceAudit}) async {
    if (!confirmed) throw StateError('CATALOGUE_CONFIRMATION_REQUIRED');
    final reviews = approvedReviews.where((r) =>
        r.dataset == pack.dataset &&
        r.version == pack.version &&
        r.licence == pack.licence &&
        r.reviewId.isNotEmpty);
    if (reviews.isEmpty) throw StateError('DATASET_REVIEW_REQUIRED');
    await _install(pack,
        approvalId: reviews.first.reviewId, sourceAudit: sourceAudit);
  }

  /// Install a bundle approved only for this private family-testing build.
  ///
  /// This path does **not** accept a `DatasetReview`, does not claim that a
  /// licence or dataset was reviewed, and is never reachable from
  /// [activate]. It refuses unless [approval] names exactly this dataset,
  /// version, licence, attribution and [sourceSha256], and unless
  /// [sourceAudit] binds every installed food to its normalized snapshot.
  ///
  /// The replacement is source-scoped and atomic: only rows whose source is
  /// [CataloguePack.dataset] are replaced, plus the known placeholder
  /// `dev-fixture` rows, which are not user data. User-created foods, saved
  /// meals, plans and diary snapshots are untouched. The manifest's `reviewId`
  /// stores [BuiltInCatalogueApproval.approvalId] so the install is visibly
  /// distinct from a reviewed activation.
  Future<void> activateBuiltIn(CataloguePack pack,
      {required BuiltInCatalogueApproval approval,
      required String sourceSha256,
      required CatalogueSourceAudit sourceAudit}) async {
    final mismatches = <String>[
      if (!approval.approvalId.startsWith(BuiltInCatalogueApproval.idPrefix))
        'approval identity',
      if (pack.dataset != approval.dataset) 'dataset',
      if (pack.version != approval.version) 'version',
      if (pack.licence != approval.licence) 'licence',
      if (pack.attribution != approval.attribution) 'attribution',
      if (sourceSha256 != approval.sourceSha256) 'source digest',
    ];
    if (mismatches.isNotEmpty) {
      throw StateError(
          'BUILT_IN_CATALOGUE_APPROVAL_MISMATCH: ${mismatches.join(', ')}');
    }
    await _install(pack,
        approvalId: approval.approvalId,
        sourceAudit: sourceAudit,
        removeDevelopmentFixture: true);
  }

  /// The installed manifest for [dataset], or `null` when it is not installed.
  Future<InstalledCatalogueManifest?> installedManifest(String dataset) async {
    final row = await (db.select(db.catalogDatasets)
          ..where((t) => t.id.equals(dataset)))
        .getSingleOrNull();
    if (row == null) return null;
    return InstalledCatalogueManifest(
        dataset: row.id,
        version: row.version,
        licence: row.licence,
        attribution: row.attribution,
        approvalId: row.reviewId,
        foodCount: row.foodCount);
  }

  /// Every installed catalogue manifest, ordered by dataset identifier.
  ///
  /// A one-shot read: the provider is created after startup provisioning, and
  /// callers that change the manifest can invalidate it. Keeping this as a
  /// Future avoids a persistent Drift stream subscription (and its pending
  /// timers) being alive for the whole app/test lifecycle.
  Future<List<InstalledCatalogueManifest>> installedCatalogues() async =>
      _manifests(await db.select(db.catalogDatasets).get());

  List<InstalledCatalogueManifest> _manifests(List<CatalogDataset> rows) {
    final sorted = [...rows]..sort((a, b) => a.id.compareTo(b.id));
    return [
      for (final row in sorted)
        InstalledCatalogueManifest(
            dataset: row.id,
            version: row.version,
            licence: row.licence,
            attribution: row.attribution,
            approvalId: row.reviewId,
            foodCount: row.foodCount)
    ];
  }

  /// Food rows currently stored for [dataset], regardless of the manifest.
  Future<int> installedFoodCount(String dataset) async {
    final row = await db.customSelect(
        'SELECT COUNT(*) AS matched FROM catalog_foods WHERE source = ?',
        variables: [Variable<String>(dataset)]).getSingle();
    return row.read<int>('matched');
  }

  /// Stored rows for [dataset] that still carry the reserved audit key.
  ///
  /// A cheap launch-time integrity signal, not a fingerprint verification; use
  /// [readSourceAudit] when the audit content itself must be validated.
  Future<int> retainedAuditCount(String dataset) async {
    final row = await db.customSelect(
        'SELECT COUNT(*) AS matched FROM catalog_foods '
        'WHERE source = ? AND details_json LIKE ?',
        variables: [
          Variable<String>(dataset),
          Variable<String>('%$_auditDetailsKey%')
        ]).getSingle();
    return row.read<int>('matched');
  }

  /// Shared activation body. Validation and staging happen before any write;
  /// the live replacement is one transaction, so a failure leaves the previous
  /// catalogue, manifest and audit intact.
  Future<void> _install(CataloguePack pack,
      {required String approvalId,
      CatalogueSourceAudit? sourceAudit,
      bool removeDevelopmentFixture = false}) async {
    final details = sourceAudit == null
        ? null
        : await _auditDetails(pack, sourceAudit);
    // All validation completes in a separate database. A bad food or interrupted
    // activation cannot leave the live dataset half-installed.
    final stage = AppDatabase.memory();
    try {
      await DriftFoodRepository(stage).replaceCatalogueBatch(pack.foods);
    } finally {
      await stage.close();
    }
    await db.transaction(() async {
      for (final f in pack.foods) {
        final existing = await (db.select(db.catalogFoods)
              ..where((t) => t.id.equals(f.id)))
            .getSingleOrNull();
        if (existing != null && existing.source != pack.dataset) {
          throw StateError('CATALOGUE_ID_COLLISION');
        }
      }
      await (db.delete(db.catalogFoods)
            ..where((t) => t.source.equals(pack.dataset)))
          .go();
      if (removeDevelopmentFixture) {
        // Exact placeholder rows only: the fixture dataset can never be a user
        // or imported dataset, and diary items keep their frozen snapshots.
        await (db.delete(db.catalogFoods)
              ..where((t) => t.source.equals('dev-fixture')))
            .go();
      }
      await DriftFoodRepository(db).replaceCatalogueBatch(pack.foods);
      if (details != null) {
        for (final food in pack.foods) {
          await (db.update(db.catalogFoods)
                ..where((t) => t.id.equals(food.id)))
              .write(CatalogFoodsCompanion(
                  detailsJson: Value(details[food.id]!)));
        }
      }
      await db.into(db.catalogDatasets).insertOnConflictUpdate(
          CatalogDatasetsCompanion.insert(
              id: pack.dataset,
              version: pack.version,
              licence: pack.licence,
              attribution: pack.attribution,
              reviewId: approvalId,
              foodCount: pack.foods.length));
    });
  }

  /// The retained source audit for an installed [dataset], or `null` when the
  /// dataset was installed without an audit.
  ///
  /// Reads the same `catalog_foods.details_json` rows the archive exports, so a
  /// restored archive returns the audit without a separate document store. An
  /// archive older than the audit feature has no audit and returns `null`;
  /// nothing is reconstructed or invented.
  ///
  /// Throws [FormatException] when stored audit rows disagree with each other,
  /// with the installed dataset manifest, or with the food snapshot they claim
  /// to describe.
  Future<CatalogueSourceAudit?> readSourceAudit(String dataset) async {
    final rows = await (db.select(db.catalogFoods)
          ..where((t) => t.source.equals(dataset)))
        .get();
    if (rows.isEmpty) return null;
    final records = <CatalogueSourceRecordAudit>[];
    for (final row in rows) {
      final stored = _auditObject(jsonDecode(row.detailsJson), 'details');
      final raw = stored.remove(_auditDetailsKey);
      if (raw == null) continue;
      final record = CatalogueSourceRecordAudit.fromJson(
          _auditObject(raw, 'record'));
      if (record.foodId != row.id) {
        throw const FormatException('Source audit names the wrong food');
      }
      if (await _snapshotFingerprint(stored) != record.foodFingerprint) {
        throw const FormatException(
            'Source audit does not match the stored food');
      }
      records.add(record);
    }
    if (records.isEmpty) return null;
    if (records.length != rows.length) {
      throw const FormatException('Source audit is incomplete');
    }
    final installed = await (db.select(db.catalogDatasets)
          ..where((t) => t.id.equals(dataset)))
        .getSingleOrNull();
    if (installed == null) {
      throw const FormatException('Source audit has no dataset manifest');
    }
    records.sort((a, b) {
      final order = a.ordinal.compareTo(b.ordinal);
      return order != 0 ? order : a.foodId.compareTo(b.foodId);
    });
    return CatalogueSourceAudit(
        dataset: installed.id,
        version: installed.version,
        licence: installed.licence,
        attribution: installed.attribution,
        records: records);
  }

  /// Validates [audit] against [pack] and merges each record into the food
  /// details blob the repository already writes.
  ///
  /// A record must name a pack food and carry that food's exact snapshot
  /// fingerprint; a stale audit built for different nutrient content is
  /// refused before anything is written. Fingerprints and merged details are
  /// computed before the activation transaction so a caller value that cannot
  /// be represented is refused instead of aborting a live write.
  static Future<Map<String, String>> _auditDetails(
      CataloguePack pack, CatalogueSourceAudit audit) async {
    final mismatch = <String>[
      if (audit.dataset != pack.dataset) 'dataset',
      if (audit.version != pack.version) 'version',
      if (audit.licence != pack.licence) 'licence',
      if (audit.attribution != pack.attribution) 'attribution'
    ];
    final recordIds = audit.records.map((record) => record.foodId).toSet();
    final foodIds = pack.foods.map((food) => food.id).toSet();
    if (recordIds.length != foodIds.length ||
        !recordIds.containsAll(foodIds)) {
      mismatch.add('record identifiers');
    }
    if (mismatch.isNotEmpty) {
      throw ArgumentError.value(audit, 'sourceAudit',
          'Source audit does not describe this pack: ${mismatch.join(', ')}');
    }
    final foods = {for (final food in pack.foods) food.id: food};
    final fingerprints = <String, String>{};
    for (final food in pack.foods) {
      fingerprints[food.id] = await catalogueFoodFingerprint(food);
    }
    for (final record in audit.records) {
      if (fingerprints[record.foodId] != record.foodFingerprint) {
        mismatch.add('record fingerprints');
        break;
      }
    }
    if (mismatch.isNotEmpty) {
      throw ArgumentError.value(audit, 'sourceAudit',
          'Source audit does not describe this pack: ${mismatch.join(', ')}');
    }
    final details = <String, String>{};
    for (final record in audit.records) {
      try {
        details[record.foodId] = jsonEncode({
          ...foodSnapshot(foods[record.foodId]!),
          _auditDetailsKey: record.toJson()
        });
      } on JsonUnsupportedObjectError {
        throw ArgumentError.value(record.sourceDetails, 'sourceDetails',
            'Source details must be JSON values');
      }
    }
    return details;
  }
}
