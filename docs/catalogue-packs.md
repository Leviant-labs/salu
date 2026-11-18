# Offline catalogue packs

Open **Food → Install pack** and choose a UTF-8 `.json` file. Salu validates the
whole pack, shows its source and attribution, and replaces the older edition of
that same dataset in one transaction. Existing diary snapshots and personal
foods are independent of catalogue data.

Example shape (illustrative values, not a distributable dataset):

```json
{
  "format": 1,
  "dataset": "regional-example",
  "edition": "2026-01",
  "attribution": "Publisher and dataset reference",
  "licence": "Licence or terms reference",
  "foods": [
    {
      "sourceId": "product-1",
      "name": "Example product",
      "preparation": "unspecified",
      "barcode": "0001234567890",
      "per100g": { "energy_kcal": 130, "protein_g": 2, "sodium_mg": null }
    }
  ]
}
```

- `dataset` uses lowercase ASCII letters, digits and hyphens. IDs and optional
  printed digit strings must be unique within the pack. Leading barcode zeros
  are significant. If installed sources match the same code, the app asks which
  product to use.
- `per100g` may contain `energy_kcal`, `protein_g`, `carbohydrate_g`, `fat_g`,
  `fiber_g`, `saturated_fat_g`, `sugars_g`, and `sodium_mg`. Missing fields and
  `null` are unknown. Numeric values must be finite and nonnegative and are
  treated as source-reported, not independently verified. Don't export per-100-ml
  or serving-based values as per 100 g. Those bases are available for custom
  foods and labels in the diary.
- Packs are limited to 16 MiB and 25,000 entries. Source-specific normalization,
  licence clearance and distribution are the publisher's responsibility. Salu
  currently bundles USDA starter foods, not a packaged-food provider dataset.
