import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

import 'catalogue/built_in_catalogue.dart';
import 'catalogue/starter_meals.dart';
import 'inference/chatgpt_auth.dart';
import 'inference/chatgpt_plan_provider.dart';
import 'inference/provider_connection.dart';

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

/// The startup provisioning attempt, overridden in `main()`.
///
/// `null` means this scope did not attempt provisioning (most tests).
/// A failure is surfaced in the search screen; the app itself still starts so
/// the user can reach their own foods and records.
final catalogueProvisioningProvider =
    Provider<CatalogueProvisioningOutcome?>((ref) => null);

final starterMealProvisioningProvider =
    StateProvider<StarterMealProvisioningOutcome?>((ref) => null);

/// Installed catalogue manifests, used to show each source's required
/// attribution next to local search and in food details.
///
/// One-shot, not a Drift watch: a persistent stream subscription kept a pending
/// drift refresh timer alive after database disposal in widget tests. The
/// manifest is written before the first frame, so a cached read is correct for
/// the app session; invalidate this provider after an operation that changes
/// the manifest (for example a restore).
final installedCataloguesProvider =
    FutureProvider<List<InstalledCatalogueManifest>>((ref) {
  final installer = CatalogueInstallService(ref.watch(databaseProvider));
  return installer.installedCatalogues();
});

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

final nutritionProfileProvider = FutureProvider<StoredDocument?>(
    (ref) => NutritionProfileStore(ref.watch(databaseProvider)).read());

Future<PlannerResult> _generateGuidedPlan(
    (PlannerContext, List<PlannedMeal>) input) async =>
    const PlannerService().plan(input.$1, existing: input.$2);

final guidedPlanServiceProvider = Provider<GuidedPlanService>((ref) =>
    GuidedPlanService(ref.watch(databaseProvider), ref.watch(clockProvider),
        ref.watch(idGeneratorProvider),
        generator: (context, existing) =>
            compute(_generateGuidedPlan, (context, existing))));

final planForDateProvider = FutureProvider.family<StoredPlan?, DiaryDate>(
    (ref, date) => ref.watch(guidedPlanServiceProvider).planForDate(date));

final mealContentProvider =
    FutureProvider<Map<String, Map<String, Object?>>>((ref) async => {
      for (final row in await LocalWorkspace(ref.watch(databaseProvider))
          .list('meal-content-v1')) row.id: row.data
    });

final secureTokenStoreProvider =
    Provider<ChatGptTokenStore>((ref) => const SecureTokenStore());

final chatGptAuthProvider = ChangeNotifierProvider<ChatGptAuthController>((ref) {
  final auth = ChatGptAuthController(store: ref.watch(secureTokenStoreProvider));
  unawaited(auth.initialize());
  final observer = _AuthLifecycleObserver(auth);
  WidgetsBinding.instance.addObserver(observer);
  ref.onDispose(() => WidgetsBinding.instance.removeObserver(observer));
  return auth;
});

final class _AuthLifecycleObserver with WidgetsBindingObserver {
  _AuthLifecycleObserver(this.auth);
  final ChatGptAuthController auth;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) auth.handleAppResumed();
  }
}

final selectedChatGptModelProvider = StateProvider<String?>((ref) => null);

final providerConnectionProvider = Provider<ProviderConnectionInfo>((ref) {
  final auth = ref.watch(chatGptAuthProvider);
  return ProviderConnectionInfo(providerId: 'chatgpt-plan',
      connected: auth.isConnected, planUsageGranted: auth.planUsageGranted,
      modelSlug: ref.watch(selectedChatGptModelProvider),
      errorCode: auth.connectionState.errorCode);
});

final chatGptModelsProvider = FutureProvider<List<ChatGptModel>>((ref) async {
  final auth = ref.watch(chatGptAuthProvider);
  if (!auth.isConnected || !auth.planUsageGranted) return const [];
  final client = http.Client();
  ref.onDispose(client.close);
  final response = await client.get(
      Uri.parse('https://api.openai.com/v1/models'),
      headers: {'Authorization': 'Bearer ${await auth.accessToken()}'});
  if (response.statusCode != 200) {
    throw StateError('MODEL_ACCESS_UNAVAILABLE:${response.statusCode}');
  }
  final body = jsonDecode(response.body) as Map;
  final rows = body['models'];
  if (rows is! List) throw StateError('MODEL_ACCESS_UNAVAILABLE');
  return [
    for (final row in rows.cast<Map<Object?, Object?>>())
      if (row['visibility'] == 'list' && row['slug'] is String)
        ChatGptModel(slug: row['slug'] as String,
            displayName: (row['display_name'] ?? row['slug']) as String)
  ];
});

final chatGptPlanProvider = Provider<ChatGptPlanProvider>((ref) {
  final auth = ref.read(chatGptAuthProvider);
  final provider = ChatGptPlanProvider(accessToken: auth.accessToken,
      listModels: () => ref.read(chatGptModelsProvider.future),
      modelSlug: () => ref.read(selectedChatGptModelProvider));
  ref.onDispose(() { provider.disconnect(); });
  return provider;
});

final groceryListProvider = FutureProvider.family<GroceryList, String>(
    (ref, planDocumentId) async {
  final db = ref.watch(databaseProvider);
  final plan = await PlanService(db, ref.watch(clockProvider),
      ref.watch(idGeneratorProvider), documentId: planDocumentId).load();
  return GroceryService(db).groceriesFor(planDocumentId: planDocumentId,
      meals: plan?.meals ?? const []);
});

final planMealStateProvider =
    FutureProvider.family<List<PlanMealStateRecord>, String>(
        (ref, planDocumentId) => PlanMealStateService(
            ref.watch(databaseProvider)).listForPlan(planDocumentId));

/// Invalidate only after a successful local transaction or archive cutover.
void invalidateGuidedWorkspace(WidgetRef ref) {
  ref.invalidate(nutritionProfileProvider);
  ref.invalidate(planForDateProvider);
  ref.invalidate(mealContentProvider);
  ref.invalidate(todayEntriesProvider);
  ref.invalidate(groceryListProvider);
  ref.invalidate(planMealStateProvider);
}
