import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_data/salu_data.dart';

import '../../providers.dart';
import '../../ui_support.dart';

/// How the user supplies the catalogue that is being inspected.
enum CataloguePreviewInput {
  /// A normalized, versioned Salu catalogue pack.
  normalizedPack,

  /// Raw USDA FoodData Central or Open Food Facts JSON.
  rawSource,

  /// The official ANSES CIQUAL XML export.
  ciqualXml,

  /// The official INSA Portuguese food-composition workbook (BDCA).
  insaWorkbook,
}

/// The citation INSA requires next to the workbook's content.
///
/// It is reproduced verbatim in the UI and is deliberately not translated:
/// the source mandates this exact Portuguese line, including the spacing in
/// `I. P.- INSA`. It aliases the adapter's constant so the importer and the
/// preview cannot drift apart.
const String insaBdcaAttribution = InsaBdcaWorkbookAdapter.attribution;

/// One workbook selected for an INSA preview.
///
/// [name] only records the selection; [bytes] are validated by the INSA
/// adapter, which matches the workbook's SHA-256, version and sheet against the
/// documented official release before any pack exists.
class InsaWorkbookSelection {
  const InsaWorkbookSelection({required this.name, required this.bytes});

  final String name;
  final List<int> bytes;
}

/// Outer size bound applied before the selected workbook is read or copied.
///
/// The official 7.1-2026 workbook is under 1 MiB; this bound keeps a
/// mis-selected large file from being loaded into memory only to be rejected.
/// The INSA adapter enforces its own content and document limits on top of
/// this.
const int _maxInsaWorkbookBytes = SourcePackImporter.maxInsaWorkbookBytes;

/// Normalizes user-supplied INSA BDCA workbook bytes into a candidate pack.
///
/// This is the production callback for [compute]; it never installs, activates
/// or approves the result and performs no database access. It is asynchronous
/// because the resulting audit hashes each normalized food. It is public so
/// tests can run this very same normalization without having to drive a
/// background isolate through the widget test's fake clock.
Future<SourcePackImport> importInsaWorkbookBytes(List<int> workbookBytes) =>
    SourcePackImporter.importInsaWorkbook(workbookBytes: workbookBytes);

/// Runs [importInsaWorkbookBytes] on a background isolate where supported.
///
/// On the web [compute] still runs the callback on the main thread, where the
/// full workbook can block the page.
Future<SourcePackImport> _runInsaImport(List<int> workbookBytes) =>
    compute(importInsaWorkbookBytes, workbookBytes);

/// One XML document selected for a CIQUAL preview.
///
/// [name] only classifies the document and records the selection; the bytes
/// are decoded and validated by the CIQUAL adapter. The official ANSES names
/// are `alim_*.xml`, `const_*.xml`, `compo_*.xml`, `alim_grp_*.xml` and
/// `sources_*.xml`.
class CiqualSourceDocument {
  const CiqualSourceDocument({required this.name, required this.bytes});

  final String name;
  final List<int> bytes;
}

/// Caller declarations and raw XML documents for one CIQUAL normalization.
class CiqualImportRequest {
  const CiqualImportRequest({
    required this.datasetVersion,
    required this.licence,
    required this.attribution,
    required this.foodsBytes,
    required this.constituentsBytes,
    required this.compositionsBytes,
    this.foodGroupsBytes,
    this.sourcesBytes,
  });

  final String datasetVersion;
  final String licence;
  final String attribution;
  final List<int> foodsBytes;
  final List<int> constituentsBytes;
  final List<int> compositionsBytes;
  final List<int>? foodGroupsBytes;
  final List<int>? sourcesBytes;
}

/// Normalizes selected CIQUAL XML into a candidate pack, touching no database.
///
/// This is the production callback for [compute]; it never installs, activates
/// or approves the result. It is public so tests can run this very same
/// normalization without having to drive a background isolate through the
/// widget test's fake clock.
SourcePackImport importCiqualDocuments(CiqualImportRequest request) =>
    SourcePackImporter.importCiqual(
      datasetVersion: request.datasetVersion,
      licence: request.licence,
      attribution: request.attribution,
      foodsBytes: request.foodsBytes,
      constituentsBytes: request.constituentsBytes,
      compositionsBytes: request.compositionsBytes,
      foodGroupsBytes: request.foodGroupsBytes,
      sourcesBytes: request.sourcesBytes,
    );

