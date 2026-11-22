# Architecture

The [Product spec](product-spec.md) defines the intended UX; the
[Nutrition engine spec](nutrition-engine-spec.md) defines calculation and policy
semantics. This document distinguishes the working slice from the remaining
target design.

## Working slice

Today renders the daily nutrition summary (`DiarySummary`) above photo cards by
meal slot and combines original diary rows with meal snapshots for totals,
exposing partial/estimated/unknown states semantically. The meal is saved before
AI runs; Drift's diary watch updates the card after a successful revision-checked
enrichment. The editor anchors its primary Save action in a keyboard-aware
`SafeArea` footer and supports reviewed label evidence per item and correction
previews for saved meals. Photos are app-support files; meal records store their
paths. First-run setup runs a seven-page resumable wizard backed by a revisioned
SQLite draft that commits atomically to the planning profile on finish (or marks
setup skipped), while Settings keeps a compact optional-field profile editor and
Plan edits food preferences directly. The food library offers catalogue search
and a stateful 4-tab `/search/library` route (`Foods`, `Meals`, `Recipes`,
`Leftovers`) with live filtering and lazy list builders. The Plan workspace uses
resolved recipes and bounded portions and derives the shopping list from the
confirmed plan. The local check-in reads diary, weight, and activity observations
and compares them to user-declared intentions. The UI defaults to a dark-luxury
emerald-accented glassmorphic/neumorphic theme (`SaluSurfaceTokens`,
`GlassSurface`, `SaluTactileButton`, `SaluTactileToggle`) with an accessible
light fallback, `en` and `pt_PT` localization via `flutter gen-l10n`, and
locale-aware number formatting (`localized_numbers.dart`).

## Modules

| Module | Depends on | Owns |
| --- | --- | --- |
| `salu_core` | Dart SDK only | Domain types, nutrition arithmetic, diary time semantics, meal revision (`reviseMealItem`), planning value types and math (`PlanService`), typed commands, ports for storage / health / inference |
| `salu_data` | `salu_core`, drift, sqlite3 | Schema, migrations, diary repositories, library & week-plan repositories (`FoodLibraryRepository`, `RecipeLibraryRepository`, `WeekPlanRepository`), and bundled catalogue |
| `app` | both, Flutter, Riverpod, go_router | UI, feature controllers (`MealEditorController`, `PlanController`, `LibraryController`), composition root, media and secure-storage adapters, ChatGPT OAuth and BYOK protocol adapters (`InferenceGateway`), feature repository wiring |

The boundary is enforced mechanically, not by convention: `salu_core`'s pubspec
has no Flutter, drift, or HTTP dependency, and `tool/check_boundaries.sh` greps
for forbidden imports. See [module layout decision](decisions/0001-module-layout.md).

## Why the core is separate

Three concrete payoffs, in order of importance:

1. **Test speed.** Domain and command tests run under plain `dart test` with a
   fake clock and fake repositories, without a device or Flutter engine. Core
   arithmetic and policy fixtures belong here; persistence tests exercise SQLite.
2. **Provider independence.** AI leads the target interaction, but provider
   transport stays outside the core. Arithmetic, planning constraints, targets,
   coaching, and offline planning remain deterministic app capabilities.
3. **One write path.** Forms and future AI-assisted actions use the same typed
   command handlers and do not bypass validation, commit policy, or idempotency.

## Command shape

```text
Manual UI ───────► Command object (validated in its constructor)
                       │
                       ├── requestId  (idempotency key, stable across retries)
                       ├── domain inputs (quantity, offset, channel)
                       ▼
                    Handler ──► ports ──► SQLite
                       │
                       ▼
               sealed result: LoggedFood(entry, created) | LogFoodRejected(reason, message)
```

`LogFoodHandler` is the scaffold's reference implementation. It resolves a
catalogue food to grams, snapshots its scaled nutrients, and appends it to the
diary. Later writes should follow the same pattern: validated inputs, injected
`Clock` and `IdGenerator` where needed, stable request IDs, and typed applied,
already-applied, and rejected outcomes.

