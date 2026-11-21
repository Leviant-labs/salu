import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

import 'assistant/assistant.dart';
import 'assistant/chatgpt_session.dart';
import 'assistant/credential_store.dart';
import 'assistant/endpoint_transport.dart';
import 'assistant/inference_gateway.dart';
import 'assistant/operation_fence.dart';
import 'features/meals/meal_estimation.dart';
import 'features/onboarding/planning_profile.dart';
import 'features/plan/week_plan.dart';
import 'features/settings/connections_controller.dart';
import 'media/managed_media_store.dart';

final operationFenceProvider = Provider<OperationFence>((ref) {
  final fence = OperationFence();
  ref.onDispose(fence.invalidate);
  return fence;
});

final credentialStoreProvider = Provider<CredentialStore>(
  (ref) => SecureCredentialStore(),
);

final endpointProfilesStoreProvider = Provider<EndpointProfilesStore>(
  (ref) => EndpointProfilesStore(ref.watch(documentStoreProvider)),
);

final endpointTransportProvider = Provider<EndpointTransport>(
  (ref) => EndpointTransport(),
);

final chatGptSessionProvider = Provider<ChatGptSession>(
  (ref) => ChatGptSession(
    transport: ref.watch(endpointTransportProvider),
    fence: ref.watch(operationFenceProvider),
  ),
);

final inferenceGatewayProvider = Provider<InferenceGateway>((ref) {
  final fence = ref.watch(operationFenceProvider);
  final transport = ref.watch(endpointTransportProvider);
  final chatGpt = SaluAssistant(
    chatGptSession: ref.watch(chatGptSessionProvider),
    fence: fence,
    transport: transport,
  );
  return InferenceGateway(
    profiles: ref.watch(endpointProfilesStoreProvider),
    credentials: ref.watch(credentialStoreProvider),
    transport: transport,
    fence: fence,
    chatGpt: chatGpt,
  );
});

/// Scoped assistant facade shared across Settings, diary, check-in, and Plan.
final assistantProvider = Provider<SaluAssistant>(
  (ref) => SaluAssistant(
    gateway: ref.watch(inferenceGatewayProvider),
    fence: ref.watch(operationFenceProvider),
    transport: ref.watch(endpointTransportProvider),
  ),
);

final mealEstimateStatusStoreProvider = Provider<MealEstimateStatusStore>(
  (ref) => MealEstimateStatusStore(ref.watch(databaseProvider)),
);

final mealEstimateErrorProvider = FutureProvider.family<SaluAssistantErrorCode?,
    ({String mealId, int revision})>((ref, key) async {
  final raw = await ref
      .watch(mealEstimateStatusStoreProvider)
      .errorFor(key.mealId, key.revision);
  if (raw == null) return null;
  return parseSaluAssistantErrorCode(raw);
});

final connectionsControllerProvider =
    ChangeNotifierProvider<ConnectionsController>((ref) {
  final fence = ref.watch(operationFenceProvider);
  final chatGptSession = ref.watch(chatGptSessionProvider);
  return ConnectionsController(
    ref.watch(endpointProfilesStoreProvider),
    ref.watch(credentialStoreProvider),
    transport: ref.watch(endpointTransportProvider),
    fence: fence,
    isChatGptConnected: () => chatGptSession.isConnected,
    signInChatGpt: chatGptSession.signIn,
    signOutChatGpt: chatGptSession.signOut,
    onInvalidate: fence.invalidate,
  );
});

final activeMealEstimatesProvider =
    ChangeNotifierProvider<ActiveMealEstimates>((ref) {
  final tracker = ActiveMealEstimates();
  ref.onDispose(tracker.reset);
  return tracker;
});

final photoMealRepositoryProvider = Provider<PhotoMealRepository>(
  (ref) => DriftPhotoMealRepository(ref.watch(databaseProvider)),
);

final mealMutationRepositoryProvider = Provider<MealMutationRepository>(
  (ref) => MealMutationRepository(
    ref.watch(databaseProvider),
    clock: ref.watch(clockProvider),
  ),
);

final managedMediaStoreProvider = Provider<ManagedMediaStore>(
  (ref) => ManagedMediaStore(
    directory: getApplicationSupportDirectory,
    newId: ref.read(idGeneratorProvider).next,
  ),
);

final diarySelectionProvider = StateProvider<DiaryDate?>((ref) => null);
final visibleDiaryDateProvider = Provider<DiaryDate>((ref) =>
    ref.watch(diarySelectionProvider) ?? ref.watch(todayDiaryDateProvider));

final todayMealsProvider = StreamProvider<List<PhotoMeal>>((ref) {
  final repository = ref.watch(photoMealRepositoryProvider);
  final date = ref.watch(visibleDiaryDateProvider);
  return repository is LivePhotoMealRepository
      ? repository.watchFor(date)
      : Stream.fromFuture(repository.listFor(date));
});

/// The open database. Overridden in `main()` with the real instance and in tests
/// with an in-memory one; reading it without an override is a wiring bug.
final databaseProvider = Provider<AppDatabase>(
  (ref) => throw StateError(
    'databaseProvider must be overridden in main() or in the test scope',
  ),
);

final documentStoreProvider = Provider<LocalDocumentStore>(
    (ref) => LocalDocumentStore(ref.watch(databaseProvider)));
final planningProfileStoreProvider = Provider<PlanningProfileStore>(
    (ref) => PlanningProfileStore(documents: ref.watch(documentStoreProvider)));
final onboardingStoreProvider = Provider<OnboardingStore>(
    (ref) => OnboardingStore(ref.watch(documentStoreProvider)));
final weekPlanStoreProvider = Provider<WeekPlanStore>(
    (ref) => WeekPlanStore(documents: ref.watch(documentStoreProvider)));

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
final todayDiaryDateProvider = Provider<DiaryDate>((ref) {
  final date = DiaryDate.ofLocal(DateTime.now());
  final timer = Timer.periodic(const Duration(seconds: 20), (_) {
    if (DiaryDate.ofLocal(DateTime.now()) != date) ref.invalidateSelf();
  });
  ref.onDispose(timer.cancel);
  return date;
});

/// Entries for the opened diary date.
final todayEntriesProvider = FutureProvider<List<LoggedEntry>>((ref) async {
  final repository = ref.watch(entryRepositoryProvider);
  return repository.entriesFor(ref.watch(visibleDiaryDateProvider));
});

/// Catalogue search results for [query]; empty below two characters.
final foodSearchProvider = FutureProvider.family<List<Food>, String>((
  ref,
  query,
) async {
  if (query.trim().length < 2) return const <Food>[];
  return ref.watch(foodRepositoryProvider).search(query);
});
