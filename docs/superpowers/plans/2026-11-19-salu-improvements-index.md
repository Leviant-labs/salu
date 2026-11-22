# Salu Improvements Implementation Plan Index

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the nine review recommendations plus restored guided onboarding and configurable AI endpoints without losing local-first behavior.

**Architecture:** Six small implementation plans share one design and existing core/data/app boundaries. Each plan has independently testable deliverables; this index is the dependency/order guide, not permission to execute every plan at once.

**Tech Stack:** Flutter 3.44.0 and its bundled Dart SDK, Riverpod 2, go_router, Drift/SQLite, native secure storage, native HTTP, existing image/file plugins.

**Spec:** `docs/superpowers/specs/2026-11-19-salu-improvements-design.md`

## Global Constraints

- Flutter is pinned to `3.44.0`; Dart is the version bundled with that Flutter SDK.
- `salu_core` depends only on the Dart SDK; Flutter, SQLite, filesystem, cryptography, and HTTP adapters stay outside it.
- Unknown, trace, reported, measured, and estimated nutrition states survive writes, migrations, exports, and restoration.
- New meals save locally before optional inference; corrections and plan changes require review and revision-checked confirmation.
- Connecting, discovering models, restarting, or restoring never authorizes a meal/photo upload or automatic provider failover.
- Credentials live in platform secure storage and never enter ordinary documents, logs, fixtures, CSV, or archives.
- Automatic targets and adaptive expenditure remain gated; all onboarding health inputs and AI setup are optional.
- Preserve existing user changes, especially untracked `app/android/`, `app/ios/`, and `linked_list_merge/`; never stage them wholesale.

---

## Scope and approval

The user requested plans for the review and their additions. No implementation is included. The shared design records planning assumptions, especially retaining ChatGPT sign-in alongside endpoint configuration and replace-only restore. Confirm those before executing the affected plan. Do not infer authorization to commit, push, publish an APK, use real credentials, or modify untracked platform work from this planning request.

## Plans and order

| Order | Plan | Depends on | Independently demonstrable outcome |
| --- | --- | --- | --- |
| 1 | [Foundation and delivery](2026-11-19-01-foundation-and-delivery.md) | none | Reproducible bootstrap, locked tooling, native CI and offline smoke test |
| 2 | [Guided onboarding](2026-11-19-02-guided-onboarding.md) | 1 | Resumable page-by-page setup, optional inputs, existing-user compatibility |
| 3 | [Endpoint connections](2026-11-19-03-endpoint-connections.md) | 1; task 4 integrates with 2 | Secure endpoint/model configuration plus bounded, injected inference |
| 4 | [Nutrition, allergies and codecs](2026-11-19-04-nutrition-allergies-codecs.md) | 1 | Plausibility screening, useful fail-closed allergy filtering, lossless recipes |
| 5 | [Data ownership and reversible diary](2026-11-19-05-data-ownership-diary.md) | 1, 3, 4; include 2's draft in archives | Move/delete/undo, managed media, encrypted restore, CSV and erase |
| 6 | [Startup, architecture and daily UX](2026-11-19-06-startup-architecture-ux.md) | 2–5 for final integration | Incremental indexing, controller/service separation, usable localized daily UI |

The numbering is a recommended delivery sequence, not an instruction to postpone safety until all provider work is finished. Plans 2, 3 (first three tasks), and 4 can be executed independently after plan 1. Only parallelize agents/worktrees after the user chooses that execution mode; shared `providers.dart`, export barrels and database migrations must be integrated serially.

## Coverage matrix

| Original point | Where implemented |
| --- | --- |
| Data ownership/recovery | Plan 5 tasks 3–5 |
| Reversible logging mistakes | Plan 5 tasks 1–2 |
| Nutrition plausibility | Plan 4 task 1 |
| Allergy-aware planning | Plan 4 task 2 |
| AI lifecycle robustness | Plan 3 tasks 2–4 |
| Reproducible release checks | Plan 1 tasks 1–3 |
| Startup/catalogue performance | Plan 6 task 1 |
| Architecture and recipe persistence | Plan 4 task 3; plan 6 task 2 |
| Daily usability/localization/accessibility | Plan 6 task 3 |
| User: restore onboarding pages | Plan 2 tasks 1–3 |
| User: compatible endpoints, credentials, discovery | Plan 3 tasks 1–4 |
| User: dark luxury green-accented glassmorphic/neumorphic UI | Plan 6 task 3 |

## Execution discipline

1. Read the shared design and the chosen plan in full. Inspect current files and user changes again; paths and existing tests are from the 2026-11-19 review.
2. Use an isolated worktree at execution time. Keep `linked_list_merge` outside all Salu edits/checks.
3. Establish a fresh baseline with plan 1. A stale generated file is a bootstrap problem until regeneration proves otherwise.
4. For each task: add the supplied red test and enumerated companion cases; run red; implement the described interfaces/algorithm; run green and existing regressions; review the diff; commit only if authorized. Commit snippets are execution instructions, not commits performed while planning.
5. Commands in plans run from the specified directory with pinned Flutter/Dart on PATH. Run commands separately; no shell command chains are required. Use `tool/check.ps1` on Windows and `bash tool/check.sh` on POSIX after plan 1.
6. Every code example is a concrete test/interface or implementation slice, not the complete application patch. Implement the adjacent enumerated behavior within the listed task; do not add placeholder bodies to production.
7. Request the applicable review/verification workflow before declaring a task complete. Do not launch agents unless that execution choice is approved.

## Completion evidence

- [ ] All six plans' task checkboxes completed with fresh red/green evidence.
- [ ] Existing v1/v2/v3 data migrations and the planned v4 journal migration verified.
- [ ] No credential string in fixtures, exported JSON, CSV, logs, or archive bytes after decryption.
- [ ] Offline app, onboarding resume, connection cancellation and restore/erase recovery verified on Android and iOS.
- [ ] Real ChatGPT/endpoint compatibility recorded as verified or explicitly unsupported; mocked transport tests are not real-account verification.
- [ ] Device benchmarks and catalogue/allergen coverage limitations recorded without invented accuracy or latency promises.
- [ ] Product/architecture/README statements describe shipped behavior, not unimplemented target functionality.
