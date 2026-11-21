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
