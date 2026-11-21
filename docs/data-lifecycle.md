# Data Lifecycle and Managed Media

## Managed Media References

Salu stores meal and nutrition-label photos in an app-owned `meal-images` directory under application support storage, addressed by opaque references rather than raw filesystem paths:

- **Reference format:** `media:<opaque-id>` where `<opaque-id>` matches `^[A-Za-z0-9_-]{1,128}$`.
- **On-disk filename:** `<application-support>/meal-images/<opaque-id>.image`.
- **Import semantics:** `ManagedMediaStore.importImage` validates the opaque identifier, writes via an exclusively created staging file inside `meal-images`, and renames into place without ever overwriting an existing managed file or deleting the source `XFile`. If copying fails, only the failed owned staging file is removed.
- **Resolution & confinement:** `ManagedMediaStore.resolve` resolves valid `media:<opaque-id>` references and recognized legacy app-owned absolute paths strictly inside the owned `meal-images` directory. Traversal segments (`..`), invalid IDs, and out-of-root paths are rejected and resolve to `null`. Missing files render an unavailable state in the UI without dropping the evidence reference from the diary record.

## Retention Default and Metadata Handling

- **Retain-until-deletion default:** Stored original photos remain in `meal-images` until an explicit cleanup or deletion choice removes all references to them.
- **Local originals vs. uploads:** Local original files stored in `meal-images` may retain camera metadata (such as EXIF) so local evidence stays intact. Whenever a photo is prepared for AI estimation or label transcription, `encodeMealUpload` decodes pixels and re-encodes a fresh PNG so original bytes and metadata (including EXIF and GPS) are never uploaded.

## Reference-Safe Cleanup

- `ManagedMediaStore.collect` and `ManagedMediaStore.removeUnreferenced` delete only unreferenced `.image` files inside the owned `meal-images` directory.
- Collection consumes the union of references across all owners: saved meals, attached nutrition labels, active meal/onboarding drafts, and unexpired mutation snapshots (with journal references added in Task 2). No collection runs until all owners are enumerated.
- When the meal editor is disposed, only unreferenced draft images are eligible for cleanup. Images belonging to a committed save or an ambiguous/failed write are protected and never deleted on disposal.

## Interrupted Picker Recovery

On platforms such as Android where the OS may kill the app process while the system camera or gallery picker is open, `ManagedMediaStore.recoverLostPickerImages` wraps `ImagePicker.retrieveLostData()` (returning an empty list safely on unsupported platforms).

When recovered photos are present in the meal editor, Salu presents an explicit **Attach to meal** / **Discard** prompt. Recovery never triggers automatic AI inference, automatic upload, or automatic diary saves.

## Revisioned Meal Mutations, Undo, and Journal Lifecycle (Schema v4)

- **Durable mutation journal (`meal_mutations`):** Every revision, date move, delete, and undo on a `PhotoMeal` runs inside a single database transaction that checks idempotency by `request_id` + `payload_digest` and verifies `expected_revision` against the active row. Replaying an identical request returns `alreadyApplied`; reusing a `request_id` with a different payload returns `stale`.
- **24-hour undo snapshot & 10-second snackbar:** Deleting a meal removes its active `photo_meals` row and writes a version-1 snapshot to `meal_mutations` with a 24-hour `undo_expires_at_ms` deadline. The diary shows a 10-second **Undo** snackbar wired to the durable undo token.
- **Revision fencing on undo:** Restoring a deleted meal assigns a strictly higher revision (`max(deleted.resultingRevision, latestMealJournalRevision) + 1`), ensuring late pre-deletion AI estimate results can never overwrite the restored meal.
- **Orphaned estimate status cleanup:** Once a deleted meal's 24-hour undo window expires, `MealMutationRepository.purgeExpiredUndoStatus` removes any orphaned `estimate:<meal-id>` status document from `local_documents`.
- **Media retention during undo:** `MealMutationRepository.referencedMedia` includes both live `photo_meals` media and unexpired deletion snapshots so media cleanup never deletes photos needed for an active undo window.
- **Batch inventory non-replenishment:** Deleting a meal logged from a cooked batch does not replenish remaining `cooked-batches` stock; the delete confirmation explicitly discloses this.
- **Legacy entries:** Legacy single-food `log_entries` rows remain readable in the diary and are explicitly outside photo-meal move/delete controls.

## Versioned Encrypted User Archives (`SALU1`)

Salu exports portable, authenticated encrypted backups using a versioned ZIP payload wrapped in a `SALU1` AEAD envelope:

