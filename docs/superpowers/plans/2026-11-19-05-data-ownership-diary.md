# Data Ownership and Reversible Diary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give users safe correction, delete/undo, portable encrypted backups, CSV export and resumable local erasure.

**Architecture:** Revision-checked commands and a SQLite mutation journal protect diary history. An app-owned media store and logical snapshot adapter separate filesystem/crypto work from transactional user-data changes; restore and erase fence async work before replacing data.

**Tech Stack:** Flutter 3.44.0, Drift schema 4, native filesystem/file_selector, crypto SHA-256, archive, cryptography, secure storage.

**Spec:** `docs/superpowers/specs/2026-11-19-salu-improvements-design.md`, sections 2, 7 and 8; depends on endpoint operation fences and recipe codecs from plans 3 and 4.

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

- Core `application/meal_commands.dart`: typed correction/move/delete/undo commands and result statuses.
- Data `codec/photo_meal_codec.dart`, `repositories/meal_mutation_repository.dart`: snapshots and schema-4 journal transactions.
- Data `repositories/user_data_repository.dart`: consistent logical snapshots, validated replacement/erase transactions.
- App `media/managed_media_store.dart`: managed refs, picker intake, resolution, reference-aware collection.
- App `data_transfer/archive_codec.dart`, `archive_crypto.dart`, `archive_service.dart`: bounded archive, encryption and staged restore.
- App `data_transfer/csv_export.dart`, `data_reset_service.dart`, `data_transfer_screen.dart`: human-readable export and explicit data controls.
- `docs/data-lifecycle.md`: retention, password recovery, platform backup and remote-deletion limitations.

### Task 1: Managed media and reference-safe cleanup

**Files:** Create `app/lib/src/media/managed_media_store.dart`, `app/test/media/managed_media_store_test.dart`, `docs/data-lifecycle.md`; modify `app/lib/src/features/meals/meal_editor_images.dart`, `meal_editor.dart`, `meal_editor_dialogs.dart`, `features/today/today_screen.dart`, `app/lib/src/providers.dart`, `app/lib/main.dart`.

**Interfaces:** `ManagedMediaStore({required Future<Directory> Function() directory,required String Function() newId})` with `Future<String> importImage(XFile image)`, `Future<File?> resolve(String reference)`, `Future<void> collect(Set<String> referenced,{required DateTime olderThanUtc})`, `Future<void> removeUnreferenced(String reference,Set<String> referenced)`, `Future<List<XFile>> recoverLostPickerImages()`. Returned refs are `media:<opaque-id>`, filenames are `<opaque-id>.image` in the app-owned `meal-images` directory. `Future<Uint8List> encodeMealUpload(String reference,{required ManagedMediaStore media})` resolves via the service and retains the existing metadata-stripping encoder.

- [ ] **Step 1: Write the red reference-lifecycle test.**

```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:salu/src/media/managed_media_store.dart';

void main() {
  test('collector never removes a referenced image', () async {
    final root = await Directory.systemTemp.createTemp('salu-media-');
    addTearDown(() => root.delete(recursive: true));
    final input = File('${root.path}/input.png');
    await input.writeAsBytes([137,80,78,71,13,10,26,10]);
    final media = ManagedMediaStore(
        directory: () async => Directory('${root.path}/owned'), newId: () => 'test-photo');
    final ref = await media.importImage(XFile(input.path));
    expect(ref, 'media:test-photo');
    await media.collect({ref}, olderThanUtc: DateTime.utc(2100));
    expect(await (await media.resolve(ref))!.exists(), isTrue);
    expect(await input.exists(), isTrue);
  });
}
```

