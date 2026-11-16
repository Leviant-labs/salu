# Calorie App — Product & Engineering Spec

Status: draft v2 · revised 2026-11-11.
Companion to `nutrition-engine-spec.md` draft v2; that document owns the domain
contracts this spec references.
Stack: **Flutter (Dart)**, iOS + Android.
Supersedes draft v1. No application implementation is implied by this document.

**Current private-test cutover:** Guided setup creates a reviewable seven-day meal
plan from bundled recipes, optionally with calculated starting estimates. Today,
My plan, Assistant and Progress are the four primary destinations. Settings and
Diary remain accessible separately. Manual and clinician targets retain their
ownership; calculated estimates are explicitly labelled and require explicit
inputs. Private testing has no clinical-approval or population-based feature
locks. Broader proposals in this draft, including photo and health integrations,
are not claims of implemented capabilities.

Optional ChatGPT plan assistance follows the documented token-sharing sign-in,
with request-specific consent, strict structured suggestions and local review
before writes. Offline planning does not depend on it. Physical Android/iPhone
callback and completed live inference are not yet verified.

## 1. Product contract

A local-first nutrition app with food logging, meal planning, coaching, health
integration, and supportive gamification. No app accounts or backend auth.
User records persist on device in SQLite.

**The app implements its features. The assistant is an optional interaction layer.**

Terminology: "assistant", "model", "inference", and "provider" mean the optional
artificial-intelligence layer. Bare "AI" is reserved for Adequate Intake in
nutrition references and is rendered "Adequate Intake (AI)" (nutrition spec
§1.1).

- Nutrition arithmetic, targets, expenditure estimation, planning constraints,
  grocery lists, coaching findings, and rewards must work without inference.
- The assistant may interpret a request, extract a label, suggest food matches
  from a photo, invoke app operations through validated commands, or explain app
  findings.
- ChatGPT-powered image input is in scope. A custom small on-device food vision
  model is a much later research project, not a release dependency or fallback.
- Planning and coaching are core features, not optional assistant add-ons.
- No backend does not mean no network: optional providers, dataset downloads,
  and platform health exchange are separate integrations with separate policies.

User-confirmed boundaries above are requirements. Mechanics below are engineering
recommendations adopted for this draft; algorithm parameters and safety policies
still need validation before release.

## 2. Architecture and authority

