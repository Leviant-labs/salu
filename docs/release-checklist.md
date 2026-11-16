# Specified release acceptance ledger

Source revision: upstream `804ac3b91186879d16e8afeec977cae0d8567418`.
The source was materialized through the authenticated GitHub connector after HTTPS
Git authentication failed. The exact unsigned upstream commit and source tree were reconstructed and hash-verified,
establishing a shallow Git checkout. Publication preserves this upstream parent.

At handoff, the supplied contracts matched the checked-out versions byte for byte;
the specifications have since been revised. Original product v2 and nutrition
v2 disagreed on per-volume records: nutrition §4 is the explicit dimensional
contract; same-unit scaling must work without density. Product §4's canonical
grams apply only when a supported mass conversion exists. Legacy measured JSON
stays measured, never retroactively relabelled as label-reported. New labels use
reported/reported_zero. Trace without a supplied numeric limit cannot be exact 0.

Status vocabulary: pending, partial, implemented-unverified, automated-pass, device-pass,
review-blocked. Tests alone do not satisfy clinical or distribution approval.
**Current testing scope:** The project owner intends this build for private
testing within their immediate family, not public distribution. Experimental
condition-aware planner preferences are enabled for this test, with explicit
limitations; they are not clinically validated. The INSA workbook is bundled
and initialized locally; permission for wider redistribution is not established.
Starting estimates are available from explicit inputs and labelled as estimates;
there is no autonomous adaptive calorie estimator or private-test approval lock.
Physical Android and iPhone callback, and completed live inference, remain pending.


| Gate | Required evidence | Status |
|---|---|---|
| Foundation | Dart MCP handshake and tool calls verified; core/data/app analysis + tests + boundary checks run; native builds recorded separately | automated-pass (host scope) |
| Arithmetic | native basis, exact decimals, unknown/trace/reported-zero, partial totals tested; production definition adapters not complete | partial; automated evidence |
| History | snapshot source/quantity, correction revisions, explicit consumed instant/offset and assigned diary day; real v1/v2 SQLite upgrade fixtures tested | automated-pass (covered flows) |
| Recording | custom foods, exact quantity selection, diary edits/time correction, completeness, favourites, barcode/manual recovery and saved-meal review UI; native-device coverage remains | partial |
| Catalogue | schema 3, FTS5 + fallback, aliases, personal ranking, barcode lookup, review-gated staged atomic packs implemented/tested; raw dataset adapters and licensed PT baseline remain | partial |
| Targets | explicit inputs, estimate provenance, manual/clinician ownership, no exercise add-back | implemented-unverified |
| Starting estimates | exact formula, missing-input and impossible-algebra behavior; reviewed acceptance | implemented-unverified |
| Adaptation | no autonomous estimator; explicit recalculation may be reviewed | not implemented |
| Planning | core reproducibility, strict unknown allergens, pins, portions, repair tested; full constraints/schedule UI and soft objectives remain | partial |
| Recipes/batches | immutable versions, yield, bounded stock + transactional intake and groceries implemented/tested; planned stock and full grocery edits remain | partial |
| Coaching/rewards | offline findings, independent safety, humane idempotent rewards | pending |
| Drafts | review, stale response rejection, cancellation, retry, no direct provider writes | pending |
| Providers | documented token-sharing, request consent, validated proposals; physical callback and live inference | implemented-unverified |
| Health | native permissions, outbox/reconciliation, duplicates, external deletions | pending |
| Data controls | archive, staged atomic restore, authenticated encryption, CSV and DB deletion tested; native picker/cache and media audit remain | partial |
| App | onboarding, navigation, EN/pt-PT, support mode; large-text widget checks; native screen-reader flows remain | partial |
| Devices | iOS + Android end-to-end, large text, screen readers, both languages | pending |
| Performance | host-only 10k synthetic search/planner p50/p95 recorded; named-device, cold/warm startup/log/RAM/DB measurements remain | pending (device gates) |
| Datasets/media | PT coverage, label/photo correction benchmarks, content rights | review-blocked |
| Privacy | actual transfers, secure credentials, threat model, retention review | review-blocked |

Android debug compilation passed. APK signature, ZIP integrity and native ELF
section bounds were checked; see validation-2026-11-08.md. The prior head also passed unsigned iOS compilation in CI. Named-device
execution remains unverified; new code requires its own build results.

