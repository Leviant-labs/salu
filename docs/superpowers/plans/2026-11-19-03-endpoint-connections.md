# Endpoint Connections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Support user-configured OpenAI/Anthropic-compatible endpoints with secure keys, model discovery and bounded inference, alongside ChatGPT sign-in.

**Architecture:** Persist nonsecret connection profiles in the data package and keys in an app-side secure-store adapter. Explicit protocol adapters feed the existing untrusted task parsers through an injected `SaluAssistant` facade; no nutrition logic depends on a provider.

**Tech Stack:** Flutter 3.44.0, Riverpod, Drift documents, flutter_secure_storage, dart:io HTTP, existing ChatGPT OAuth/JWT implementation.

**Spec:** `docs/superpowers/specs/2026-11-19-salu-improvements-design.md`, sections 2 and 5. Confirm the retain-ChatGPT assumption before execution.

## Global Constraints

- Flutter is pinned to `3.44.0`; Dart is the version bundled with that Flutter SDK.
- `salu_core` depends only on the Dart SDK; Flutter, SQLite, filesystem, cryptography, and HTTP adapters stay outside it.
- Unknown, trace, reported, measured, and estimated nutrition states survive writes, migrations, exports, and restoration.
- New meals save locally before optional inference; corrections and plan changes require review and revision-checked confirmation.
- Connecting, discovering models, restarting, or restoring never authorizes a meal/photo upload or automatic provider failover.
- Credentials live in platform secure storage and never enter ordinary documents, logs, fixtures, CSV, or archives.
- Automatic targets and adaptive expenditure remain gated; all onboarding health inputs and AI setup are optional.
- Preserve existing user changes, especially untracked `app/android/`, `app/ios/`, and `linked_list_merge/`; never stage them wholesale.

---

## File structure

- Core `providers/endpoint_profile.dart`: protocol, discovery mode, validated nonsecret profile and model descriptors.
- Data `repositories/endpoint_profiles_store.dart`: version-1 documents and revision-safe selection.
- App `assistant/credential_store.dart`: secure slot interface/implementation; no DB dependency.
- App `assistant/endpoint_transport.dart`, `operation_fence.dart`: bounded same-origin network I/O and cancellation epochs.
- App `assistant/model_discovery.dart`, `protocol_adapters.dart`, `sse_decoder.dart`: explicit discovery/wire formats.
- App `assistant/inference_gateway.dart`: selected-profile dispatch and error normalization.
- App `features/settings/connections_controller.dart`, `connections_screen.dart`: profile editing and explicit test/discovery.
- Existing `assistant.dart`: migration facade, not another global provider registry.

### Task 1: Profiles, model selection and secure credential lifecycle

**Files:** Create `packages/salu_core/lib/src/providers/endpoint_profile.dart`, `packages/salu_data/lib/src/repositories/endpoint_profiles_store.dart`, `app/lib/src/assistant/credential_store.dart`, `app/lib/src/features/settings/connections_controller.dart`; add corresponding `endpoint_profile_test.dart`, `endpoint_profiles_store_test.dart`, `app/test/assistant/credential_store_test.dart`; modify core/data export barrels.

**Interfaces:** Produces `EndpointProtocol { openaiChat, openaiResponses, anthropicMessages }`, `ModelDiscoveryMode { models, catalogue, manual }`; `EndpointProfile({required String id, required String name, required EndpointProtocol protocol, required Uri apiRoot, required String credentialRef, String? modelId, ModelDiscoveryMode discovery=ModelDiscoveryMode.models, bool allowInsecureLocal=false, bool? imageInput})` with identically named final fields and `toJson/fromJson`. Model IDs must be nonempty, at most 256 characters and contain no control characters. Profile IDs are opaque IDs, never derived from keys.