```text
Manual UI / optional assistant interaction
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

### 2.1 Document authority

`nutrition-engine-spec.md` owns nutrient definitions and arithmetic, quantity and
snapshot semantics, eligibility/target/planning/coaching rule behavior, typed
domain contracts, and algorithm acceptance. This document owns product scope,
user-facing flows, consent UX, provider authorization, storage/export/privacy,
delivery gates, and the platform stack.

Neither document overrides the other in its own area. A conflicting statement
must be revised in the owning document before release; a cross-reference is not
a substitute for that revision. This document does not assert implementation:
the release ledger records it separately.

### 2.2 One write path

The same application services serve forms, buttons, and conversational requests.
No core service imports a remote inference provider. The assistant cannot execute
arbitrary SQL, read the database directly, or mutate records without a typed
command.

- Reads expose only the necessary, user-authorized information.
- Writes have typed parameters, domain validation, and the confirmation their
  handler requires. An imported or assistant-proposed value is not a write.
- Assistant-derived food entries, corrections, targets, and plan changes require
  a local-user confirmation of the current revision before commit.
- Multi-step changes are transactional where applicable.
- Every write carries a stable request ID; retries return the original receipt
  rather than create duplicate logs, targets, plans, or health writes.
- An async result is attached to its originating draft and revision. A stale
  result cannot replace an edited, cancelled, or committed draft.
- The assistant's authority is the allowlist and role model in nutrition spec
  §2.1–2.2. It may issue only assistant-invocable proposal commands and
  explanations; it cannot confirm, commit, grant consent, switch providers, read
  credentials, activate datasets, write health records, or delete data.
- Assistant output, OCR text, label text, and imported content are untrusted
  data, never instructions. Embedded text cannot change the allowlist, role,
  policy, or confirmation state.
- Consent is scoped per provider, purpose, payload class, request, draft, and
  revision. It is given on a UI surface, consumed by one transfer, and permanently
  revocable; a model-rendered prompt is not a consent surface.
- Review is an event by the local user against one revision, not a status that
  survives an edit and not a claim of accuracy. There is no `verified` state; a
  reviewed estimate remains an estimate with its provenance.
- Explanations preserve the source finding's evidence, numbers, and
  qualifications. They cannot add derived numbers, diagnoses, or treatment
  advice (nutrition spec §2.6).
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
create a reviewed custom food with `label_printed` provenance; generic model
estimates remain `assistant_inferred`/`estimated` after review and are never
promoted to measured or "verified" database facts.

A proposed quantity carries its method and limits (nutrition spec §4.1.1). A
photo estimate is not a measurement, cannot carry an uncalibrated percentage
confidence, and cannot establish batch yield or pantry stock. The confirmed
quantity is stored separately from the estimate and is what the arithmetic uses.
Review accepts a value for logging; it does not verify accuracy. If a printed
serving mass is missing, the label quantity stays per serving/item rather than
being converted to invented grams.

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
- All chat free text is safety-scanned locally before any command runs; the
  assistant is not the detector. A validated typed command consumes only the
  text spans bound to its typed arguments. The matcher still scans every span,
  including consumed command spans; only residual routing is limited to
  unconsumed text, so an eligible phrase inside an exact bound food name still
  creates `user_reported` while the command executes. All non-whitespace,
  non-punctuation text that is not consumed — including the residual of a mixed
  command+symptom message, and any free-text argument value that is not a
  manual-UI safe input mode — enters the typed safety channel and can only
  become `user_reported`, `unclassified_report`, or `declined`. It is never
  silently ignored. For example, "log 100 g apple, also I have a numb tongue"
  logs the apple and routes the residual to safety intake, not silence. A
  rejected or unlisted command consumes nothing, so all of its text enters
  safety intake.
  Safe input modes are manual-UI fields only: they retain or echo the value, scan
  it, offer the safety channel on an eligible match, show a persistent
  non-safety notice with a visible safety-channel action, and never assert the
  text is non-symptomatic. A model cannot declare a span, field, or argument
  safe.
  Provider absence or extraction failure does not justify fabricated "no
  symptoms", triage, urgency, or reassurance. This proposed safety routing is
  not a gate on starting estimates in the private-testing implementation.
- Chat is not a bypass. Conversational changes use the same allowlisted command,
  validation, revision check, and local-user confirmation as the UI. A chat-only
  write path is a defect, not a feature.
- Voice is optional. Device/locale support and offline availability must be
  checked; never silently substitute remote ASR for an on-device privacy promise.
- Combining inputs preserves provenance and supports merge/replace decisions
  without double-counting the same item.
- Corrections improve explicit local aliases and saved defaults where useful;
  they do not imply an automatic training pipeline.

## 4. Nutrition data and calculations

### 4.1 Sources and delivery

INSA's Portuguese food-composition database is the primary catalogue target;
France's CIQUAL is a fallback, not a substitute silently presented as INSA.
USDA FoodData Central and Open Food Facts remain other candidate sources.
Verify source-specific distribution rights and measure Portuguese coverage;
neither available nutrient fields nor coverage imply completeness.

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

- Distinguish unknown, measured zero, trace, and estimated values. A value keeps
  its source qualifier through import, review, and correction; there is no
  `verified` upgrade (nutrition spec §1.1, §4.1).
- Track and expose all supported source nutrients and constituents, including
  energy, protein, carbohydrate, sugars, fats, fibre, vitamins and minerals.
  Availability depends on source coverage and compatible definitions; missing
  values remain unknown, not zero. Do not promise a fixed micronutrient count.
- Nutrient displays expose missing coverage; do not diagnose deficiency from
  incomplete logs or missing nutrient values.
- Canonical mass in grams only when a supported conversion exists. Volume
  conversion requires a food-specific density; piece/serving conversion requires
  a recorded portion weight. A volume-only record remains per ml and is computed
  by the dimensional contract (nutrition spec §4.2) without an invented mass.
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
  not silently overwritten by check-ins. An assistant may propose a target the
  user typed or stated; it cannot generate, install, or approve an automatic
  target, and the recorded origin remains `userDeclared` (nutrition spec §2.2,
  §7.1).
- The intended population is adults. Goals are user-selected (loss,
  maintenance or gain); conditions and preferences are explicitly declared,
  editable and optional. Future condition-aware dietary and meal-schedule
  recommendations should account for, at minimum, diabetes, a separate history
  or risk of low blood glucose, high triglycerides and high cholesterol, without
  inferring diagnoses, disease severity or medication needs. The intended output
  is food composition and meal organization, not treatment or medication
  advice. Condition-aware dietary advice still requires reviewed policy and
  safety routing; declarations alone do not certify a recommendation as safe.

### 5.2 Adaptive mechanism

The intended adaptation uses weight as its only body measurement; smartwatch
and other health measurements are not prerequisites. A candidate may also use
explicitly recorded food intake and goal history. A weight trend alone does not
identify energy expenditure or the cause of a change. Any algorithm and its
inputs remain subject to the nutrition specification's evaluation gate.

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
- The assistant can translate 'make dinners quicker' into validated planner
  inputs or explain a swap. It does not implement the planner, certify its
  output, or accept a relaxation; that requires the user's confirmation on the
  current plan revision (nutrition spec §2.3, §9.3).

## 7. Deterministic coaching — core

Weekly check-ins and on-demand insight cards work with no provider connected.

- Compute findings from local history: logging coverage, weight trend, plan
  consistency, selected nutrient coverage, and possible progress plateaus.
- Each finding includes its time window, evidence, data-quality caveats, and a
  suggested action from a versioned rule library.
- Use templated language as the complete baseline experience.
- Suggest holding course or improving data quality before unnecessary target
  changes. No moral judgments about food or punishment for missed days.
- The assistant may explain findings and answer questions using authorized app
  queries. Derived numeric claims must come from tool results. Clearly
  distinguish general model commentary from app-computed findings.
- An explanation preserves the finding's evidence and limitations and is
  validated before display (nutrition spec §2.6). Numbers, units, evidence
  references, and required qualifications are checked exhaustively; a detected
  forbidden phrase or a stripped caveat withdraws the explanation and shows the
  deterministic template. Forbidden-phrase detection is list-based and does not
  guarantee catching every paraphrase.
- Conversational changes route back through ordinary reviewed app operations and
  local-user confirmation. Chat is not a confirmation channel and cannot satisfy
  review, grant consent, or bypass an allowlist (nutrition spec §2.2–2.3).
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
- Use the typed request/result envelope and audit snapshot in nutrition spec
  §2.1 and §2.5. Record provider id, provider-reported model id or `unknown`,
  adapter version, prompt/schema versions, consent id, and disposition. Never
  infer a model identity from behavior or marketing.
- Capability checks cover image input, structured output/tool calls, context,
  streaming, and cancellation. Validate results regardless of advertised support.
  Advertising `toolCalls` grants no command permission; the allowlist for that
  request is the only permission (nutrition spec §2.2).
- Tool output is parsed by a versioned adapter against the declared schema.
  Unknown fields, wrong units, unsupported tasks, and free-text commands are
  rejected. No command is executed from prose.
- The assistant cannot grant or change consent, authorize a provider, switch
  providers, read credentials, approve a dataset, or confirm a draft. Those are
  local-user UI actions with their own surfaces.
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
- Provider data is untrusted input. Treat OCR text, food names, label text, and
  imported content as data, not instructions. Embedded text cannot widen the
  allowlist, change a role, grant consent, or skip confirmation; validate all
  resulting commands and discard a stale or mismatched result.
- Audit snapshots contain a payload hash and algorithm, payload classes,
  structured proposal, and provenance by default, not raw media, raw chat text,
  or a safety quote span. A quote is shown transiently for category
  confirmation; its persisted form is a hash/length unless the explicit
  sensitive-text retention setting is on, and that setting is covered by
  deletion. A `reported_text_ref` is null when text was not retained (nutrition
  spec §2.5, §3.5).

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
10. Assistant boundary tests: allowlist denial, consent withdrawal, stale
    revision/`Superseded`, idempotent replay and conflicting retry, prompt
    injection in label text, untrusted tool output, mandatory local-user
    confirmation, explanation evidence/caveat validation, and model-identity
    `unknown` handling (nutrition spec §2, §12).
11. Safety-channel tests: fail-closed routing of all unconsumed free text
    (including mixed command+symptom messages and free-text arguments), consumed
    span typing/overlap rejection, matching of an eligible phrase inside a
    consumed exact-name span, safe-input-mode retention/scan behavior, eligible
    phrase matching, negated/quoted/attributed ineligibility, classification
    transitions and decline reasons, `unclassified_report` blocking only new
    automatic advice, approved-copy selection, and no assistant-authored triage
    or reassurance (nutrition spec §3.5, §12).

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

Assistant-specific unresolved decisions: approval and localisation of the
symptom phrase table and safety copy; the negation/quotation/attribution matcher
rules; the closed schema of manual-UI safe input modes and their visible copy;
the reviewer for the command allowlist and each high-impact command;
whether a provider exposes a stable model identifier (absence must remain
`unknown`); retention limits for raw media/chat text and safety quotes, and
their deletion path; and the schema/version support window for adapters. None of
these is established by this draft.
