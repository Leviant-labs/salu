# Calorie App — Product & Engineering Spec

Status: draft v2 · 2026-11-07
Stack: **Flutter (Dart)**, iOS + Android.
Supersedes draft v1. No application implementation is implied by this document.

## 1. Product contract

A local-first nutrition app with food logging, meal planning, coaching, health
integration, and supportive gamification. No app accounts or backend auth.
User records persist on device in SQLite.

**The app implements its features. AI is an optional interaction layer.**

- Nutrition arithmetic, targets, expenditure estimation, planning constraints,
  grocery lists, coaching findings, and rewards must work without inference.
- AI may interpret a request, extract a label, suggest food matches from a photo,
  invoke app operations through validated commands, or explain app findings.
- ChatGPT-powered image input is in scope. A custom small on-device food vision
  model is a much later research project, not a release dependency or fallback.
- Planning and coaching are core features, not optional AI add-ons.
- No backend does not mean no network: optional providers, dataset downloads,
  and platform health exchange are separate integrations with separate policies.

User-confirmed boundaries above are requirements. Mechanics below are engineering
recommendations adopted for this draft; algorithm parameters and safety policies
still need validation before release.

## 2. Architecture and authority

```text
Manual UI / optional AI interaction
                 |
        Typed commands and queries
                 |
       Validation / draft review
                 |
     Deterministic application services
       |         |          |
   Nutrition   Planning   Coaching
       |         |          |
      Local repositories and SQLite
                 |
      Explicit health/export adapters
```

The same application services serve forms, buttons, and conversational requests.
No core service imports a remote inference provider. AI cannot execute arbitrary
SQL or mutate the database directly.

- Reads expose only the necessary, user-authorized information.
- Writes have typed parameters, domain validation, and appropriate confirmation.
- AI-derived food entries and target/plan changes require review before commit.
- Multi-step changes are transactional where applicable.
- Requests have stable IDs; retries do not create duplicate logs or health writes.
- An async result is attached to its originating draft and revision. A stale
  result cannot replace an edited or committed meal.
- Disabling every provider must leave all core workflows functional.

## 3. Food logging and optional vision

### 3.1 Baseline inputs

- Search local foods; recent foods and favorites; repeat or copy a meal.
- Barcode lookup against installed regional product data.
- Custom food entry, recipes, saved meals, and explicit quantities/units.
- Optional local barcode recognition is distinct from food recognition.
- Barcode misses lead to label capture or manual entry, never a dead end.

### 3.2 ChatGPT-powered image inputs

Keep two distinct operations and UI descriptions:

1. **Label OCR:** extract printed nutrition, serving basis, units, product name,
   and ingredient/allergen statements when present. Preserve missing/ambiguous
   fields instead of inventing values. OCR does not verify label correctness.
2. **Meal-photo assistance:** propose visible foods and possible quantities.
   This is visual inference, not OCR. Hidden ingredients and exact mass are
   not established by a photo. Ask for clarification or a measured amount.

Both return editable drafts. The deterministic nutrition service calculates
nutrition from confirmed food records and quantities. Explicit label values may
create a reviewed custom food; generic model estimates are not silently promoted
to verified database facts.

- Image sharing requires disclosure and consent for the selected provider and
  purpose. Merely connecting a provider does not authorize unrelated transfers.
- Strip unnecessary metadata; choose resolution/crops that preserve label text.
- Retain source images locally only under a documented retention setting.
- Benchmark image tokens, latency, OCR quality, and correction effort on actual
  labels and meals. No fixed cost or accuracy claim is assumed.
- Cloud vision unavailable: use manual/search/barcode entry. Do not require a
  local food model or automatically queue uploads for later transmission.

### 3.3 Other interaction shortcuts

- Natural-language logging resolves to structured food-and-quantity drafts.
- Voice is optional. Device/locale support and offline availability must be
  checked; never silently substitute remote ASR for an on-device privacy promise.
- Combining inputs preserves provenance and supports merge/replace decisions
  without double-counting the same item.
- Corrections improve explicit local aliases and saved defaults where useful;
  they do not imply an automatic training pipeline.

## 4. Nutrition data and calculations

### 4.1 Sources and delivery

Candidate sources: USDA FoodData Central, France's CIQUAL reference table, and
Open Food Facts for packaged products. Measure Portuguese coverage rather than
assuming these sources provide complete European coverage.