Future<SourcePackImport> _runCiqualImport(CiqualImportRequest request) =>
    compute(importCiqualDocuments, request);

enum _CiqualRole { foods, constituents, compositions, foodGroups, sources }

const List<_CiqualRole> _requiredCiqualRoles = <_CiqualRole>[
  _CiqualRole.foods,
  _CiqualRole.constituents,
  _CiqualRole.compositions,
];

_CiqualRole? _ciqualRole(String name) {
  final basename = name.split(RegExp(r'[/\\]')).last.toLowerCase();
  if (basename.startsWith('alim_grp')) return _CiqualRole.foodGroups;
  if (basename.startsWith('alim')) return _CiqualRole.foods;
  if (basename.startsWith('const')) return _CiqualRole.constituents;
  if (basename.startsWith('compo')) return _CiqualRole.compositions;
  if (basename.startsWith('sources')) return _CiqualRole.sources;
  return null;
}

String _ciqualRoleLabel(_CiqualRole role) => switch (role) {
      _CiqualRole.foods => 'foods (alim_*)',
      _CiqualRole.constituents => 'constituents (const_*)',
      _CiqualRole.compositions => 'compositions (compo_*)',
      _CiqualRole.foodGroups => 'food groups (alim_grp_*)',
      _CiqualRole.sources => 'sources (sources_*)',
    };

/// Classifies the selected documents and builds the normalization request.
///
/// The official document kind cannot be inferred from the shared `<TABLE>`
/// root without parsing, so the documented ANSES filename prefixes are used.
/// Unknown names, duplicate kinds, missing required documents and documents
/// above the adapter's 128 MiB limit are rejected before any parsing starts.
CiqualImportRequest _ciqualRequest(
  List<CiqualSourceDocument> documents, {
  required String datasetVersion,
  required String licence,
  required String attribution,
}) {
  final selected = <_CiqualRole, CiqualSourceDocument>{};
  for (final document in documents) {
    final role = _ciqualRole(document.name);
    if (role == null) {
      throw FormatException(
          'CIQUAL files are recognized by the official ANSES filename prefix; '
          '"${document.name}" is not an alim_, const_, compo_, alim_grp_ or '
          'sources_ XML document');
    }
    if (document.bytes.length > CiqualFoodAdapter.maxDocumentBytes) {
      throw FormatException(
          'CIQUAL "${document.name}" exceeds the '
          '${CiqualFoodAdapter.maxDocumentBytes}-byte document limit');
    }
    final previous = selected[role];
    if (previous != null) {
      throw FormatException(
          'CIQUAL preview received two ${_ciqualRoleLabel(role)} files: '
          '"${previous.name}" and "${document.name}"');
    }
    selected[role] = document;
  }
  final missing = <String>[
    for (final role in _requiredCiqualRoles)
      if (!selected.containsKey(role)) _ciqualRoleLabel(role),
  ];
  if (missing.isNotEmpty) {
    throw FormatException(
        'CIQUAL preview needs the foods (alim_*), constituents (const_*) and '
        'compositions (compo_*) XML files; missing: ${missing.join(', ')}');
  }
  return CiqualImportRequest(
    datasetVersion: datasetVersion,
    licence: licence,
    attribution: attribution,
    foodsBytes: selected[_CiqualRole.foods]!.bytes,
    constituentsBytes: selected[_CiqualRole.constituents]!.bytes,
    compositionsBytes: selected[_CiqualRole.compositions]!.bytes,
    foodGroupsBytes: selected[_CiqualRole.foodGroups]?.bytes,
    sourcesBytes: selected[_CiqualRole.sources]?.bytes,
  );
}

/// Inspection only: a preview never grants review approval or installs a pack.
///
/// Salu packs and raw JSON are read as text with a 50 MiB limit. CIQUAL XML is
/// read as bytes because the official 2020 export is Windows-1252, and each
/// document uses [CiqualFoodAdapter.maxDocumentBytes] (128 MiB) instead. The
/// INSA workbook is also read as bytes, up to
/// [SourcePackImporter.maxInsaWorkbookBytes] (8 MiB), because XLSX is a binary
/// ZIP container. Real CIQUAL normalization and INSA workbook parsing are
/// CPU-heavy, so production runs them through [compute]:
/// a background isolate on desktop and mobile, but the same main thread on the
/// web, where the full document can block the page. On platforms with isolates
/// the selected bytes are copied into the worker, so peak memory during a real
/// import is several times the document size; this screen retains only the
/// file names and the resulting candidate pack.
class CataloguePreviewScreen extends ConsumerStatefulWidget {
  const CataloguePreviewScreen({
    super.key,
    this.loadPack,
    this.loadCiqualFiles,
    this.runCiqualImport,
    this.loadInsaWorkbook,
    this.runInsaImport,
  });