`EndpointProfilesStore(LocalDocumentStore documents)` exposes `Future<({int revision,List<EndpointProfile> profiles,String? activeId})> load()` and `Future<bool> save({required int expectedRevision,required List<EndpointProfile> profiles,required String? activeId})`. `activeId` is null, `chatgpt-plan`, or an existing profile ID. `CredentialStore` exposes `Future<String?> read(String ref)`, `Future<void> write(String ref,String secret)`, `Future<void> delete(String ref)`, `Future<void> clearSaluCredentials()`. `SecureCredentialStore` uses only `salu.*` slots. `ConnectionsController(EndpointProfilesStore profiles,CredentialStore credentials)` exposes `Future<void> saveProfile(EndpointProfile profile,{String? newKey})`, `Future<void> removeProfile(String id)`, `Future<void> select(String? id)`; profile construction is task-owned pure metadata, saving never calls HTTP.

- [ ] **Step 1: Write the red secret-exclusion test.**

```dart
import 'dart:convert';
import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

void main() {
  test('serialized connection contains a slot reference, never a key', () {
    final profile = EndpointProfile(id: 'home', name: 'Home server',
        protocol: EndpointProtocol.openaiChat,
        apiRoot: Uri.parse('https://inference.example/v1'),
        credentialRef: 'salu.endpoint.home.1', modelId: 'vision-test');
    final json = jsonEncode(profile.toJson());
    expect(json, contains('salu.endpoint.home.1'));
    expect(jsonDecode(json), isNot(contains('apiKey')));
    expect(EndpointProfile.fromJson(jsonDecode(json)).apiRoot, profile.apiRoot);
  });
}
```

Run core `dart test test/endpoint_profile_test.dart`; expect missing type. Add cases for malformed URLs, duplicate profile IDs, missing selected IDs, future document versions, failed secure writes/deletes and destination changes that require a new key. Use in-memory `CredentialStore` in app tests with a `Map<String,String>` and exact interface implementations; no real secrets or plugins.
- [ ] **Step 2: Implement metadata and staged secret writes.** Validate lengths (name 80, API root 2,048, key 4,096 characters), reject CR/LF in keys, require same-origin relative paths and reject URL userinfo/query/fragment. Persist `endpoint-connections` with version 1 and CAS revision. For a new/replaced key: create a fresh `salu.endpoint.<id>.<generation>` slot, write it, then commit the profile reference; if commit fails remove the new slot, retain the old profile and key. Only retire the previous slot after a successful commit. Track dynamic slots and deferred owned-slot cleanup in a secure-storage manifest, and explicitly include pre-existing `salu.*` keys (`salu.assistant.openai.api_key`, `salu.chatgpt.session.v1`, `salu.chatgpt.host.v1`, `salu.chatgpt.welcome`) in `clearSaluCredentials()` so erasure does not depend solely on `FlutterSecureStorage.readAll()`; never copy keys into that manifest or the DB. Origin/protocol change requires `newKey`. Removal first invalidates/cancels operations (Task 2 supplies the fence), then removes profile/reference, then cleans its secret. No failing credential operation may appear connected in UI.
- [ ] **Step 3: Run green and persistence regression.** Run all three new test files and the root check. Assert a test key string never occurs in raw `local_documents.payload`, exceptions, or `toString()` output. No network factory may be created by load/save/select.
- [ ] **Step 4: Commit.**

```bash
git add packages/salu_core/lib/src/providers/endpoint_profile.dart packages/salu_core/lib/salu_core.dart packages/salu_core/test/endpoint_profile_test.dart packages/salu_data/lib/src/repositories/endpoint_profiles_store.dart packages/salu_data/lib/salu_data.dart packages/salu_data/test/endpoint_profiles_store_test.dart app/lib/src/assistant/credential_store.dart app/lib/src/features/settings/connections_controller.dart app/test/assistant/credential_store_test.dart
git commit -m "feat: store named endpoint profiles with secure credential references"
```

### Task 2: Bounded transport, cancellation and terminal SSE handling

