import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

import '../../providers.dart';
import '../../ui_support.dart';

/// Locally saved food drafts do not send data or record intake until confirmed.
class DraftsScreen extends ConsumerStatefulWidget {
  const DraftsScreen({super.key});

  @override
  ConsumerState<DraftsScreen> createState() => _DraftsScreenState();
}

class _DraftsScreenState extends ConsumerState<DraftsScreen> {
  late Future<List<MealDraft>> drafts;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    drafts = MealDraftStore(ref.read(databaseProvider)).list();
  }

  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: Text(tr(c, 'Drafts', 'Rascunhos'))),
        body: FutureBuilder<List<MealDraft>>(
          future: drafts,
          builder: (c, result) {
            if (result.hasError) return Center(child: Text('${result.error}'));
            if (!result.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final active = result.data!
                .where((d) =>
                    d.status == DraftStatus.review ||
                    d.status == DraftStatus.editing)
                .toList();
            if (active.isEmpty) {
              return Center(
                  child: Text(
                      tr(c, 'No saved drafts', 'Sem rascunhos guardados')));
            }
            return ListView(children: [
              Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(tr(
                      c,
                      'Drafts stay on this device and are not diary entries. Review before recording.',
                      'Os rascunhos ficam neste dispositivo e não são registos no diário. Revê antes de registar.'))),
              for (final draft in active)
                ListTile(
                  title: Text(
                      (draft.values['food'] as Map?)?['name'] as String? ??
                          tr(c, 'Incomplete draft', 'Rascunho incompleto')),
                  subtitle: Text(draft.values['day'] as String? ?? ''),
                  onTap: busy || draft.status != DraftStatus.review
                      ? null
                      : () => _review(draft),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      tooltip: tr(c, 'Edit amount', 'Editar quantidade'),
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: busy || draft.status != DraftStatus.review
                          ? null
                          : () => _editAmount(draft),
                    ),
                    IconButton(
                      tooltip: tr(c, 'Discard draft', 'Descartar rascunho'),
                      icon: const Icon(Icons.delete_outline),
                      onPressed: busy ? null : () => _discard(draft),
                    ),
                  ]),
                )
            ]);
          },
        ),
      );

  Future<void> _discard(MealDraft draft) async {
    if (!await confirmAction(
        context,
        tr(context, 'Discard draft?', 'Descartar rascunho?'),
        tr(context, 'This does not change your diary.',
            'Isto não altera o diário.'))) {
      return;
    }
    try {
      await MealDraftStore(ref.read(databaseProvider)).cancel(
          id: draft.id,
          requestId: ref.read(idGeneratorProvider).next(),
          expectedRevision: draft.revision);
      if (mounted) setState(_reload);
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }

  Future<void> _editAmount(MealDraft draft) async {
    try {
      final current = FoodAmount.fromJson(
          Map<String, Object?>.from(draft.values['amount']! as Map));
      final input = await askText(context,
          title: tr(context, 'New amount (${current.unit.name})',
              'Nova quantidade (${current.unit.name})'));
      if (input == null) return;
      final value = Exact.parse(input.trim().replaceAll(',', '.'));
      if (!value.positive) throw ArgumentError('Positive amount required');
      final updated =
          FoodAmount.exact(value, current.unit, measureId: current.measureId);
      await MealDraftStore(ref.read(databaseProvider)).edit(
          id: draft.id,
          requestId: ref.read(idGeneratorProvider).next(),
          expectedRevision: draft.revision,
          values: {...draft.values, 'amount': updated.toJson()});
      if (mounted) setState(_reload);
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }

  Future<void> _review(MealDraft draft) async {
    try {
      final data = draft.values;
      final snapshot = Map<String, Object?>.from(data['food']! as Map);
      final id = snapshot['id']! as String;
      final food = await ref.read(foodRepositoryProvider).findById(id);
      if (food == null ||
          jsonEncode(foodSnapshot(food)) != jsonEncode(snapshot)) {
        throw StateError(
            'Food changed or is no longer available. Create a new draft from the current food.');
      }
      final amount = FoodAmount.fromJson(
          Map<String, Object?>.from(data['amount']! as Map));
      final day = DiaryDate.parse(data['day']! as String);
      final stamp = EventStamp(
          instant: DateTime.parse(data['instant']! as String),
          offsetMinutes: data['offset']! as int);
      if (!mounted) return;
      final reviewed = await confirmAction(
          context,
          tr(context, 'Record this intake?', 'Registar este consumo?'),
          '${food.name}\n${amount.value} ${amount.unit.name}\n${day.toIso()} · ${stamp.localWallTime.toIso8601String().substring(0, 16).replaceFirst('T', ' ')} (UTC ${stamp.offsetMinutes >= 0 ? '+' : ''}${stamp.offsetMinutes} min)\n${food.source.dataset} · ${food.source.datasetVersion ?? tr(context, 'version unknown', 'versão desconhecida')}\n\n${tr(context, 'Confirm only if you consumed this food.', 'Confirma apenas se consumiste este alimento.')}');
      if (!reviewed || !mounted) return;
      setState(() => busy = true);
      final ids = ref.read(idGeneratorProvider);
      final request = ids.next();
      final n = amount.value.toDouble();
      final quantity = switch (amount.unit) {
        FoodUnit.g => MassQuantity(n),
        FoodUnit.ml => VolumeQuantity(n),
        FoodUnit.item => PieceQuantity(n),
        FoodUnit.serving => ServingQuantity(n)
      };
      await MealDraftStore(ref.read(databaseProvider)).confirm(
          id: draft.id,
          requestId: request,
          expectedRevision: draft.revision,
          reviewed: true,
          writeLocal: () async {
            final current = await ref.read(foodRepositoryProvider).findById(id);
            if (current == null ||
                jsonEncode(foodSnapshot(current)) != jsonEncode(snapshot)) {
              throw StateError('Food changed. Create a new draft.');
            }
            final result = await ref.read(logFoodHandlerProvider).handle(
                LogFoodCommand(
                    requestId: 'draft-log:$request',
                    foodId: id,
                    quantity: quantity,
                    exactQuantity: amount,
                    diaryDate: day,
                    eatenAt: stamp.instantUtc,
                    offsetMinutes: stamp.offsetMinutes));
            if (result is LogFoodRejected) throw StateError(result.message);
          });
      ref.invalidate(todayEntriesProvider);
      ref.invalidate(recentFoodsProvider);
      if (mounted) {
        setState(_reload);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(tr(context, 'Food recorded', 'Alimento registado'))));
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}
