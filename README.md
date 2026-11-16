# Salu

Local-first nutrition recording, planning and coaching in Flutter for Android and
iOS. SQLite holds the user's records. No app account or backend is required.
AI and health exchange are optional integration boundaries.

**This is a staged development build. The complete specified release is not ready.**
The attached contracts are preserved in `docs/product-spec.md`,
`docs/nutrition-engine-spec.md` and `docs/architecture.md`. Current implementation
limits, evidence and outstanding gates are tracked in `docs/release-checklist.md`
and `docs/decisions/0003-contract-reconciliation.md`.

## Development

Flutter 3.47.9 (bundled Dart 3.13.7), a full JDK 17 for Android, and native SQLite
for host tests. Android dependencies currently need SDK platforms 34, 35 and 36,
build tools 36 and NDK 28.2.13676358. A Java runtime without javac cannot build.
Dependency lockfiles are committed. `.codex/config.toml` registers `dart mcp-server`;
add the repository root with the server's roots mechanism before using its tools.

```bash
bash tool/verify.sh
cd app
flutter build apk --debug --target-platform android-arm64
```

Android and iOS hosts are version-controlled. `app/tool/bootstrap_platforms.sh`
only creates missing hosts; it preserves existing hosts and application sources.
iOS compilation requires macOS and Xcode. CI includes an unsigned iOS build job,
which does not replace device or accessibility testing.

## Implemented development workflows

- Local food search, user-entered foods and explicit quantity confirmation.
- Native g/ml/item/serving source bases. Matching volume needs no density;
  incompatible dimensions require recorded conversions. Unknown grams stay absent.
- Nutrient states, exact decimal/rational scaling, partial-record completeness,
  quantity/source snapshots, stable diary dates and explicit diary corrections.
- Guided onboarding proposes a seven-day plan from bundled meals, without food
  search or recipe creation. Plans and groceries are reviewed before saving;
  meals are never automatically logged. Existing recipes, batches and history
  remain available.
- Grocery names are simplified for shopping while retaining source identities.
  Ready-cooked rice is shown as a cooked-weight requirement, not silently
  converted to an estimated quantity of dry rice.
- Guided plans can favor explicitly classified whole-grain options when lipid
  conditions are declared. Brown-rice meals start from raw INSA rice and take
  45 minutes; shorter cooking limits exclude them. This is a relative preference,
  not a guarantee of clinical suitability.
- Optional starting calorie and macro estimates use explicit profile inputs and
  exact arithmetic. They are estimates, not measured requirements; manual and
  clinician-provided targets retain their ownership. Planning also works without
  numbers.
- Local weekly coverage/safety/hold-course check-ins, water records and an
  endpoint-only weight reading log (no trend, target or calorie proposals),
  plus idempotent engagement events without food/weight/fasting penalties.
- English and European Portuguese screens, scalable layouts and labelled controls.
- Versioned full archive, encrypted user-controlled backup, CSV, staged atomic
  restore, deletion and schema-v1-to-v2 migration tests.
- Optional ChatGPT plan assistance uses the documented token-sharing sign-in,
  request-specific consent and locally reviewed proposals. No app account or
  API key is needed. Android sign-in has been reported working on a test phone;
  completed live inference remains unverified. Image upload is not part of
  this integration.

The INSA 7.1–2026 workbook is bundled and installed automatically for private
family testing; Food search shows its source attribution. Existing custom foods
and diary snapshots are retained. The data are not coverage-validated, and wider
redistribution rights remain unconfirmed. INSA available carbohydrate is retained
with its source definition, separately from EU carbohydrate totals. Host-only
profiling is in `docs/host-profile.json`.

## Remaining release work

Physical Android and iPhone testing, live ChatGPT sign-in and completed inference,
accessibility, performance, native health integration, wider distribution rights,
and platform signing remain open. Private testing does not impose approval-based
feature locks; clinical and distribution review would be separate work before a
wider release.

## Dependency boundaries

`app` → `salu_data` → `salu_core`. The core has no runtime package dependencies,
Flutter, database or network imports. Run `bash tool/check_boundaries.sh` to enforce
that boundary. Feature writes use validated domain values and revision-checked,
idempotent local transactions; additional feature-specific commands are still
needed before exposing every operation to optional provider output.