Do not label this ledger or a debug artifact a completed release while gates are open.

## Historical development additions (handoff a5c77db)

The following handoff and verification records describe their time, not current
capabilities or evidence for the guided implementation.

- Weekly check-ins now report their explicit window and day coverage; this is not
  the complete set of coaching rules. Adaptation remains disabled.
- Manual grocery entries can be added, edited, checked and removed. The full
  planner, repair and grocery workflows remain partial.
- Catalogue filtering and ranking now precede the search result limit. A
  production catalogue, licence review and device performance evidence remain open.
- Draft review UI and the health export outbox have durable local stores.
  Neither is connected to a provider or native health platform; adapters,
  authorization and platform testing remain open.
- Local deletion and restore refresh cached catalogue and meal views. Native
  cache/media deletion and platform backup audits are still required.

These additions were committed in handoff `a5c77db`; historical host checks do
not verify this checkout or replace the reviews and device gates above.
Batch reservation validation, catalogue activation preview, recorded weight
comparisons and atomic safety/target updates are present. Planner reservation
persistence and UI, production datasets, broader coaching and device validation
remain open.

## Historical Windows handoff

- Fetched `origin`; handoff branch tip is `a5c77db85d8f732d6ac0948ef29be1de4b5cd395`.
  Initial working tree was clean, including untracked files.
- Flutter 3.47.9 / Dart 3.13.7 installed from the official Windows archive;
  SHA-256 matched `d8e2b5977e09082c6440f89dc1aa887b94c8fbcc3b39222797046295a3f68a9e`.
  The configured Dart MCP command answered an initialize request; registration
  in this host's active tool session is not established.
- `flutter doctor -v`: Windows, Chrome, Edge and Visual Studio available;
  Android SDK found but command-line tools missing. Android platform 36.1 and
  build tools 36.0.0 are installed; the located JDK is 8. No Android device was
  listed by `adb devices -l`. iOS build requires macOS/Xcode and real-device
  validation remains open.
- Pinned CI baseline: `bash tool/check_boundaries.sh` initially failed on CRLF
  checkout; after enforcing LF for shell scripts it passed. Core locked pub,
  `dart analyze --fatal-infos`, and `dart test --reporter expanded` passed (94
  tests). Data locked pub, `dart run build_runner build`, analysis and `dart
  test` passed (35 tests); generation warned about analyzer language version and
  a nullable SQL constraint. App locked pub and analysis passed. `flutter test
  --no-pub --name '^(?!.*a changed food requires a new review)' --reporter
  expanded` initially passed 25 tests with the reported failure excluded.
  After correcting its snackbar observation timing, `flutter test` passed all
  28 tests. The draft-specific run also covered unchanged confirmation, removed
  food, changed food, and a change between review and commit; rejection left
  the diary empty. Both snapshot checks remain in place.
- Batch audit: `dart test test/batch_service_test.dart --reporter expanded`
  passed 12 scenarios, including concurrent stock reservations, stale revisions,
  transaction rollback, retries, release, consumption and corrections. A
  separate in-memory service smoke reserved 400 g without intake, consumed it
  once, replayed the identical request and rejected a conflicting retry.
  Planner integration still needs to reconcile consumed reservation IDs and
  changed batch revisions; existing plans must not double-count consumed stock.
- Legacy batch receipts store only post-write documents, not full request
  fingerprints. Matching old requests now return
  `LEGACY_REQUEST_REVIEW_REQUIRED` rather than guessing which reservation
  changed or silently replaying a different request; existing stock is retained.
- Subsequent offline work: exact nutrient unit conversion, definition-aware
  energy derivation and recording corrections were added. `dart test` in
  `salu_core` passed 118 tests and `dart analyze --fatal-infos` passed.
  `dart test --reporter failures-only` in `salu_data` passed 46 tests, including
  prior SQLite upgrades and restored batch retry. In `app`, `flutter test
  --no-pub test/catalogue_flows_test.dart --reporter expanded` passed 13 tests
  and `flutter analyze --fatal-infos --no-pub` passed. The merged `flutter test
  --reporter expanded` subsequently passed 38 tests; desktop smoke was not run.
