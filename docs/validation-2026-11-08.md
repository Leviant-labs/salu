# Development validation — 8 November 2026

This records observed development evidence, not completion of the product release.

| Check | Observed result |
|---|---|
| Dart MCP | initialize, root registration, pub, fixes, analyzer and test tool calls verified |
| Core analysis | no diagnostics after fixes |
| Data analysis | no diagnostics after fixes |
| Flutter app analysis | no diagnostics after fixes |
| Core tests | 64 passed |
| Data tests | 15 passed, including real v1 migration, archive/encryption, batch-stock corrections |
| Widget tests | 6 passed, including offline native-volume logging and pt-PT large-text support mode |
| Module boundary checks | passed; no core runtime package dependencies, remote/database/Flutter imports |
| Git whitespace check | passed; Windows wrapper normalized through attributes |
| Android compilation | debug arm64 APK built with Flutter 3.47.9 and full Temurin JDK 17 |
| APK signature | apksigner verifies APK Signature Scheme v2, one debug signer |
| APK structure | ZIP CRCs and section-table bounds for every packaged ELF library passed |
| iOS compilation | not run locally; requires macOS/Xcode; unsigned CI job added |
| Device execution / accessibility | not run; Android/iOS devices, screen readers and native picker/permissions remain gates |
| Host profiling | reproducible synthetic 10k-catalogue search and planner smoke profile in host-profile.json |

The SDK's Azure metadata auto-detection was avoided with CI=true after inspecting
its short-circuit path. A full JDK, SDK platforms 34/35/36, build tools 36, NDK
28.2.13676358 and CMake 3.22.1 were provisioned for Android. TLS remained enabled;
the downloaded JDK was configured with the inherited environment proxy CA.

Native build warnings: file_picker still applies the legacy Kotlin Gradle plugin;
the pinned Flutter tool currently supports it but warns about future compatibility.
The last incremental build emitted native-strip temporary-file warnings and still
completed successfully. Packaged ZIP integrity, signatures and native ELF headers
were independently checked. These checks do not establish device runtime behavior.
The generated Gradle heap was reduced to 2 GiB and workers capped at two for this
8 GiB build environment.

Drift's multiple-instance debug warning appears in restore tests because live and
staging databases are intentionally separate executors. No global warning suppression
was added to conceal an actual shared-executor configuration error.

The full remaining feature/review/device checklist is in release-checklist.md.

## CI follow-up

The first remote Flutter app job passed. The data job exposed a Dart 3.13
experimental-member warning for Drift's pinned TableMigration API; its single
call site is now explicitly acknowledged, preserving the tested migration code.
Android CI lacked sdkmanager on PATH; Android SDK setup is now explicit before
installing plugin platforms. These follow-up changes affect CI setup and a
source annotation only; the saved APK is the original development build from
commit 0922de5. The workspace became unavailable after source and APK saving,
so follow-up checks run on GitHub Actions rather than being reported as local runs.


## Catalogue and recording continuation

The saved branch at 03e7761 was recovered and tree-hash verified before editing.
All four jobs at that head passed in Actions run 42485271610, including unsigned
macOS/iOS compilation. This supersedes the earlier locally-unavailable CI note;
it does not establish iOS device execution or signing eligibility.

The continuation adds schema 3 and archive format 3 (reads archive 2), FTS5
search with accent/alias support and a no-FTS fallback, exact GTIN lookup,
favourites, recently recorded foods, immutable saved-meal snapshots with separate
intake confirmation, explicit civil time/offset and assigned diary date, and
source-specific nutrient observations. Supplied energy units are preserved;
only an absent numeric counterpart derives by 4.184. US/unspecified carbohydrate
is retained in source observations and excluded from EU available-carbohydrate
projection. Custom-food inputs retain exact decimals. Ordinary repeat/save paths
refuse finite cooked-batch allocations; the batch workflow owns those stocks.

Catalogue packs validate in an isolated database and activate transactionally
only with confirmation and a matching release-pinned dataset/version/licence
review. No production dataset reviews are bundled. Raw USDA/CIQUAL/OFF adapters,
a licensed Portuguese baseline and dataset management UI remain outstanding.
This code does not establish source authorization or approve its own content.

Local validation for this continuation: 67 core tests, 24 data tests and 9 widget
tests; the data tests include real v2 SQLite upgrades, older archive restoration,
FTS index updates/fallback, favourite retry semantics, dataset rollback/review
gates, source-definition preservation, saved-meal confirmation and exact count
and volume quantities. Widget flows cover local barcode/favourites at 1.5x text,
backdated exact intake and saved-meal cancellation/confirmation, in addition to
the existing pt-PT supportive 2x text checks. Core/data/app analysis and boundary
checks must remain clear before publication. No connected device or simulator
was used. Native build results for this continuation are recorded separately.
