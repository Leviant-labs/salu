# Salu improvement programme — planning design

Status: proposed implementation basis, not an implementation or release approval.

## 1. Scope and assumptions

This document translates the repository review and the user's two additions into six independently deliverable plans. It supplements `docs/product-spec.md`, `docs/architecture.md`, and `docs/nutrition-engine-spec.md`; it does not replace their safety or privacy contracts.

User requirements:
- Restore first-run onboarding as guided, separate pages rather than the current long profile form.
- Add simple OpenAI-compatible and Anthropic-compatible endpoint configuration, credential storage, and model discovery through `/models` or a provider-specific `/catalogue`.

Planning assumptions requiring confirmation before execution:
- Keep ChatGPT sign-in alongside endpoint/key connections. No current connection is silently replaced.
- Support multiple named connections, one explicitly selected active connection, and one selected model per connection. Per-task routing and automatic failover are outside this iteration.
- Keep profile editing as a compact form in Settings; only first-run setup is a wizard.
- Preserve generated native hosts, with reviewed, versioned configuration inputs and deterministic verification. Existing untracked native folders are not disposable scaffolding.
- Full-archive restore replaces user data after review; merging two diaries is outside this iteration.
- A local HTTP endpoint is an explicit advanced opt-in. Remote endpoints require HTTPS.

## 2. Global constraints

Copy these exact requirements into every implementation plan:

- Flutter is pinned to `3.44.0`; Dart is the version bundled with that Flutter SDK.
- `salu_core` depends only on the Dart SDK; Flutter, SQLite, filesystem, cryptography, and HTTP adapters stay outside it.
- Unknown, trace, reported, measured, and estimated nutrition states survive writes, migrations, exports, and restoration.
- New meals save locally before optional inference; corrections and plan changes require review and revision-checked confirmation.
- Connecting, discovering models, restarting, or restoring never authorizes a meal/photo upload or automatic provider failover.
- Credentials live in platform secure storage and never enter ordinary documents, logs, fixtures, CSV, or archives.
- Automatic targets and adaptive expenditure remain gated; all onboarding health inputs and AI setup are optional.
- Preserve existing user changes, especially untracked `app/android/`, `app/ios/`, and `linked_list_merge/`; never stage them wholesale.

## 3. Baseline and verification honesty

The review observed schema version 3, 41 passing core tests, clean core analysis, and 30 passing focused assistant tests. Broader suites were blocked by stale ignored Drift output and unresolved local dependencies. These are baseline observations, not evidence of a clean build or a source defect after regeneration.

Before feature implementation, resolve dependencies and regenerate in an isolated worktree. Pin the SDK and track application/package resolution locks for this monorepo. Never edit generated `.g.dart` files manually or treat ignored build output as source.

## 4. Guided onboarding

Pages, in fixed order: Welcome; Goals; Starting point; Food preferences; Declared targets; AI setup; Review. Use Next, Back, Skip this step, and a persistent step label. Android back returns to the preceding page; exiting the first page does not silently complete setup.

Persist a versioned `onboarding-draft` document with the current step and only validated profile fields. Do not persist raw credentials or incomplete numeric input. Save on successful page navigation; await the save before advancing. A failed save keeps the user and edits on the same page. Completion writes the final profile and removes the draft in one SQLite transaction; `onboarded` is set only at completion or explicit Skip setup. Skipping setup retains an existing committed profile and does not implicitly commit unfinished answers.

Already-onboarded installations do not see the wizard again. The existing profile and preferences editors remain reachable and accept blank optional weight/targets; their current requirement for weight during editing is removed. Existing tests that expect weight to be mandatory must change explicitly.

The AI page initially supports Skip and a callback for connection setup. The provider plan supplies that callback; failed authentication never blocks onboarding. Selecting a model is not permission to send meal data.

## 5. Endpoint profiles and provider contracts