  /// Optional reader for tests; null means the platform file picker.
  ///
  /// Normalized packs and raw source JSON are both read through this hook.
  final Future<String?> Function()? loadPack;

  /// Optional byte reader for tests; null means the platform file picker.
  ///
  /// This replaces only the platform selection. Classifying, validating and
  /// normalizing the returned documents remains the production path.
  final Future<List<CiqualSourceDocument>?> Function()? loadCiqualFiles;

  /// Optional execution strategy for the CIQUAL normalization.
  ///
  /// Defaults to [compute]. Tests pass [importCiqualDocuments] directly because
  /// widget tests run under a fake clock that does not drive isolate ports;
  /// the parsed documents and errors are otherwise identical.
  final Future<SourcePackImport> Function(CiqualImportRequest)? runCiqualImport;

  /// Optional byte reader for tests; null means the platform file picker.
  ///
  /// This replaces only the platform selection. The returned bytes are still
  /// size-checked, normalized by the INSA adapter and previewed by the same
  /// production path.
  final Future<InsaWorkbookSelection?> Function()? loadInsaWorkbook;

  /// Optional execution strategy for the INSA workbook normalization.
  ///
  /// Defaults to [compute]. Tests pass [importInsaWorkbookBytes] directly (or
  /// a synthetic importer) because widget tests run under a fake clock that
  /// does not drive isolate ports; the preview and failure handling are the
  /// same production path.
  final Future<SourcePackImport> Function(List<int>)? runInsaImport;

  @override
  ConsumerState<CataloguePreviewScreen> createState() =>
      _CataloguePreviewState();
}

class _CataloguePreviewState extends ConsumerState<CataloguePreviewScreen> {
  CataloguePreviewInput input = CataloguePreviewInput.normalizedPack;
  String source = 'usda-fdc';
  final TextEditingController version = TextEditingController();
  final TextEditingController licence = TextEditingController();
  final TextEditingController attribution = TextEditingController();

  /// Drives the horizontal source selector so its scrollbar can show that
  /// additional source modes are reachable on narrow screens.
  final ScrollController inputScrollController = ScrollController();

  CataloguePack? pack;
  CatalogueActivationPreview? preview;
  List<FoodImportResult>? records;

  /// Source-document diagnostics, distinct from per-record issues.
  ///
  /// They stay visible with the preview because an unmappable column or unsafe
  /// source detail still needs review before any activation.
  List<FoodImportIssue>? sourceIssues;
  bool loading = false;
  bool failed = false;
  bool metadataMissing = false;
  String? failureDetail;

  /// Names of the documents selected for the last CIQUAL attempt.
  ///
  /// Only names are retained: the raw bytes can be tens of megabytes per
  /// document and are not needed after normalization.
  List<String>? ciqualFileNames;

  /// Name of the workbook selected for the last INSA attempt.
  ///
  /// The workbook bytes can be several megabytes and are not retained after
  /// normalization.
  String? insaWorkbookName;

  @override
  void dispose() {
    version.dispose();
    licence.dispose();
    attribution.dispose();
    inputScrollController.dispose();
    super.dispose();
  }

  Future<String?> _pick() async {
    final file = await openFile(acceptedTypeGroups: [
      const XTypeGroup(label: 'Salu catalogue', extensions: ['json'])
    ]);
    if (file == null) return null;
    if (await file.length() > 50 * 1024 * 1024) {
      throw const FormatException('Catalogue pack too large');
    }
    return file.readAsString();
  }

  Future<List<CiqualSourceDocument>?> _pickCiqualFiles() async {
    final files = await openFiles(acceptedTypeGroups: [
      const XTypeGroup(label: 'CIQUAL XML', extensions: ['xml'])
    ]);
    if (files.isEmpty) return null;
    final documents = <CiqualSourceDocument>[];
    for (final file in files) {
      // The adapter enforces this limit too; checking the raw length first
      // avoids reading an oversized document into memory only to reject it.
      if (await file.length() > CiqualFoodAdapter.maxDocumentBytes) {
        throw FormatException(
            'CIQUAL "${file.name}" exceeds the '
            '${CiqualFoodAdapter.maxDocumentBytes}-byte document limit');
      }
      documents.add(CiqualSourceDocument(
          name: file.name, bytes: await file.readAsBytes()));
    }
    return documents;
  }