- **Envelope & Cryptography:** `magic ("SALU1", 5 B) || salt (16 B) || nonce (12 B) || ciphertext || tag (16 B)`. Keys are derived with **PBKDF2-HMAC-SHA256** at **600,000 iterations** (256-bit key) using a fresh `Random.secure()` salt and nonce per export. Payloads are encrypted with **AES-256-GCM** authenticating the 33-byte header (`magic || salt || nonce`) as Associated Data (AAD). Passwords must be at least **12 characters**; malformed headers, wrong magic, short passwords, or over-limit files are rejected before KDF runs.
- **Allowlisted Archive Contents (Format 1):** Only `manifest.json` (format `1`, schema version `4`, `recordsFormat: 1`, `mediaOmitted`, `catalogueManifest`, counts, and per-file sizes + SHA-256 hashes), `records.json` (`format: 1`), and `media/<opaque-id>` (`^[A-Za-z0-9_-]{1,128}$`) are permitted. Path traversal (`..`), backslashes, drive letters, absolute paths, symlinks, duplicate ZIP members, hash/size mismatches, duplicate record IDs, malformed nutrient states, broken media evidence references (unless `mediaOmitted: true`), and provider profiles (`endpoint-connections`) are rejected.
- **Hard Resource Limits:** Enforced before expensive allocation or decompression:
  - Maximum encrypted / compressed archive payload: **64 MiB**
  - Maximum total expanded archive bytes: **128 MiB**
  - Maximum ZIP members: **25,000**
  - Maximum `records.json` expanded bytes: **16 MiB**
  - Maximum individual media file bytes: **24 MiB**
- **No Password Recovery:** Salu never persists, logs, or transmits backup passwords or derived keys. If a backup password is forgotten, the archive cannot be recovered.
- **Plaintext CSV Distinction:** Spreadsheet CSV exports are **unencrypted** and intended for ad-hoc analysis; they do not replace encrypted `SALU1` backups and do not include managed media or full restore metadata.
- **No Automatic Cloud Backup:** Salu is local-first and makes no promise of automatic cloud sync or cloud backup. Users choose where to store their exported encrypted archives.

## Consistent Snapshots, Staged Replace-Only Restore, and Write-Gate Fencing

- **Consistent 5-table snapshot (`UserDataRepository`):** Snapshots read `log_entries`, `log_entry_items`, `photo_meals`, `local_documents`, and `meal_mutations` inside one consistent database read transaction rather than raw-copying an open SQLite/WAL file.
- **Explicit Document Namespace Classifier:** Every `local_documents.id` is classified explicitly:
  - **User documents** (exported, replaced on restore, deleted on erase): `planning-profile`, `onboarding-draft`, `food-library`, `recipe-library`, `cooked-batches`, `check-in-settings`, `day:*`, `week:*`, `estimate:*`.
  - **Catalogue edition metadata** (`catalogue-edition:*`): exported into `catalogueManifest` alongside the bundled starter catalogue version (`bundledCatalogueDataset`), preserved on restore and erase.
  - **Nonpersonal system state** (`search-index-state`): excluded from user snapshots and preserved on restore and erase.
  - **Provider/credential metadata** (`endpoint-connections`, retired-credential metadata): excluded from user snapshots and cleared on restore and erase.
  - **Unknown namespaces:** Fail `snapshot()` visibly with `UnsupportedDocumentNamespaceException` so new features cannot silently leak or drop user data.
- **Staged Replace-Only Restore (`ArchiveService`):**
  - `inspect()` decrypts, decodes, and validates the archive in a temporary staging directory under `Isolate.run` and returns a password-free `RestorePreview` bound to a SHA-256 `contentDigest`. Any tampering or removal of staged files invalidates the preview.
  - `restore()` verifies the digest, stages archived media into `ManagedMediaStore` under **fresh managed IDs** (remapping `photoPath` and item `labelPaths` in the replacement snapshot so existing media remain completely untouched), acquires `DataWriteGate.exclusive`, immediately invalidates `OperationFence`, persists a durable credential-cleanup marker, and replaces the five user tables in FK-safe order inside one transaction while preserving `catalog_foods`, `catalog_barcodes`, `catalogue-edition:*`, and `search-index-state`.
  - On media-write or DB-replace failure, only newly staged unreferenced media are cleaned up; the original database and original media remain completely intact.
- **Write-Gate Fencing (`DataWriteGate`):** Ordinary app writes run inside `DataWriteGate.runWrite`. When an exclusive restore or erase is requested, new writes are rejected immediately (`DataWriteBlockedException`), admitted writes drain before the exclusive section starts, nested exclusive calls are rejected without deadlock, and network waits (such as AI meal estimation) stay outside `runWrite` with an `OperationFence` epoch check inside `runWrite` before commit.
- **Post-Restore Credential Cleanup Recovery:** After a restore commits, `ArchiveService` clears stored credentials via `CredentialStore.clearSaluCredentials()` and removes the durable cleanup marker. If cleanup fails or is interrupted, the marker remains on disk and `resumePendingCredentialCleanup()` retries it before allowing AI use after restart.
