import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide Column, isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/assistant/assistant.dart';
import 'package:salu/src/assistant/credential_store.dart';
import 'package:salu/src/assistant/endpoint_transport.dart';
import 'package:salu/src/assistant/inference_gateway.dart';
import 'package:salu/src/assistant/model_discovery.dart';
import 'package:salu/src/assistant/operation_fence.dart';
import 'package:salu/src/features/meals/meal_editor_ai.dart';
import 'package:salu/src/features/onboarding/planning_profile.dart';
import 'package:salu/src/features/plan/plan_screen.dart';
import 'package:salu/src/features/plan/plan_suggestions.dart';
import 'package:salu/src/features/plan/week_plan.dart' hide MealSlot;
import 'package:salu/src/features/settings/connections_controller.dart';
import 'package:salu/src/features/settings/connections_screen.dart';
import 'package:salu/src/features/settings/settings_screen.dart';
import 'package:salu/src/features/today/today_screen.dart';
import 'package:salu/src/providers.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

import '../meals/meal_editor_fakes.dart';

const _fakeKey1 = 'sk-test-connections-alpha-111111';
const _fakeKey2 = 'sk-test-connections-bravo-222222';

final class _MemoryCredentialStore implements CredentialStore {
  final Map<String, String> slots = <String, String>{};
  bool failWrite = false;
  Future<void> Function(String ref)? onWrite;

  @override
  Future<String?> read(String ref) async => slots[ref];

  @override
  Future<void> write(String ref, String secret) async {
    SecureCredentialStore.validateRef(ref);
    SecureCredentialStore.validateSecret(secret);
    if (onWrite != null) {
      await onWrite!(ref);
    }
    if (failWrite) throw StateError('secure write failed');
    slots[ref] = secret;
  }

  @override
  Future<void> delete(String ref) async {
    SecureCredentialStore.validateRef(ref);
    slots.remove(ref);
  }

  @override
  Future<void> clearSaluCredentials() async => slots.clear();
}

final class _CasConflictInterceptor extends QueryInterceptor {
  int conflictOnPutRemaining = 0;
  bool _expectPutSelect = false;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final rows = await super.runSelect(executor, statement, args);
    if (statement.contains('local_documents') &&
        args.contains('endpoint-connections') &&
        rows.isNotEmpty) {
      if (conflictOnPutRemaining <= 0) {
        _expectPutSelect = false;
        return rows;
      }
      if (_expectPutSelect) {
        conflictOnPutRemaining--;
        _expectPutSelect = false;
        return [
          {
            ...rows.first,
            'revision': (rows.first['revision'] as int) + 1,
          },
        ];
      }
      _expectPutSelect = true;
    }
    return rows;
  }
}

final class _FakeEntryRepository implements EntryRepository {
  @override
  Future<void> append(LoggedEntry entry) async {}

  @override
  Future<List<LoggedEntry>> entriesFor(DiaryDate date) async => const [];

  @override
  Future<LoggedEntry?> findByRequestId(String requestId) async => null;
}

final class _FakeWeekPlanStore extends WeekPlanStore {
  @override
  Future<WeekPlan> load(DateTime monday) async => WeekPlan(monday);

  @override
  Future<void> save(WeekPlan plan) async {}
}

final class _FakeProfileStore extends PlanningProfileStore {
  @override
  Future<PlanningProfile> load() async => const PlanningProfile(
        preferences: FoodPreferences(likes: 'Soup', dislikes: 'Olives'),
        dailyEnergyKcal: 2000,
      );
}

final class _FakeTransportClient implements HttpClient {
  _FakeTransportClient(this._handler);

  final Future<HttpClientResponse> Function(String method, Uri uri) _handler;

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      _FakeTransportRequest('GET', url, _handler);

