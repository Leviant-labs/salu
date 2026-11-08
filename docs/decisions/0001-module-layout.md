# 0001 — Three modules, one database

Status: accepted (scaffold, 2026-11-08)

## Context

The spec requires nutrition arithmetic, planning and coaching to work with no
provider connected, and requires the same validated operations behind forms,
buttons and (later) conversational requests. A single Flutter package with
"sensible folder structure" cannot enforce that: the first convenient
`import 'package:flutter/material.dart'` inside a target calculator is invisible
in review and only shows up as a test suite that needs an engine.

## Decision

Three modules with a one-way dependency edge:

- `salu_core` — pure Dart, SDK-only dependencies.
- `salu_data` — drift/SQLite implementations of core ports.
- `app` — Flutter UI, composition root, platform adapters.

Enforced by pubspec dependencies plus `tool/check_boundaries.sh` in CI.

## Consequences

- Domain and command tests run under `dart test` in about a second, with fake
  clock and fake repositories; no emulator, no engine.
- Adding an AI feature forces a port in `salu_core` and an adapter in `app`,
  which is exactly the review point we want.
- One extra step when a domain type needs a Flutter type (it cannot; the type
  belongs in the app, or the domain design is wrong).
- Not a monorepo tooling commitment: no melos, no pub workspace. Path
  dependencies and three `pub get` calls are enough at this size.
