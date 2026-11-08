import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_data/salu_data.dart';

import '../../providers.dart';
import '../../ui_support.dart';

/// Inspection only: a preview never grants review approval or installs a pack.
class CataloguePreviewScreen extends ConsumerStatefulWidget {
  const CataloguePreviewScreen({super.key, this.loadPack});

  /// Optional reader for tests; null means the platform file picker.
  final Future<String?> Function()? loadPack;

  @override
  ConsumerState<CataloguePreviewScreen> createState() =>
      _CataloguePreviewState();
}

class _CataloguePreviewState extends ConsumerState<CataloguePreviewScreen> {
  CataloguePack? pack;
  CatalogueActivationPreview? preview;
  bool loading = false;
  bool failed = false;

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

  Future<void> _inspect() async {
    setState(() {
      loading = true;
      failed = false;
      pack = null;
      preview = null;
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

  @override
  Widget build(BuildContext context) {
    final candidate = pack;
    final result = preview;
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
    return Scaffold(
      appBar: AppBar(
          title: Text(tr(
              context, 'Catalogue preview', 'Pré-visualização do catálogo'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(tr(
            context,
            'Inspect a Salu catalogue pack without installing it. Licence and source review are required before activation.',
            'Inspeciona um pacote de catálogo Salu sem o instalar. A licença e a fonte têm de ser revistas antes da ativação.')),
        const SizedBox(height: 12),
        FilledButton(
            onPressed: loading ? null : _inspect,
            child: Text(tr(context, 'Choose catalogue pack',
                'Escolher pacote de catálogo'))),
        if (loading) const LinearProgressIndicator(),
        if (failed)
          Text(tr(context, 'Could not read this catalogue pack.',
              'Não foi possível ler este pacote de catálogo.')),
        if (candidate != null && result != null) ...[
          const SizedBox(height: 16),
          SelectableText('${candidate.dataset} · ${candidate.version}'),
          SelectableText(
              '${tr(context, 'Licence', 'Licença')}: ${candidate.licence}'),
          SelectableText(
              '${tr(context, 'Attribution', 'Atribuição')}: ${candidate.attribution}'),
          Text(
              '${tr(context, 'Installed version', 'Versão instalada')}: ${result.installedVersion ?? tr(context, 'none', 'nenhuma')}'),
          const SizedBox(height: 12),
          ids(tr(context, 'Added', 'Adicionados'), result.addedIds),
          ids(tr(context, 'Replaced', 'Substituídos'), result.replacedIds),
          ids(tr(context, 'Retired', 'Retirados'), result.retiredIds),
          ids(tr(context, 'Conflicting', 'Em conflito'), result.conflictingIds),
          const SizedBox(height: 12),
          Text(tr(
              context,
              'This is a point-in-time preview, not an approval or a nutrient-by-nutrient comparison. Nothing has been installed.',
              'Esta é uma pré-visualização pontual, não uma aprovação nem uma comparação nutriente a nutriente. Nada foi instalado.')),
        ]
      ]),
    );
  }
}