  Future<InsaWorkbookSelection?> _pickInsaWorkbook() async {
    final file = await openFile(acceptedTypeGroups: [
      const XTypeGroup(
          label: 'INSA BDCA workbook',
          extensions: ['xlsx'],
          mimeTypes: [
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
          ])
    ]);
    if (file == null) return null;
    // The adapter enforces content limits too; checking the raw length first
    // avoids reading an oversized workbook into memory only to reject it.
    final length = await file.length();
    if (length > _maxInsaWorkbookBytes) {
      throw FormatException('INSA workbook "${file.name}" exceeds the '
          '${_maxInsaWorkbookBytes ~/ (1024 * 1024)} MiB limit');
    }
    if (length == 0) {
      throw FormatException('INSA workbook "${file.name}" is empty');
    }
    return InsaWorkbookSelection(
        name: file.name, bytes: await file.readAsBytes());
  }

  void _clearResult() {
    pack = null;
    preview = null;
    records = null;
    sourceIssues = null;
    failed = false;
    metadataMissing = false;
    failureDetail = null;
    ciqualFileNames = null;
    insaWorkbookName = null;
  }

  void _selectInput(CataloguePreviewInput next) {
    if (next == input) return;
    setState(() {
      input = next;
      _clearResult();
    });
  }

  Future<void> _inspectPack() async {
    setState(() {
      loading = true;
      _clearResult();
    });
    try {
      final content = await (widget.loadPack ?? _pick)();
      if (content == null) return;
      final candidate = CataloguePack.decode(content);
      final result = await CatalogueInstallService(ref.read(databaseProvider))
          .preview(candidate);
      if (!mounted) return;
      setState(() {
        pack = candidate;
        preview = result;
      });
    } catch (_) {
      if (mounted) setState(() => failed = true);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _importSource() async {
    final datasetVersion = version.text.trim();
    final licenceId = licence.text.trim();
    final attributionText = attribution.text.trim();
    if (datasetVersion.isEmpty ||
        licenceId.isEmpty ||
        attributionText.isEmpty) {
      setState(() {
        loading = false;
        _clearResult();
        metadataMissing = true;
      });
      return;
    }
    setState(() {
      loading = true;
      _clearResult();
    });
    try {
      final content = await (widget.loadPack ?? _pick)();
      if (content == null) return;
      // The shared importer normalizes every record or fails the whole import;
      // this screen only presents the result and never persists it.
      final imported = SourcePackImporter.importJson(
          source: source,
          jsonText: content,
          datasetVersion: datasetVersion,
          licence: licenceId,
          attribution: attributionText);
      final result = await CatalogueInstallService(ref.read(databaseProvider))
          .preview(imported.pack);
      if (!mounted) return;
      setState(() {
        pack = imported.pack;
        records = imported.records;
        sourceIssues = imported.issues;
        preview = result;
      });
    } on FormatException catch (error) {
      if (mounted) {
        setState(() {
          failed = true;
          failureDetail = error.message;
        });
      }
    } catch (_) {
      if (mounted) setState(() => failed = true);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _importCiqual() async {
    final datasetVersion = version.text.trim();
    final licenceId = licence.text.trim();
    final attributionText = attribution.text.trim();
    if (datasetVersion.isEmpty ||
        licenceId.isEmpty ||
        attributionText.isEmpty) {
      setState(() {
        loading = false;
        _clearResult();
        metadataMissing = true;
      });
      return;
    }
    setState(() {
      loading = true;
      _clearResult();
    });
    try {
      final documents = await (widget.loadCiqualFiles ?? _pickCiqualFiles)();
      if (documents == null || documents.isEmpty) return;
      if (!mounted) return;
      setState(() {
        ciqualFileNames = [for (final document in documents) document.name];
      });
      final request = _ciqualRequest(
        documents,
        datasetVersion: datasetVersion,
        licence: licenceId,
        attribution: attributionText,
      );
      // The request is normalized without the UI isolate on platforms that
      // support it; the result is still only previewed below, never installed.
      final imported =
          await (widget.runCiqualImport ?? _runCiqualImport)(request);
      if (!mounted) return;
      final result = await CatalogueInstallService(ref.read(databaseProvider))
          .preview(imported.pack);
      if (!mounted) return;
      setState(() {
        pack = imported.pack;
        records = imported.records;
        sourceIssues = imported.issues;
        preview = result;
      });
    } on FormatException catch (error) {
      if (mounted) {
        setState(() {
          failed = true;
          failureDetail = error.message;
        });
      }
    } on ArgumentError catch (error) {
      final Object? message = error.message;
      if (mounted) {
        setState(() {
          failed = true;
          failureDetail = message?.toString();
        });
      }
    } catch (_) {
      if (mounted) setState(() => failed = true);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _importInsa() async {
    setState(() {
      loading = true;
      _clearResult();
    });
    try {
      final selection = await (widget.loadInsaWorkbook ?? _pickInsaWorkbook)();
      if (selection == null) return;
      // The picker applies the outer bound; repeat it for the injected reader
      // so empty or oversized selections are always rejected before parsing.
      if (selection.bytes.isEmpty) {
        throw FormatException('INSA workbook "${selection.name}" is empty');
      }
      if (selection.bytes.length > _maxInsaWorkbookBytes) {
        throw FormatException('INSA workbook "${selection.name}" exceeds the '
            '${_maxInsaWorkbookBytes ~/ (1024 * 1024)} MiB limit');
      }
      if (!mounted) return;
      setState(() => insaWorkbookName = selection.name);
      // The workbook is normalized without the UI isolate on platforms that
      // support it; the result is still only previewed below, never installed.
      final imported =
          await (widget.runInsaImport ?? _runInsaImport)(selection.bytes);
      if (!mounted) return;
      final result = await CatalogueInstallService(ref.read(databaseProvider))
          .preview(imported.pack);
      if (!mounted) return;
      setState(() {
        pack = imported.pack;
        records = imported.records;
        sourceIssues = imported.issues;
        preview = result;
      });
    } on FormatException catch (error) {
      if (mounted) {
        setState(() {
          failed = true;
          failureDetail = error.message;
        });
      }
    } on ArgumentError catch (error) {
      final Object? message = error.message;
      if (mounted) {
        setState(() {
          failed = true;
          failureDetail = message?.toString();
        });
      }
    } catch (_) {
      if (mounted) setState(() => failed = true);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final candidate = pack;
    final result = preview;
    final diagnostics = records;
    final isRaw = input == CataloguePreviewInput.rawSource;
    final isCiqual = input == CataloguePreviewInput.ciqualXml;
    final isInsa = input == CataloguePreviewInput.insaWorkbook;
    final selectedCiqualFiles = ciqualFileNames;
    final selectedInsaWorkbook = insaWorkbookName;
    final theme = Theme.of(context);
    Widget ids(String title, List<String> values) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$title: ${values.length}',
                style: Theme.of(context).textTheme.titleSmall),
            if (values.isNotEmpty) SelectableText(values.take(20).join('\n')),
            if (values.length > 20)
              Text(tr(context, 'First 20 identifiers shown.',
                  'São mostrados os primeiros 20 identificadores.')),
          ],
        );
    final withDiagnostics = diagnostics == null
        ? 0
        : diagnostics
            .where((record) =>
                record.issues.isNotEmpty || record.unmappedNutrients.isNotEmpty)
            .length;
    final issueTotals = <String, int>{};
    if (diagnostics != null) {
      for (final record in diagnostics) {
        for (final issue in record.issues) {
          issueTotals.update(issue.code, (count) => count + 1,
              ifAbsent: () => 1);
        }
      }
    }
    // Descriptive coverage of the source's own nutrient identities. A blank
    // source cell is an unknown observation, never a zero, so only observations
    // carrying an amount count as "with a value".
    final nutrientRecords = <String, int>{};
    final nutrientValued = <String, int>{};
    if (diagnostics != null) {
      for (final record in diagnostics) {
        for (final observation in record.food.observations) {
          final id = observation.nutrient.id;
          nutrientRecords.update(id, (count) => count + 1, ifAbsent: () => 1);
          if (observation.amount != null) {
            nutrientValued.update(id, (count) => count + 1, ifAbsent: () => 1);
          }
        }
      }
    }
    return Scaffold(
      appBar: AppBar(
          title: Text(tr(
              context, 'Catalogue preview', 'Pré-visualização do catálogo'))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr(
                context,
                'Inspect a Salu catalogue pack without installing it. Licence and source review are required before activation.',
                'Inspeciona um pacote de catálogo Salu sem o instalar. A licença e a fonte têm de ser revistas antes da ativação.')),
            const SizedBox(height: 12),
            Scrollbar(
              controller: inputScrollController,
              thumbVisibility: true,
              scrollbarOrientation: ScrollbarOrientation.bottom,
              child: SingleChildScrollView(
                controller: inputScrollController,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(bottom: 10),
                child: SegmentedButton<CataloguePreviewInput>(
                  key: const Key('catalogue-input'),
                  segments: [
                    ButtonSegment(
                        value: CataloguePreviewInput.normalizedPack,
                        label: Text(tr(context, 'Salu pack', 'Pacote Salu'))),
                    ButtonSegment(
                        value: CataloguePreviewInput.rawSource,
                        label: Text(tr(context, 'Raw source JSON',
                            'JSON da fonte original'))),
                    ButtonSegment(
                        value: CataloguePreviewInput.ciqualXml,
                        label: Text(tr(context, 'CIQUAL XML', 'XML CIQUAL'))),
                    ButtonSegment(
                        value: CataloguePreviewInput.insaWorkbook,
                        label: Text(tr(context, 'INSA BDCA', 'INSA BDCA'))),
                  ],
                  selected: {input},
                  onSelectionChanged: loading
                      ? null
                      : (values) => _selectInput(values.single),
                ),
              ),
            ),
            if (isRaw) ...[
              const SizedBox(height: 12),
              Text(
                  tr(
                      context,
                      'Normalize raw USDA FoodData Central or Open Food Facts JSON in memory. Accepts documented records as a single object or an array. Nothing is downloaded, nothing is installed and licence review is still required.',
                      'Normaliza JSON em bruto do USDA FoodData Central ou do Open Food Facts em memória. Aceita registos documentados como objeto único ou matriz. Nada é transferido, nada é instalado e a revisão da licença continua a ser necessária.')),
              const SizedBox(height: 12),
              Text(tr(context, 'Source', 'Fonte'),
                  style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Wrap(spacing: 8, children: [
                ChoiceChip(
                  label: const Text('USDA FoodData Central'),
                  selected: source == 'usda-fdc',
                  onSelected: loading
                      ? null
                      : (_) => setState(() => source = 'usda-fdc'),
                ),
                ChoiceChip(
                  label: const Text('Open Food Facts'),
                  selected: source == 'open-food-facts',
                  onSelected: loading
                      ? null
                      : (_) => setState(() => source = 'open-food-facts'),
                ),
              ]),
            ],
            if (isCiqual) ...[
              const SizedBox(height: 12),
              Text(
                  tr(
                      context,
                      'Normalize the official ANSES CIQUAL XML files in memory. Select the foods (alim_*), constituents (const_*) and compositions (compo_*) files; food groups (alim_grp_*) and sources (sources_*) are optional. Nothing is downloaded, nothing is installed and licence review is still required.',
                      'Normaliza em memória os ficheiros XML oficiais da CIQUAL (ANSES). Selecione os ficheiros de alimentos (alim_*), constituintes (const_*) e composições (compo_*); os grupos de alimentos (alim_grp_*) e as fontes (sources_*) são opcionais. Nada é transferido, nada é instalado e a revisão da licença continua a ser necessária.')),
              if (selectedCiqualFiles != null) ...[
                const SizedBox(height: 8),
                Text(tr(context, 'Selected files', 'Ficheiros selecionados'),
                    style: theme.textTheme.titleSmall),
                SelectableText(selectedCiqualFiles.join('\n')),
              ],
            ],
            if (isInsa) ...[
              const SizedBox(height: 12),
              Text(
                  tr(
                      context,
                      'Preview the official INSA Portuguese food-composition workbook (BDCA v${InsaBdcaWorkbookAdapter.version}) that you obtained yourself. Salu does not bundle this workbook, and this preview does not grant or imply permission to redistribute it. It is normalized in memory; nothing is downloaded, nothing is installed and content and licence review is still required before activation.',
                      'Pré-visualiza o livro oficial da Tabela da Composição de Alimentos do INSA (BDCA v${InsaBdcaWorkbookAdapter.version}) que obteve por si. O Salu não inclui este livro e esta pré-visualização não concede nem implica permissão para o redistribuir. É normalizado em memória; nada é transferido, nada é instalado e a revisão do conteúdo e da licença continua a ser necessária antes da ativação.')),
              const SizedBox(height: 8),
              Text(
                  tr(context, 'Required source citation',
                      'Citação obrigatória da fonte'),
                  style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              // Reproduced exactly: INSA mandates this Portuguese line.
              const SelectableText(insaBdcaAttribution),
              const SizedBox(height: 8),
              Text(tr(
                  context,
                  'The selected file must be the official v${InsaBdcaWorkbookAdapter.version} XLSX workbook with the "${InsaBdcaWorkbookAdapter.sheetName}" sheet. Other versions, other sheets or modified workbooks are rejected. Blank cells remain unknown: polyols, free sugars, allergens and density are never inferred, and values keep the source basis (per 100 g edible; per 100 ml only for alcoholic drinks).',
                  'O ficheiro selecionado tem de ser o livro XLSX oficial v${InsaBdcaWorkbookAdapter.version} com a folha "${InsaBdcaWorkbookAdapter.sheetName}". Outras versões, outras folhas ou livros modificados são rejeitados. As células vazias permanecem desconhecidas: nunca são inferidos polióis, açúcares livres, alergénios ou densidade, e os valores mantêm a base da fonte (por 100 g de parte edível; por 100 ml apenas para bebidas alcoólicas).')),
              if (selectedInsaWorkbook != null) ...[
                const SizedBox(height: 8),
                Text(tr(context, 'Selected workbook', 'Livro selecionado'),
                    style: theme.textTheme.titleSmall),
                SelectableText(selectedInsaWorkbook),
              ],
            ],
            if (isRaw || isCiqual) ...[
              const SizedBox(height: 12),
              TextField(
                key: const Key('catalogue-dataset-version'),
                controller: version,
                enabled: !loading,
                decoration: InputDecoration(
                    labelText: tr(context, 'Dataset version',
                        'Versão do conjunto de dados'),
                    errorText: metadataMissing && version.text.trim().isEmpty
                        ? tr(context, 'Required', 'Obrigatório')
                        : null),
              ),
              TextField(
                key: const Key('catalogue-licence'),
                controller: licence,
                enabled: !loading,
                decoration: InputDecoration(
                    labelText: tr(context, 'Licence', 'Licença'),
                    errorText: metadataMissing && licence.text.trim().isEmpty
                        ? tr(context, 'Required', 'Obrigatório')
                        : null),
              ),
              TextField(
                key: const Key('catalogue-attribution'),
                controller: attribution,
                enabled: !loading,
                decoration: InputDecoration(
                    labelText: tr(context, 'Attribution', 'Atribuição'),
                    errorText:
                        metadataMissing && attribution.text.trim().isEmpty
                            ? tr(context, 'Required', 'Obrigatório')
                            : null),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton(
                onPressed: loading
                    ? null
                    : isRaw
                        ? _importSource
                        : isCiqual
                            ? _importCiqual
                            : isInsa
                                ? _importInsa
                                : _inspectPack,
                child: Text(isRaw
                    ? tr(context, 'Choose source JSON',
                        'Escolher JSON da fonte')
                    : isCiqual
                        ? tr(context, 'Choose CIQUAL XML files',
                            'Escolher ficheiros XML CIQUAL')
                        : isInsa
                            ? tr(context, 'Choose INSA workbook',
                                'Escolher livro INSA')
                            : tr(context, 'Choose catalogue pack',
                                'Escolher pacote de catálogo'))),
            if (loading) const LinearProgressIndicator(),
            if (loading && isCiqual)
              Text(tr(
                  context,
                  'Normalizing CIQUAL XML. The full export can take several minutes.',
                  'A normalizar o XML CIQUAL. A exportação completa pode demorar vários minutos.')),
            if (loading && isInsa)
              Text(tr(
                  context,
                  'Normalizing the INSA workbook. The full workbook can take several minutes.',
                  'A normalizar o livro do INSA. O livro completo pode demorar vários minutos.')),
            if (metadataMissing)
              Text(tr(
                  context,
                  'Dataset version, licence and attribution are required for source data.',
                  'A versão do conjunto de dados, a licença e a atribuição são obrigatórias para dados de origem.')),
            if (failed)
              Text(isInsa
                  ? tr(context, 'Could not import this INSA workbook.',
                      'Não foi possível importar este livro INSA.')
                  : isCiqual
                      ? tr(context, 'Could not import these CIQUAL files.',
                          'Não foi possível importar estes ficheiros CIQUAL.')
                      : isRaw
                          ? tr(context, 'Could not import these source records.',
                              'Não foi possível importar estes registos de origem.')
                          : tr(context, 'Could not read this catalogue pack.',
                              'Não foi possível ler este pacote de catálogo.')),
            if (failed && failureDetail != null)
              SelectableText(
                  '${tr(context, 'Details', 'Detalhes')}: $failureDetail'),
            if (candidate != null && result != null) ...[
              const SizedBox(height: 16),
              SelectableText('${candidate.dataset} · ${candidate.version}'),
              SelectableText(
                  '${tr(context, 'Licence', 'Licença')}: ${candidate.licence}'),
              SelectableText(
                  '${tr(context, 'Attribution', 'Atribuição')}: ${candidate.attribution}'),
              Text(
                  '${tr(context, 'Installed version', 'Versão instalada')}: ${result.installedVersion ?? tr(context, 'none', 'nenhuma')}'),
              if (diagnostics != null) ...[
                const SizedBox(height: 16),
                Text(
                    '${tr(context, 'Imported records', 'Registos importados')}: ${diagnostics.length}',
                    style: theme.textTheme.titleSmall),
                Text(
                    '${tr(context, 'Records with diagnostics', 'Registos com diagnósticos')}: $withDiagnostics'),
                if (sourceIssues != null && sourceIssues!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                      '${tr(context, 'Source document issues', 'Problemas do documento de origem')}: ${sourceIssues!.length}',
                      style: theme.textTheme.titleSmall),
                  for (final issue in sourceIssues!.take(20))
                    SelectableText(issue.toString()),
                  if (sourceIssues!.length > 20)
                    Text(tr(context, 'First 20 issues shown.',
                        'São mostrados os primeiros 20 problemas.')),
                ],
                if (issueTotals.isNotEmpty)
                  SelectableText(
                      '${tr(context, 'Issue codes', 'Códigos de problema')}: ${issueTotals.entries.map((entry) => '${entry.key} ×${entry.value}').join(', ')}'),
                if (nutrientRecords.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                      '${tr(context, 'Nutrient coverage', 'Cobertura de nutrientes')}: ${nutrientRecords.length} ${tr(context, 'source identities', 'identidades da fonte')}',
                      style: theme.textTheme.titleSmall),
                  for (final entry in nutrientRecords.entries)
                    SelectableText(
                        '${nutrientLabel(context, entry.key)}: ${nutrientValued[entry.key] ?? 0}/${entry.value} ${tr(context, 'records with a value', 'registos com valor')}'),
                  Text(tr(
                      context,
                      'Descriptive source coverage only. Missing values stay unknown, not zero; this is not an adequacy, content or licence assessment.',
                      'Cobertura descritiva da fonte apenas. Valores em falta permanecem desconhecidos, não zero; isto não é uma avaliação de adequação, conteúdo ou licença.')),
                ],
                for (final record in diagnostics.take(50))
                  _RecordDiagnostics(record),
                if (diagnostics.length > 50)
                  Text(tr(context, 'First 50 records shown.',
                      'São mostrados os primeiros 50 registos.')),
              ],
              const SizedBox(height: 12),
              ids(tr(context, 'Added', 'Adicionados'), result.addedIds),
              ids(tr(context, 'Replaced', 'Substituídos'), result.replacedIds),
              ids(tr(context, 'Retired', 'Retirados'), result.retiredIds),
              ids(tr(context, 'Conflicting', 'Em conflito'),
                  result.conflictingIds),
              const SizedBox(height: 12),
              Text(tr(
                  context,
                  'This is a point-in-time preview, not an approval or a nutrient-by-nutrient comparison. Nothing has been installed.',
                  'Esta é uma pré-visualização pontual, não uma aprovação nem uma comparação nutriente a nutriente. Nada foi instalado.')),
            ]
          ],
        ),
      ),
    );
  }
}

/// Per-record import diagnostics retained for review, never approvals.
class _RecordDiagnostics extends StatelessWidget {
  const _RecordDiagnostics(this.record);

  final FoodImportResult record;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(record.food.id),
          Text(record.food.name),
          for (final issue in record.issues) SelectableText(issue.toString()),
          for (final nutrient in record.unmappedNutrients)
            SelectableText(
                '${tr(context, 'Unmapped', 'Não mapeado')}: $nutrient'),
          if (record.sourceDetails.isNotEmpty)
            SelectableText(
                '${tr(context, 'Source details', 'Detalhes da fonte')}: ${record.sourceDetails.keys.join(', ')}'),
        ],
      ),
    );
  }
}
