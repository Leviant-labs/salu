import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import '../../providers.dart';
import '../../ui_support.dart';

Exact? _optionalAmount(Object? json) => json is Map
    ? Exact.fromJson(Map<String, Object?>.from(json))
    : null;

/// A validated cooked-stock document plus the arithmetic the plan and the
/// batches screen both need. Reservations are never written from here.
final class BatchStockView {
  BatchStockView(this.document)
      : recipe = recipeFromSnapshot(
            Map<String, Object?>.from(document.data['recipe']! as Map)),
        available = Exact.fromJson(
            Map<String, Object?>.from(document.data['available']! as Map)),
        finishedWeightG = _optionalAmount(document.data['finishedWeightG']),
        unit = FoodUnit.values.byName(document.data['unit']! as String),
        allocations = [
          for (final raw in document.data['allocations']! as List)
            BatchAllocation(
                (raw as Map)['id']! as String,
                Exact.fromJson(
                    Map<String, Object?>.from(raw['amount']! as Map)),
                raw['status']! as String,
                intakeRequestId: raw['intakeRequestId'] as String?)
        ] {
    if (!available.positive ||
        allocated.compareTo(available) > 0 ||
        (unit != FoodUnit.g && unit != FoodUnit.serving) ||
        (unit == FoodUnit.g &&
            (finishedWeightG == null || !finishedWeightG!.positive))) {
      throw StateError('INVALID_BATCH');
    }
    if (allocations.map((a) => a.id).toSet().length != allocations.length) {
      throw StateError('DUPLICATE_ALLOCATION');
    }
  }

  final StoredDocument document;
  final RecipeVersion recipe;
  final Exact available;
  final FoodUnit unit;

  /// Measured finished weight for gram stock. Serving stock deliberately has
  /// no weight: portions follow the recipe's equal-serving convention.
  final Exact? finishedWeightG;
  final List<BatchAllocation> allocations;

  int get revision => document.revision;
  Exact get allocated =>
      allocations.fold(Exact.zero, (sum, a) => sum + a.amount);
  Exact get remaining => available - allocated;
  Exact get reserved => allocations
      .where((a) => a.status == 'planned')
      .fold(Exact.zero, (sum, a) => sum + a.amount);

  /// The stock quantity this meal would use, expressed in the batch's own
  /// unit. Gram batches are derived from the measured yield; serving batches
  /// use the exact meal portions because each serving is an equal portion of
  /// the cooked recipe.
  Exact amountForPortions(Exact portions) => unit == FoodUnit.g
      ? finishedWeightG! * portions / recipe.servings
      : portions;

  CookedBatch get cookedBatch => CookedBatch(
      id: document.id,
      recipe: recipe,
      revision: revision,
      available: available,
      unit: unit,
      finishedWeightG: finishedWeightG,
      allocations: allocations);
}

String _number(Exact value) {
  var text = value.toDouble().toStringAsFixed(3);
  text = text.replaceFirst(RegExp(r'0+$'), '');
  text = text.replaceFirst(RegExp(r'\.$'), '');
  return text.isEmpty ? '0' : text;
}

/// Exact stock quantity in [unit]. Serving stock is never rendered as grams.
String batchAmountLabel(BuildContext c, FoodUnit unit, Exact value) =>
    unit == FoodUnit.g
        ? '${_number(value)} g'
        : '${_number(value)} ${_number(value) == '1' ? tr(c, 'serving', 'porção') : tr(c, 'servings', 'porções')}';

class BatchesScreen extends ConsumerStatefulWidget {
  const BatchesScreen({super.key});
  @override
  ConsumerState<BatchesScreen> createState() => _BatchesState();
}

class _BatchesState extends ConsumerState<BatchesScreen> {
  List<BatchStockView> batches = [];
  bool loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data =
          await LocalWorkspace(ref.read(databaseProvider)).list('batch');
      final views = <BatchStockView>[];
      for (final d in data) {
        try {
          views.add(BatchStockView(d));
        } catch (_) {
          // A document that no longer parses is not offered as usable stock.
        }
      }
      if (mounted) {
        setState(() {
          batches = views
            ..sort((a, b) => a.recipe.name.compareTo(b.recipe.name));
          loaded = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => loaded = true);
        showFailure(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext c) => Scaffold(
      appBar:
          AppBar(title: Text(tr(c, 'Cooked batches', 'Lotes confecionados'))),
      body: !loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              Text(tr(
                  c,
                  'Stock remains across calendar weeks. Storage safety is not assessed. Reserved quantities stay held for planned meals; log only food you actually consumed.',
                  'O stock mantém-se entre semanas. A segurança de conservação não é avaliada. As quantidades reservadas ficam retidas para refeições planeadas; regista apenas o que realmente consumiste.')),
              const SizedBox(height: 12),
              if (batches.isEmpty)
                Text(tr(c, 'No cooked batches have been recorded yet.',
                    'Ainda não foram registados lotes confecionados.')),
              for (final b in batches) _batchCard(c, b)
            ]));

