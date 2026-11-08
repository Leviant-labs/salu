# Specified release acceptance ledger

Source revision: upstream `804ac3b91186879d16e8afeec977cae0d8567418`.
The source was materialized through the authenticated GitHub connector after HTTPS
Git authentication failed. The exact unsigned upstream commit and source tree were reconstructed and hash-verified,
establishing a shallow Git checkout. Publication preserves this upstream parent.

The supplied contracts match the checked-out repository versions byte for byte. Product v2 and nutrition
v2 disagree on per-volume records: nutrition §4 is the explicit dimensional
contract; same-unit scaling must work without density. Product §4's canonical
grams apply only when a supported mass conversion exists. Legacy measured JSON
stays measured, never retroactively relabelled as label-reported. New labels use
reported/reported_zero. Trace without a supplied numeric limit cannot be exact 0.

Status vocabulary: pending, partial, implemented-unverified, automated-pass, device-pass,
review-blocked. Tests alone do not satisfy clinical or distribution approval.

| Gate | Required evidence | Status |
|---|---|---|
| Foundation | Dart MCP handshake and tool calls verified; core/data/app analysis + tests + boundary checks run; native builds recorded separately | automated-pass (host scope) |
| Arithmetic | native basis, exact decimals, unknown/trace/reported-zero, partial totals tested; production definition adapters not complete | partial; automated evidence |
| History | snapshot source/quantity, correction revisions, explicit consumed instant/offset and assigned diary day; real v1/v2 SQLite upgrade fixtures tested | automated-pass (covered flows) |
| Recording | custom foods, exact quantity selection, diary edits/time correction, completeness, favourites, barcode/manual recovery and saved-meal review UI; native-device coverage remains | partial |
| Catalogue | schema 3, FTS5 + fallback, aliases, personal ranking, barcode lookup, review-gated staged atomic packs implemented/tested; raw dataset adapters and licensed PT baseline remain | partial |
| Targets | declared ownership and references, safety routes, no exercise add-back | pending |
| Automatic targets | reviewed versioned eligibility and target policies | review-blocked |
| Adaptation | specified algorithm, simulation + held-out + prospective evaluation | review-blocked |
| Planning | core reproducibility, strict unknown allergens, pins, portions, repair tested; full constraints/schedule UI and soft objectives remain | partial |
| Recipes/batches | immutable versions, yield, bounded stock + transactional intake and groceries implemented/tested; planned stock and full grocery edits remain | partial |
| Coaching/rewards | offline findings, independent safety, humane idempotent rewards | pending |
| Drafts | review, stale response rejection, cancellation, retry, no direct provider writes | pending |
| Providers | authorization/terms/distribution review, capability and consent tests | review-blocked |
| Health | native permissions, outbox/reconciliation, duplicates, external deletions | pending |
| Data controls | archive, staged atomic restore, authenticated encryption, CSV and DB deletion tested; native picker/cache and media audit remain | partial |
| App | onboarding, navigation, EN/pt-PT, support mode; large-text widget checks; native screen-reader flows remain | partial |
| Devices | iOS + Android end-to-end, large text, screen readers, both languages | pending |
| Performance | host-only 10k synthetic search/planner p50/p95 recorded; named-device, cold/warm startup/log/RAM/DB measurements remain | pending (device gates) |
| Datasets/media | PT coverage, label/photo correction benchmarks, content rights | review-blocked |
| Privacy | actual transfers, secure credentials, threat model, retention review | review-blocked |

Android debug compilation passed. APK signature, ZIP integrity and native ELF
section bounds were checked; see validation-2026-11-08.md. The prior head also passed unsigned iOS compilation in CI. Named-device
execution remains unverified; new code requires its own build results.

Do not label this ledger or a debug artifact a completed release while gates are open.

## Current development additions

- Weekly check-ins now report their explicit window and day coverage; this is not
  the complete set of coaching rules. Adaptation remains disabled.
- Manual grocery entries can be added, edited, checked and removed. The full
  planner, repair and grocery workflows remain partial.
- Catalogue filtering and ranking now precede the search result limit. A
  production catalogue, licence review and device performance evidence remain open.
- Draft review and the health export outbox now have durable local stores and
  recovery tests. Neither is connected to a provider or native health platform;
  review UI, adapters, authorization and platform testing remain open.
- Local deletion and restore refresh cached catalogue and meal views. Native
  cache/media deletion and platform backup audits are still required.

These additions are uncommitted development work and do not change the release
status or replace the reviews and device gates above.

Additional development work covers batch reservation validation, catalogue activation
preview, recorded weight comparisons and atomic safety/target updates. Planner
reservation persistence and UI, production datasets, broader coaching, and device
validation remain open. Current host checks pass 142 tests; this is not release evidence.
