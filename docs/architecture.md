# Architecture

## Modules

| Module | Depends on | Owns |
| --- | --- | --- |
| `salu_core` | Dart SDK only | Domain types, nutrition arithmetic, diary time semantics, typed commands, ports for storage / health / inference |
| `salu_data` | `salu_core`, drift, sqlite3 | Schema, migrations, repository implementations, development fixture catalogue |
| `app` | both, Flutter, Riverpod, go_router | UI, composition root, platform adapters (camera, health, secure storage, OAuth) |

The boundary is enforced mechanically, not by convention: `salu_core`'s pubspec
has no Flutter, drift, or HTTP dependency, and `tool/check_boundaries.sh` greps
for forbidden imports so the rule survives a careless edit.

## Why the core is separate

Three concrete payoffs, in order of importance:

1. **Test speed.** Domain and command tests run under plain `dart test` with a
   fake clock and fake repositories: ~1 s, no device, no Flutter engine. The
   spec's golden tests (units, raw/cooked, recipe yield, historical snapshots,
   diary dates) all live at this level.
2. **A forcing function against AI in the core.** If a feature needs a provider,
   it needs an HTTP client, which cannot be imported here. Planning, coaching,
   targets and arithmetic must therefore be implementable without inference.
3. **One write path.** Forms, buttons and (later) validated AI commands all call
   the same typed command handlers, so validation and idempotency cannot be
   bypassed by adding a new entry point.

## Command shape

```text
UI / optional AI ──► Command object (validated in its constructor)
                       │
                       ├── requestId  (idempotency key, stable across retries)
                       ├── domain inputs (quantity, offset, channel)
                       ▼
                    Handler ──► ports ──► SQLite
                       │
                       ▼
               sealed result: Applied | AlreadyApplied | Rejected(reason, message)
```

`LogFoodHandler` is a typed command handler with injected clock and IDs. Other
writes do not all follow this shape yet: some UI flows compose operations via
`LocalWorkspace`. Those flows need transaction-wide validation before they are
exposed to provider-generated requests.

Rejections carry user-facing text because the recovery path matters: a volume
quantity on a food with no density says *enter a mass instead* rather than
failing silently.

## Storage decisions

**Nutrients as JSON, not columns.** A profile column per nutrient would flatten
unknown / trace / estimated into `NULL` and lose the distinction the spec
requires. `NutrientProfile.toJson()` is the stored form, and it is the same codec
used by export. Cost: no SQL aggregation over nutrients. That is acceptable
because totals are computed in Dart from a handful of rows per day; if that ever
becomes measurable, a generated rollup table is the answer, not falsified columns.

**Diary date as `yyyy-MM-dd` text.** Stored, not derived. A timestamp plus an
offset can produce a different date later (offset lookup changes, DST, travel);
the assigned date is a user-visible fact and must not move under history.

**Snapshot rows.** `log_entry_items.nutrients_json` is the eaten amount at write
time. Catalogue updates touch `catalog_foods` only. A test asserts that a
corrected catalogue row does not change a stored entry.

**Idempotency in the schema.** `log_entries.request_id` is unique. The handler
checks first for a clean `alreadyApplied` result; the unique index is the
backstop for races and retried queue items, and a test asserts it fires.

**Catalogue vs user data.** `catalog_foods` is replaceable and can be reinstalled
from a dataset download; the diary cannot. They share a database file for
transactional simplicity but have no foreign keys between them, precisely so a
catalogue rebuild never touches user rows.

## Migration policy

The current schema is version 3. Its upgrade handles v1 and v2 databases in a
transaction; upgrading v1 adds basis and item snapshots, user documents and
receipts, and v3 adds catalogue details, aliases and dataset records. No version
ships without an upgrade path from every earlier version, a migrated fixture of
each prior schema, and byte-for-byte stability of user-visible values across migration.

## Provider and health boundaries

`InferenceProvider` and `HealthPort` define boundaries in `salu_core`. The app
implements optional ChatGPT token-sharing authentication and Responses transport;
it has no connected native health adapter. Each inference transfer requires
request-specific consent, and structured output is validated and reviewed before
any plan write. Physical Android/iPhone callback and live inference remain
unverified.

Guided onboarding and plan changes use the same draft and revision-checked local
acceptance path. Each guided week retains its profile and target snapshots and
its own grocery overlays; explicit consumption creates a diary link. Starting
estimates use explicit inputs and remain distinct from user- or clinician-owned
targets. INSA available carbohydrate retains its source definition rather than
being projected into EU carbohydrate.

The four primary destinations are Today, My plan, Assistant and Progress;
Settings and the diary remain accessible separately.

## Known debt

- FTS5 catalogue search has a fallback; production dataset adapters and licensed
  regional content remain outstanding.
- Provider transport and draft review need end-to-end device and live-service
  validation; a connected native health adapter remains outstanding.
- Native platform integration, signing, permissions and device validation remain
  release gates. Previous CI evidence does not validate the current handoff.