- Bundle a useful baseline and offer versioned regional downloads. Offline means
  installed data remains usable; obtaining a new dataset requires a transfer.
- Separate application/user data from replaceable catalogue data.
- Preserve source IDs, source versions, preparation state, and provenance.
- Source-specific adapters normalize units and definitions without pretending
  incompatible nutrient definitions are equivalent.
- OFF is not public domain: document ODbL/database-content/image obligations and
  the derivative/collective database boundary before shipping imported data.
- Import pipeline validates, stages, and atomically activates updates; interrupted
  updates do not leave a half-installed catalogue.
- Ranking considers query relevance, preparation state, region, source quality,
  and personal usage. Define quality badges; do not call every imported item
  verified.

### 4.2 Data model

Foods, nutrient observations, quantity conversions, recipes and recipe versions,
saved meals, meal drafts, logged food snapshots, and source metadata.

- Distinguish unknown, measured zero, trace, and estimated values.
- Store calories/macros/fiber/sugars/sodium and supported vitamins/minerals;
  additional constituents are allowed. No unsupported '95+ micronutrients'
  completeness promise.
- Nutrient displays expose missing coverage; do not diagnose deficiency from
  incomplete logs or missing nutrient values.
- Canonical mass in grams. Volume conversion requires food-specific density;
  piece/serving conversions require a recorded portion weight.
- Preserve raw/cooked state, edible quantity, recipe yield, and finished weight
  when known. Do not treat water gain/loss as nutrient gain/loss.
- Recipe handling must document retained/discarded ingredients and any nutrient
  retention assumptions. Unsupported precision is disclosed, not fabricated.
- Do not force source energy values to equal a naive macro-derived calculation;
  distinguish validation warnings from explicit corrections.
- Logged entries snapshot quantities, nutrients, source, and recipe version.
  Catalogue or recipe updates do not silently rewrite historical intake.
- Corrections to history are explicit operations with updated rollups.

### 4.3 Time semantics

Store event time, original zone/offset, and the assigned diary date. A timezone
change does not silently move past meals or break past rewards. Separate elapsed
time from calendar-day calculations for fasting, DST, and travel.

## 5. Targets and adaptive expenditure

### 5.1 Baseline

- Cut / maintain / gain goals, with user-editable calorie and macro targets.
- Initial energy estimate: Mifflin-St Jeor plus an activity assumption where
  appropriate to the supported adult population. Explain that it is an estimate.
- Nutrient reference targets have a named source/version and appropriate profile
  inputs; a target is not a medical diagnosis or prescription.
- Manual overrides remain available within the documented safety policy and are
  not silently overwritten by check-ins.

### 5.2 Adaptive mechanism

Engineering approach: estimate a smoothed weight trend and combine it with
sufficiently complete logged intake over a rolling observation window. Blend
with the baseline rather than reacting to a single weigh-in.

- Distinguish missing intake from a deliberately confirmed complete day.
- Require defined observation duration, weigh-in coverage, and intake coverage.
- Show data sufficiency/quality separately from estimator output. These are not
  calibrated statistical confidence claims without validation.
- Underlogging is a known bias; weight trend cannot uniquely identify it.
- Sparse data, rapid unexplained shifts, illness, and inconsistent logging can
  pause adjustment; 'not enough information' is a valid result.
- Bound adjustment rate and require approval at weekly check-in. Do not silently
  compensate for a missed target by making the next target more restrictive.
- Backdated edits trigger a documented recalculation/versioning policy.
- Define observation windows, smoothing, bounds, and safety limits in a separate
  versioned algorithm specification and validate with simulations and fixtures.

**One energy budget:** baseline/adaptive expenditure includes ordinary activity.
Do not automatically add steps, MET calories, or imported exercise calories on
top. Activity can be displayed as context; exceptions need an explicit policy
that prevents double-counting.

## 6. Deterministic meal planning — core

A local recipe catalogue with resolved ingredients, serving ranges, preparation
time, dietary metadata, and provenance supports useful offline planning.

Pipeline:

1. Collect schedule, targets, exclusions, preferences, and available ingredients.
2. Filter eligible recipes using hard constraints.
3. Select meals and adjust discrete portions with a bounded local search.
4. Recalculate totals and validate constraints after every adjustment/swap.
5. Present a plan with objective deviations and any unresolved requirements.
6. Aggregate ingredients into an editable grocery list.