  Widget _batchCard(BuildContext c, BatchStockView b) {
    String amount(Exact value) => batchAmountLabel(c, b.unit, value);
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(12),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${b.recipe.name} · v${b.recipe.revision}'),
                  subtitle: Text(b.unit == FoodUnit.g
                      ? '${tr(c, 'Measured finished weight', 'Peso final medido')}: ${amount(b.finishedWeightG!)} · ${tr(c, 'remaining unreserved', 'restante não reservado')}: ${amount(b.remaining)}'
                      : '${tr(c, 'Equal servings in this batch', 'Porções iguais neste lote')}: ${amount(b.available)} · ${tr(c, 'remaining unreserved', 'restante não reservado')}: ${amount(b.remaining)}'),
                  trailing: IconButton(
                      tooltip: tr(c, 'Log consumed batch portion',
                          'Registar porção consumida do lote'),
                      icon: const Icon(Icons.restaurant),
                      onPressed:
                          b.remaining.positive ? () => _consume(c, b) : null)),
              if (b.unit == FoodUnit.serving)
                Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                        tr(
                            c,
                            'Serving stock uses the recipe\'s equal-serving convention. No finished weight is measured or guessed.',
                            'O stock em porções usa a convenção de porções iguais da receita. Não é medido nem presumido qualquer peso final.'),
                        style: Theme.of(c).textTheme.bodySmall)),
              if (b.allocations.isNotEmpty) ...[
                Text(tr(c, 'Stock allocations', 'Alocações de stock'),
                    style: Theme.of(c).textTheme.titleSmall),
                for (final a in b.allocations)
                  ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(a.status == 'planned'
                          ? Icons.push_pin_outlined
                          : Icons.check_circle_outline),
                      title: Text(
                          '${a.status == 'planned' ? tr(c, 'Reserved', 'Reservado') : tr(c, 'Consumed', 'Consumido')} ${amount(a.amount)}'),
                      subtitle: Text(a.status == 'planned'
                          ? tr(
                              c,
                              'Held for a planned meal. This is not intake.',
                              'Retido para uma refeição planeada. Isto não é consumo.')
                          : tr(
                              c,
                              'Recorded as consumed and never returned to stock.',
                              'Registado como consumido e nunca devolvido ao stock.')))
              ],
              const SizedBox(height: 4),
              Text(
                  tr(c,
                      'Record new cooked batches from a recipe\'s menu in the Plan tab. Reservations are created and released there so the plan and stock stay consistent.',
                      'Regista novos lotes confecionados no menu de uma receita no separador Plano. As reservas são criadas e libertadas aí para manter o plano e o stock consistentes.'),
                  style: Theme.of(c).textTheme.bodySmall)
            ])));
  }

  Future<void> _consume(BuildContext c, BatchStockView batch) async {
    final unit = batch.unit;
    final amount = await askText(c,
        title: unit == FoodUnit.g
            ? tr(c, 'Measured consumed grams', 'Gramas consumidos medidos')
            : tr(c, 'Consumed servings', 'Porções consumidas'),
        initial: _number(batch.remaining));
    if (amount == null || !c.mounted) return;
    try {
      final quantity = Exact.parse(amount.replaceAll(',', '.'));
      if (!quantity.positive || quantity.compareTo(batch.remaining) > 0) {
        showFailure(
            c,
            StateError(unit == FoodUnit.g
                ? tr(
                    c,
                    'The amount exceeds the unreserved stock. Reserved grams stay held for planned meals.',
                    'A quantidade excede o stock não reservado. As gramas reservadas ficam retidas para refeições planeadas.')
                : tr(
                    c,
                    'The amount exceeds the unreserved stock. Reserved servings stay held for planned meals.',
                    'A quantidade excede o stock não reservado. As porções reservadas ficam retidas para refeições planeadas.')));
        return;
      }
      final label = batchAmountLabel(c, unit, quantity);
      if (!await confirmAction(
          c,
          tr(c, 'Record consumed batch portion?',
              'Registar porção consumida do lote?'),
          unit == FoodUnit.g
              ? tr(
                  c,
                  'Record $label from this cooked batch as consumed? This writes intake, uses stock once, and does not assess storage safety.',
                  'Registar $label deste lote confecionado como consumidos? Isto escreve no diário, usa stock uma vez e não avalia a segurança de conservação.')
              : tr(
                  c,
                  'Record $label from this cooked batch as consumed? No gram equivalent is available because no finished weight was measured. This writes intake using the recipe\'s equal-serving convention, uses stock once, and does not assess storage safety.',
                  'Registar $label deste lote confecionado para consumo? Não existe equivalente em gramas porque não foi medido qualquer peso final. Isto escreve no diário usando a convenção de porções iguais da receita, usa stock uma vez e não avalia a segurança de conservação.'))) {
        return;
      }
      await BatchService(ref.read(databaseProvider), ref.read(clockProvider),
              ref.read(idGeneratorProvider))
          .consumeAmount(
              requestId: ref.read(idGeneratorProvider).next(),
              batchId: batch.document.id,
              expectedRevision: batch.revision,
              amount: quantity,
              unit: unit,
              offsetMinutes: currentOffsetMinutes(),
              confirmed: true);
      ref.invalidate(todayEntriesProvider);
      await _load();
    } catch (e) {
      if (c.mounted) showFailure(c, e);
    }
  }
}
