# Salu

Photo-first meal diary and AI-assisted weekly planning for iOS and Android.
The diary and planner are usable offline; AI actions send only the inputs
disclosed at the point of use. Salu has no account or backend.

Spec: [`docs/product-spec.md`](docs/product-spec.md) (product contract and
release gates), [`docs/architecture.md`](docs/architecture.md) (working slice and
target design), and [`docs/nutrition-engine-spec.md`](docs/nutrition-engine-spec.md)
(calculation mechanics).

## Layout

```text
app/                    Flutter app: UI, composition root, platform adapters
packages/salu_core/     Pure Dart: domain, nutrition math, typed commands, ports
packages/salu_data/     Drift/SQLite: schema, migrations, repository adapters
docs/                   Spec, architecture, decisions
tool/                   Repo-level checks
```

Dependency direction is one-way: `app` → `salu_data` → `salu_core`, and
`salu_core` depends on nothing but the Dart SDK. `tool/check_boundaries.sh`
fails the build if that is violated.

## Run it

Salu pins Flutter to the version in [`tool/flutter-version.txt`](tool/flutter-version.txt) (`3.44.0`).

On Windows, add the pinned Flutter SDK `bin` directory to `PATH` before running checks (for example in PowerShell, and ensure Git for Windows is installed so `tool/check_boundaries.sh` runs under Git Bash):

```powershell
$env:PATH = "<path-to-flutter>\bin;$env:PATH"
```

Run the full repo check suite from the repository root:

```powershell
pwsh -File tool/check.ps1
```

On macOS/Linux (or Git Bash with Flutter on `PATH`):

```bash
bash tool/check.sh
```

To generate native platform folders (`android/`, `ios/`, not committed) before running the app on a device or emulator:

```bash
(cd app && bash tool/bootstrap_platforms.sh && flutter pub get && flutter run)
```

`packages/salu_data` needs a sqlite3 shared library on the host
(`libsqlite3-dev` on Debian/Ubuntu).

## Try the new flow

1. AI connections are optional and configured in **Settings → Manage AI connections** (or **Your setup → Set up AI connection** during onboarding):
   - **ChatGPT account:** choose **Continue with ChatGPT** and approve plan usage in your browser. Eligible ChatGPT plan limits apply.
   - **BYOK (Bring Your Own Key) API endpoints:** add a named endpoint profile for **OpenAI Chat Completions**, **OpenAI Responses**, or **Anthropic Messages** with your own API key (stored in platform secure storage and never shown again), discover models (`GET /models` or `/catalogue`) or enter a model ID manually, and optionally enable **Allow local network HTTP** for loopback or private LAN servers (`http://127.0.0.1`, `10.x`, `192.168.x`; public `http://` is always blocked). Provider API billing may apply.
   - Only the explicitly selected active connection is used, with no automatic fallback. Real third-party service compatibility remains unverified until tested on device with opt-in credentials outside automated fixture tests.
2. In **Today → Log a meal**, take or choose a photo and type “This was my lunch
   today.” **Save with AI estimate** puts the photo under Lunch right away.
   Salu fills in estimates when they arrive, or offers a retry. Use the calendar
   or **Find and correct a meal** to review earlier entries. Attach several
   label photos to an item and check the printed values before applying them.
3. In **Food**, search a bundled 78-food starter catalogue with Portuguese
   aliases and international staples. Save a custom food (including its barcode),
   favorite catalogue entries, reuse meals, or build a recipe and record a cooked
   batch. **Install pack** adds [source-specific catalogue editions](docs/catalogue-packs.md)
   for offline search and barcode lookup. Catalogue source: USDA Agricultural
   Research Service, [FoodData Central SR Legacy](https://fdc.nal.usda.gov/)
   (April 2018, CC0 1.0).
4. On first run, a seven-page resumable setup wizard walks through Welcome,
   goals and routine, starting weight, food preferences, declared daily
   targets, optional AI setup, and Review. Every input is optional and no
   automatic targets are calculated. Progress saves locally on each step so you
   can resume after reopening, skip individual steps, or choose **Skip setup**
   from Welcome; optional AI setup does not authorize meal or photo uploads.
   Afterward, **Settings → Planning profile** opens the compact profile editor
   (with all fields optional) and **Plan** also lets you edit food preferences.
   In **Plan**, choose recipes, fill slots offline, or ask the assistant for a
   swap. The review shows nutrition against your targets and changes to grocery
   requirements before saving. **Log separately** records what you actually ate.
5. In **Today → Weekly check-in**, record weight and activity and mark which days
   are complete. Salu shows what the records support and can offer optional
   food or activity ideas based on your declared intentions. It never changes
   your targets.

The starter catalogue is not a complete regional or branded database. Pack
installation is available; no third-party branded packs are bundled. Recipe
choices with unknown allergen information are excluded when a strict allergy is
recorded. Automatic targets and adaptive expenditure remain gated as described
in the nutrition engine spec.
