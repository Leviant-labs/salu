import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import '../../intake_moment.dart';
import '../../providers.dart';
import '../../ui_support.dart';

class SavedMealsScreen extends ConsumerWidget {
  const SavedMealsScreen({super.key});
  @override
  Widget build(BuildContext c, WidgetRef ref) => Scaffold(
      appBar: AppBar(title: Text(tr(c, 'Saved meals', 'Refeições guardadas'))),
      body: ref.watch(savedMealsProvider).when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('$e')),
          data: (meals) => meals.isEmpty
              ? Center(
                  child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(tr(
                          c,
                          'Save a consumed meal from its diary menu. Saved meals keep their original nutrient snapshots.',
                          'Guarda uma refeição consumida no menu do diário. As refeições guardadas mantêm os valores nutricionais originais.'))))
              : ListView(children: [
                  for (final meal in meals)
                    ListTile(
                        title: Text(meal.data['name']! as String),
                        trailing: IconButton(
                            tooltip: tr(c, 'Record consumed meal',
                                'Registar refeição consumida'),
                            icon: const Icon(Icons.add_circle_outline),
                            onPressed: () async {
                              final day = ref.read(todayDiaryDateProvider);
                              final now =
                                  ref.read(clockProvider).nowUtc().toLocal();
                              final local = DateTime(day.year, day.month,
                                  day.day, now.hour, now.minute);
                              try {
                                final result =
                                    await showDialog<ReviewedIntakeMoment>(
                                        context: c,
                                        builder: (_) => IntakeMomentDialog(
                                            stamp: EventStamp(
                                                instant: local,
                                                offsetMinutes: local
                                                    .timeZoneOffset.inMinutes),
                                            day: day,
                                            title: tr(
                                                c,
                                                'Confirm consumed meal',
                                                'Confirmar refeição consumida'),
                                            includeMultiplier: true));
                                if (result == null) return;
                                await ref
                                    .read(foodLibraryProvider)
                                    .logSavedMeal(LogSavedMealCommand(
                                        requestId: ref
                                            .read(idGeneratorProvider)
                                            .next(),
                                        mealId: meal.id,
                                        confirmed: true,
                                        multiplier: result.multiplier,
                                        stamp: result.stamp,
                                        diaryDate: result.day));
                                ref.invalidate(todayEntriesProvider);
                                ref.invalidate(recentFoodsProvider);
                                if (c.mounted) {
                                  ScaffoldMessenger.of(c).showSnackBar(SnackBar(
                                      content: Text(tr(c, 'Meal recorded',
                                          'Refeição registada'))));
                                }
                              } catch (e) {
                                if (c.mounted) showFailure(c, e);
                              }
                            }))
                ])));
}