An endpoint profile has stable ID, display name, protocol (`openaiChat`, `openaiResponses`, `anthropicMessages`), API root URL including any deployment prefix, discovery mode (`models`, `catalogue`, `manual`), selected model ID, an optional explicit image-input declaration, and `allowInsecureLocal`. No arbitrary credential-bearing headers or arbitrary discovery origins are supported.

Paths are relative to the configured API root: `models`, `catalogue`, `chat/completions`, `responses`, and `messages`. For example, an API root ending in `/v1` keeps that prefix; URL joining must never drop it or double `/v1`. Reject URL userinfo, query strings, fragments, non-HTTP schemes, and CR/LF. Resolve only same-origin paths. Redirects are disabled. Permit HTTP only after explicit local-network opt-in for loopback, `.local`, and private-address hosts; resolve and verify addresses before use, including IPv6. This is a mobile native feature, not a browser proxy.

Keys use per-connection secure-storage slots. Profile documents contain no key material. Changing an origin or protocol requires re-entering the key; credentials are never silently reused for a new destination. Failed secure-store writes cannot leave an apparently connected profile. Disconnect immediately invalidates the connection epoch and cancels its local requests even if remote revocation fails.

Reuse and extend `InferenceProvider` rather than putting provider policy in nutrition code. Preserve the `SaluAssistant.ask` call shape as a migration facade while moving its dispatch behind injected providers. Normalize successful task output to the existing untrusted JSON object contract. Task parsers still enforce domain validation.

OpenAI Chat Completions, OpenAI Responses, and Anthropic Messages have separate serializers/parsers. Anthropic uses `x-api-key` and `anthropic-version: 2023-06-01`; OpenAI-compatible endpoints use Bearer authentication. Transport compatibility is explicit, not inferred from a model name. Own-key adapters request non-streamed bounded replies first; retain streaming support for the existing ChatGPT adapter.

`models` supports the providers' `data` list of `{id, display_name?}` and pagination where returned. `catalogue` supports only documented, tested shapes: `data:[{id,display_name?}]` or `models:[{id,name?}]`. Reject ambiguous IDs and malformed structures; allow manual entry on 404/405 or unsupported shape. Discovery is an explicit GET, never a generation call. Limit 10 pages, 1 MiB per response, and 2,000 unique IDs; keep the first occurrence's display name. Never infer image support solely from a list result. Manual capability declarations are clearly labelled unverified and runtime rejection remains possible.

One operation deadline is 45 seconds, including credentials, refresh, discovery if actually needed, upload, and parsing. Connection timeout is at most 10 seconds. User-triggered discovery/test has a 15-second deadline. Generation responses are at most 512 KiB, input text at most 24 Ki UTF-16 code units, at most four images, 4 MiB each and 8 MiB total, maximum JSON nesting depth 32. Retry only through explicit user action. Cache discovered models per profile until explicit refresh; ordinary generation uses the stored selected model.

Incremental SSE parsing accepts only complete terminal output, stops at completion without waiting for connection close, and rejects failed, truncated, or oversized responses. Connection and data-reset epochs fence late writes. Safe error categories reach the meal card and Settings without raw server bodies or secrets.

## 6. Nutrition and allergy reliability

Plausibility checks are engineering screening rules, not clinical guidance. Version 1 blocks automatic use of negative/nonfinite values, more than 10,000 kcal per item, more than 1,000 g of a gram nutrient, or more than 100,000 mg sodium per item. For a declared gram portion, energy above 12 kcal/g or any individual gram nutrient above 1.1 times portion mass is suspect. A macro-energy difference above max(100 kcal, 30% of declared energy) is a review warning only. Do not derive mass checks for ml/pieces/servings or silently convert kJ/salt. Store suspect fields as unknown in automatic estimates while preserving safe fields and a review issue; OCR issues are shown before applying label evidence. Manual records remain editable and explicit user review can retain an unusual value with provenance.

