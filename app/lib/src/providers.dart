import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

/// The open database. Overridden in `main()` with the real instance and in tests
/// with an in-memory one; reading it without an override is a wiring bug.
final databaseProvider = Provider<AppDatabase>(
  (ref) => throw StateError(
    'databaseProvider must be overridden in main() or in the test scope',
  ),
);

/// Catalogue reads.
final foodRepositoryProvider = Provider<FoodRepository>(
  (ref) => DriftFoodRepository(ref.watch(databaseProvider)),
);

/// Diary reads and writes.
final entryRepositoryProvider = Provider<EntryRepository>(
  (ref) => DriftEntryRepository(ref.watch(databaseProvider)),
);

/// Journal clock. Tests override this instead of sleeping.
final clockProvider = Provider<Clock>((ref) => const SystemClock());

/// Identifier source for new records.
final idGeneratorProvider = Provider<IdGenerator>((ref) => RandomIdGenerator());

/// The typed command handler used by the forms and buttons.
final logFoodHandlerProvider = Provider<LogFoodHandler>(
  (ref) => LogFoodHandler(
    foods: ref.watch(foodRepositoryProvider),
    entries: ref.watch(entryRepositoryProvider),
    clock: ref.watch(clockProvider),
    ids: ref.watch(idGeneratorProvider),
  ),
);

/// The user's UTC offset right now, in minutes.
///
/// A real device reading, not a constant: the diary date depends on it.
int currentOffsetMinutes() => DateTime.now().timeZoneOffset.inMinutes;

/// The diary date the app opens on.
final selectedDiaryDateProvider = StateProvider<DiaryDate?>((ref) => null);

final todayDiaryDateProvider = Provider<DiaryDate>(
  (ref) =>
      ref.watch(selectedDiaryDateProvider) ??
      DiaryDate.assign(
        EventStamp(
            instant: DateTime.now(), offsetMinutes: currentOffsetMinutes()),
      ),
);

/// Entries for the opened diary date.
final todayEntriesProvider = FutureProvider<List<LoggedEntry>>((ref) async {
  final repository = ref.watch(entryRepositoryProvider);
  return repository.entriesFor(ref.watch(todayDiaryDateProvider));
});

/// Catalogue search results for [query]; empty below two characters.
final foodSearchProvider = FutureProvider.family<List<Food>, String>((
  ref,
  query,
) async {
  if (query.trim().length < 2) return const <Food>[];
  return ref.watch(foodRepositoryProvider).search(query);
});

final foodLibraryProvider = Provider<FoodLibraryService>((ref) =>
    FoodLibraryService(ref.watch(databaseProvider), ref.watch(clockProvider),
        ref.watch(idGeneratorProvider)));
final favoriteFoodsProvider = FutureProvider<List<Food>>(
    (ref) => ref.watch(foodLibraryProvider).favorites());
final recentFoodsProvider = FutureProvider<List<Food>>(
    (ref) => ref.watch(foodLibraryProvider).recent());
final savedMealsProvider = FutureProvider<List<StoredDocument>>(
    (ref) => LocalWorkspace(ref.watch(databaseProvider)).list('saved-meal'));
