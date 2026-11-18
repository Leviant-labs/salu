# Salu — Product & Engineering Spec

Status: target product contract · draft v3
Stack: **Flutter (Dart)**, iOS + Android.

This spec describes the intended product, not shipped behavior. See
[Architecture](architecture.md) for the baseline scaffold and target boundaries,
and the [Nutrition engine spec](nutrition-engine-spec.md) for calculation and
policy contracts.

## 1. Product contract

A photo-first, AI-led nutrition app with food logging, meal planning, coaching,
health integration, and supportive gamification. The primary logging experience
starts with a meal photo and can use natural language to say what and when to log.
The Plan workspace uses AI to choose or suggest meals. No app accounts or backend
auth; user records persist on device in SQLite.

- AI interprets intent and evidence and proposes choices. App services own
  nutrition arithmetic, policy, planning validation, and persisted records.
- Offline operation is a capability, not the primary UX. Manual logging and the
  installed catalogue, along with local planning, groceries, and coaching, must
  remain usable without provider access. Connecting a provider is optional.
- ChatGPT-powered image input is in scope. A custom small on-device food vision
  model is a much later research project, not a release dependency or fallback.
- No backend does not mean no network: optional providers, dataset downloads,
  and platform health exchange are separate integrations with separate policies.

User-confirmed boundaries above are requirements. Mechanics below are engineering
recommendations adopted for this draft; algorithm parameters and safety policies
still need validation before release.

## 2. Architecture and authority