Canonical allergen IDs cover milk, egg, fish, crustacean, mollusc, peanut, treeNut, soy, wheatGluten, sesame, celery, mustard, lupin, and sulphite. Known English and European Portuguese aliases map to these IDs; an unresolved strict term fails closed with an explanation, never becomes an ignored constraint. Ingredient exclusions remain distinct from allergen declarations. Declaration status is unknown or declared, with provenance; an empty declared set is not a cross-contamination guarantee. Seed only recipes whose declarations can be explicitly documented; do not manufacture certainty from food names.

Versioned recipe codecs preserve serving bounds, allergen status/source, ingredient source/licence/quality/preparation/tags, density/portion definitions, purchase IDs, and all current amounts. Read the existing unversioned form with its current defaults, but never upgrade unknown allergen status to a declaration. Unknown future document versions are rejected without overwriting saved data. Recipe and batch round trips must preserve meaning.

## 7. Reversible diary and media lifecycle

Add request-ID-idempotent revise, move, delete, and undo operations. Moving retains the meal ID, evidence, creation instant, and recorded offset; only assigned diary date changes. Dates cannot be later than the captured current diary date. Updating/removing a meal photo is an explicit correction and cannot remove label evidence implicitly.

Schema version 4 adds a `meal_mutations` journal containing request ID, meal ID, expected/resulting revision, operation, before/after JSON, creation time and undo expiry. Delete removes the active row but retains an undo snapshot for 24 hours. Undo succeeds only against the journal's latest compatible state and restores a higher revision, so a pre-deletion inference result cannot overwrite it. The visible snackbar offers Undo for 10 seconds; the journal is still part of recovery/export until expiry. Stock consumed from a cooked batch is not automatically replenished by meal deletion; explicitly disclose that inventory is separate. A later inventory adjustment requires its own command.

Images have managed IDs and relative filenames, not machine-dependent absolute references in exported data. A media service owns path resolution, intake, reference scanning, and garbage collection. Do not delete a file referenced by a live meal, label, draft, or unexpired journal. Failed/ambiguous writes protect media until reconciliation. Recover Android image-picker lost data through an explicit resume/confirm flow, never automatic inference. Retain existing original images until a user selects cleanup; upload encoding continues to strip metadata. Document that locally retained originals may still contain metadata.

## 8. Backup, export, restore, and erase

Use a logical versioned archive, not a raw copy of a live SQLite/WAL file. Export all user tables/documents, meal mutations, recipe versions, planning/profile/draft/check-in data, and optional media. Replaceable catalogues are not included: include their edition/licence manifest, preserve all user snapshots, and explain that catalogues must be reinstalled for search. Never archive provider profiles or credentials. Explicitly classify nonpersonal catalogue edition/index metadata (including `search-index-state`) separately from user documents; retain installed system metadata on restore/erase and exclude it from the user snapshot. Unknown document kinds fail export visibly until classified; do not silently discard new feature data.

Add `archive` and `cryptography` only to the app adapter package, with resolved versions locked. Archive format 1 is ZIP containing `manifest.json`, `records.json`, and `media/<opaque-id>`. Hash media with existing SHA-256 support. Run compression and cryptography off the UI isolate. Initial limits: 64 MiB encrypted/compressed payload, 128 MiB total expanded bytes, 25,000 files, 16 MiB records JSON, 24 MiB individual media. Reject over-limit exports/imports with an actionable message; never silently omit selected data. A large diary can explicitly choose records-only export.

Encrypt with AES-256-GCM, a fresh 16-byte salt, fresh 12-byte nonce, and PBKDF2-HMAC-SHA256 at 600,000 iterations. Envelope: magic `SALU1`, salt, nonce, ciphertext, 16-byte authentication tag; magic and salt/nonce are authenticated associated data. UI confirms a password of at least 12 characters. Password is never persisted; forgetting it means the archive cannot be recovered. This is an engineering default to benchmark on target devices, not a claimed universal latency budget. Do not offer an unencrypted full archive in this iteration; CSV is explicitly plaintext.