**Files:** Create `app/lib/src/assistant/endpoint_transport.dart`, `operation_fence.dart`, `sse_decoder.dart`, `app/test/assistant/endpoint_transport_test.dart`, `sse_decoder_test.dart`; modify `chatgpt_session.dart:31–142,163–233,275–302`, `assistant.dart:167–233,409–451`.

**Interfaces:** `OperationFence` has `int capture()`, `bool isCurrent(int epoch)`, `void invalidate()`, and `void Function() onInvalidate(void Function() abort)` returning an unregister callback. `EndpointTransport({HttpClient Function()? clientFactory,Duration timeout=const Duration(seconds:45)})` exposes `Future<Map<String,dynamic>> send({required Uri uri,required String method,required Map<String,String> headers,Map<String,Object?>? body,required bool allowInsecureLocal,required OperationFence fence,int maxBytes=524288})`. `SseDecoder` exposes `Map<String,dynamic>? add(String chunk)` and `void finish()`; it bounds 512 KiB total UTF-8 event bytes and returns only a terminal `response.completed.response` envelope, rejecting error/incomplete events. `finish` fails if no successful terminal event has been observed. The transport accepts raw UTF-8 chunks through a streaming decoder, not per-chunk `utf8.decode`.

- [ ] **Step 1: Write red bounded/cancellation tests.** One complete decoder regression:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/assistant/sse_decoder.dart';

void main() {
  test('terminal event completes without waiting for EOF', () {
    final decoder = SseDecoder();
    expect(decoder.add('data: {"type":"response.com'), isNull);
    final result = decoder.add('pleted","response":{"status":"completed"}}\n\n');
    expect(result!['status'], 'completed');
  });
}
```

Run app `flutter test --no-pub test/assistant/sse_decoder_test.dart`; expect missing decoder. In transport tests create a loopback `HttpServer` with test-only local opt-in. Test stalled connect/headers/body, chunked over-limit bodies, 307 to a second server receiving zero requests, cancellation during secure-key wait and stream read, CRLF headers rejected locally, UTF-8 split across chunks, CRLF/multiline SSE and EOF without completion. Give the tests short injected deadlines (50–100ms), not production-duration sleeps. Preserve all existing assistant tests.
- [ ] **Step 2: Implement shared deadlines and fences.** Capture the fence before awaiting credentials; register each new client for force-close on invalidation; check current epoch immediately before adding request bytes and after parsing. Set `followRedirects=false`, connection timeout 10s, bounded streamed body reader, safe status-to-error mapping and a single deadline for all awaited stages. DNS resolve HTTP local destinations and verify allowed address classes; disable proxies for explicitly local HTTP so keys cannot be sent to a system proxy. Do not disable TLS validation. Refactor ChatGPT `signIn()` (closing its loopback `HttpServer` on fence invalidation and routing token exchange plus JWKS fetch through bounded transport rather than unbounded `addKeySetUrl` / `_postForm`), refresh, and model lookup to use bounded reads and the same remaining deadline; model discovery is not repeated on every generation once a model is selected. Extract the old successful SSE parsing semantics into the decoder and complete on terminal events even if the server keeps the socket open. Map network/timeouts as such, not uniformly `authenticationFailed`. `OperationFence.invalidate()` increments before aborting subscribers; late futures cannot authorize a request or a diary write.
- [ ] **Step 3: Run green and old assistant regressions.** Run `flutter test --no-pub test/assistant test/assistant_test.dart`; verify no raw provider-body output in errors. Assert a held-open terminal stream completes promptly and all clients close after error/cancel.
- [ ] **Step 4: Commit.**

```bash
git add app/lib/src/assistant/endpoint_transport.dart app/lib/src/assistant/operation_fence.dart app/lib/src/assistant/sse_decoder.dart app/lib/src/assistant/chatgpt_session.dart app/lib/src/assistant/assistant.dart app/test/assistant/endpoint_transport_test.dart app/test/assistant/sse_decoder_test.dart
git commit -m "fix: bound provider operations and cancel stale streamed requests"
```

### Task 3: Protocol adapters and explicit model discovery

**Files:** Create `app/lib/src/assistant/protocol_adapters.dart`, `model_discovery.dart`, `inference_gateway.dart`, `app/test/assistant/protocol_adapters_test.dart`, `model_discovery_test.dart`; modify `packages/salu_core/lib/src/providers/inference.dart` to add the planning task and a separate trusted instructions field without removing existing enum values or required arguments.

**Interfaces:** Add `String instructions=''` to the `InferenceRequest` constructor and a final `instructions` field; keep `prompt` as untrusted user content and all current required fields. `DiscoveredModel({required String id,required String name})`; `Future<List<DiscoveredModel>> discoverModels(EndpointProfile profile,CredentialStore credentials,EndpointTransport transport,OperationFence fence)`; `Uri endpointUri(Uri root,String relativePath)`; `Map<String,Object?> encodeGeneration(EndpointProfile profile,InferenceRequest request)`; `Map<String,dynamic> decodeGeneration(EndpointProtocol protocol,Map<String,dynamic> envelope)`; `InferenceGateway({required EndpointProfilesStore profiles,required CredentialStore credentials,required EndpointTransport transport,required OperationFence fence,required SaluAssistant chatGpt})` exposes `Future<bool> get isConnected`, `Future<String?> get activeProviderLabel`, `Future<Map<String,dynamic>> ask({required String instructions,required String prompt,List<Uint8List> images=const [],InferenceTask task=InferenceTask.mealPhoto,String? requestId})`, `Future<void> disconnect()`. Gateway detects exact JPEG/PNG magic bytes to build typed `ImageAttachment(bytes, mimeType)` (rejecting unsupported image bytes before sending) and forwards `task`, `requestId`, and `instructions` into `InferenceRequest`. Preserve the existing `SaluAssistant.ask` call shape with optional `task`/`requestId` parameters. Gateway is the production dispatch facade; the injected legacy `chatGpt` must be constructed without a gateway to avoid recursion. Own-key adapters implement `InferenceProvider` and accept the new `InferenceTask.planSuggestions` too.

- [ ] **Step 1: Write red path/serializer/discovery tests.**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/assistant/protocol_adapters.dart';

void main() {
  test('API root prefix survives endpoint joining', () {
    final root = Uri.parse('https://gateway.example/team/v1');
    expect(endpointUri(root, 'chat/completions').toString(),
        'https://gateway.example/team/v1/chat/completions');
    expect(endpointUri(root, 'models').toString(),
        'https://gateway.example/team/v1/models');
  });
}
```

