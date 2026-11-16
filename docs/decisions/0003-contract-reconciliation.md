# Contract reconciliation and implementation limits

The attached corrected nutrition v2 and product v2 were the original inputs to
this decision. They were byte-identical to the checked-out contracts at handoff;
that is a historical observation, not a claim about the current documents. The
nutrition and product specifications have since been revised, including the
assistant boundary and explicit ownership in their respective §1.1 and §2.1.
Refer to the current specifications and release ledger for their present status.

Native nutrition basis is now recorded for g/ml/item/serving. The legacy per100g
property/column name is retained for compatibility; its actual basis is in
basisUnit/basisValue (default 100 g for old rows). A volume-only snapshot can have
unknown grams rather than a fabricated mass. Source energy remains independent
of macro-derived checks. Label zeros use reported_zero. Legacy measured states
are preserved. Trace no longer implies exact zero.

Exact rational arithmetic preserves decimal source values and recipe allocations;
legacy double-facing getters are display/compatibility boundaries. Modern nutrient
observation contracts additionally carry definition/form/scope identities; these
are not yet integrated into a production dataset-import pipeline or all legacy UI
records. Do not claim complete EU/US import normalization or reference-table coverage.

Schema v2 adds catalogue basis, item quantity/source snapshots, versioned user
feature documents and command receipts. A real v1 SQLite fixture is migrated and
compared before/after. Immutable recipe versions are separate documents; plan
snapshots preserve the selected revision. Cooked batch stock is separate from
recipes, and allocation plus intake commit transactionally.

Current planning UI creates organization-only dinner schedules. Core planning also
validates supplied hard numerical ranges, portions, exclusions, repeat allowances
and pins. Full schedule editing, practical soft-objective optimization, persisted
constraint/relaxation revisions, planned-batch allocation and complete grocery
editing are outstanding. Search is explicitly finite/bounded; exhaustion and
missing data are distinct from a certificate of empty/enumerated feasibility.

Generic document persistence is internal infrastructure, not a substitute for
feature-specific commands. The present UI still composes several operations in
app code. More typed commands and transaction-wide validation are needed before
opening those operations to provider-generated requests.

No autonomous adaptation estimator is bundled. Starting estimates use the exact
Mifflin-St Jeor formula with explicit profile inputs and documented assumptions.
Local coaching currently covers declared safety needs, record completeness and
holding course. Other rule families require versioned rules and UI.

The release ledger must retain these gaps. Passing automated checks or producing
a debug APK does not close the specified product release.