- Same inputs, catalogue version, and seed produce reproducible output.
- Allergies and explicit exclusions are hard constraints, not scoring penalties.
  Unknown ingredient/allergen status cannot establish suitability. Avoid blanket
  'allergy-safe' guarantees, including cross-contamination guarantees.
- Calorie/macro closeness, variety, cooking effort, and ingredient reuse are soft
  objectives with documented priorities and sensible portion bounds.
- Empty/infeasible results explain the conflict and offer user-controlled
  alternatives; never silently relax a hard constraint.
- Plans are not intake. Logging a planned meal is a separate confirmation and
  supports changed portions, substitutions, and leftovers.
- Grocery aggregation merges compatible quantities; do not invent conversions.
- AI can translate 'make dinners quicker' into validated planner inputs or
  explain a swap. It does not implement the planner or certify its output.

## 7. Deterministic coaching — core

Weekly check-ins and on-demand insight cards work with no provider connected.

- Compute findings from local history: logging coverage, weight trend, plan
  consistency, selected nutrient coverage, and possible progress plateaus.
- Each finding includes its time window, evidence, data-quality caveats, and a
  suggested action from a versioned rule library.
- Use templated language as the complete baseline experience.
- Suggest holding course or improving data quality before unnecessary target
  changes. No moral judgments about food or punishment for missed days.
- AI may explain findings and answer questions using authorized app queries.
  Derived numeric claims must come from tool results. Clearly distinguish
  general model commentary from app-computed findings.
- Conversational changes route back through ordinary reviewed app operations.
- Define population/safety boundaries before release: minors, pregnancy or
  breastfeeding, disordered-eating concerns, medical nutrition needs, aggressive
  goals, and symptom-related requests. Obtain qualified review of these rules.
- No diagnosis, treatment promises, or guaranteed outcome claims.

## 8. Supportive tracking and gamification

- Water, weight, steps, and exercise records; optional fasting timer.
- Fasting is user-directed, not an escalating challenge or a prerequisite to
  rewards. Support disabling calorie/weight/fasting nudges independently.
- Pet/cosmetics reward engagement, planning, learning, and returning after breaks.
- No pet harm/sadness caused by eating more, missing a weigh-in, or breaking a fast.
- Never reward progressively lower intake, faster weight loss, or longer fasting.
- Humane streak policy, optional notifications, and no sensitive lock-screen copy
  by default. Reward transactions are idempotent across retries and restoration.

## 9. Provider module — optional

```text
InferenceProvider
├── ChatGPTPlanProvider  // separate external provider authorization, not app auth
└── OwnKeyProvider       // optional user-funded alternative
```

No on-device food model in the release dependency graph.

- Separate provider authentication/transport from typed task adapters and app
  commands. A provider implements capabilities, not nutrition policy.
- Capability checks cover image input, structured output/tool calls, context,
  streaming, and cancellation. Validate results regardless of advertised support.
- ChatGPT integration uses supported public-client authorization where eligible;
  verify app distribution/commercial eligibility, scopes, redirect handling,
  transport limitations, models, and terms before release.
- Tokens/keys go in platform secure storage, not exported database contents.
- Implement refresh, revocation, partial streams, retry limits, offline state,
  disconnect, and consent withdrawal.
- Show authoritative quota information only if exposed by a supported surface;
  otherwise show observed errors/state and a provider usage-management link.
- Never switch providers, spend BYOK credit, or transmit a queued photo without
  appropriate user authorization. Quota exhaustion never blocks core features.
- Provider data is untrusted input. Treat OCR text, food names, and imported
  content as data, not instructions; validate all resulting commands.

## 10. Health exchange, backup, export, and deletion

### Health exchange

Use HealthKit on iOS and Health Connect on Android through platform adapters.
Verify exact package/type support; do not assume full cross-platform symmetry.

- Request minimum permissions for enabled features and handle denial/revocation.
- Read selected activity/weight; write user-confirmed supported nutrition/weight.
- Track origins and external IDs to prevent read-write loops and duplicates.
- Use an outbox/reconciliation mechanism for retriable external writes; handle
  external edits/deletions without automatically resurrecting removed records.