Run app `flutter test --no-pub test/assistant/protocol_adapters_test.dart`; expect missing adapter. Add raw HTTP fixtures for each protocol, unknown models, refusal, partial responses, valid JSON arrays rejected, text-only models rejecting images, discovery 401/403/404/405/429, both supported catalogue shapes, duplicate IDs, pagination loops and byte/page/item limits. Fixtures contain fake keys only. Assert discovery makes GET requests, never generation POST requests.
- [ ] **Step 2: Implement explicit wire contracts.** Keep `request.instructions` in the trusted developer/system channel and `request.prompt`/images in user content for every protocol; never promote captions, OCR or food names into system instructions. Assert those boundaries in wire-fixture tests. OpenAI Chat posts `model`, `messages` with system instructions and user text/image parts, bounded `max_tokens`; accept exactly the completed assistant content from the first valid choice and reject `finish_reason:length`. Responses uses the existing `input`/`output` contract, `store:false`, JSON output mode when supported. Anthropic posts `model`, `max_tokens:2048`, top-level `system`, user content blocks and base64 image sources; accept text blocks only with a successful stop reason, reject `max_tokens`, tool-use and refusal/invalid JSON. Use Bearer headers for OpenAI, `x-api-key` plus `anthropic-version:2023-06-01` for Anthropic. Do not silently retry using a different protocol or omit an image the user consented to send. Validate the normalized JSON object for depth/nonfinite values and accidental credential reflection before returning it.

