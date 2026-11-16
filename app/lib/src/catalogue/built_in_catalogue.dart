import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:salu_data/salu_data.dart';

/// The exact official INSA BDCA 7.1–2026 workbook bundled with this build.
///
/// The bytes are packaged at build time; Salu never downloads them at runtime.
/// They were obtained from the PortFIR download link
/// `https://portfir.insa.min-saude.pt/wp-content/uploads/2025/11/insa_tca.xlsx`.
/// That URL is mutable and is never trusted at runtime: the adapter's pinned
/// SHA-256 ([InsaBdcaWorkbookAdapter.workbookSha256]) is the authority.
const String bundledInsaBdcaWorkbookAsset =
    'assets/catalogue/insa_tca_7.1_2026.xlsx';

/// Normalizes bundled workbook bytes.
///
/// Top-level so it can run through [compute] on platforms with isolates while
/// tests can call the same function directly.
Future<SourcePackImport> importBundledInsaWorkbook(List<int> bytes) =>
    SourcePackImporter.importInsaWorkbook(workbookBytes: bytes);

/// Outcome of the one startup attempt to provision the bundled catalogue.
///
/// `failure` is retained so the search screen can explain why no built-in
/// catalogue is available instead of silently presenting an empty search.
final class CatalogueProvisioningOutcome {
  const CatalogueProvisioningOutcome.installed(
      BuiltInCatalogueProvision this.provision)
      : failure = null;

  const CatalogueProvisioningOutcome.failed(Object this.failure)
      : provision = null;

  final BuiltInCatalogueProvision? provision;
  final Object? failure;
}

/// Reads the bundled workbook from the application asset bundle.
Future<List<int>> loadBundledInsaWorkbook() async {
  final data = await rootBundle.load(bundledInsaBdcaWorkbookAsset);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

/// Ensures the bundled INSA catalogue is installed in [db].
///
/// This is called from the composition root before the first frame. It is
/// idempotent across launches and source-scoped: an intact installation is not
/// rewritten, while a missing or incomplete one is replaced atomically without
/// touching user foods, plans, saved meals or diary snapshots. A failure throws
/// and leaves the database as it was.
///
/// [normalize] defaults to a background isolate. Tests pass
/// [importBundledInsaWorkbook] directly because Flutter widget tests run under
/// a fake clock that does not drive isolate ports.
Future<BuiltInCatalogueProvision> provisionBundledCatalogue(
  AppDatabase db, {
  Future<List<int>> Function()? loadWorkbookBytes,
  BuiltInWorkbookNormalizer? normalize,
}) {
  return BuiltInCatalogueProvisioner(db).ensureInstalled(
    loadWorkbookBytes: loadWorkbookBytes ?? loadBundledInsaWorkbook,
    normalize: normalize ??
        (bytes) => compute(importBundledInsaWorkbook, bytes),
  );
}