Run app `flutter test --no-pub test/media/managed_media_store_test.dart`; expect missing service. Add traversal/absolute ref rejection, nonexistent file, collision/no overwrite, failed copy cleanup, old app-owned absolute path resolution, out-of-root path denial, unreferenced-only cleanup and picker process-death recovery. This fixture tests ownership, not PNG decoding; encoder tests use valid image bytes already available in meal-editor tests.
- [ ] **Step 2: Implement and migrate access sites.** Create files exclusively, copy before returning a ref and delete only failed owned staging files. Validate opaque IDs (`[A-Za-z0-9_-]{1,128}`), never concatenate untrusted archive names into real paths. Resolve recognized old absolute refs only to the known owned directory/basename; do not read or delete arbitrary external files. Keep old evidence referenced even if its file is missing; show unavailable state. Replace direct `Image.file(File(photoPath))` with a media-resolving widget and inject the service in tests/production. Update all label/image encoders and fakes in the same commit. Collector consumes refs from meals, labels, onboarding/meal drafts and unexpired mutation snapshots (Task 2 adds journal refs); no collection runs until all owners are enumerated. The stored originals remain unchanged until an explicit cleanup/retention choice; uploads stay metadata-stripped. Recovery from `ImagePicker.retrieveLostData()` offers resume/attach/discard, never an automatic upload or intake save. Document retain-until-deletion default and that local originals can retain metadata.
- [ ] **Step 3: Verify green and image regressions.** Run media tests and `flutter test --no-pub test/meals`; test missing image rendering and deny/regrant camera on device. Ensure editor disposal cannot delete a successfully committed or ambiguous-write image.
- [ ] **Step 4: Commit.**

```bash
git add app/lib/src/media/managed_media_store.dart app/lib/src/features/meals app/lib/src/features/today/today_screen.dart app/lib/src/providers.dart app/lib/main.dart app/test/media/managed_media_store_test.dart app/test/meals docs/data-lifecycle.md
git commit -m "feat: manage photo references and recover interrupted picker input"
```

### Task 2: Revisioned move, correction, delete and undo

**Files:** Create `packages/salu_core/lib/src/application/meal_commands.dart`, `packages/salu_data/lib/src/codec/photo_meal_codec.dart`, `repositories/meal_mutation_repository.dart`, `packages/salu_data/test/meal_mutation_test.dart`, `app/test/meals/meal_mutation_ui_test.dart`; modify export barrels, `domain/photo_meal.dart`, data `database/tables.dart`, `database/app_database.dart`, `drift_photo_meal_repository.dart`, app `meal_editor.dart`, `today_screen.dart`, `providers.dart`, `docs/data-lifecycle.md`.

**Interfaces:** `enum MutationStatus { applied,alreadyApplied,stale,notFound,expired,invalidDate }`; `MealMutationResult({required MutationStatus status,PhotoMeal? meal,String? undoToken})`; `sealed class MealCommand` with `String requestId`; `ReviseMeal({required String requestId,required PhotoMeal meal,required int expectedRevision})`, `MoveMeal({required String requestId,required String mealId,required int expectedRevision,required DiaryDate date,required DiaryDate today})`, `DeleteMeal({required String requestId,required String mealId,required int expectedRevision})`, `UndoMeal({required String requestId,required String undoToken})`.

`MealMutationRepository(AppDatabase db,{required Clock clock})` exposes `Future<MealMutationResult> apply(MealCommand command)`, `Future<Set<String>> referencedMedia(DateTime nowUtc)`. `encodePhotoMeal(PhotoMeal)` returns `Map<String,Object?>`; `decodePhotoMeal(Map<String,dynamic>)` accepts legacy and version-1 snapshots. Extend `PhotoMeal.copyWith` with `DiaryDate? date`, `String? photoPath`, `bool clearPhoto=false`; if clearPhoto is true path becomes null, otherwise retain/update existing path. Preserve all existing fields and plan 4's nutrition review issues.

- [ ] **Step 1: Write the red move/undo regression.**

```dart
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

void main() {
  test('move keeps identity and delete undo advances revision', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final meals = DriftPhotoMealRepository(db);
    final mutations = MealMutationRepository(db, clock: const SystemClock());
    final today = DiaryDate.parse('2026-11-19');
    await meals.saveNew(PhotoMeal(id: 'meal', date: today, slot: MealSlot.lunch,
        caption: 'Soup', createdAt: DateTime.utc(2026,11,19), photoPath: 'media:photo'));
    final moved = await mutations.apply(MoveMeal(requestId: 'move', mealId: 'meal',
        expectedRevision: 1, date: today.addDays(-1), today: today));
    expect(moved.meal!.id, 'meal');
    expect(await meals.listFor(today), isEmpty);
    final deleted = await mutations.apply(DeleteMeal(requestId: 'delete',
        mealId: 'meal', expectedRevision: moved.meal!.revision));
    final undone = await mutations.apply(UndoMeal(requestId: 'undo',
        undoToken: deleted.undoToken!));
    expect(undone.status, MutationStatus.applied);
    expect(undone.meal!.revision, greaterThan(moved.meal!.revision));
    expect(undone.meal!.photoPath, 'media:photo');
  });
}
```

