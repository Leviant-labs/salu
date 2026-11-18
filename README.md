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

```bash
# 1. codegen: drift tables -> app_database.g.dart (not committed)
(cd packages/salu_data && dart pub get && dart run build_runner build)

# 2. packages
(cd packages/salu_core && dart pub get && dart analyze && dart test)
(cd packages/salu_data && dart analyze && dart test)

# 3. app: platform folders (android/, ios/) are generated, not committed
(cd app && bash tool/bootstrap_platforms.sh && flutter pub get && flutter analyze && flutter test)
```

`packages/salu_data` needs a sqlite3 shared library on the host
(`libsqlite3-dev` on Debian/Ubuntu).

## Try the new flow

1. For AI features, go to **Settings → OpenAI API key**. This uses your API
   project's billing rather than ChatGPT subscription access.
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
4. In first-run setup or **Settings → Planning profile**, enter any declared
   targets, activity and food preferences you want Salu to use. In **Plan**,
   choose recipes, fill slots offline, or ask the assistant for a swap. The
   review shows nutrition against your targets and changes to grocery requirements
   before saving. **Log separately** records what you actually ate.
5. In **Today → Weekly check-in**, record weight and activity and mark which days
   are complete. Salu shows what the records support and can offer optional
   food or activity ideas based on your declared intentions. It never changes
   your targets.

The starter catalogue is not a complete regional or branded database. Pack
installation is available; no third-party branded packs are bundled. Recipe
choices with unknown allergen information are excluded when a strict allergy is
recorded. Automatic targets and adaptive expenditure remain gated as described
in the nutrition engine spec.
