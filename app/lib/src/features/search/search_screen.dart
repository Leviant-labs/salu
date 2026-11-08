import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_core/salu_core.dart';

import '../../labels.dart';
import '../../providers.dart';

/// Catalogue search with a one-tap 100 g log.
///
/// The tap is a manual confirmation by the user, so it writes directly through
/// the typed command. Anything AI-derived must go through a reviewed draft first;
/// that path does not exist yet and is not simulated here.
class SearchScreen extends ConsumerStatefulWidget {
  /// Creates the screen.
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _logHundredGrams(Food food) async {
    final handler = ref.read(logFoodHandlerProvider);
    final result = await handler.handle(
      LogFoodCommand(
        requestId: ref.read(idGeneratorProvider).next(),
        foodId: food.id,
        quantity: MassQuantity(100),
        offsetMinutes: currentOffsetMinutes(),
        channel: EntryChannel.search,
      ),
    );

    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    switch (result) {
      case LoggedFood(:final entry):
        ref.invalidate(todayEntriesProvider);
        final item = entry.items.first;
        messenger.showSnackBar(
          SnackBar(
            content: Text('Logged ${item.grams.round()} g of ${item.name}'),
          ),
        );
      case LogFoodRejected(:final message):
        messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(foodSearchProvider(_query));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            controller: _controller,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search foods',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _controller.clear();
                        setState(() => _query = '');
                      },
                    ),
              border: const OutlineInputBorder(),
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        Expanded(
          child: results.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, stackTrace) => Center(child: Text('$error')),
            data: (foods) {
              if (_query.trim().length < 2) {
                return const _Hint(
                  text: 'Type at least two characters to search the catalogue.',
                );
              }
              if (foods.isEmpty) {
                return const _Hint(
                  text:
                      'No match. Barcode, label capture and manual entry land '
                      'in the next slice.',
                );
              }
              return ListView.separated(
                itemCount: foods.length,
                separatorBuilder: (context, index) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final food = foods[index];
                  final energy = food.per100g[NutrientKey.energyKcal];
                  return ListTile(
                    title: Text(food.name),
                    subtitle: Text(
                      energy.isKnown
                          ? '${energy.numericValue!.round()} kcal / 100 g · '
                                '${food.source.dataset}'
                          : 'energy unknown · ${food.source.dataset}',
                    ),
                    trailing: IconButton(
                      tooltip: 'Log 100 g',
                      icon: const Icon(Icons.add_circle_outline),
                      onPressed: () => _logHundredGrams(food),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}
