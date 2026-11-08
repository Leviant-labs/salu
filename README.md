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
- Declared targets with ownership, blocked automatic generation/adaptation, safety
  declarations and a supportive display mode.
- Immutable recipe versions, equal-serving calculations, finite cooked batches,
  transactional batch intake, deterministic organization-only dinner plans,
  pinned meals and grocery checkmarks. Plans never auto-log consumption.
- Local weekly coverage/safety/hold-course check-ins, water/weight records and
  idempotent engagement events without food/weight/fasting penalties.
- English and European Portuguese screens, scalable layouts and labelled controls.
- Versioned full archive, encrypted user-controlled backup, CSV, staged atomic
  restore, deletion and schema-v1-to-v2 migration tests.
- Provider capability/authorization/consent/revision contracts and failure tests.
  No provider transport is connected and no image is queued for upload.

The fixture catalogue is debug-only and clearly source-tagged. It is not a
licensed/coverage-validated production dataset. Custom foods remain usable without
any fixture or provider. Host-only profiling is in `docs/host-profile.json`.

## Remaining release work

Production catalogue/import/licensing and Portuguese coverage; source-specific
nutrient definitions throughout persistence/import/UI; reference-policy editions
and comparisons in the app; all coaching families; full planning schedule and
objective controls, repair/relaxation revisions, planned-batch stock and grocery
editing; saved meals/favourites/barcodes; complete tracking/reward presentation;
provider transports and draft-review screens; native health adapters and durable
reconciliation; native backup/cache/deletion audits; device accessibility,
performance and end-to-end evidence. Platform signing/distribution is not configured.

The safety/target/adaptation policies, provider eligibility/terms, clinical copy
and data rights require their own reviews. Unit tests and debug compilation do
not constitute those approvals. Automatic targets return `POLICY_NOT_APPROVED`;
adaptation stays disabled for ordinary users.

## Dependency boundaries

`app` → `salu_data` → `salu_core`. The core has no runtime package dependencies,
Flutter, database or network imports. Run `bash tool/check_boundaries.sh` to enforce
that boundary. Feature writes use validated domain values and revision-checked,
idempotent local transactions; additional feature-specific commands are still
needed before exposing every operation to optional provider output.