- Further recording/migration verification: the core correction contract test
  passed 24 cases; four data test files covering diary, batch and v1/v2 migration
  passed 40 cases; `flutter test --no-pub test/catalogue_flows_test.dart
  --reporter expanded` passed 14 cases. A standalone SQLite smoke changed only
  the selected item (100 g to 200 g), leaving the other at 50 g and advancing
  the revision. An isolated Windows desktop build failed before launch because
  the installed Visual Studio tools lack `atlstr.h`; visual interaction remains
  unverified.
- Source-record adapters for USDA FoodData Central and Open Food Facts now
  normalize supplied records into catalogue foods without granting dataset
  approval. `dart test test/source_import_test.dart --reporter expanded` passed
  19 cases; `dart analyze --fatal-infos` passed for data. A standalone OFF
  fixture smoke retained allergen status as unknown. Import audit details are
  available as a content-bound audit for explicitly reviewed activation; the
  preview UI does not activate packs. Licensed regional content, source review
  and real-dataset coverage are not established.
- Reviewed item substitution preserves other snapshots and rejects finite-batch
  edits; a SQLite smoke confirmed substitution and identical retry. Raw USDA
  and OFF JSON can be previewed with explicit source metadata and diagnostics;
  preview neither installs nor approves a dataset. The source-pack tests passed
  19 cases, diary tests 16, and the two affected widget files 24; core, data and
  app analysis passed. Device UI remains unverified.
- `dart test test/catalogue_source_audit_test.dart --reporter expanded` passed
  seven audit, mismatch, rollback and archive scenarios. A standalone in-memory
  fixture smoke confirmed preview makes no writes and a test-only reviewed
  activation retains its source audit; this is not production approval.
- CIQUAL XML adapter synthetic checks passed 18 cases. The first combined
  real-data smoke timed out; after streaming parser changes, separate local
  smokes loaded the official 2025 (3,484 foods) and 2020 (3,185 foods) files
  and normalized one record from each. These are host-only checks, not a
  coverage benchmark, content review or licence approval.
