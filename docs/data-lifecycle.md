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