```text
Photo + language / Plan / manual controls
                 |
      AI interpretation where available
                 |
        Typed commands and queries
                 |
        Validation / commit policy
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
- Writes have typed parameters and domain validation. A clear request to log a
  new meal authorizes its local creation without a second confirmation (§3).
  Corrections require preview and confirmation; target and plan changes also
  require user confirmation before commit.
- Multi-step changes are transactional where applicable.
- Requests have stable IDs; retries do not create duplicate logs or health writes.
- An async result is bound to its originating request and, for changes, the
  revision it would modify. A stale result cannot replace a committed meal or
  override intervening edits.
- Disabling every provider must leave all core workflows functional.

## 3. Photo-first food logging

### 3.1 New meal vs. correction

- With a meal photo, “this was my lunch today” is an explicit new-meal logging
  request. Save it under **Lunch** on the resolved diary date for “today.” Use the
  stated meal and date rather than inferring them from upload time (§4.3).
- Once validated, save an explicit new meal immediately, without a review step.
  Show where it was saved, the items, and their known and estimated values. Mark
  estimates visibly on the meal and affected diary totals; count the saved
  estimates immediately. Keep unresolved items, quantities, or nutrients visible
  as unknown, not zero, and mark affected totals as partial or unavailable.
- A photo without clear logging intent can produce suggestions but does not write
  intake. Clarify ambiguous intent, date, or meal identity when it prevents safe
  routing; unresolved nutrition alone does not block a clear new-meal save.
- To correct a saved meal, show a preview of the specific meal and the proposed
  changes, including affected values and totals. Keep the saved meal and totals
  as-is until the user confirms. Confirmation revises the existing meal rather
  than logging another one.

### 3.2 Meal photos and label evidence

1. **Meal-photo inference:** suggest visible foods and portions. A photo does
   not establish hidden ingredients or exact mass. Keep usable values visibly
   estimated and ask for clarification or a measured amount where useful.
2. **Label OCR:** extract printed nutrition, serving basis, units, product name,
   and ingredient/allergen statements when present. Preserve missing/ambiguous
   fields instead of inventing values. OCR does not verify label correctness or
   establish how much was eaten.

A single meal can include its photo and multiple label photos. Attach labels to
the corresponding items as evidence, including multiple views of a single label;
they are not additional servings or diary entries. For a matched product, use
legible label values on their stated basis and scale to the eaten quantity when
compatible. Replace overlapping generic estimates for that item rather than
adding both. If the association is unclear, ask which item the label belongs to
and keep it unassigned until resolved. Applying late evidence to an already
saved meal follows the correction flow in §3.1.

The app calculates nutrition from resolved observations and portions. Generic
model estimates stay estimated and do not become verified catalogue facts.

- Image sharing requires disclosure and consent for the selected provider and
  purpose. Merely connecting a provider does not authorize unrelated transfers.
- Strip unnecessary metadata; choose resolution/crops that preserve label text.
- Retain source images locally only under a documented retention setting.
- Benchmark image tokens, latency, OCR quality, and correction effort on actual
  labels and meals. No fixed cost or accuracy claim is assumed.
- If cloud vision is unavailable, offer search, barcode, and manual entry. Do not
  require a local food model or automatically queue uploads for later transmission.

### 3.3 Alternative inputs and no-match paths

- Search local foods; recent foods and favorites; repeat or copy a meal.
- Barcode lookup against installed regional product data.
- Custom food entry, recipes, saved meals, and explicit quantities/units.
- Optional local barcode recognition is distinct from food recognition.
- A photo, search, or barcode miss offers a different search (including local
  names), a clearly identified generic match if appropriate, ingredient entry,
  label capture or transcription, or manual/custom entry. A reviewed label can
  be saved as a custom food. If nothing resolves, a requested meal can still be
  saved with an unknown item and corrected later. Never silently substitute an
  unrelated product or assume a missing value is zero.
- Text-only logging uses the same intent and commit rules as photo logging.
- Voice is optional. Device/locale support and offline availability must be
  checked; never silently substitute remote ASR for an on-device privacy promise.
- Corrections improve explicit local aliases and saved defaults where useful;
  they do not imply an automatic training pipeline.

## 4. Nutrition data and calculations

### 4.1 Sources and delivery

Candidate sources: USDA FoodData Central, France's CIQUAL reference table, and
Open Food Facts for packaged products. Measure Portuguese coverage rather than
assuming these sources provide complete European coverage.

- Build an international catalogue: bundle a useful baseline and offer versioned
  regional downloads for local foods, brands, barcodes, and names. Rank relevant
  regional matches first without hiding relevant matches from other installed
  regions. Installed data remains searchable offline; new downloads require a
  transfer. Disclose known coverage gaps and use the no-match paths in §3.3.
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
- Keep estimates and unresolved fields in meal snapshots with item-level source
  and evidence provenance; they are not new verified catalogue entries.
- Store calories/macros/fiber/sugars/sodium and supported vitamins/minerals;
  additional constituents are allowed. No unsupported '95+ micronutrients'
  completeness promise.
- Nutrient displays expose missing coverage; do not diagnose deficiency from
  incomplete logs or missing nutrient values.
- Canonical mass in grams when available. Preserve native label bases; scaling
  within the same basis needs no conversion. Converting volume to mass requires
  food-specific density; converting pieces/servings to mass requires a recorded
  portion weight.
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
Resolve relative dates like “today” against the diary's local context at the
request, not when an asynchronous result arrives. An explicit meal slot is stored
separately from the event time. A date and meal slot do not establish an exact
eating time.

## 5. Targets and adaptive expenditure

### 5.1 Onboarding and baseline

- Onboarding lets users record a starting weight, choose a goal, enter or review
  calorie/macro targets, and set food preferences, dislikes, and exclusions.
  Let users skip optional inputs, edit them later, or start with neutral logging.
- Support cut, maintain, and gain goals with user-editable calorie/macro targets.
- Users may also choose optional, non-prescriptive dietary or activity changes
  they want to try. Treat these as editable preferences or intentions, not medical
  advice, requirements to log or plan, or permission to change targets.
- Initial energy estimate: Mifflin-St Jeor plus an activity assumption where
  appropriate to the supported adult population. Explain that it is an estimate.
  Automatic target proposals require approved eligibility and target policies and
  user confirmation; see the [nutrition engine policy](nutrition-engine-spec.md#3-eligibility-and-safety--one-policy-separate-permissions).
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
- Adaptation stays experimental until the [engine's acceptance gate](nutrition-engine-spec.md#84-acceptance-gate)
  is met. Version and validate the observation windows, smoothing, bounds, and
  safety limits before enabling proposals for ordinary users.

**One energy budget:** baseline/adaptive expenditure includes ordinary activity.
Do not automatically add steps, MET calories, or imported exercise calories on
top. Activity can be displayed as context; exceptions need an explicit policy
that prevents double-counting.

## 6. Plan workspace

Plan is a dedicated, full-size workspace, with a day/week schedule, meals and
portions, target summaries where applicable, swaps and pins, and an editable
grocery list. Users can ask AI to choose meals for a schedule or suggest a swap,
then review and confirm the result in Plan. A local recipe catalogue with
resolved ingredients, serving ranges, preparation time, dietary metadata, and
provenance supports the same workspace with manual controls and local search
when AI is unavailable.

Pipeline:

1. Collect schedule, targets, exclusions, preferences, and available ingredients.
2. Filter eligible recipes using hard constraints.
3. Use AI to select eligible meals or propose candidates and portions. Resolve
   suggested recipes and ingredients before use; use bounded local search for
   provider-free selection and portion adjustment.
4. Recalculate totals in app services and validate constraints for every candidate
   and every adjustment/swap before it can be accepted.
5. Present a plan with objective deviations and any unresolved requirements.
6. Aggregate ingredients into an editable grocery list.

- Local search is reproducible for the same inputs, catalogue and policy versions,
  and seed. AI choices can vary; validation of a given candidate is deterministic.
- Allergies and explicit exclusions are hard constraints, not scoring penalties.
  Unknown ingredient/allergen status cannot establish suitability. Avoid blanket
  'allergy-safe' guarantees, including cross-contamination guarantees.
- Calorie/macro closeness, variety, cooking effort, and ingredient reuse are soft
  objectives by default, with documented priorities and sensible portion bounds.
  Use saved preferences too: “I dislike carbonara” steers choices away from it;
  “never include carbonara” is an explicit exclusion. Respect pantry stock and
  pinned meals according to the planner's constraint rules.
- Explain missing data, search exhaustion, or demonstrated infeasibility and
  offer user-controlled alternatives; never silently relax a hard constraint.
- Plans are not intake. Logging a planned meal is a separate confirmation and
  supports changed portions, substitutions, and leftovers.
- Grocery aggregation merges compatible quantities; do not invent conversions.
- Build groceries from the selected plan and preserve user edits and checkmarks
  through plan repair. AI cannot certify a recipe, override a failed validation,
  or silently turn a plan into intake.

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
  Saving an estimate locally does not itself confirm an external health write.
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
10. Photo-first flow: a photo with “this was my lunch today” saves under Lunch
    once, with estimates visible and counted immediately and unresolved values
    shown as unknown. Multiple labels update the corresponding item evidence
    without adding servings. Corrections leave totals unchanged until confirmed.
11. Plan and onboarding: AI choices and swaps pass app validation; dislike and
    explicit exclusion are distinct; approved plan drives editable groceries.
    Starting weight, targets, and preferences are editable; skipping optional
    inputs or ineligible automatic targets leaves neutral logging usable.
12. Catalogue: installed regional and international entries remain searchable
    offline; photo/search/barcode misses have manual or unresolved-entry paths.

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
