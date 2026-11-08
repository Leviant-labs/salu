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

`LogFoodHandler` is the reference implementation. Every later write (edit a
target, confirm a plan, delete an entry) follows the same shape: constructor
validation, injected `Clock` and `IdGenerator`, an idempotent lookup before the
write, and a result type that separates "did it" from "was already done" from
"refused, here is what to do instead".

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

`schemaVersion` starts at 1. No version ships without:

1. a `stepByStep` migration step from every earlier version,
2. a fixture of the previous schema migrated forward in a test, and
3. byte-for-byte stability of user-visible values across the migration.

Schema v1 covers the catalogue and the diary only. Targets, plans, weight and
water arrive with their features, each with its migration, rather than as
speculative empty tables.

## Provider and health boundaries

`InferenceProvider` and `HealthPort` are interfaces in `salu_core` with no
implementation. The app decides whether a provider exists, holds credentials in
secure storage, and gates every transfer on an explicit consent scope. Provider
output is typed as untrusted text and must be converted into a validated command
before it can change anything. The scaffold's Settings screen labels each
integration as not implemented rather than showing a dead switch.

## Known debt

- `LIKE` search only; FTS5 arrives with the real import pipeline.
- No draft/review entity yet, so AI-derived writes have nowhere to land. That is
  deliberate: the review path must exist *before* the first provider does.
- Platform folders are generated by script, so signing, permissions and Info.plist
  keys are not yet codified.
- App-side code is written against pinned major versions (Riverpod 2, go_router
  14–16, drift 2) and has not been through CI yet.