  @override
  Future<HttpClientRequest> postUrl(Uri url) async =>
      _FakeTransportRequest('POST', url, _handler);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeTransportRequest(method, url, _handler);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeTransportRequest implements HttpClientRequest {
  _FakeTransportRequest(this._method, this._uri, this._handler);

  final String _method;
  final Uri _uri;
  final Future<HttpClientResponse> Function(String method, Uri uri) _handler;

  @override
  final HttpHeaders headers = _FakeTransportHeaders();

  @override
  int contentLength = -1;

  @override
  bool followRedirects = true;

  @override
  void add(List<int> data) {}

  @override
  Future<HttpClientResponse> close() => _handler(_method, _uri);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeTransportHeaders implements HttpHeaders {
  @override
  ContentType? contentType;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeTransportResponse extends StreamView<List<int>>
    implements HttpClientResponse {
  _FakeTransportResponse(this.statusCode, List<int> body)
      : contentLength = body.length,
        super(Stream<List<int>>.value(body));

  @override
  final int statusCode;

  @override
  final int contentLength;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _scrollAndTap(WidgetTester tester, Finder finder) async {
  final scaffolds = find.byType(Scaffold);
  if (scaffolds.evaluate().isNotEmpty) {
    ScaffoldMessenger.maybeOf(tester.element(scaffolds.last))
        ?.removeCurrentSnackBar();
    await tester.pumpAndSettle();
  }
  final verticalScrollable = find
      .byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      )
      .last;
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: verticalScrollable,
    );
  }
  final target = finder.first;
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'save masks key, keeps key hidden after save, and runs no discovery until tapped',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final profilesStore = EndpointProfilesStore(LocalDocumentStore(db));
    final creds = _MemoryCredentialStore();
    var discoveryCalls = 0;

    final controller = ConnectionsController(
      profilesStore,
      creds,
      discoverModelsCallback: (profile, _, __, ___) async {
        discoveryCalls++;
        return const [
          DiscoveredModel(id: 'gpt-4.1-mini', name: 'GPT-4.1 Mini')
        ];
      },
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: ConnectionsScreen(controller: controller)),
    );
    await tester.pumpAndSettle();

    await _scrollAndTap(tester, find.text('Add endpoint'));

