# 0002 — Unknown is a state, not a number

Status: accepted (scaffold, 2026-11-08)

## Context

Nutrition data is incomplete in four different ways that a `double?` column
merges into one: no measurement exists, a zero was measured, a value is below the
reporting threshold, and a value was estimated (photo inference, recipe yield).
Treating them as one produces either fabricated zeros in the diary or a total that
silently omits what it does not know.

## Decision

`NutrientValue` is sealed with four variants, and every consumer sees the state:

- `NutrientUnknown` — no number, `numericValue == null`.
- `NutrientMeasured` — includes explicit zero.
- `NutrientTrace` — contributes 0, flagged.
- `NutrientEstimated` — numeric, carries its `basis`.

Summing yields `NutrientSum { value, isComplete, includesTrace, includesEstimate }`.
An absent nutrient reads as `NutrientSum.noData`, not a verified zero.

## Consequences

- Display code must show coverage (`-- g`) and cannot accidentally print `0 g`
  for data it never had.
- Daily totals can be "partial" without being wrong; the Today summary says so.
- Storage uses the JSON codec instead of one column per nutrient, preserving the
  distinction across the database boundary.
- Scaling by mass (the common operation) is total-preserving: unknown stays
  unknown, trace stays trace, basis is retained.