Restore decrypts and validates bounds, format, hashes, IDs, references, nutrient states, dates and document versions in staging before acquiring a write fence. Reject traversal paths, absolute paths, symlinks, duplicate members/IDs, unsupported future versions, and corrupt archives. Show a preview of counts and replacement scope. After confirmation, stage media under fresh IDs, replace user rows atomically, then release the fence. If DB commit fails, old data/media remain usable; staged unreferenced media are cleaned later. Clear connection state and require explicit reconnection; never restore an upload queue. Credentials are cleared only after successful data replacement, with a persistent cleanup marker to finish after interruption.

CSV contains ISO date, meal ID, slot, food name, portion amount/unit, nutrient key, value, state, and provenance; unknown value is empty, not zero. Escape delimiters/newlines and neutralize spreadsheet formula prefixes in user-controlled text. CSV is not a full backup.

Erase uses an app-owned reset marker and immediately fences/cancels operations, then clears user tables, journals, user/provider documents, local images/thumbnails/staging, recognized legacy files, and all `salu.*` credential slots. Keep replaceable catalogue rows and nonpersonal catalogue edition/index metadata. Resume incomplete erase before opening the UI after restart, prevent legacy JSON reimport, and do not claim deletion from user-held archives, remote providers, OS backups or health stores. No forensic secure-erasure guarantee for flash storage.

## 9. Startup, architecture and daily UX

Render a recoverable startup shell before database/catalogue initialization. Once initialized, search uses an incrementally maintained FTS index with a persisted index-format version. Only absent/outdated indexes rebuild. Index changes and catalogue changes commit together. On devices without FTS, use a paginated whole-catalogue fallback with bounded page memory rather than permanently hiding all rows after the first 512.

Extract deterministic meal corrections and plan/grocery calculations into core application services, persistence into `salu_data`, and side-effect orchestration into injected app controllers. Keep routing/presentation in widgets. Avoid repository-wide rewrites, changing nutrition rules during extraction, or breaking batch debit/diary atomicity. Tests must compare before/after snapshots on the same fixtures.

Today shows a compact recorded-intake summary before meal cards, with unknown/partial/estimated states unchanged. Targets are opt-in context, never a pressure ring by default. Surface recent/favorite reuse in logging. Replace the long library modal with a searchable screen containing Foods, Meals, Recipes, and Leftovers sections. Keep Save accessible above keyboard/safe-area in the meal editor and preserve correction preview.

Localize interface and input parsing for `en` and `pt_PT` using Flutter localization/ARB resources; machine IDs, JSON, source names and archive dates are locale independent. Test screen readers, contrast, 200% text, 320px-wide layout, dark mode, keyboard/focus order, and reduced-motion behavior. No new analytics dependency.

## 10. Release evidence and exclusions

Normal CI resolves locked dependencies, regenerates Drift, checks boundaries, formatting, analysis, unit/widget tests, builds Android release without release signing secrets, and builds iOS with `--no-codesign` on macOS. Device smoke tests exercise onboarding, offline logging/correction/restart and media permission denial; provider contract tests use loopback fixtures with fake secrets. Real-account sign-in and image input require a separate opt-in release checklist, not secrets in general CI.

Record named-device p50/p95 cold/warm startup, search with 25,000 foods, recipe planning, peak memory, database/media size, provider request preparation and label correction effort. Do not invent release-performance numbers before measurement. Track 78-food starter and 8 starter-recipe coverage explicitly; measure Portuguese coverage and curate/licence packs separately.

Out of scope: health integration implementation, automatic calorie targets, adaptive expenditure, rewards/gamification, custom sync, on-device food recognition, provider marketplaces, background upload queues, and arbitrary discovery schemas. Existing placeholders for these features remain honest and are not presented as implemented.
