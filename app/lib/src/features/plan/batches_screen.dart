import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import '../../providers.dart';
import '../../ui_support.dart';

class BatchesScreen extends ConsumerStatefulWidget {
  const BatchesScreen({super.key});
  @override
  ConsumerState<BatchesScreen> createState() => _BatchesState();
}

class _BatchesState extends ConsumerState<BatchesScreen> {
  List<StoredDocument> batches = [];
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = await LocalWorkspace(ref.read(databaseProvider)).list('batch');
    if (mounted) setState(() => batches = data);
  }

  @override
  Widget build(BuildContext c) => Scaffold(
      appBar:
          AppBar(title: Text(tr(c, 'Cooked batches', 'Lotes confecionados'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(tr(
            c,
            'Stock remains across calendar weeks. Storage safety is not assessed. Log only food you actually consumed.',
            'O stock mantém-se entre semanas. A segurança de conservação não é avaliada. Regista apenas o que realmente consumiste.')),
        for (final b in batches) _tile(c, b)
      ]));
  Widget _tile(BuildContext c, StoredDocument b) {
    final recipe =
        recipeFromSnapshot(Map<String, Object?>.from(b.data['recipe']! as Map));
    final available =
        Exact.fromJson(Map<String, Object?>.from(b.data['available']! as Map));
    final allocations = b.data['allocations']! as List;
    final used = allocations.fold<Exact>(
        Exact.zero,
        (sum, v) =>
            sum +
            Exact.fromJson(
                Map<String, Object?>.from((v as Map)['amount']! as Map)));
    return ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(recipe.name),
        subtitle: Text(
            '${number((available - used).toDouble())} g ${tr(c, 'remaining', 'restantes')}'),
        trailing: IconButton(
            tooltip: tr(c, 'Log consumed batch portion',
                'Registar porção consumida do lote'),
            icon: const Icon(Icons.restaurant),
            onPressed:
                (available - used).positive ? () => _consume(c, b) : null));
  }

  Future<void> _consume(BuildContext c, StoredDocument batch) async {
    final amount = await askText(c,
        title: tr(c, 'Measured consumed grams', 'Gramas consumidos medidos'));
    if (amount == null) return;
    try {
      final grams = Exact.parse(amount.replaceAll(',', '.'));
      await BatchService(ref.read(databaseProvider), ref.read(clockProvider),
              ref.read(idGeneratorProvider))
          .consume(
              requestId: ref.read(idGeneratorProvider).next(),
              batchId: batch.id,
              expectedRevision: batch.revision,
              grams: grams,
              offsetMinutes: currentOffsetMinutes(),
              confirmed: true);
      ref.invalidate(todayEntriesProvider);
      await _load();
    } catch (e) {
      if (c.mounted) showFailure(c, e);
    }
  }
}