Run data `dart test test/meal_mutation_test.dart`; expect missing commands/repository. Add duplicate request IDs with identical/different payloads, stale preview, expired undo via a fake `Clock`, late estimate before deletion/after undo, future-date rejection, concurrent edits and stock-not-replenished tests. Test upgrading real v1/v2/v3 fixture schemas to v4 with user-visible values unchanged.
- [ ] **Step 2: Implement schema-4 journal transactions and UI.** Add `MealMutations` table with request-ID primary key, meal ID, operation, expected/resulting revision, before/after JSON, created-at ms, nullable undo expiry ms and a payload digest. Add to Drift annotation and regenerate (never hand-edit generated output). Upgrade by running existing v1/v2-to-v3 changes then creating the journal, and accept from=3 to=4 explicitly. Every mutation checks duplicate request first; exact replay returns alreadyApplied, changed payload for the same ID returns stale. Compare active row revision and write row+journal in one transaction. Undo reads the deletion journal and latest meal journal entry, verifies the 24-hour deadline/current absence, restores at a strictly higher revision and records its own request. Old estimates cannot match that revision. Photo replace/move update date/photo columns as well as current editable fields; original recording instant/offset never change.

In editor add date/photo change and Delete actions; review shows affected date/slot/items/totals before correction. Capture stable request IDs per action, disable duplicate submissions and refresh on stale. Delete returns to diary, snackbar Undo lasts 10 seconds; failure says why rather than pretending success. Undo references the durable token. Invalidate/watch both old/new dates and check-in results. Keep legacy individual-food rows readable and explicitly outside photo-meal mutation scope until migrated through a separately tested adapter; do not present delete controls that silently do nothing on them. Warn that deleting a batch-derived meal does not replenish stock. Include unexpired journal media in collector refs.
- [ ] **Step 3: Verify green, migration and concurrency tests.** Run data journal/photo/diary suites, app mutation/meal/Today suites and root checks. Add device move/delete/undo/restart cases and assert one original meal ID, no duplicate intake and no lost photo.
- [ ] **Step 4: Commit.**

```bash
git add packages/salu_core/lib/src/application/meal_commands.dart packages/salu_core/lib/src/domain/photo_meal.dart packages/salu_core/lib/salu_core.dart packages/salu_data/lib/src/codec/photo_meal_codec.dart packages/salu_data/lib/src/repositories/meal_mutation_repository.dart packages/salu_data/lib/src/database/tables.dart packages/salu_data/lib/src/database/app_database.dart packages/salu_data/lib/src/repositories/drift_photo_meal_repository.dart packages/salu_data/lib/salu_data.dart packages/salu_data/test/meal_mutation_test.dart app/lib/src/features/meals/meal_editor.dart app/lib/src/features/today/today_screen.dart app/lib/src/providers.dart app/test/meals/meal_mutation_ui_test.dart docs/data-lifecycle.md
git commit -m "feat: add revisioned meal move delete and undo commands"
```

### Task 3: Versioned encrypted archive codec

**Files:** Modify `app/pubspec.yaml` and lockfile; create `app/lib/src/data_transfer/archive_codec.dart`, `archive_crypto.dart`, `app/test/data_transfer/archive_codec_test.dart`, `archive_crypto_test.dart`; update `docs/data-lifecycle.md`.

**Interfaces:** `ArchiveContents({required Map<String,Object?> records,required Map<String,Uint8List> media,required Map<String,Object?> catalogueManifest})`; `Uint8List encodeArchive(ArchiveContents contents)`, `ArchiveContents decodeArchive(Uint8List zipBytes)`; `Future<Uint8List> encryptArchive(Uint8List zipBytes,String password)`, `Future<Uint8List> decryptArchive(Uint8List encrypted,String password)`. Archive format is exactly the shared-design ZIP/envelope, with independently versioned manifest and records format=1. All functions enforce caps before expensive allocation; decoding cannot write files.

- [ ] **Step 1: Write red encryption/authentication tests.**

```dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/data_transfer/archive_crypto.dart';

void main() {
  test('archive authenticates password and randomizes repeated exports', () async {
    final bytes = Uint8List.fromList([1,2,3]);
    const password = 'test-only-password';
    final first = await encryptArchive(bytes, password);
    final second = await encryptArchive(bytes, password);
    expect(first, isNot(orderedEquals(second)));
    expect(await decryptArchive(first, password), orderedEquals(bytes));
    await expectLater(decryptArchive(first, 'wrong-test-password'), throwsA(isA<FormatException>()));
    first[first.length - 1] ^= 1;
    await expectLater(decryptArchive(first, password), throwsA(isA<FormatException>()));
  });
}
```