Rejections carry user-facing text because the recovery path matters: a volume
quantity on a food with no density says *enter a mass instead* rather than
failing silently.

## Storage decisions

**Nutrients as JSON, not columns.** One nullable numeric column per nutrient
would lose unknown / trace / estimated distinctions. `NutrientProfile.toJson()`
is the scaffold's stored form; export is future work. See the
[nutrient state decision](decisions/0002-nutrient-state-model.md). Totals are
computed in Dart. If profiling calls for a rollup table, it must preserve those
distinctions.

**Diary date as `yyyy-MM-dd` text.** Stored, not derived. A timestamp plus an
offset can produce a different date later (offset lookup changes, DST, travel);
the assigned date is a user-visible fact and must not move under history.

**Snapshot rows.** `log_entry_items.nutrients_json` is the eaten amount at write
time. Catalogue updates touch `catalog_foods` only. A test asserts that a
corrected catalogue row does not change a stored entry.

**Idempotency in the schema.** `log_entries.request_id` is unique. The handler
checks first for a clean `alreadyApplied` result; the unique index is the
backstop for races and retried queue items, and a test asserts it fires.

**Catalogue vs user data.** The replaceable fixture catalogue and diary share a
database file but have no foreign keys between them. Future dataset installation
can replace catalogue rows without rewriting diary snapshots.

## Migration policy

`schemaVersion` starts at 1. No version ships without:

1. an explicit migration path from every earlier version,
2. a fixture of the previous schema migrated forward in a test, and
3. byte-for-byte stability of user-visible values across the migration.

Schema v2 added `photo_meals` without modifying v1 data. Schema v3 adds estimate
status and recording offset, revisioned `local_documents`, and indexed barcode
lookup. A meal has a stable ID and a compare-and-update revision; item snapshots
store stable IDs and any label paths. Full revision history and managed media
retention are separate follow-up work. Profile and weekly-plan documents import
their original local JSON once, on first access, and then use SQLite. Manual
grocery rows, overrides and checked flags remain intact. Batch logging debits
inventory and creates a meal in the same transaction.

## Provider and health boundaries

`SaluAssistant` delegates to `InferenceGateway` (scoped per Riverpod `ProviderScope`), which routes requests strictly to the single explicitly selected connection with zero automatic provider or model fallback:

- **ChatGPT plan authorization (`chatgpt-plan`):** browser PKCE OAuth via `ChatGptSession` (with JWKS ID-token verification, token refresh, and SSE Responses transport). Eligible ChatGPT plan limits apply.
- **BYOK endpoint profiles:** named `EndpointProfile` metadata persisted in `local_documents` (`endpoint-connections`) paired with opaque `salu.endpoint.<id>.<gen>` slots in `SecureCredentialStore`. Supports OpenAI Chat Completions (`/chat/completions`), OpenAI Responses (`/responses`), and Anthropic Messages (`/messages`), explicit bounded `GET` model discovery (`models`/`catalogue`) or manual model IDs, and explicit opt-in for loopback/private-network `http://` (public `http://` is rejected). Changing an endpoint's origin or protocol requires re-entering the API key; connection mutations invalidate `OperationFence` to abort in-flight work.
- **Compatibility note:** Real-service compatibility across live ChatGPT, OpenAI, and Anthropic endpoints is unverified until manually tested with opt-in credentials outside automated fixture/mock tests.