Discovery calls only relative `models` or `catalogue` at the configured root. Parse the exact shared-design shapes, enforce 10 pages/2,000 IDs/1 MiB per page/15-second overall deadline, and validate any pagination URL stays same-origin and under the root prefix. Use `after_id` for supported Anthropic ID pagination; otherwise accept an explicit same-origin `next` URL or a terminal page. Unknown pagination shape returns an actionable discovery error with manual entry available; no endpoint-path guessing. Treat image capability as unverified unless explicitly declared; selecting a model never probes it with meal data. Gateway uses only `activeId` and saved model; no provider/model auto-fallback. ChatGPT remains an adapter choice, not an app account requirement.
- [ ] **Step 3: Verify green protocol contract tests.** Run the two new files plus all assistant tests. Capture outbound method/path/headers/body at a loopback server; assert keys are absent from parsed results and error strings, wrong-origin discovery receives no request, and no profile selection sends user content.
- [ ] **Step 4: Commit.**

```bash
git add app/lib/src/assistant/protocol_adapters.dart app/lib/src/assistant/model_discovery.dart app/lib/src/assistant/inference_gateway.dart app/test/assistant/protocol_adapters_test.dart app/test/assistant/model_discovery_test.dart packages/salu_core/lib/src/providers/inference.dart
git commit -m "feat: add explicit OpenAI and Anthropic adapters with model discovery"
```

### Task 4: Connection screens, onboarding hook and injected feature use

**Files:** Create `app/lib/src/features/settings/connections_screen.dart`, `app/test/settings/connections_screen_test.dart`, `packages/salu_data/lib/src/repositories/meal_estimate_status_store.dart`, `packages/salu_data/test/meal_estimate_status_store_test.dart`; modify `connections_controller.dart`, `app/lib/src/providers.dart:11`, `assistant/assistant.dart:38–73,107`, `features/settings/settings_screen.dart`, `router.dart`, `features/today/today_screen.dart`, `features/today/check_in_screen.dart`, `features/search/search_screen.dart`, `features/plan/plan_suggestions.dart`, `features/meals/meal_estimation.dart`, `features/meals/meal_editor_ai.dart:80–109`, `features/onboarding/onboarding_wizard.dart`, data export barrel, `README.md`, `docs/architecture.md`, `docs/platform-release-checklist.md`.

**Interfaces:** Add optional `InferenceGateway? gateway` to `SaluAssistant` while keeping existing constructors/ask/key-test behavior when it is absent. Production `assistantProvider` constructs one gateway-backed facade per provider scope; use `ref.watch/read(assistantProvider)` at every production caller and remove both the global `saluAssistant` singleton and the module-level `activeMealEstimates` singleton (scoping active-estimate tracking to a Riverpod provider/controller cleared on dispose and reset). `ConnectionsScreen` accepts `ConnectionsController` and discovery/test callbacks. Controller adds `Future<List<DiscoveredModel>> discover(String id)` and `Future<void> testConnection(String id)`; Test connection performs only bounded credential/discovery availability checks and clearly says generation/image access is not verified. Onboarding uses Task 2 plan's `openConnections` callback.

- [ ] **Step 1: Write the failing connection widget test.** With real in-memory profile documents and an in-memory `CredentialStore`, mount the screen and enter fake metadata/key; assert the key is obscured and no discovery occurs until tapped. Add a complete small UI seam test:

```dart
testWidgets('onboarding can finish without connecting AI', (tester) async {
  final db = AppDatabase.memory();
  addTearDown(db.close);
  final documents = LocalDocumentStore(db);
  final store = OnboardingStore(documents);
  await store.save(OnboardingDraft(step: OnboardingStep.aiSetup));
  var opened = false;
  await tester.pumpWidget(MaterialApp(home: OnboardingWizard(store: store,
      onCompleted: () {}, openConnections: (_) async => opened = true)));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Skip this step'));
  await tester.pumpAndSettle();
  expect(opened, isFalse);
  expect(find.text('Review your setup'), findsOneWidget);
});
```