Run app `flutter test --no-pub test/data_transfer/archive_crypto_test.dart`; expect missing implementation. Archive tests cover unknown formats, duplicate members, `../`, Windows drive/backslash paths, absolute paths, symlinks, hash mismatch, duplicate record IDs, broken evidence refs, ZIP bombs/expanded limits, malformed nutrient states and provider-profile exclusion. Tests use deterministic small fixtures; production salt/nonce randomness is never weakened to speed them up.
- [ ] **Step 2: Implement exact bounded format and encryption.** Add `archive: ^4.0.0`, `cryptography: ^2.7.0` in app only, resolve/lock against the pinned SDK and inspect transitive licence/dependency changes. Use existing SHA-256 to hash each included media object; manifest lists format, schema, per-file size/hash and counts. Member allowlist is `manifest.json`, `records.json`, and `media/<valid-opaque-id>`; reject every other path/member type. Validate compressed file/entry/total expanded sizes while reading, before extracting or decoding oversized strings. Parse records through explicit versioned validators, not arbitrary SQL/table names. Reject missing selected media; records-only archives state media omitted explicitly and restore missing-media placeholders intentionally.

Implement PBKDF2-HMAC-SHA256 at 600,000 iterations and 256-bit output, AES-256-GCM, random 16-byte salt and 12-byte nonce, magic `SALU1`, 16-byte tag and authenticated envelope header. Reject malformed/truncated headers and over-limit payloads before KDF; return only a safe wrong-password-or-corrupt message for authentication failures. Password has at least 12 characters; never log/store it or an exported key. Run codec/crypto through `Isolate.run` in the later service, passing bytes/strings only, with UI busy state and no backup password persistence. Document hard limits and no password recovery, plaintext CSV distinction, and absence of automatic cloud backup promises.
- [ ] **Step 3: Verify green and resource bounds.** Run both test files; check decrypted fixtures preserve unknown/trace/estimated states. Measure large permitted payload memory and KDF latency on target devices; a failure blocks the backup release rather than silently lowering security or dropping photos.
- [ ] **Step 4: Commit.**

```bash
git add app/pubspec.yaml app/pubspec.lock app/lib/src/data_transfer/archive_codec.dart app/lib/src/data_transfer/archive_crypto.dart app/test/data_transfer/archive_codec_test.dart app/test/data_transfer/archive_crypto_test.dart docs/data-lifecycle.md
git commit -m "feat: encode authenticated encrypted user archives"
```

### Task 4: Consistent snapshots and staged replace-only restore

**Files:** Create `packages/salu_data/lib/src/repositories/user_data_repository.dart`, `packages/salu_data/test/user_data_repository_test.dart`, `app/lib/src/data_transfer/archive_service.dart`, `app/lib/src/data_transfer/data_write_gate.dart`, `app/test/data_transfer/archive_service_test.dart`, `app/test/data_transfer/data_write_gate_test.dart`; modify data exports, `app/lib/src/providers.dart`, app meal/onboarding/profile/plan/library/check-in write paths, `docs/data-lifecycle.md`.

**Interfaces:** `UserDataSnapshot({required List<Map<String,Object?>> entries,required List<Map<String,Object?>> entryItems,required List<Map<String,Object?>> meals,required List<Map<String,Object?>> documents,required List<Map<String,Object?>> mutations})` with versioned `toJson/fromJson`. `UserDataRepository(AppDatabase db)` exposes `Future<UserDataSnapshot> snapshot()`, `Future<void> replace(UserDataSnapshot snapshot)`, `Future<void> erase()`. Field maps use explicit schema column names/types, not executable SQL. `DataWriteGate` exposes `bool get blocked`, `Future<T> runWrite<T>(Future<T> Function() work)`, `Future<T> exclusive<T>(Future<T> Function() work)`; it rejects new ordinary writes while an exclusive operation is requested, waits for already-admitted writes to drain and then runs the exclusive operation. Nested exclusive operations are rejected; no app controller bypasses the gate. `ArchiveService({required UserDataRepository data,required ManagedMediaStore media,required OperationFence fence,required CredentialStore credentials,required DataWriteGate gate,required Future<Directory> Function() stagingDirectory})` exposes `Future<Uint8List> export({required String password,required bool includeMedia})`, `Future<RestorePreview> inspect(Uint8List encrypted,String password)`, `Future<void> restore(RestorePreview preview)`; `RestorePreview` holds validated staged content, counts and a content digest, not a persisted password. It is invalidated when its temp staging content changes.

