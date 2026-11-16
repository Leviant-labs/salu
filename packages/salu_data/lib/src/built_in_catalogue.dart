import 'package:cryptography/cryptography.dart';

import 'catalogue_install.dart';
import 'database/app_database.dart';
import 'import/insa_bdca_workbook.dart';
import 'import/source_pack_import.dart';

/// Normalizes bundled source bytes into a candidate pack.
///
/// Production wraps the import in a background isolate; tests can pass the
/// importer directly so a fake-clock widget test does not depend on isolate
/// ports. The normalized pack is still validated and activated through the
/// same [BuiltInCatalogueProvisioner] path.
typedef BuiltInWorkbookNormalizer = Future<SourcePackImport> Function(
    List<int> bytes);

/// Whether a launch changed the installed built-in catalogue.
enum BuiltInCatalogueProvisionStatus {
  /// A complete manifest, food count and retained audit already matched.
  alreadyInstalled,

  /// No manifest existed and the bundled catalogue was installed.
  installed,

  /// A manifest existed but its rows/count/audit were incomplete; the source
  /// scope was replaced atomically from the bundle.
  repaired,
}

/// Result of one [BuiltInCatalogueProvisioner.ensureInstalled] attempt.
final class BuiltInCatalogueProvision {
  const BuiltInCatalogueProvision({
    required this.status,
    required this.dataset,
    required this.version,
    required this.foodCount,
    required this.approvalId,
    required this.sourceSha256,
  });

  final BuiltInCatalogueProvisionStatus status;
  final String dataset, version, approvalId, sourceSha256;
  final int foodCount;
}

/// Installs a catalogue bundled into this private build, idempotently.
///
/// The provisioner is deliberately separate from the general reviewed-pack
/// activation path. It accepts only a [BuiltInCatalogueApproval], verifies the
/// exact source SHA-256 before parsing, requires a content-bound source audit,
/// and delegates the atomic source-scoped write to
/// [CatalogueInstallService.activateBuiltIn].
///
/// It never downloads anything: [loadWorkbookBytes] must return the bytes
/// already packaged with the application. A failed load, digest, parse,
/// validation or write raises and leaves the live catalogue unchanged.
final class BuiltInCatalogueProvisioner {
  BuiltInCatalogueProvisioner(this.db);

  final AppDatabase db;

  /// Ensures the bundled INSA BDCA 7.1–2026 catalogue is installed.
  ///
  /// A complete installation for the same version is left untouched on every
  /// later launch. An installation of a different INSA version is a conflict,
  /// not a silent downgrade: it throws `BUILT_IN_CATALOGUE_VERSION_CONFLICT`
  /// and preserves the existing manifest and rows. Missing, orphaned or
  /// incomplete rows are replaced only within the catalogue's own source
  /// scope, atomically.
  Future<BuiltInCatalogueProvision> ensureInstalled({
    required Future<List<int>> Function() loadWorkbookBytes,
    BuiltInCatalogueApproval approval = BuiltInCatalogueApproval.insaBdca,
    BuiltInWorkbookNormalizer? normalize,
  }) async {
    final installer = CatalogueInstallService(db);
    final existing = await installer.installedManifest(approval.dataset);
    if (existing != null && existing.version != approval.version) {
      throw StateError('BUILT_IN_CATALOGUE_VERSION_CONFLICT: '
          'installed ${existing.version}, bundled ${approval.version}');
    }
    if (existing != null) {
      final rows = await installer.installedFoodCount(approval.dataset);
      if (!existing.approvalId
          .startsWith(BuiltInCatalogueApproval.idPrefix)) {
        // A reviewed activation installed this dataset. Never downgrade its
        // provenance or overwrite it from the bundle; an incomplete reviewed
        // install is reported instead of silently replaced.
        if (existing.foodCount > 0 && existing.foodCount == rows) {
          return BuiltInCatalogueProvision(
              status: BuiltInCatalogueProvisionStatus.alreadyInstalled,
              dataset: existing.dataset,
              version: existing.version,
              foodCount: existing.foodCount,
              approvalId: existing.approvalId,
              sourceSha256: approval.sourceSha256);
        }
        throw StateError('BUILT_IN_CATALOGUE_CONFLICTING_INSTALL: '
            'reviewed ${existing.dataset} installation is incomplete');
      }
      final audits = await installer.retainedAuditCount(approval.dataset);
      if (existing.foodCount > 0 &&
          existing.foodCount == rows &&
          audits == rows) {
        return BuiltInCatalogueProvision(
            status: BuiltInCatalogueProvisionStatus.alreadyInstalled,
            dataset: existing.dataset,
            version: existing.version,
            foodCount: existing.foodCount,
            approvalId: existing.approvalId,
            sourceSha256: approval.sourceSha256);
      }
    }

    final bytes = await loadWorkbookBytes();
    if (bytes.isEmpty) {
      throw FormatException(
          'Bundled ${approval.dataset} workbook is empty');
    }
    if (bytes.length > SourcePackImporter.maxInsaWorkbookBytes) {
      throw FormatException('Bundled ${approval.dataset} workbook exceeds the '
          '${SourcePackImporter.maxInsaWorkbookBytes ~/ (1024 * 1024)} MiB '
          'limit');
    }
    final digest = await _sha256Hex(bytes);
    if (digest != approval.sourceSha256) {
      throw FormatException(
          'Bundled ${approval.dataset} workbook SHA-256 does not match the '
          'pinned ${approval.version} release');
    }
    final normalizer = normalize ??
        (List<int> value) => SourcePackImporter.importInsaWorkbook(
            workbookBytes: value);
    final imported = await normalizer(bytes);
    final mismatches = <String>[
      if (imported.pack.dataset != approval.dataset) 'dataset',
      if (imported.pack.version != approval.version) 'version',
      if (imported.pack.licence != approval.licence) 'licence',
      if (imported.pack.attribution != approval.attribution) 'attribution',
    ];
    if (mismatches.isNotEmpty) {
      throw StateError(
          'BUILT_IN_CATALOGUE_PACK_MISMATCH: ${mismatches.join(', ')}');
    }
    final audit = await imported.sourceAudit;
    await installer.activateBuiltIn(imported.pack,
        approval: approval, sourceSha256: digest, sourceAudit: audit);
    return BuiltInCatalogueProvision(
        status: existing == null
            ? BuiltInCatalogueProvisionStatus.installed
            : BuiltInCatalogueProvisionStatus.repaired,
        dataset: imported.pack.dataset,
        version: imported.pack.version,
        foodCount: imported.pack.foods.length,
        approvalId: approval.approvalId,
        sourceSha256: digest);
  }
}

/// SHA-256 of the exact bytes read from the bundled asset.
///
/// Kept local so the provisioner can fail on a substituted asset before the
/// adapter parses any XML. The adapter independently pins the same digest.
Future<String> _sha256Hex(List<int> bytes) async {
  final digest = await Sha256().hash(bytes);
  final buffer = StringBuffer();
  for (final byte in digest.bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// Re-exported so callers cannot accidentally use a different pinned digest.
const String insaBdcaBundledWorkbookSha256 =
    InsaBdcaWorkbookAdapter.workbookSha256;