- Define source-priority/deduplication for overlapping steps and exercise.
- Health stores are not a backup of recipes, photos, plans, and app history.

### Backup and export

- Human-readable CSV export plus a versioned full-fidelity JSON/archive export.
- Restore imports validate schema, references, duplicates, and compatibility;
  malformed imports must not partially mutate the live database.
- Backup/restore includes recipes, plans, preferences, and optional media, not
  just daily totals. Exclude credentials; restored provider connections may
  require reauthorization.
- Offer an encrypted user-controlled archive with a documented recovery model.
- Review platform backup eligibility and health-data policies before promising
  iCloud/CloudKit or automatic platform backup. No custom cloud sync in v1.

### Deletion and privacy

- Document deletion of DB records, photos, thumbnails, temporary files, caches,
  pending requests, and credentials. Include retention/backup exclusions.
- Explain separate options and limitations for deleting exported Health records,
  user-controlled backups, and provider-held records. No 'delete everywhere'
  promise without the ability to fulfill it.
- No third-party analytics SDKs by default; crash reporting opt-in and scrubbed.
- Minimize shared history; disclose provider, purpose, payload classes, and
  provider retention terms. Authorization for inference usage is not blanket
  consent to share all health data.
- Review GDPR roles, legal bases, sensitive-data handling, and transfers against
  the actual data flow; do not assume 'no backend' resolves compliance.
- Suggested privacy copy: 'Your records are stored on your device. Connected
  features share selected data only with your permission.'
- Document device-at-rest protection, DB/media threat model, secure key handling,
  and backup encryption; local storage alone is not a security guarantee.

## 11. Technical stack and delivery

- Flutter/Dart UI; independent domain/application modules.
- SQLite via drift, with tested migrations; local search using FTS where supported.
- Camera/barcode, health, secure storage, OAuth/deep links, and optional ASR behind
  platform interfaces. Verify packages with device spikes before committing.
- Network-free core execution; no remote config or provider handshake prerequisite.
- EN and European Portuguese initially. Define regional dataset coverage
  separately from interface localization; do not promise all EU locales at launch.
- Accessibility: scalable text, screen-reader flows, contrast, reduced motion,
  and alternatives to camera/voice input.
- Measure core search/logging latency, planner runtime, cold start, DB footprint,
  peak RAM, image request tokens, and time-to-corrected-log on named devices.
- Record p50/p95 and cold/warm conditions. Set release budgets after profiling;
  no unbenchmarked sub-second local vision or universal cloud-latency promise.

## 12. Release gates

1. With network disabled and no provider credentials: search, log, correct,
   calculate, plan, generate groceries, run a weekly check-in, and earn rewards.
2. Golden tests: known/unknown nutrients, units, raw/cooked food, recipe yield,
   stable historical snapshots, diary dates, and backfilled corrections.
3. Planner tests: reproducibility, valid portion bounds, impossible constraints,
   unknown allergen status, swaps, and no plan-to-intake auto-logging.
4. Coaching/target simulations: missing data, underlogging scenarios, weight
   spikes, stalls, manual overrides, paused adaptation, and no exercise add-back.
5. Provider tests: malformed output, incorrect units, revoked tokens, unsupported
   capabilities, failed/partial streams, stale drafts, cancellation, and retries.
6. Health tests: denial/revocation, offline outbox, duplicate writes, source loops,
   external deletion, and platform-specific type limitations.
7. Restore/migration tests: full round trip, corruption, interrupted update,
   incompatible schema, duplicate import, and credential exclusion.
8. Privacy/safety review: shared payloads and consent, archive protection,
   deletion limitations, population boundaries, and reward behavior.
9. Benchmark Portuguese label and food examples for coverage, correction effort,
   OCR quality, token use, and actual logging time.

## 13. Deferred work and unresolved release decisions

Much later research: a custom small on-device food vision/portion model and any
training/evaluation pipeline. It must not delay or provide a fictional fallback
for the core release.

Out of scope for v1: custom cross-device sync, social/leaderboards, watch apps,
and global correction learning/federated learning.

Before release resolve: dataset licences and regional size/coverage; recipe
content rights and curation; validated target/coaching safety parameters;
ChatGPT integration eligibility and actual capabilities; platform backup policy;
and device-specific performance budgets. These are gates, not assumed facts.