- [ ] **Step 1: Write a red consistent-snapshot test.**

```dart
import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

void main() {
  test('snapshot excludes connection profiles but includes ordinary documents', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final docs = LocalDocumentStore(db);
    await docs.put('endpoint-connections', 0, {'version':1,'activeId':'private-endpoint'});
    await docs.put('day:2026-11-19', 0, {'weightKg':75.5});
    final saved = await UserDataRepository(db).snapshot();
    expect(saved.documents.map((r) => r['id']), contains('day:2026-11-19'));
    expect(saved.documents.map((r) => r['id']), isNot(contains('endpoint-connections')));
  });
}
```

Run data `dart test test/user_data_repository_test.dart`; expect missing adapter. Add full five-table round trip, entry-item foreign keys, migration journal, profile/plan/recipe/batch/draft/check-in documents, unsupported future document rejection and transaction rollback. App tests inject a media-write failure before DB commit and a DB failure after staging; original records/photos remain accessible in both. Test late inference after restore cannot mutate the replacement dataset. Gate tests use Completers to prove admitted writes drain, new writes reject, exclusive failure releases the gate and no nested acquisition deadlocks.
- [ ] **Step 2: Implement snapshots and restore fence.** Snapshot the five user tables in one read transaction; do not raw-copy an open SQLite/WAL file. Enumerate allowed user-document namespaces: planning-profile, onboarding-draft, food-library, recipe-library, cooked-batches, check-in-settings, `day:`, `week:` and `estimate:`. Catalogue edition records go to the manifest, not live user documents on restore. Explicitly exclude endpoint-connections, retired-credential cleanup metadata and system `search-index-state`. Unknown namespace blocks export with a named unsupported-data error; add a codec/classification when new features appear. Preserve replaceable catalogue rows and their local edition/index metadata during restore and erase; clear all user/provider documents, not those nonpersonal system records. Register these system kinds in the same explicit classifier so they never break later exports.

Validate all restored rows/types/uniqueness/references and supported document formats before mutation. Convert archived refs to fresh staged managed IDs, leaving existing media untouched. `restore` verifies the preview digest, requests the app-wide write gate, invalidates inference epochs immediately, waits for admitted writes to drain, persists a cleanup marker, then replaces child/parent tables in foreign-key-safe order inside one transaction. Never interpolate archive-supplied identifiers into SQL. Retain old managed files until commit succeeds; on failure clean only new unreferenced staging and keep the old DB. After commit clear connection metadata/credentials, invalidate providers, remove marker, and release the write gate. A pending marker resumes cleanup before app use after restart. Credential cleanup failures are reported and retried before allowing AI use, not represented as fully disconnected while a usable token remains. Do not restore active selections, background work or legacy-import triggers. In this task route every existing app write through `runWrite`, including check-in, batch logging, profile/draft writes and legacy imports; keep network waits outside the admitted-write section and recheck operation epoch inside it before committing. The later erase service uses this already-established gate.
- [ ] **Step 3: Verify green and restoration on a fresh install.** Run snapshot/service/codec tests, journal migrations and root checks. On Android/iOS export a fixture containing photos/labels/recipes/plan/check-in, restore into a fresh app, compare all counts/nutrient states/media hashes and confirm connection setup is required. Record corrupt/wrong-password/interrupted cases with no partial mutation.
- [ ] **Step 4: Commit.**

```bash
git add packages/salu_data/lib/src/repositories/user_data_repository.dart packages/salu_data/lib/salu_data.dart packages/salu_data/test/user_data_repository_test.dart app/lib/src/data_transfer/archive_service.dart app/lib/src/data_transfer/data_write_gate.dart app/test/data_transfer/archive_service_test.dart app/test/data_transfer/data_write_gate_test.dart app/lib/src/providers.dart app/lib/src/features/meals app/lib/src/features/onboarding app/lib/src/features/plan app/lib/src/features/search app/lib/src/features/today/check_in_screen.dart docs/data-lifecycle.md
git commit -m "feat: restore validated snapshots with staged media and async fencing"
```

### Task 5: CSV, resumable erase and real Settings controls