Place this in `app/test/onboarding/onboarding_wizard_test.dart` using its Task 2 imports plus `salu_core`. Run both widget files red. Add edit/remove/select, 404/manual ID, disconnected/busy states, hidden key after save, endpoint change warning, failed discovery retry, and no implicit fallback tests. Test an assistant-provider override reaches meals, planning and check-in without touching real storage.
- [ ] **Step 2: Wire UI and safe task status.** Settings lists ChatGPT and endpoint profiles, active selection, protocol/root, selected model and observed connection state. New/Edit collects protocol, API root, masked key, discovery mode, local HTTP opt-in and model selection; provide explicit Save, Discover models, Test connection and Remove actions. Never display a saved key or call generation on Save. Consent copy (including `check_in_screen.dart:105`) uses actual provider display name and destination, not hard-coded OpenAI, and states user-funded billing may apply. Rewrite `SaluAssistantException.message` (`assistant.dart:38–73`) to be provider-agnostic (never saying "OpenAI" or "ChatGPT" when an Anthropic or custom endpoint fails), and parameterize `parseMealEstimate` (`meal_editor_ai.dart:80–109`) so `NutrientEstimated.basis` and `PhotoMealItem.source` record neutral/provider-accurate provenance (e.g. `ai-meal-estimate` or `<provider-protocol>-meal-estimate`) rather than hardcoding `openai-meal-estimate`. Cancel/failure does not erase a working connection.

Pass the injected assistant through route constructors. Remove singleton defaults from `AssistantPlanSuggestionSource` and require an assistant where used in production; update affected tests. Keep `PhotoMeal` and its items JSON shape unchanged for error-status persistence. Add data `MealEstimateStatusStore(AppDatabase db)` with `Future<bool> finish(PhotoMeal updated,int expectedRevision,{String? errorCode})` and `Future<String?> errorFor(String mealId,int revision)`. `finish` transactionally calls revision-checked meal replace and writes version-1 `estimate:<meal-id>` containing only resulting meal revision and a safe error code; a stale replacement writes no status. `errorFor` ignores a status for another revision. The app validates codes against `SaluAssistantErrorCode` and treats unknown future codes as generic unavailable. Tests cover stale revisions, restart persistence and no raw error text. Busy, disconnected and quota errors get distinct recovery actions; user retries remain explicit. Restore/erase will call the same fence in plan 5.
- [ ] **Step 3: Verify full integration and document compatibility honestly.** Run onboarding, settings, assistant, meal editor, plan and Today tests plus root checks. Update README/architecture to describe BYOK versus ChatGPT separately and reconcile obsolete API-key-only prose. Device checklist covers loopback/private HTTP opt-in, actual HTTPS provider image input, browser cancel/return, token refresh and account changes. Mark real-service compatibility unverified until tested with opt-in credentials outside chat/fixtures; never ask for a key in the conversation.
- [ ] **Step 4: Commit exact UI/wiring files.**

```bash
git add app/lib/src/features/settings app/lib/src/assistant/assistant.dart app/lib/src/providers.dart app/lib/src/router.dart app/lib/src/features/today app/lib/src/features/search/search_screen.dart app/lib/src/features/plan/plan_suggestions.dart app/lib/src/features/meals/meal_estimation.dart app/lib/src/features/meals/meal_editor_ai.dart app/lib/src/features/onboarding/onboarding_wizard.dart app/test/settings app/test/onboarding packages/salu_data/lib/src/repositories/meal_estimate_status_store.dart packages/salu_data/test/meal_estimate_status_store_test.dart packages/salu_data/lib/salu_data.dart README.md docs/architecture.md docs/platform-release-checklist.md
git commit -m "feat: configure AI connections in settings and optional onboarding"
```