    final keyFieldFinder = find.widgetWithText(TextFormField, 'API key');
    expect(keyFieldFinder, findsOneWidget);
    final editableText = tester.widget<EditableText>(
      find.descendant(of: keyFieldFinder, matching: find.byType(EditableText)),
    );
    expect(editableText.obscureText, isTrue);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Endpoint name'),
      'OpenAI Custom',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'API root URL'),
      'https://api.example.com/v1',
    );
    await tester.enterText(keyFieldFinder, _fakeKey1);
    await _scrollAndTap(tester, find.text('Save'));

    expect(discoveryCalls, 0);
    expect(controller.profiles, hasLength(1));
    expect(creds.slots[controller.profiles.single.credentialRef], _fakeKey1);
    expect(find.textContaining(_fakeKey1), findsNothing);
    expect(find.text('OpenAI Custom'), findsOneWidget);

    // Edit form must also never display the saved key.
    await _scrollAndTap(tester, find.text('Edit'));
    expect(find.textContaining(_fakeKey1), findsNothing);
  });

  testWidgets(
      'select, edit with endpoint-change warning, cancel/failure preservation, and remove',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final profilesStore = EndpointProfilesStore(LocalDocumentStore(db));
    final creds = _MemoryCredentialStore();
    var invalidations = 0;
    final controller = ConnectionsController(
      profilesStore,
      creds,
      onInvalidate: () => invalidations++,
    );
    addTearDown(controller.dispose);

    await controller.saveProfile(
      EndpointProfile(
        id: 'p1',
        name: 'Working Endpoint',
        protocol: EndpointProtocol.openaiChat,
        apiRoot: Uri.parse('https://working.example/v1'),
        credentialRef: 'salu.endpoint.p1.1',
        modelId: 'm1',
      ),
      newKey: _fakeKey1,
    );

    await tester.pumpWidget(
      MaterialApp(home: ConnectionsScreen(controller: controller)),
    );
    await tester.pumpAndSettle();

    // Select active connection.
    await _scrollAndTap(tester, find.text('Select'));
    expect(controller.activeId, 'p1');
    expect(invalidations, greaterThanOrEqualTo(1));

    // Edit and change API root -> endpoint-change warning shown; saving without
    // new key fails cleanly and preserves existing working profile.
    await _scrollAndTap(tester, find.text('Edit'));
    await tester.enterText(
      find.widgetWithText(TextFormField, 'API root URL'),
      'https://changed.example/v1',
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining(
        'Changing the protocol or endpoint origin requires re-entering the API key',
      ),
      findsOneWidget,
    );
    await _scrollAndTap(tester, find.text('Save'));
    expect(controller.profiles.single.apiRoot.host, 'working.example');

    // Cancel returns without touching the working connection.
    await _scrollAndTap(tester, find.text('Cancel'));
    expect(controller.profiles.single.apiRoot.host, 'working.example');
    expect(controller.activeId, 'p1');

    // Failed write during rotation preserves old working connection.
    await _scrollAndTap(tester, find.text('Edit'));
    creds.failWrite = true;
    await tester.enterText(
      find.widgetWithText(TextFormField, 'API root URL'),
      'https://changed.example/v1',
    );
    await tester.enterText(
      find.widgetWithText(
        TextFormField,
        'New API key (optional unless endpoint changed)',
      ),
      _fakeKey2,
    );
    await _scrollAndTap(tester, find.text('Save'));
    expect(controller.profiles.single.apiRoot.host, 'working.example');
    creds.failWrite = false;
    await _scrollAndTap(tester, find.text('Cancel'));

    // Remove profile clears activeId and credential.
    await _scrollAndTap(tester, find.text('Remove'));
    expect(controller.profiles, isEmpty);
    expect(controller.activeId, isNull);
    expect(creds.slots, isEmpty);
  });

  testWidgets(
      '404 failed discovery allows retry and manual model ID; test connection discloses unverified generation/image',
      (tester) async {
    var return404 = true;
    var postRequests = 0;
    final transport = EndpointTransport(
      clientFactory: () => _FakeTransportClient((method, uri) async {
        if (method == 'POST') {
          postRequests++;
        }
        if (return404) {
          return _FakeTransportResponse(404, utf8.encode('missing $_fakeKey1'));
        }
        return _FakeTransportResponse(
          200,
          utf8.encode(jsonEncode({
            'data': [
              {'id': 'claude-sonnet-4-5', 'display_name': 'Claude Sonnet 4.5'},
            ],
          })),
        );
      }),
    );

    final db = AppDatabase.memory();
    addTearDown(db.close);
    final profilesStore = EndpointProfilesStore(LocalDocumentStore(db));
    final creds = _MemoryCredentialStore();
    final controller = ConnectionsController(
      profilesStore,
      creds,
      transport: transport,
      fence: OperationFence(),
    );
    addTearDown(controller.dispose);

    await controller.saveProfile(
      EndpointProfile(
        id: 'ant',
        name: 'Anthropic Endpoint',
        protocol: EndpointProtocol.anthropicMessages,
        apiRoot: Uri.parse('https://anthropic.example/v1'),
        credentialRef: 'salu.endpoint.ant.1',
      ),
      newKey: _fakeKey1,
    );

    await tester.pumpWidget(
      MaterialApp(home: ConnectionsScreen(controller: controller)),
    );
    await tester.pumpAndSettle();

    // 404 discovery shows safe error and never leaks secret.
    await _scrollAndTap(tester, find.text('Discover models'));
    expect(find.textContaining(_fakeKey1), findsNothing);
    expect(find.text('Retry discovery'), findsOneWidget);

    // Retry discovery succeeds and shows model selection.
    return404 = false;
    await _scrollAndTap(tester, find.text('Retry discovery'));
    await _scrollAndTap(tester, find.text('Claude Sonnet 4.5'));
    expect(controller.profiles.single.modelId, 'claude-sonnet-4-5');

    // Test connection checks discovery/credentials only and discloses limits.
    await _scrollAndTap(tester, find.text('Test connection'));
    expect(postRequests, 0);
    expect(
      find.textContaining('Generation and image input are not verified'),
      findsOneWidget,
    );

    // Manual model ID override works in Edit even without discovery.
    await _scrollAndTap(tester, find.text('Edit'));
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Model ID'),
      'manual-model-id',
    );
    await _scrollAndTap(tester, find.text('Save'));
    expect(controller.profiles.single.modelId, 'manual-model-id');
  });

  testWidgets(
      'disconnected and busy states work with zero implicit fallback across configured profiles',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final profilesStore = EndpointProfilesStore(LocalDocumentStore(db));
    final creds = _MemoryCredentialStore();
    final fence = OperationFence();

    await profilesStore.save(
      expectedRevision: 0,
      profiles: [
        EndpointProfile(
          id: 'p1',
          name: 'Profile One',
          protocol: EndpointProtocol.openaiChat,
          apiRoot: Uri.parse('https://one.example/v1'),
          credentialRef: 'salu.endpoint.p1.1',
          modelId: 'm1',
        ),
        EndpointProfile(
          id: 'p2',
          name: 'Profile Two',
          protocol: EndpointProtocol.anthropicMessages,
          apiRoot: Uri.parse('https://two.example/v1'),
          credentialRef: 'salu.endpoint.p2.1',
          modelId: 'm2',
        ),
      ],
      activeId: null,
    );
    await creds.write('salu.endpoint.p1.1', _fakeKey1);

    final controller = ConnectionsController(
      profilesStore,
      creds,
      fence: fence,
    );
    addTearDown(controller.dispose);

    final busyCompleter = Completer<List<DiscoveredModel>>();
    await tester.pumpWidget(
      MaterialApp(
        home: ConnectionsScreen(
          controller: controller,
          onDiscoverModels: (_) => busyCompleter.future,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No active connection'), findsOneWidget);

    final discoverFinder = find.text('Discover models');
    final verticalScrollable = find
        .byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        )
        .last;
    await tester.scrollUntilVisible(
      discoverFinder,
      200,
      scrollable: verticalScrollable,
    );
    await tester.ensureVisible(discoverFinder.first);
    await tester.tap(discoverFinder.first);
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    busyCompleter.complete(const []);
    await tester.pumpAndSettle();
  });

  testWidgets(
      'assistantProvider override reaches meals, planning, and check-in without real storage',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final mealRepo = DriftPhotoMealRepository(db);
    final api = FakeOpenAi(reply: {
      'items': [
        {
          'name': 'Oatmeal',
          'portion': {'amount': 200, 'unit': 'grams'},
          'nutrients': {'energy_kcal': 150},
        },
      ],
      'meals': const <Object>[],
      'groceries': const <Object>[],
      'topic': 'coverage',
    });

    final date = DiaryDate.parse('2026-11-19');
    final pendingMeal = PhotoMeal(
      id: 'meal-override-1',
      date: date,
      slot: MealSlot.breakfast,
      caption: 'Breakfast oats',
      createdAt: DateTime.utc(2026, 11, 19, 8),
      estimateStatus: MealEstimateStatus.unavailable,
    );
    await mealRepo.saveNew(pendingMeal);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          planningProfileStoreProvider.overrideWithValue(_FakeProfileStore()),
          todayDiaryDateProvider.overrideWithValue(date),
          diarySelectionProvider.overrideWith((ref) => date),
          todayMealsProvider.overrideWith((ref) => mealRepo.watchFor(date)),
          entryRepositoryProvider.overrideWithValue(_FakeEntryRepository()),
          assistantProvider.overrideWithValue(api.assistant),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => Column(
                children: [
                  const Expanded(child: TodayScreen()),
                  TextButton(
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => Scaffold(
                          appBar: AppBar(title: const Text('Plan')),
                          body: PlanScreen(
                            store: _FakeWeekPlanStore(),
                            profileStore: _FakeProfileStore(),
                            suggestions: AssistantPlanSuggestionSource(
                              assistant: ref.read(assistantProvider),
                            ),
                            assistant: ref.read(assistantProvider),
                          ),
                        ),
                      ),
                    ),
                    child: const Text('Open Plan'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. Meals (TodayScreen retry uses overridden assistantProvider).
    await tester.ensureVisible(find.text('Retry AI estimate'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry AI estimate'));
    await tester.pumpAndSettle();
    expect(api.requests, hasLength(1));

    // 2. Check-in uses overridden assistantProvider and activeProviderLabel.
    await tester.tap(find.text('Weekly check-in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask Salu to explain'));
    await tester.pumpAndSettle();
    expect(find.textContaining('OpenAI'), findsOneWidget);
    await tester.tap(find.text('Explain'));
    await tester.pumpAndSettle();
    expect(api.requests, hasLength(2));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    // 3. Planning uses overridden assistantProvider.
    await tester.tap(find.text('Open Plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Suggest meals & groceries'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Request suggestions'));
    await tester.pumpAndSettle();
    expect(api.requests, hasLength(3));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets(
      'TodayScreen surfaces distinct recovery actions for busy, notConnected, quotaExceeded, and unknown error codes',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final mealRepo = DriftPhotoMealRepository(db);
    final statusStore = MealEstimateStatusStore(db);
    final date = DiaryDate.parse('2026-11-19');

    Future<void> addMealWithError(String id, String errorCode) async {
      final meal = PhotoMeal(
        id: id,
        date: date,
        slot: MealSlot.lunch,
        caption: 'Meal $id',
        createdAt: DateTime.utc(2026, 11, 19, 12),
        estimateStatus: MealEstimateStatus.pending,
      );
      await mealRepo.saveNew(meal);
      await statusStore.finish(
        meal.copyWith(estimateStatus: MealEstimateStatus.unavailable),
        1,
        errorCode: errorCode,
      );
    }

    await addMealWithError('m-busy', 'busy');
    await addMealWithError('m-disc', 'notConnected');
    await addMealWithError('m-quota', 'quotaExceeded');
    await addMealWithError('m-future', 'brandNewFutureCode');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          todayDiaryDateProvider.overrideWithValue(date),
          diarySelectionProvider.overrideWith((ref) => date),
          todayMealsProvider.overrideWith((ref) => mealRepo.watchFor(date)),
          entryRepositoryProvider.overrideWithValue(_FakeEntryRepository()),
        ],
        child: const MaterialApp(home: Scaffold(body: TodayScreen())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Wait and retry AI estimate'),
      200,
    );
    expect(find.text('Wait and retry AI estimate'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Open AI connections'),
      200,
    );
    expect(find.text('Open AI connections'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Switch or check connection'),
      200,
    );
    expect(find.text('Switch or check connection'), findsOneWidget);

    final unavailableMessage =
        const SaluAssistantException(SaluAssistantErrorCode.serviceUnavailable)
            .message;
    await tester.scrollUntilVisible(
      find.text(unavailableMessage),
      200,
    );
    expect(find.text(unavailableMessage), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });

  test('parseMealEstimate parameterizes provenance without hardcoding OpenAI',
      () {
    final reply = {
      'items': [
        {
          'name': 'Soup',
          'portion': {'amount': 200, 'unit': 'millilitres'},
          'nutrients': {'energy_kcal': 120},
        },
      ],
    };

    final defaultItems = parseMealEstimate(reply);
    expect(defaultItems.single.source, 'ai-meal-estimate');
    expect(
      (defaultItems.single.nutrients[NutrientKey.energyKcal]
              as NutrientEstimated)
          .basis,
      'ai-meal-estimate',
    );

    final anthropicItems = parseMealEstimate(
      reply,
      provenance: 'anthropicMessages-meal-estimate',
    );
    expect(anthropicItems.single.source, 'anthropicMessages-meal-estimate');
    expect(
      (anthropicItems.single.nutrients[NutrientKey.energyKcal]
              as NutrientEstimated)
          .basis,
      'anthropicMessages-meal-estimate',
    );
  });

  testWidgets(
      'SettingsScreen shows active endpoint profile and opens ConnectionsScreen',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final profilesStore = EndpointProfilesStore(LocalDocumentStore(db));
    final creds = _MemoryCredentialStore();
    final controller = ConnectionsController(
      profilesStore,
      creds,
      isChatGptConnected: () async => false,
    );

    await controller.saveProfile(
      EndpointProfile(
        id: 'p1',
        name: 'Claude Endpoint',
        protocol: EndpointProtocol.anthropicMessages,
        apiRoot: Uri.parse('https://api.anthropic.com/v1'),
        credentialRef: 'salu.endpoint.p1.1',
        modelId: 'claude-sonnet-4-5',
      ),
      newKey: _fakeKey1,
    );
    await controller.select('p1');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          credentialStoreProvider.overrideWithValue(creds),
          connectionsControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(home: Scaffold(body: SettingsScreen())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Active: Claude Endpoint'), findsOneWidget);
    await _scrollAndTap(tester, find.text('Manage AI connections'));
    expect(find.text('AI connections'), findsOneWidget);
  });

  test(
      'disconnectChatGpt serializes with profile store and checks CAS save result',
      () async {
    final interceptor = _CasConflictInterceptor();
    final db = AppDatabase(NativeDatabase.memory().interceptWith(interceptor));
    addTearDown(db.close);
    final profilesStore = EndpointProfilesStore(LocalDocumentStore(db));
    final writeGate = Completer<void>();
    var gatingWrites = false;
    final creds = _MemoryCredentialStore()
      ..onWrite = (_) async {
        if (gatingWrites && !writeGate.isCompleted) {
          await writeGate.future;
        }
      };

    var chatGptConnected = true;
    var signOutCalls = 0;
    final controller = ConnectionsController(
      profilesStore,
      creds,
      isChatGptConnected: () async => chatGptConnected,
      signOutChatGpt: () async {
        signOutCalls++;
        chatGptConnected = false;
      },
    );
    addTearDown(controller.dispose);

    await controller.select(EndpointProfile.reservedChatGptId);
    expect(controller.activeId, EndpointProfile.reservedChatGptId);

    // 1. Repeated CAS failures throw StateError without claiming disconnected.
    interceptor.conflictOnPutRemaining = 10;
    await expectLater(controller.disconnectChatGpt(), throwsStateError);
    interceptor.conflictOnPutRemaining = 0;
    expect(controller.activeId, EndpointProfile.reservedChatGptId);
    expect(signOutCalls, 0);

    // 2. Single CAS mismatch retries cleanly.
    interceptor.conflictOnPutRemaining = 1;
    await controller.disconnectChatGpt();
    expect(signOutCalls, 1);
    expect(controller.activeId, isNull);
    expect(controller.chatGptConnected, isFalse);

    // 3. Serialization waits for an in-flight profile save before
    //    disconnecting ChatGPT.
    chatGptConnected = true;
    await controller.select(EndpointProfile.reservedChatGptId);
    gatingWrites = true;
    final saveFuture = controller.saveProfile(
      EndpointProfile(
        id: 'p1',
        name: 'Profile 1',
        protocol: EndpointProtocol.openaiChat,
        apiRoot: Uri.parse('https://one.example/v1'),
        credentialRef: 'salu.endpoint.p1.1',
      ),
      newKey: _fakeKey1,
    );
    await Future<void>.delayed(Duration.zero);

    var disconnectFinished = false;
    final disconnectFuture = controller.disconnectChatGpt().whenComplete(() {
      disconnectFinished = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(disconnectFinished, isFalse);
    expect(signOutCalls, 1);

    writeGate.complete();
    await saveFuture;
    await disconnectFuture;

    expect(signOutCalls, 2);
    expect(controller.activeId, isNull);
    expect(controller.chatGptConnected, isFalse);
    expect((await profilesStore.load()).activeId, isNull);
    expect(controller.profiles, hasLength(1));
  });

  test(
      'removeProfile during in-flight discover/testConnection leaves no ghost status or models',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final profilesStore = EndpointProfilesStore(LocalDocumentStore(db));
    final creds = _MemoryCredentialStore();
    final fence = OperationFence();

    final discoverStarted = Completer<void>();
    final discoverFinish = Completer<List<DiscoveredModel>>();
    final controller = ConnectionsController(
      profilesStore,
      creds,
      fence: fence,
      onInvalidate: fence.invalidate,
      discoverModelsCallback: (_, __, ___, ____) {
        if (!discoverStarted.isCompleted) discoverStarted.complete();
        return discoverFinish.future;
      },
    );
    addTearDown(controller.dispose);

    await controller.saveProfile(
      EndpointProfile(
        id: 'p1',
        name: 'Ephemeral',
        protocol: EndpointProtocol.openaiChat,
        apiRoot: Uri.parse('https://ephemeral.example/v1'),
        credentialRef: 'salu.endpoint.p1.1',
      ),
      newKey: _fakeKey1,
    );

    final pendingDiscover = controller.discover('p1');
    await discoverStarted.future;

    await controller.removeProfile('p1');
    expect(controller.profiles, isEmpty);

    discoverFinish.complete(
      const [DiscoveredModel(id: 'm1', name: 'Model 1')],
    );
    await pendingDiscover;

    expect(controller.discoveredModelsFor('p1'), isEmpty);
    expect(controller.statusFor('p1').outcome, ConnectionCheckOutcome.untested);

    // Same protection holds when an in-flight testConnection errors after removal.
    await controller.saveProfile(
      EndpointProfile(
        id: 'p2',
        name: 'Ephemeral 2',
        protocol: EndpointProtocol.openaiChat,
        apiRoot: Uri.parse('https://ephemeral2.example/v1'),
        credentialRef: 'salu.endpoint.p2.1',
      ),
      newKey: _fakeKey1,
    );
    final testStarted = Completer<void>();
    final testFinish = Completer<List<DiscoveredModel>>();
    final controller2 = ConnectionsController(
      profilesStore,
      creds,
      fence: fence,
      onInvalidate: fence.invalidate,
      discoverModelsCallback: (_, __, ___, ____) {
        if (!testStarted.isCompleted) testStarted.complete();
        return testFinish.future;
      },
    );
    addTearDown(controller2.dispose);
    await controller2.load();

    final pendingTest = controller2.testConnection('p2');
    await testStarted.future;
    await controller2.removeProfile('p2');
    testFinish.completeError(
      const SaluAssistantException(SaluAssistantErrorCode.timeout),
    );
    await expectLater(pendingTest, throwsA(isA<SaluAssistantException>()));
    expect(
      controller2.statusFor('p2').outcome,
      ConnectionCheckOutcome.untested,
    );
  });

  testWidgets(
      'disconnecting an active BYOK profile in SettingsScreen clears activeId without signing out ChatGPT',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final profilesStore = EndpointProfilesStore(LocalDocumentStore(db));
    final creds = _MemoryCredentialStore();
    final fence = OperationFence();
    var chatGptConnected = true;
    var chatGptSignOutCalls = 0;

    final controller = ConnectionsController(
      profilesStore,
      creds,
      fence: fence,
      onInvalidate: fence.invalidate,
      isChatGptConnected: () async => chatGptConnected,
      signOutChatGpt: () async {
        chatGptSignOutCalls++;
        chatGptConnected = false;
      },
    );

    await controller.saveProfile(
      EndpointProfile(
        id: 'p1',
        name: 'Claude Endpoint',
        protocol: EndpointProtocol.anthropicMessages,
        apiRoot: Uri.parse('https://api.anthropic.com/v1'),
        credentialRef: 'salu.endpoint.p1.1',
        modelId: 'claude-sonnet-4-5',
      ),
      newKey: _fakeKey1,
    );
    await controller.select('p1');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          credentialStoreProvider.overrideWithValue(creds),
          operationFenceProvider.overrideWithValue(fence),
          connectionsControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(home: Scaffold(body: SettingsScreen())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Active: Claude Endpoint'), findsOneWidget);
    await _scrollAndTap(tester, find.text('Disconnect'));

    expect(controller.activeId, isNull);
    expect((await profilesStore.load()).activeId, isNull);
    expect(chatGptConnected, isTrue);
    expect(chatGptSignOutCalls, 0);
    expect(find.text('Not connected'), findsOneWidget);

    // Also verify InferenceGateway.disconnect() preserves ChatGPT when a BYOK
    // profile was active.
    await controller.select('p1');
    final fakeChatGptKeyStore = _FakeKeyStore('chatgpt-session-present');
    final gateway = InferenceGateway(
      profiles: profilesStore,
      credentials: creds,
      transport: EndpointTransport(),
      fence: fence,
      chatGpt: SaluAssistant(keyStore: fakeChatGptKeyStore, fence: fence),
    );
    await gateway.disconnect();
    expect((await profilesStore.load()).activeId, isNull);
    expect(await fakeChatGptKeyStore.read(), 'chatgpt-session-present');
  });
}

final class _FakeKeyStore implements SaluAssistantKeyStore {
  _FakeKeyStore(this._value);
  String? _value;
  @override
  Future<String?> read() async => _value;
  @override
  Future<void> write(String key) async => _value = key;
  @override
  Future<void> delete() async => _value = null;
}