**Files:** Create `app/lib/src/data_transfer/csv_export.dart`, `data_reset_service.dart`, `data_transfer_screen.dart`, `app/test/data_transfer/csv_export_test.dart`, `data_reset_service_test.dart`, `app/test/settings/data_transfer_screen_test.dart`; modify `features/settings/settings_screen.dart:87–109`, `app/lib/main.dart`, `providers.dart`, `README.md`, `docs/data-lifecycle.md`, `docs/platform-release-checklist.md`.

**Interfaces:** `String csvCell(String value)`, `String exportDiaryCsv(UserDataSnapshot snapshot)`; `DataResetService({required UserDataRepository data,required CredentialStore credentials,required OperationFence fence,required DataWriteGate gate,required Future<Directory> Function() supportDirectory})` exposes `Future<void> erase()`, `Future<void> resumeIfPending()`; `DataTransferScreen` receives archive/reset services and a snapshot callback via providers. Consume Task 4's `DataWriteGate` and already-gated write paths; do not introduce a second independent lock or move the gate down into core/SQLite. The gate is not a substitute for transactions or revision checks.

- [ ] **Step 1: Write red CSV/reset/widget tests.**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/data_transfer/csv_export.dart';

void main() {
  test('CSV quotes delimiters and neutralizes formula-like food names', () {
    expect(csvCell('=1+1'), '"\'=1+1"');
    expect(csvCell('Soup, "large"'), '"Soup, ""large"""');
    expect(csvCell('line\nbreak'), '"line\nbreak"');
  });
}
```

Run app `flutter test --no-pub test/data_transfer/csv_export_test.dart`; expect missing helper. Reset tests use a temp owned support directory and in-memory credentials; simulate failures after marker, DB erase and media erase, then call `resumeIfPending` and assert idempotent completion. Include old `planning_profile_v1.json`/week files, active request cancellation, queued writes, owned-slot cleanup, unrelated files/credentials untouched, retained catalogue and no legacy reimport. Widget tests assert confirmation before replacement/erase and password never displayed/persisted.
- [ ] **Step 2: Implement CSV, erase and Settings UI.** CSV always quotes cells, doubles quotes and prefixes a single quote for user text whose first non-whitespace character is `=`, `+`, `-` or `@`, including control/leading whitespace variants. Keep numeric columns numeric; unknown value is empty with a separate explicit state column. Emit one row per item/nutrient, preserving original legacy entries and photo meals, ISO dates and provenance. Warn that CSV is plaintext and incomplete as a backup.

Erase writes an owned durable `salu-reset-pending.json` marker, requests the write gate and invalidates operations before deleting data. Enumerate exact app-owned directories (meal-images, thumbnails if present, transfer staging), recognized legacy profile/week files and `salu.*` secret slots; do not recursive-delete the entire support directory. Clear all user/provider documents and journal/diary tables, retain catalogue rows plus nonpersonal edition/index metadata, and ensure legacy files cannot be reimported. Remove marker only after all owned components clear. Bootstrap calls `resumeIfPending` before opening normal routes; errors render retry rather than access to partially reset data. Reset marks setup incomplete and drops in-memory drafts/connections. No health/provider/backup deletion promise.

Replace Settings placeholders with Backup, Restore, Export CSV and Delete local data actions. Use native file selection; wrong password/cancel leaves everything unchanged. Show restore counts/replacement warning and require a second explicit confirmation; erase lists scope and remote/export limitations. Export destination cancellation must not report success or leave plaintext temp files. Document encrypted archive limits, retention and OS backup review; do not claim flash forensics resistance. Verify Task 4's gating still covers direct check-in/document writes, batch logs and legacy file importers.
- [ ] **Step 3: Verify green and crash recovery.** Run data-transfer/settings tests and root checks. Use device kill/relaunch at each destructive phase, verify pending marker recovery and that old JSON cannot resurrect erased data. Validate screen-reader announcements and no password/diary contents in diagnostics.
- [ ] **Step 4: Commit.**

```bash
git add app/lib/src/data_transfer app/lib/src/features/settings/settings_screen.dart app/lib/src/features/onboarding app/lib/src/features/plan app/lib/src/features/search app/lib/src/features/today/check_in_screen.dart app/lib/main.dart app/lib/src/providers.dart app/test/data_transfer app/test/settings/data_transfer_screen_test.dart README.md docs/data-lifecycle.md docs/platform-release-checklist.md
git commit -m "feat: expose CSV backup restore and resumable local data deletion"
```