- Source licence evidence: USDA FoodData Central states its data are CC0 and
  requests attribution ([API guide](https://fdc.nal.usda.gov/api-guide));
  CIQUAL's official 2025 dataset states Etalab 2.0
  ([dataset record](https://doi.org/10.57745/RDMHWY)). Attribution, update
  dates and applicable change notices still need to accompany redistribution.
  INSA's [site](https://portfir.insa.min-saude.pt/pt/) gives attribution
  requirements but has not established permission to bundle its data. These
  licence findings do not constitute a content review, coverage assessment or
  authorization to enable automatic targets or adaptation. User authorization
  to proceed does not replace the required source and qualified policy reviews.
- CIQUAL source preview now accepts the official XML set and performs parsing
  off the UI isolate on native platforms. A Dart isolate smoke imported all
  3,484 CIQUAL 2025 foods with diagnostics and no activation. Web remains
  subject to main-thread parsing; memory/device performance is unverified.
- Pinned host checks after these changes: `bash tool/check_boundaries.sh`;
  locked pub get, `dart analyze --fatal-infos` and `dart test` in core (132
  passed); locked pub get, `dart run build_runner build`, data analysis and
  tests (133 passed); locked Flutter pub get, `flutter analyze --fatal-infos`
  and `flutter test` (52 passed). Data tests emitted Drift's multiple-database
  debug warning during staging/restore. These results do not close review or
  device gates.
- Source-supplied intervals and evidence dates are retained with observations.
  Recorded summaries expose each source interval with its food, original basis,
  unit and provenance rather than summing it or presenting it as a bound on
  actual intake. A targeted contract test and a standalone summary smoke passed.
- USDA's [FoodData Central](https://fdc.nal.usda.gov/) states its published
  data are CC0 1.0 and requests source attribution. The official Foundation
  Foods 2026-10-29 JSON release was normalized locally: 424 foods and 10
  `negative-amount` diagnostics; no data were activated or bundled. Its
  bulk `FoundationFoods` envelope is supported. This source statement is
  evidence for review, not a substitute for the release's content/licence
  review or a Portuguese coverage benchmark.
- The [CIQUAL 2025 deposit](https://doi.org/10.57745/RDMHWY) identifies
  `etalab-2.0`; its documentation requires source/version attribution.
  [Open Food Facts terms](https://world.openfoodfacts.org/terms-of-use) describe
  separate database, content and image licences. Their obligations and any
  derivative/collective database boundary remain subject to review.
- [INSA's Portuguese food-composition table](https://portfir.insa.min-saude.pt/pt/)
  is available as a 7.1–2026 workbook and requests visible attribution.
  Publicly documented redistribution permission was not found; free download
  alone is not evidence that bundling is permitted. No Portuguese dietary
  coverage percentage has been established.
- Earlier preview verification: a user-supplied INSA 7.1–2026 workbook was
  checked with visible attribution and a pinned SHA-256 and sheet identity. The
  official workbook produced 1,376 candidate records; the preview did not
  activate data or grant approval. Synthetic parser/pack tests (32) and
  catalogue-preview widget tests (19) passed. The later bundled family-test
  installation is recorded below; content and public redistribution reviews
  remain open.
- Planner development checks: 31 core planning/batch tests and 39 data
  transaction/batch/restore-validation tests passed. A standalone local
  smoke saved and reloaded a cooked-stock reservation at batch revision 2
  while leaving the diary empty. App analysis and 14 targeted planner widget
  tests passed before subsequent ingredient-freshness work; device checks
  remain open. Any eligible slot can now be excluded without moving retained
  dates or pins; a standalone middle-slot removal smoke left the diary empty.
- Users can mark recipe ingredients unavailable. The planner treats these as
  explicit hard constraints rather than inferred pantry inventory, and commit
  validation rejects plans that use them. A local smoke confirmed rejection
  without writing a plan or diary entry; malformed saved selections fail closed.
- Users can also mark recipes preferred as a soft, deterministic planner
  objective; allergies, availability and pinned meals take precedence. A local
  smoke selected the preferred recipe among equally eligible alternatives;
  targeted core and widget tests passed.
- Gram and serving stock can both be created, reserved and separately consumed;
  serving stock does not infer a gram equivalent. A standalone serving smoke
  reserved one serving without intake, then confirmed a single diary entry;
  74 targeted data tests and five serving widget tests passed. Legacy gram
  receipts remain recognized; legacy ambiguous receipts still require review.
- Offline coaching now reports bounded recording, fibre, weight-observation and
  date-level plan evidence with caveats and versioned rule identities. A
  standalone check-in smoke reported a seek-advice result and two undeclared
  days with adaptation disabled; 29 coaching domain tests passed. App analysis
  and six check-in/Today widget tests passed before subsequent privacy and
  ingredient-freshness changes. Trend, plateau, adequacy and adherence are not
  claimed without their required policy or evidence.
- Local health outbox checks passed: 26 domain tests and eight SQLite-store
  tests cover denial, retry, duplicate IDs and external deletion. A standalone
  SQLite smoke kept an external-deletion marker and rejected requeueing it.
  No native adapter or transfer was exercised; platform health support remains
  open. Scoped consent/draft and reward retry tests also passed locally.
- Latest host verification: boundary checks passed; `salu_core` analysis and
  227 tests, `salu_data` analysis and 249 tests, and Flutter analysis and 119
  widget tests passed. Drift emitted its multiple-database debug warning during
  staging and restore tests. A reward/plan smoke also confirmed a persisted
  reservation without diary intake and an idempotent engagement reward.
- The rewards screen now exposes local, non-punitive cosmetic choices and
  explicit engagement, learning and return actions. Its selected cosmetic and
  reward events are stored locally. A pt-PT widget flow also passed at 2×
  text scale; native large-text and screen-reader checks remain open.
- Calorie and weight display controls can be changed independently; supportive
  mode overrides both without erasing their saved choices. A fasting-prompt
  preference is stored for future prompts; no fasting notifications exist.
  A narrow pt-PT navigation widget flow passed at 2× text scale.
- Family-test planning reads optional condition declarations and can rank
  meals by known saturated fat, fibre, free sugars or sodium where applicable.
  Conflicting conditions and unknown data are disclosed; no treatment or
  clinical suitability is claimed. Supported conditions and data coverage are
  incomplete, and the experimental rules have not had qualified clinical review.
- The source-linked candidate condition table in `nutrition-engine-spec.md`
  §3.3 includes food allergy, coeliac disease, blood pressure, kidney disease,
  eating concerns, lactose intolerance, gout, digestive triggers and pregnancy
  or breastfeeding, alongside diabetes, low glucose and lipid conditions.
  Primary sources were checked; the complete proposed rule set has not been
  clinically reviewed or implemented. Selected experimental rules are active.
- Nutrition and product contracts now specify a proposed assistant boundary,
  user-reviewed commands, symptom intake, quantity provenance and constrained
  explanations. These are specification requirements, not claims that a
  provider, chat-based safety intake or model-provenance snapshot is deployed.
- Project owner approved proceeding with the outlined implementation. This is
  product authorization, not evidence of third-party dataset redistribution
  rights, a qualified clinical review, or completion of technical validation.
- The INSA 7.1–2026 workbook is bundled and the app provisions its source-scoped
  catalogue on startup for family testing. Provisioning validates the pinned
  digest and preserves custom foods and historical diary snapshots; the general
  reviewed-pack activation path remains separate.
- Android emulator smoke: the updated build populated the bundled catalogue
  automatically and a search for `frango` returned INSA 7.1–2026 foods with
  attribution; the earlier diary snapshot remained visible. The emulator had
  no saved recipes, so a device-generated condition-aware plan was not exercised.
  Planner/widget tests exercised condition-dependent selection and conflict and
  missing-data handling with test recipes. Users must create recipes to plan.
- Latest integrated checks: core analysis and 255 tests, data analysis and
  261 tests, app analysis and 137 widget tests passed. Drift emitted its
  multiple-database debug warning. These checks do not validate clinical advice.
- The INSA 7.1–2026 adapter recognizes all 48 published main-sheet nutrient
  columns. A real-workbook smoke normalized 1,376 foods with 48 observations
  on the first record and zero unmapped columns; this is not a content, rights
  or population-coverage approval. Source gaps remain unknown. INSA available
  carbohydrate is retained as an observation but not projected into generic
  daily carbohydrate totals because the definitions have not been reconciled.
  Food details and source preview report coverage; Today can expand additional
  nutrient totals, retaining partial/unknown status.
- A local weight-reading screen lists recorded measurements and only compares
  unambiguous endpoints, without claiming fat loss or a trend. Weight is the
  chosen body measurement for future adaptation, not evidence by itself of
  expenditure or causation. Adaptive calorie proposals remain disabled pending
  a specified, reviewed and evaluated policy.
- Verification for the expanded scope: core analysis and 227 tests, data
  analysis and 249 tests, and app analysis and 128 widget tests passed; the
  boundary check passed. Drift emitted its existing multiple-database debug
  warning. On Android, the rebuilt app showed expanded nutrient totals,
  Portuguese goal/condition declarations and the local weight screen; these
  device checks do not validate clinical recommendations.
- Recording/nutrition remain partial: reviewed production activation and
  licensed regional datasets remain open. Planner integration, coaching,
  consent/platform work, localization, accessibility and end-to-end/device
  verification remain open. Automatic targets and adaptation stay blocked.

## Historical Android tooling and smoke

- Installed Temurin JDK 17.0.21+9 under `C:\temp` from the verified Adoptium
  archive and Android SDK command-line tools plus platforms 34, 35 and 36 into
  the existing SDK. With `JAVA_HOME` and `ANDROID_HOME` set, `flutter doctor -v`
  reports the Android toolchain available and existing SDK licences accepted.
  On Windows x64, the Android 15 Google APIs x86_64 image, `Salu_API_35`
  virtual device and NDK 28.2.13676358 were installed. The first boot was
  blocked by disk space; NTFS compression of the newly installed system image,
  NDK toolchain and generated intermediates freed space without deleting
  existing SDK downloads or caches. Compression can affect performance.
  Windows Hypervisor Platform accelerated the emulator; the Google APIs guest
  reported a Google Play services startup ANR under resource pressure.
- The Android x86_64 debug APK built and ran on the emulator. A device smoke
  completed onboarding, searched the debug-only apple fixture, recorded 100 g,
  and displayed 52 kcal, 0.3 g protein, 14 g carbohydrate, 0.2 g fat and 2.4 g
  fibre. The same entry and totals remained after force-stop and relaunch.
  Fixture values are placeholders, not reviewed nutrition data.
- The first Android rendering exposed missing Material icons. Enabling
  `uses-material-design` in `app/pubspec.yaml`, rebuilding and reinstalling
  restored the visible navigation and action icons. Gradle still warns about
  future Kotlin-plugin compatibility for `file_picker` and SDK XML versions.
  This smoke does not replace broader device, accessibility or release testing.