The meal, label, check-in, and plan flows each disclose the active provider destination (and potential plan limits or API billing) and require an explicit user request. Provider output and OCR text are untrusted data; neither can call a repository directly. Safe meal-estimation failure codes persist separately in `MealEstimateStatusStore` (`estimate:<meal-id>`) bound to the meal revision without changing `PhotoMeal` JSON. `HealthPort` remains an interface.
Local meal autosave never authorizes an external health write. Preserve separate
user confirmation, permissions, origin tracking, idempotency, and reconciliation
as specified in [Health exchange](product-spec.md#health-exchange).

## Target flows

### Photo-first logging and meal corrections

```text
Photo + text + label images
  -> app adapter (consent, provider request)
  -> parse untrusted intent and evidence
  -> resolve diary date / meal slot, item links, and quantities
  -> validate typed command and choose commit path
       explicit new meal -> atomic save -> receipt and live diary totals
       existing meal    -> preview -> confirm revision -> atomic correction
       ambiguous intent or target -> clarify without writing
```

- Resolve “this was my lunch today” to the Lunch slot on the diary date in
  the request's local context. Capture that context before inference; completion
  time is not meal time or a new date assignment.
- Validate a clear new-meal request, then persist one snapshot even if some
  fields remain unknown. Show the receipt and update totals from the committed
  state immediately. Known and usable estimated contributions count; preserve
  estimate provenance and surface missing coverage instead of supplying zeros.
- Use one meal ID and stable item IDs. A photo and several labels can provide
  evidence for those items; the number of evidence attachments is not a quantity.
  Resolve associations and compatible serving bases before scaling, and select
  one effective contribution per item and nutrient. Ambiguous label links do not
  add intake. Updating saved values with new evidence is a correction.
- Keep corrections uncommitted while previewing item and rollup changes. Bind an
  accepted preview to the meal's expected revision and check it at commit; a stale
  preview must be refreshed. Persist the revision and invalidate dependent totals
  and findings. Use stable request IDs across retries so a repeated provider result
  cannot create another meal; discard results for cancelled or superseded work.

### Plan, onboarding, and catalogue

- The full-size Plan workspace owns the schedule, swaps, pins, portions, and
  editable groceries. AI selects or suggests candidates using relevant preferences
  and pantry data. Resolve recipe and batch IDs and validate eligibility, hard
  constraints, portions, stock, and totals in app services before a confirmed
  commit. A dislike affects ranking unless the user makes it an exclusion.
  Grocery aggregation uses the validated plan; local search and manual editing
  support the same workspace without a provider. Plan is never intake.
- First-run onboarding (`OnboardingWizard`, `OnboardingController`, and
  `OnboardingStore`) walks across seven pages: Welcome, goals/activity,
  starting weight, food preferences, declared daily targets, optional AI setup,
  and Review. Draft progress persists in `local_documents` (`onboarding-draft`)
  on each step so restarts resume where the user left off. Users can skip setup
  from Welcome or skip individual pages; all inputs remain optional with no
  automatic target calculations, the AI setup step makes no network calls and
  authorizes no meal/photo uploads, and finishing commits `planning-profile`
  and clears the draft atomically. Settings retains the compact `_ProfileEditor`
  with all fields optional, and Plan uses `FoodPreferencesScreen`. Policy gates
  automatic target proposals and the user confirms them; optional intentions do
  not trigger target changes or bypass review.
- Versioned regional imports stage and atomically activate international food
  datasets while preserving source provenance and user records. Search installed
  data across regions offline. No-match flows can accept a supported generic
  match, ingredients, a label or manual entry, or an unresolved meal item; an
  absent catalogue match is not a zero or permission to invent a source.

## Known debt

- The 78-food starter uses FTS5 when available, with a bounded fallback on
  builds without it. [Separately distributed packs](catalogue-packs.md) can be
  installed from a local file with barcode data. Broader vetted regional and
  branded pack distribution and coverage measurement are still open.
- A restarted app keeps the saved meal and offers a retry for interrupted AI
  work. No upload resumes automatically. Meal date lookup recognizes simple
  calendar phrases; complex references require manual date or meal selection.
- The planner has a small recipe set, soft target comparisons, strict exclusion
  checks for known ingredient names and fail-closed handling of unknown allergen
  status. Pantry-based suggestions, richer recipe curation, and clinical allergen
  certification are not part of this implementation. The check-in offers local
  record summaries and optional routine ideas, not automatic target changes.
- Platform hosts are generated. The bootstrap configures Android network access
  and iOS camera/photo permission strings; real-device checks and signing remain.
