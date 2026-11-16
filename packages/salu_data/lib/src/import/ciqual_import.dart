import 'dart:convert';

import 'package:salu_core/salu_core.dart';

import 'source_import.dart';

/// Normalizes the official ANSES CIQUAL food composition table.
///
/// The adapter consumes the XML export documented by ANSES:
///
/// * `alim_*.xml` — foods (`alim_code`, French/English/scientific names,
///   group codes, Jones factor).
/// * `const_*.xml` — constituents, whose names include the source unit.
/// * `compo_*.xml` — one value per food/constituent pair. `teneur` is a
///   decimal number, the literal `traces`, a maximum such as `<10`, or `-`
///   when no value is available. `min`/`max`, `code_confiance` and
///   `source_code` are retained for audit.
/// * `alim_grp_*.xml` — optional group/subgroup/sub-subgroup names.
/// * `sources_*.xml` — optional source-code citations.
///
/// Official sources:
/// * Current CIQUAL 2025 dataset, DOI <https://doi.org/10.57745/RDMHWY>
///   (Recherche Data Gouv; files dated 2025-11-03).
/// * CIQUAL 2020 dataset, DOI <https://doi.org/10.5281/zenodo.4770600> and
///   <https://www.data.gouv.fr/datasets/table-de-composition-nutritionnelle-des-aliments-ciqual-2020>.
/// * ANSES CIQUAL portal <https://ciqual.anses.fr/>.
///
/// All CIQUAL nutrient values are per 100 g of edible portion. The adapter
/// records that native basis without converting mass or volume, and it never
/// assumes a density. Dataset version and licence stay caller declarations:
/// this class does not bundle a dataset or grant a licence/review.
///
/// The parser is deliberately limited to the simple, documented element/attribute
/// grammar, rejects DTDs, CDATA and unknown entity references, and bounds
/// document size and nesting depth. Official 2020 records include a few
/// unescaped `<` and non-entity `&` characters in text; a `<` that cannot begin
/// markup or an `&` that does not form a recognized entity is treated as text.
/// Prefer [CiqualFoodAdapter.fromBytes] for raw official files: it reads each
/// XML declaration and decodes UTF-8 and Windows-1252 explicitly. Do not decode
/// Windows-1252 with `latin1`; bytes 0x80-0x9F map to different characters.
/// A String passed to [CiqualFoodAdapter.fromXml] must already be decoded
/// correctly according to its declaration.
///
/// Parsing is synchronous CPU work. Callers should run an import off the UI
/// isolate; the adapter now streams one record at a time rather than retaining a
/// full-document tree.
final class CiqualFoodAdapter {
  CiqualFoodAdapter._({
    required this.datasetVersion,
    required this.licence,
    required List<CiqualFoodRecord> foods,
    required Map<String, CiqualConstituent> constituents,
    required List<CiqualFoodGroup> groups,
    required Map<String, CiqualSource> sources,
    required Map<String, List<CiqualComposition>> compositionsByFood,
    required Map<(String, String), CiqualComposition> compositionsByPair,
    required Map<String, CiqualFoodRecord> foodByCode,
    required Map<String, CiqualFoodGroup> groupByKey,
  })  : _foods = foods,
        _constituents = constituents,
        _groups = groups,
        _sources = sources,
        _compositionsByFood = compositionsByFood,
        _compositionByPair = compositionsByPair,
        _foodByCode = foodByCode,
        _groupByKey = groupByKey;

  /// Builds a table from the official CIQUAL XML documents.
  ///
  /// [foodsXml], [constituentsXml] and [compositionsXml] are required and must
  /// be the matching official documents, not arbitrary XML with similar tags.
  /// [foodGroupsXml] and [sourcesXml] are optional; when supplied, composition
  /// source codes are checked against the citation document.
  ///
  /// The strings must already be decoded correctly according to their XML
  /// declarations; this method does not guess an encoding. Use [fromBytes] for
  /// raw official files. Each document is limited to [maxDocumentBytes]
  /// characters.
  ///
  /// Throws [ArgumentError] when the declared dataset version or licence is
  /// empty, and [FormatException] when the documents are malformed, disagree
  /// about a constituent's unit, duplicate a food/constituent/composition
  /// identifier, or reference an unknown constituent/source code. Duplicate
  /// group rows are retained for audit as described on [groups].
  factory CiqualFoodAdapter.fromXml({
    required String datasetVersion,
    required String licence,
    required String foodsXml,
    required String constituentsXml,
    required String compositionsXml,
    String? foodGroupsXml,
    String? sourcesXml,
  }) {
    final version = datasetVersion.trim();
    final licenceId = licence.trim();
    if (version.isEmpty) {
      throw ArgumentError('CIQUAL dataset version is required');
    }
    if (licenceId.isEmpty) {
      throw ArgumentError('CIQUAL licence identifier is required');
    }

    final foods = _parseFoods(_recordElements(foodsXml, 'foods', 'ALIM'));
    final constituents = _parseConstituents(
        _recordElements(constituentsXml, 'constituents', 'CONST'));
    final groups = foodGroupsXml == null
        ? const <CiqualFoodGroup>[]
        : _parseGroups(
            _recordElements(foodGroupsXml, 'food groups', 'ALIM_GRP'));
    final sources = sourcesXml == null
        ? const <String, CiqualSource>{}
        : _parseSources(_recordElements(sourcesXml, 'sources', 'SOURCES'));
    final compositions = _parseCompositions(
      _recordElements(compositionsXml, 'compositions', 'COMPO'),
      constituents: constituents,
      foodCodes: <String>{for (final food in foods) food.code},
      sources: sources,
      sourcesProvided: sourcesXml != null,
    );

    final foodByCode = <String, CiqualFoodRecord>{
      for (final food in foods) food.code: food,
    };
    // CIQUAL 2020 repeats one group/subgroup/sub-subgroup triple with different
    // subgroup wording. The rows are retained for audit; lookups use the first
    // document occurrence, which keeps resolution deterministic.
    final groupByKey = <String, CiqualFoodGroup>{};
    for (final group in groups) {
      groupByKey.putIfAbsent(group.key, () => group);
    }

    return CiqualFoodAdapter._(
      datasetVersion: version,
      licence: licenceId,
      foods: List<CiqualFoodRecord>.unmodifiable(foods),
      constituents: Map<String, CiqualConstituent>.unmodifiable(constituents),
      groups: List<CiqualFoodGroup>.unmodifiable(groups),
      sources: Map<String, CiqualSource>.unmodifiable(sources),
      compositionsByFood:
          Map<String, List<CiqualComposition>>.unmodifiable(
              compositions.byFood),
      compositionsByPair:
          Map<(String, String), CiqualComposition>.unmodifiable(
              compositions.byPair),
      foodByCode: Map<String, CiqualFoodRecord>.unmodifiable(foodByCode),
      groupByKey: Map<String, CiqualFoodGroup>.unmodifiable(groupByKey),
    );
  }

  /// Builds a table from raw official CIQUAL XML bytes.
  ///
  /// Each document's XML declaration selects UTF-8 or an explicit Windows-1252
  /// decoder. ISO-8859-1/Latin-1 declarations use Dart's ISO-8859-1 codec;
  /// unsupported declarations and undefined Windows-1252 bytes fail closed.
  /// This is the recommended entry point for the downloadable 2020
  /// (`windows-1252`) and 2025 (UTF-8) files.
  ///
  /// The same version, licence and document-size checks as [fromXml] apply.
  factory CiqualFoodAdapter.fromBytes({
    required String datasetVersion,
    required String licence,
    required List<int> foods,
    required List<int> constituents,
    required List<int> compositions,
    List<int>? foodGroups,
    List<int>? sources,
  }) =>
      CiqualFoodAdapter.fromXml(
        datasetVersion: datasetVersion,
        licence: licence,
        foodsXml: _decodeCiqualXml(foods, 'foods'),
        constituentsXml: _decodeCiqualXml(constituents, 'constituents'),
        compositionsXml: _decodeCiqualXml(compositions, 'compositions'),
        foodGroupsXml: foodGroups == null
            ? null
            : _decodeCiqualXml(foodGroups, 'food groups'),
        sourcesXml:
            sources == null ? null : _decodeCiqualXml(sources, 'sources'),
      );

  /// Dataset name used in [FoodSource.dataset] and local food identifiers.
  static const String dataset = 'ciqual';

  /// Maximum size accepted for one XML document: 128 MiB.
  ///
  /// [fromBytes] checks the raw byte length before decoding; [fromXml] checks
  /// the decoded character length. This bounds parser memory and rejects
  /// unbounded input.
  static const int maxDocumentBytes = 128 * 1024 * 1024;

  /// Definition for CIQUAL's `N x facteur Jones, avec fibres` energy values.
  ///
  /// These are distinct from the EU 1169/2011 declared-energy values (codes
  /// 327/328) and are therefore retained under their own definition instead of
  /// being merged into one energy slot.
  static const String jonesEnergyDefinition = 'ciqual_jones_energy_with_fibre';

  /// Definition for code 25003, protein calculated with N x 6.25.
  ///
  /// Code 25000 (`N x facteur de Jones`) is the default [NutrientKey.proteinG]
  /// observation; the crude-protein value keeps a separate identity.
  static const String crudeProteinDefinition = 'ciqual_crude_protein_n625';

  final String datasetVersion;
  final String licence;

  final List<CiqualFoodRecord> _foods;
  final Map<String, CiqualConstituent> _constituents;
  final List<CiqualFoodGroup> _groups;
  final Map<String, CiqualSource> _sources;
  final Map<String, List<CiqualComposition>> _compositionsByFood;
  final Map<(String, String), CiqualComposition> _compositionByPair;
  final Map<String, CiqualFoodRecord> _foodByCode;
  final Map<String, CiqualFoodGroup> _groupByKey;

  /// Food records in document order.
  List<CiqualFoodRecord> get foods => _foods;

  /// Constituent records keyed by `const_code`.
  Map<String, CiqualConstituent> get constituents => _constituents;

  /// Food-group records in document order. CIQUAL 2020 repeats one
  /// group/subgroup/sub-subgroup triple with different wording; duplicate rows
  /// are retained for audit and [foodGroupFor] uses the first occurrence.
  List<CiqualFoodGroup> get groups => _groups;

  /// Source citations keyed by `source_code`. A 2020 source code may carry
  /// more than one citation; 2025 codes carry one.
  Map<String, CiqualSource> get sources => _sources;

  /// The typed food record for [code], or `null` when it is not in this table.
  CiqualFoodRecord? foodRecord(String code) => _foodByCode[code.trim()];

  /// The group row for [foodCode], when the optional group document was loaded
  /// and contains a matching group/subgroup/sub-subgroup triple.
  CiqualFoodGroup? foodGroupFor(String foodCode) {
    final food = _foodByCode[foodCode.trim()];
    if (food == null) return null;
    return _groupByKey[food.groupKey];
  }

  /// The raw composition cell for a food/constituent pair, when present.
  CiqualComposition? compositionFor(
          String foodCode, String constituentCode) =>
      _compositionByPair[(foodCode.trim(), constituentCode.trim())];

  /// All raw composition cells for [foodCode], in document order.
  List<CiqualComposition> compositionsFor(String foodCode) =>
      _compositionsByFood[foodCode.trim()] ?? const <CiqualComposition>[];

  /// Normalizes every food in document order.
  List<FoodImportResult> adaptAll() => List<FoodImportResult>.unmodifiable(
      _foods.map((food) => adapt(food.code)));

  /// Normalizes one food by its official `alim_code`.
  ///
  /// Numeric values are retained as exact decimals. `traces` becomes a trace
  /// observation, `-`/an empty value becomes an unknown observation, and a
  /// maximum such as `<10` is retained as an unknown observation with no
  /// below-detection claim. The literal maximum is preserved in the observation
  /// origin, in `sourceDetails['upperBounds']`, and as an upper-exclusive
  /// [SourceInterval] scoped to the composition cell; no missing or bounded
  /// value becomes zero and no intake bound is implied. An unsupported value is
  /// reported instead of guessed.
  FoodImportResult adapt(String foodCode) {
    final record = _foodByCode[foodCode.trim()];
    if (record == null) {
      throw ArgumentError.value(
          foodCode, 'foodCode', 'Unknown CIQUAL alim_code');
    }

    final builder = ImportedFoodBuilder(
        dataset: dataset, datasetVersion: datasetVersion, licence: licence);
    builder.detail('alim_nom_eng', record.englishName);
    builder.detail('alim_nom_sci', record.scientificName);
    builder.detail('alim_grp_code', record.groupCode);
    builder.detail('alim_ssgrp_code', record.subgroupCode);
    builder.detail('alim_ssssgrp_code', record.subSubgroupCode);
    builder.detail('facteur_Jones', record.jonesFactorRaw);

    final group = _groupByKey[record.groupKey];
    if (group != null) {
      builder.detail('foodGroupNameFr', group.groupNameFr);
      builder.detail('foodGroupNameEn', group.groupNameEn);
      builder.detail('foodSubgroupNameFr', group.subgroupNameFr);
      builder.detail('foodSubgroupNameEn', group.subgroupNameEn);
      builder.detail('foodSubSubgroupNameFr', group.subSubgroupNameFr);
      builder.detail('foodSubSubgroupNameEn', group.subSubgroupNameEn);
    }

    if (record.preparationAmbiguous) {
      builder.issue(
          'ambiguous-preparation',
          'Source name contains both raw and cooked preparation terms; '
          'preparation is left unspecified',
          field: 'alim_nom_fr');
    }

    final compositions =
        _compositionsByFood[record.code] ?? const <CiqualComposition>[];
    final basis = FoodAmount('100', FoodUnit.g);
    final sourceCodes = <String>{};
    final upperBounds = <String, String>{};
    var hasMappedRow = false;
    var hasUsableValue = false;

    for (final composition in compositions) {
      if (composition.sourceCode != null) {
        sourceCodes.add(composition.sourceCode!);
      }
      if (composition.kind == CiqualValueKind.upperBound) {
        upperBounds[composition.constituentCode] = composition.rawValue;
      }
      final constituent = _constituents[composition.constituentCode]!;
      final spec = _specs[composition.constituentCode];
      if (spec == null) {
        if (composition.kind != CiqualValueKind.missing) {
          builder.unmapped(_label(constituent));
        }
        continue;
      }
      hasMappedRow = true;

      if (composition.confidence != null &&
          !_confidenceCodes.contains(composition.confidence)) {
        builder.issue(
            'unknown-confidence',
            'CIQUAL confidence code "${composition.confidence}" is not A-D',
            field: 'compo/${composition.constituentCode}/code_confiance');
      }

      final origin = _origin(composition);
      switch (composition.kind) {
        case CiqualValueKind.amount:
          final amountValue = composition.amount!;
          final amountQualifier = amountValue == Exact.zero
              ? ObservationQualifier.reportedZero
              : ObservationQualifier.reported;
          final amountAdded = builder.addObservation(
              key: spec.key,
              amount: amountValue,
              sourceUnit: spec.sourceUnit,
              basis: basis,
              sourceId: record.code,
              origin: origin,
              definition: spec.definition,
              qualifier: amountQualifier);
          if (amountAdded) {
            hasUsableValue = true;
          } else {
            builder.unmapped(_label(constituent));
          }
        case CiqualValueKind.trace:
          final traceAdded = builder.addObservation(
              key: spec.key,
              amount: null,
              sourceUnit: spec.sourceUnit,
              basis: basis,
              sourceId: record.code,
              origin: origin,
              definition: spec.definition,
              qualifier: ObservationQualifier.trace);
          if (traceAdded) {
            hasUsableValue = true;
          } else {
            builder.unmapped(_label(constituent));
          }
        case CiqualValueKind.upperBound:
          // CIQUAL documents `<x` as a maximum, not as an evidence-backed
          // below-detection result. Keep the cell unknown and record the
          // literal maximum as an upper-exclusive source interval scoped to
          // this composition cell. The raw text stays in the origin and
          // sourceDetails['upperBounds']; no intake bound is implied.
          final bound = composition.upperBound;
          final upperBoundAdded = builder.addObservation(
              key: spec.key,
              amount: null,
              sourceUnit: spec.sourceUnit,
              basis: basis,
              sourceId: record.code,
              origin: origin,
              definition: spec.definition,
              qualifier: ObservationQualifier.unknown,
              suppliedInterval: bound == null
                  ? null
                  : SourceInterval(
                      lower: null,
                      upper: bound,
                      lowerInclusive: false,
                      upperInclusive: false,
                      scope: _upperBoundScope(composition),
                      method: _upperBoundMethod));
          if (!upperBoundAdded) builder.unmapped(_label(constituent));
        case CiqualValueKind.missing:
          final missingAdded = builder.addObservation(
              key: spec.key,
              amount: null,
              sourceUnit: spec.sourceUnit,
              basis: basis,
              sourceId: record.code,
              origin: origin,
              definition: spec.definition,
              qualifier: ObservationQualifier.unknown);
          if (!missingAdded) builder.unmapped(_label(constituent));
        case CiqualValueKind.unsupported:
          builder.issue(
              'unsupported-source-value',
              'Unsupported CIQUAL teneur "${composition.rawValue}"',
              field: 'compo/${composition.constituentCode}/teneur');
          builder.unmapped(_label(constituent));
      }
    }

    if (compositions.isEmpty) {
      builder.issue('no-nutrition-data', 'CIQUAL food has no composition rows');
    } else if (!hasUsableValue) {
      builder.issue(
          hasMappedRow ? 'no-usable-nutrients' : 'no-mapped-nutrients',
          hasMappedRow
              ? 'Mapped CIQUAL constituents have no numeric or trace value'
              : 'No supplied CIQUAL constituent has a reviewed mapping');
    }

    if (upperBounds.isNotEmpty) {
      builder.detail(
          'upperBounds', Map<String, String>.unmodifiable(upperBounds));
    }
    if (sourceCodes.isNotEmpty) {
      final codes = sourceCodes.toList()..sort();
      builder.detail('sourceCodes', List<String>.unmodifiable(codes));
    }

    return builder.build(
        id: '$dataset:${record.code}',
        name: record.frenchName,
        sourceId: record.code,
        basisUnit: FoodUnit.g,
        basisValue: '100',
        preparation: record.preparation,
        aliases: _aliases(record));
  }
}

/// One food row from an official `alim_*.xml` document.
final class CiqualFoodRecord {
  const CiqualFoodRecord({
    required this.code,
    required this.frenchName,
    required this.englishName,
    required this.groupCode,
    required this.subgroupCode,
    required this.subSubgroupCode,
    this.scientificName,
    this.jonesFactorRaw,
    this.jonesFactor,
    required this.preparation,
    required this.preparationAmbiguous,
  });

  final String code;
  final String frenchName;
  final String englishName;
  final String? scientificName;
  final String groupCode;
  final String subgroupCode;
  final String subSubgroupCode;
  final String? jonesFactorRaw;
  final Exact? jonesFactor;

  /// Conservative preparation state read from unambiguous French-name tokens.
  /// Ambiguous names stay [Preparation.unspecified] with
  /// [preparationAmbiguous] set.
  final Preparation preparation;
  final bool preparationAmbiguous;

  /// Group/subgroup/sub-subgroup lookup key.
  String get groupKey => '$groupCode/$subgroupCode/$subSubgroupCode';
}

/// One constituent definition from an official `const_*.xml` document.
final class CiqualConstituent {
  const CiqualConstituent({
    required this.code,
    required this.nameFr,
    required this.nameEn,
    this.infoFoodsCode,
  });

  final String code;
  final String nameFr;
  final String nameEn;
  final String? infoFoodsCode;
}

/// One group/subgroup/sub-subgroup row from `alim_grp_*.xml`.
final class CiqualFoodGroup {
  const CiqualFoodGroup({
    required this.groupCode,
    required this.groupNameFr,
    required this.groupNameEn,
    required this.subgroupCode,
    required this.subgroupNameFr,
    required this.subgroupNameEn,
    required this.subSubgroupCode,
    required this.subSubgroupNameFr,
    required this.subSubgroupNameEn,
  });

  final String groupCode;
  final String groupNameFr;
  final String groupNameEn;
  final String subgroupCode;
  final String subgroupNameFr;
  final String subgroupNameEn;
  final String subSubgroupCode;
  final String subSubgroupNameFr;
  final String subSubgroupNameEn;

  String get key => '$groupCode/$subgroupCode/$subSubgroupCode';
}

/// Source codes and their citations from `sources_*.xml`.
final class CiqualSource {
  CiqualSource({required this.code, required List<String> citations})
      : citations = List<String>.unmodifiable(citations);

  final String code;

  /// One or more citations. CIQUAL 2020 can repeat a source code for different
  /// citations; CIQUAL 2025 uses one citation per code.
  final List<String> citations;
}

/// How a raw `teneur` value was written in the source.
enum CiqualValueKind {
  /// A finite decimal amount.
  amount,

  /// The literal `traces` marker.
  trace,

  /// A maximum such as `<10`; [CiqualComposition.upperBound] holds the bound.
  /// The source does not document this as a detection limit, so the adapter
  /// does not infer a below-detection qualifier; it records an upper-exclusive
  /// source interval with [CiqualComposition.upperBound] and keeps the cell
  /// observation unknown.
  upperBound,

  /// `-`, an empty element, or a `missing` attribute.
  missing,

  /// A value this adapter does not understand. It is never given a numeric
  /// interpretation.
  unsupported,
}

/// One raw composition cell from `compo_*.xml`.
///
/// Exact decimals are parsed into [Exact] while [rawValue] keeps the source
/// spelling (including comma decimal separators). The adapter does not log the
/// plan as intake; this type is for import review only.
final class CiqualComposition {
  const CiqualComposition({
    required this.foodCode,
    required this.constituentCode,
    required this.rawValue,
    required this.kind,
    this.amount,
    this.upperBound,
    this.observedMin,
    this.observedMax,
    this.observedMinRaw,
    this.observedMaxRaw,
    this.confidence,
    this.sourceCode,
  });

  final String foodCode;
  final String constituentCode;

  /// Literal source text, trimmed, with entities already decoded.
  final String rawValue;
  final CiqualValueKind kind;

  /// Exact amount when [kind] is [CiqualValueKind.amount].
  final Exact? amount;

  /// Exact maximum when [kind] is [CiqualValueKind.upperBound].
  final Exact? upperBound;

  final Exact? observedMin;
  final Exact? observedMax;
  final String? observedMinRaw;
  final String? observedMaxRaw;

  /// Source confidence code (`A`-`D`), when supplied.
  final String? confidence;

  /// Source citation code, when supplied.
  final String? sourceCode;
}

/// Mapping from a constituent code to the app nutrient identity this build
/// understands. A code is never interpreted from its translated name alone.
final class _CiqualConstSpec {
  const _CiqualConstSpec(this.key, this.sourceUnit, [this.definition]);

  final NutrientKey key;
  final String sourceUnit;
  final String? definition;
}

const Map<String, _CiqualConstSpec> _specs = <String, _CiqualConstSpec>{
  // EU 1169/2011 declared energy.
  '327': _CiqualConstSpec(
      NutrientKey.energyKj, 'kJ', NutrientDefinitions.declaredEnergy),
  '328': _CiqualConstSpec(
      NutrientKey.energyKcal, 'kcal', NutrientDefinitions.declaredEnergy),
  // N x Jones factor, with fibres: a different energy definition.
  '332': _CiqualConstSpec(
      NutrientKey.energyKj, 'kJ', CiqualFoodAdapter.jonesEnergyDefinition),
  '333': _CiqualConstSpec(
      NutrientKey.energyKcal, 'kcal', CiqualFoodAdapter.jonesEnergyDefinition),
  // CIQUAL's primary protein value uses per-food Jones factors.
  '25000': _CiqualConstSpec(NutrientKey.proteinG, 'g'),
  '25003': _CiqualConstSpec(
      NutrientKey.proteinG, 'g', CiqualFoodAdapter.crudeProteinDefinition),
  // CIQUAL carbohydrates exclude fibre and include polyols (EU definition).
  '31000': _CiqualConstSpec(
      NutrientKey.carbohydrateG, 'g', NutrientDefinitions.euAvailableCarbohydrate),
  '32000': _CiqualConstSpec(NutrientKey.sugarsG, 'g'),
  '34100': _CiqualConstSpec(NutrientKey.fiberG, 'g'),
  '40000': _CiqualConstSpec(NutrientKey.fatG, 'g'),
  '40302': _CiqualConstSpec(NutrientKey.saturatedFatG, 'g'),
  '10110': _CiqualConstSpec(NutrientKey.sodiumMg, 'mg'),
  '10200': _CiqualConstSpec(NutrientKey.calciumMg, 'mg'),
  '10260': _CiqualConstSpec(NutrientKey.ironMg, 'mg'),
  '10530': _CiqualConstSpec(NutrientKey.iodineUg, 'µg'),
  '52100': _CiqualConstSpec(NutrientKey.vitaminDUg, 'µg'),
  '55100': _CiqualConstSpec(NutrientKey.vitaminCMg, 'mg'),
};

const Set<String> _confidenceCodes = <String>{'A', 'B', 'C', 'D'};

final RegExp _cookedPreparation = RegExp(
  r'(?:^|[^A-Za-zÀ-ÖØ-öø-ÿ])'
  r'(?:cuit(?:e|es|s)?|bouilli(?:e|es|s)?|rôti(?:e|es|s)?|'
  r'grillé(?:e|es|s)?|frit(?:e|es|s)?|sauté(?:e|es|s)?|'
  r'poêlé(?:e|es|s)?|appertisé(?:e|es|s)?|pasteurisé(?:e|es|s)?|'
  r'stérilisé(?:e|es|s)?|précuit(?:e|es|s)?|poché(?:e|es|s)?|'
  r'braisé(?:e|es|s)?|préfrit(?:e|es|s)?)'
  r'(?=$|[^A-Za-zÀ-ÖØ-öø-ÿ])',
  caseSensitive: false,
);

final RegExp _rawPreparation = RegExp(
  r'(?:^|[^A-Za-zÀ-ÖØ-öø-ÿ])cru(?:e|es|s)?'
  r'(?=$|[^A-Za-zÀ-ÖØ-öø-ÿ])',
  caseSensitive: false,
);

(Preparation, bool) _preparation(String name) {
  final cooked = _cookedPreparation.hasMatch(name);
  final raw = _rawPreparation.hasMatch(name);
  if (cooked && raw) return (Preparation.unspecified, true);
  if (cooked) return (Preparation.cooked, false);
  if (raw) return (Preparation.raw, false);
  return (Preparation.unspecified, false);
}

List<String> _aliases(CiqualFoodRecord record) {
  final aliases = <String>[];
  void add(String? value) {
    final text = value?.trim();
    if (text == null || text.isEmpty || text == record.frenchName) return;
    if (text == '-' || text.toLowerCase().contains('genus and species unknown')) {
      return;
    }
    if (!aliases.contains(text)) aliases.add(text);
  }

  add(record.englishName);
  add(record.scientificName);
  return List<String>.unmodifiable(aliases);
}

String _label(CiqualConstituent constituent) =>
    '${constituent.code} ${constituent.nameEn}';

/// The documented scope of the interval implied by a CIQUAL `<x` `teneur`.
///
/// CIQUAL reports that maximum for this composition cell's own value per 100 g
/// of edible portion. It is not an intake bound, a confidence interval or a
/// detection limit.
String _upperBoundScope(CiqualComposition composition) =>
    'ciqual:compo/${composition.constituentCode}/teneur';

/// The reporting convention behind [_upperBoundScope], named for review.
const String _upperBoundMethod =
    'CIQUAL maximum ("<x") reporting; upper-exclusive bound, '
    'not a detection limit';

String _origin(CiqualComposition composition) {
  final buffer = StringBuffer('ciqual:compo/${composition.constituentCode}');
  if (composition.sourceCode != null) {
    buffer.write(';source=${composition.sourceCode}');
  }
  if (composition.confidence != null) {
    buffer.write(';confidence=${composition.confidence}');
  }
  buffer.write(';teneur=${composition.rawValue}');
  if (composition.observedMinRaw != null) {
    buffer.write(';min=${composition.observedMinRaw}');
  }
  if (composition.observedMaxRaw != null) {
    buffer.write(';max=${composition.observedMaxRaw}');
  }
  return buffer.toString();
}

/// Parsed official documents, indexed for one adapter instance.
final class _CompositionIndex {
  const _CompositionIndex({required this.byFood, required this.byPair});

  final Map<String, List<CiqualComposition>> byFood;
  final Map<(String, String), CiqualComposition> byPair;
}

const Map<int, int> _windows1252CodePoints = <int, int>{
  0x80: 0x20AC,
  0x82: 0x201A,
  0x83: 0x0192,
  0x84: 0x201E,
  0x85: 0x2026,
  0x86: 0x2020,
  0x87: 0x2021,
  0x88: 0x02C6,
  0x89: 0x2030,
  0x8A: 0x0160,
  0x8B: 0x2039,
  0x8C: 0x0152,
  0x8E: 0x017D,
  0x91: 0x2018,
  0x92: 0x2019,
  0x93: 0x201C,
  0x94: 0x201D,
  0x95: 0x2022,
  0x96: 0x2013,
  0x97: 0x2014,
  0x98: 0x02DC,
  0x99: 0x2122,
  0x9A: 0x0161,
  0x9B: 0x203A,
  0x9C: 0x0153,
  0x9E: 0x017E,
  0x9F: 0x0178,
};

String? _windows1252Encoding(String encoding) {
  switch (encoding) {
    case 'windows-1252':
    case 'windows1252':
    case 'cp1252':
      return 'windows-1252';
    default:
      return null;
  }
}

String _decodeWindows1252(List<int> bytes, String role) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    if (byte >= 0x80 && byte <= 0x9F) {
      final codePoint = _windows1252CodePoints[byte];
      if (codePoint == null) {
        throw FormatException(
            'CIQUAL $role XML contains undefined windows-1252 byte '
            '0x${byte.toRadixString(16).padLeft(2, '0')}');
      }
      buffer.writeCharCode(codePoint);
    } else {
      buffer.writeCharCode(byte);
    }
  }
  return buffer.toString();
}

String _declaredEncoding(List<int> bytes) {
  final probeLength = bytes.length > 512 ? 512 : bytes.length;
  final probe = latin1.decode(bytes.sublist(0, probeLength));
  final match = RegExp(
    r'''<\?xml[^>]*\bencoding\s*=\s*["']([^"']+)["']''',
    caseSensitive: false,
  ).firstMatch(probe);
  return match == null ? 'utf-8' : match.group(1)!.trim().toLowerCase();
}

String _decodeCiqualXml(List<int> bytes, String role) {
  if (bytes.isEmpty) {
    throw FormatException('CIQUAL $role XML is empty');
  }
  if (bytes.length > CiqualFoodAdapter.maxDocumentBytes) {
    throw FormatException(
        'CIQUAL $role XML exceeds the '
        '${CiqualFoodAdapter.maxDocumentBytes}-byte limit');
  }
  for (final byte in bytes) {
    if (byte < 0 || byte > 0xFF) {
      throw FormatException(
          'CIQUAL $role XML contains invalid byte value $byte');
    }
  }

  final encoding = _declaredEncoding(bytes);
  final hasUtf8Bom = bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF;
  if (bytes.length >= 2 &&
      ((bytes[0] == 0xFF && bytes[1] == 0xFE) ||
          (bytes[0] == 0xFE && bytes[1] == 0xFF))) {
    throw FormatException(
        'Unsupported UTF-16 CIQUAL $role XML; pass correctly decoded text');
  }
  final isUtf8 = encoding == 'utf-8' || encoding == 'utf8';
  if (hasUtf8Bom && !isUtf8) {
    throw FormatException(
        'CIQUAL $role XML has a UTF-8 BOM but declares "$encoding"');
  }

  if (isUtf8) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw FormatException('CIQUAL $role XML is not valid UTF-8');
    }
  }
  final windowsEncoding = _windows1252Encoding(encoding);
  if (windowsEncoding != null) {
    return _decodeWindows1252(bytes, role);
  }
  switch (encoding) {
    case 'iso-8859-1':
    case 'iso8859-1':
    case 'latin1':
    case 'latin-1':
      return latin1.decode(bytes);
    default:
      throw FormatException(
          'Unsupported CIQUAL $role XML encoding "$encoding"; pass correctly '
          'decoded text or use utf-8/windows-1252');
  }
}

Iterable<_XmlNode> _recordElements(
    String xml, String role, String recordName) {
  if (xml.length > CiqualFoodAdapter.maxDocumentBytes) {
    throw FormatException(
        'CIQUAL $role XML exceeds the '
        '${CiqualFoodAdapter.maxDocumentBytes}-character limit');
  }
  return _XmlReader(xml).parseRecords(recordName, role);
}

List<CiqualFoodRecord> _parseFoods(Iterable<_XmlNode> elements) {
  final foods = <CiqualFoodRecord>[];
  final codes = <String>{};
  for (final element in elements) {
    final code = _requiredText(element, 'alim_code');
    _requireDigits(code, 'alim_code');
    if (!codes.add(code)) {
      throw FormatException('Duplicate CIQUAL alim_code $code');
    }
    final frenchName = _requiredText(element, 'alim_nom_fr');
    final englishName = _requiredText(element, 'alim_nom_eng');
    final groupCode = _requiredText(element, 'alim_grp_code');
    final subgroupCode = _requiredText(element, 'alim_ssgrp_code');
    final subSubgroupCode = _requiredText(element, 'alim_ssssgrp_code');
    _requireDigits(groupCode, 'alim_grp_code');
    _requireDigits(subgroupCode, 'alim_ssgrp_code');
    _requireDigits(subSubgroupCode, 'alim_ssssgrp_code');
    final scientificName = _leafText(element, 'alim_nom_sci');
    final jonesFactorRaw = _leafText(element, 'facteur_Jones');
    final jonesFactor = jonesFactorRaw == null
        ? null
        : _parseNumberStrict(jonesFactorRaw, 'facteur_Jones');
    final preparation = _preparation(frenchName);
    foods.add(CiqualFoodRecord(
      code: code,
      frenchName: frenchName,
      englishName: englishName,
      scientificName: scientificName,
      groupCode: groupCode,
      subgroupCode: subgroupCode,
      subSubgroupCode: subSubgroupCode,
      jonesFactorRaw: jonesFactorRaw,
      jonesFactor: jonesFactor,
      preparation: preparation.$1,
      preparationAmbiguous: preparation.$2,
    ));
  }
  return List<CiqualFoodRecord>.unmodifiable(foods);
}

Map<String, CiqualConstituent> _parseConstituents(
    Iterable<_XmlNode> elements) {
  final constituents = <String, CiqualConstituent>{};
  for (final element in elements) {
    final code = _requiredText(element, 'const_code');
    _requireDigits(code, 'const_code');
    if (constituents.containsKey(code)) {
      throw FormatException('Duplicate CIQUAL const_code $code');
    }
    final constituent = CiqualConstituent(
      code: code,
      nameFr: _requiredText(element, 'const_nom_fr'),
      nameEn: _requiredText(element, 'const_nom_eng'),
      infoFoodsCode: _leafText(element, 'code_INFOODS'),
    );
    final spec = _specs[code];
    if (spec != null) _validateMappedUnit(constituent, spec);
    constituents[code] = constituent;
  }
  return Map<String, CiqualConstituent>.unmodifiable(constituents);
}

List<CiqualFoodGroup> _parseGroups(Iterable<_XmlNode> elements) {
  final groups = <CiqualFoodGroup>[];
  for (final element in elements) {
    final group = CiqualFoodGroup(
      groupCode: _requiredText(element, 'alim_grp_code'),
      groupNameFr: _requiredText(element, 'alim_grp_nom_fr'),
      groupNameEn: _requiredText(element, 'alim_grp_nom_eng'),
      subgroupCode: _requiredText(element, 'alim_ssgrp_code'),
      subgroupNameFr: _requiredText(element, 'alim_ssgrp_nom_fr'),
      subgroupNameEn: _requiredText(element, 'alim_ssgrp_nom_eng'),
      subSubgroupCode: _requiredText(element, 'alim_ssssgrp_code'),
      subSubgroupNameFr: _requiredText(element, 'alim_ssssgrp_nom_fr'),
      subSubgroupNameEn: _requiredText(element, 'alim_ssssgrp_nom_eng'),
    );
    _requireDigits(group.groupCode, 'alim_grp_code');
    _requireDigits(group.subgroupCode, 'alim_ssgrp_code');
    _requireDigits(group.subSubgroupCode, 'alim_ssssgrp_code');
    // Official 2020 data repeats one triple with different subgroup wording.
    // Keep every source row; the adapter's lookup map keeps the first one.
    groups.add(group);
  }
  return List<CiqualFoodGroup>.unmodifiable(groups);
}

Map<String, CiqualSource> _parseSources(Iterable<_XmlNode> elements) {
  final citationsByCode = <String, List<String>>{};
  final order = <String>[];
  for (final element in elements) {
    final code = _requiredText(element, 'source_code');
    _requireDigits(code, 'source_code');
    final citations = citationsByCode.putIfAbsent(code, () {
      order.add(code);
      return <String>[];
    });
    final citation = _leafText(element, 'ref_citation');
    if (citation != null && !citations.contains(citation)) {
      citations.add(citation);
    }
  }
  return Map<String, CiqualSource>.unmodifiable(<String, CiqualSource>{
    for (final code in order)
      code: CiqualSource(code: code, citations: citationsByCode[code]!),
  });
}

_CompositionIndex _parseCompositions(
  Iterable<_XmlNode> elements, {
  required Map<String, CiqualConstituent> constituents,
  required Set<String> foodCodes,
  required Map<String, CiqualSource> sources,
  required bool sourcesProvided,
}) {
  final byFood = <String, List<CiqualComposition>>{};
  final byPair = <(String, String), CiqualComposition>{};
  for (final element in elements) {
    final foodCode = _requiredText(element, 'alim_code');
    final constituentCode = _requiredText(element, 'const_code');
    _requireDigits(foodCode, 'alim_code');
    _requireDigits(constituentCode, 'const_code');
    if (!foodCodes.contains(foodCode)) {
      throw FormatException(
          'CIQUAL composition references unknown alim_code $foodCode');
    }
    if (!constituents.containsKey(constituentCode)) {
      throw FormatException(
          'CIQUAL composition references unknown const_code $constituentCode');
    }
    final pair = (foodCode, constituentCode);
    if (byPair.containsKey(pair)) {
      throw FormatException(
          'Duplicate CIQUAL composition for $foodCode/$constituentCode');
    }

    final teneur = _child(element, 'teneur', required: true)!;
    if (teneur.children.isNotEmpty) {
      throw const FormatException('CIQUAL <teneur> must contain text only');
    }
    final rawValue = teneur.text.trim();
    final isMissing = teneur.attributes.containsKey('missing') ||
        rawValue.isEmpty ||
        rawValue == '-';
    var kind = CiqualValueKind.missing;
    Exact? amount;
    Exact? upperBound;
    if (!isMissing) {
      final lower = rawValue.toLowerCase();
      if (lower == 'traces') {
        kind = CiqualValueKind.trace;
      } else if (rawValue.startsWith('<')) {
        final bound = _parseNumber(rawValue.substring(1).trim());
        if (bound == null) {
          kind = CiqualValueKind.unsupported;
        } else {
          kind = CiqualValueKind.upperBound;
          upperBound = bound;
        }
      } else {
        final number = _parseNumber(rawValue);
        if (number == null) {
          kind = CiqualValueKind.unsupported;
        } else {
          kind = CiqualValueKind.amount;
          amount = number;
        }
      }
    }

    final minRaw = _boundRaw(_child(element, 'min'));
    final maxRaw = _boundRaw(_child(element, 'max'));
    final observedMin = minRaw == null
        ? null
        : _parseNumberStrict(minRaw, 'compo.min');
    final observedMax = maxRaw == null
        ? null
        : _parseNumberStrict(maxRaw, 'compo.max');
    final confidence = _leafText(element, 'code_confiance');
    final sourceCode = _leafText(element, 'source_code');
    if (sourceCode != null) _requireDigits(sourceCode, 'source_code');
    if (sourcesProvided &&
        sourceCode != null &&
        !sources.containsKey(sourceCode)) {
      throw FormatException(
          'CIQUAL composition references unknown source_code $sourceCode');
    }

    final composition = CiqualComposition(
      foodCode: foodCode,
      constituentCode: constituentCode,
      rawValue: rawValue,
      kind: kind,
      amount: amount,
      upperBound: upperBound,
      observedMin: observedMin,
      observedMax: observedMax,
      observedMinRaw: minRaw,
      observedMaxRaw: maxRaw,
      confidence: confidence,
      sourceCode: sourceCode,
    );
    byPair[pair] = composition;
    byFood.putIfAbsent(foodCode, () => <CiqualComposition>[]).add(composition);
  }
  return _CompositionIndex(
    byFood: <String, List<CiqualComposition>>{
      for (final entry in byFood.entries)
        entry.key: List<CiqualComposition>.unmodifiable(entry.value),
    },
    byPair:
        Map<(String, String), CiqualComposition>.unmodifiable(byPair),
  );
}

void _validateMappedUnit(
    CiqualConstituent constituent, _CiqualConstSpec spec) {
  final fr = _unitFromLabel(constituent.nameFr) ?? 'unparsed';
  final en = _unitFromLabel(constituent.nameEn) ?? 'unparsed';
  if (fr != spec.sourceUnit || en != spec.sourceUnit) {
    throw FormatException(
        'CIQUAL constituent ${constituent.code} declares units '
        '$fr/$en; the reviewed mapping requires ${spec.sourceUnit}');
  }
}

final RegExp _unitSuffix =
    RegExp(r'\(\s*([^()/]+?)\s*/\s*100\s*g\s*\)\s*$');

String? _unitFromLabel(String label) {
  final match = _unitSuffix.firstMatch(label.trim());
  if (match == null) return null;
  return canonicalNutrientUnit(match.group(1)!.trim());
}

_XmlNode? _child(_XmlNode parent, String name, {bool required = false}) {
  final matches = <_XmlNode>[
    for (final child in parent.children)
      if (child.name == name) child,
  ];
  if (matches.isEmpty) {
    if (required) {
      throw FormatException('CIQUAL <${parent.name}> has no <$name>');
    }
    return null;
  }
  if (matches.length > 1) {
    throw FormatException('CIQUAL <${parent.name}> has duplicate <$name>');
  }
  return matches.single;
}

String? _leafText(_XmlNode parent, String name, {bool required = false}) {
  final child = _child(parent, name, required: required);
  if (child == null) return null;
  if (child.children.isNotEmpty) {
    throw FormatException('CIQUAL <$name> must contain text only');
  }
  if (child.attributes.containsKey('missing')) return null;
  final text = child.text.trim();
  return text.isEmpty ? null : text;
}

String _requiredText(_XmlNode parent, String name) {
  final value = _leafText(parent, name, required: true);
  if (value == null) {
    throw FormatException('CIQUAL <${parent.name}> has empty <$name>');
  }
  return value;
}

String? _boundRaw(_XmlNode? node) {
  if (node == null) return null;
  if (node.children.isNotEmpty) {
    throw FormatException('CIQUAL <${node.name}> must contain text only');
  }
  if (node.attributes.containsKey('missing')) return null;
  final raw = node.text.trim();
  return raw.isEmpty || raw == '-' ? null : raw;
}

final RegExp _digits = RegExp(r'^\d+$');

void _requireDigits(String value, String field) {
  if (!_digits.hasMatch(value)) {
    throw FormatException('CIQUAL $field "$value" is not numeric');
  }
}

final RegExp _decimal =
    RegExp(r'^-?\d+(?:[.,]\d+)?(?:[eE][+-]?\d+)?$');

final RegExp _xmlEntity =
    RegExp(r'&(amp|lt|gt|quot|apos|#\d{1,7}|#[xX][0-9A-Fa-f]{1,6});');

Exact? _parseNumber(String raw) {
  final text = raw.trim();
  if (!_decimal.hasMatch(text)) return null;
  try {
    return Exact.parse(text.replaceAll(',', '.'));
  } on FormatException {
    return null;
  }
}

Exact _parseNumberStrict(String raw, String field) {
  final value = _parseNumber(raw);
  if (value == null) {
    throw FormatException('CIQUAL $field "$raw" is not a finite decimal');
  }
  return value;
}

/// A strictly parsed XML element. The official CIQUAL files use one root
/// element with repeated record children and leaf text fields, so a full XML
/// implementation is unnecessary; rejecting anything outside that grammar keeps
/// malformed or ambiguous documents from being interpreted.
final class _XmlNode {
  _XmlNode(this.name, this.attributes);

  static const List<_XmlNode> _noChildren = <_XmlNode>[];

  final String name;
  final Map<String, String> attributes;
  List<_XmlNode> _children = _noChildren;
  List<_XmlNode> get children => _children;
  String text = '';

  void addChild(_XmlNode child) {
    if (identical(_children, _noChildren)) {
      _children = <_XmlNode>[];
    }
    _children.add(child);
  }
}

final class _XmlReader {
  _XmlReader(this.source);

  static const int _maxDepth = 32;

  final String source;
  int _index = 0;

  Iterable<_XmlNode> parseRecords(String recordName, String role) sync* {
    _skipDocumentPrefix();
    _parseRootStart();
    var count = 0;
    while (true) {
      _skipWhitespaceAndComments();
      if (_index >= source.length) _fail('unclosed <TABLE>');
      if (_startsWith('</')) {
        _index += 2;
        final closing = _parseName();
        _skipWhitespace();
        _expect('>');
        if (closing != 'TABLE') {
          _fail('mismatched closing tag </$closing> for <TABLE>');
        }
        break;
      }
      if (!_startsWith('<')) {
        _fail('unexpected text in <TABLE>');
      }
      final record = _parseElement(1);
      if (record.name != recordName) {
        _fail('unexpected <${record.name}> in CIQUAL $role document');
      }
      count += 1;
      yield record;
    }
    _skipWhitespaceAndComments();
    if (_index != source.length) _fail('trailing content after root element');
    if (count == 0) {
      _fail('CIQUAL $role document has no <$recordName> records');
    }
  }

  void _skipDocumentPrefix() {
    if (source.isNotEmpty && source.codeUnitAt(0) == 0xFEFF) {
      _index = 1;
    }
    _skipWhitespace();
    if (_startsWith('<?xml')) _skipUntil('?>');
    _skipWhitespaceAndComments();
  }

  void _parseRootStart() {
    _expect('<');
    final name = _parseName();
    if (name != 'TABLE') {
      _fail('CIQUAL document root is <$name>, expected <TABLE>');
    }
    while (true) {
      _skipWhitespace();
      if (_startsWith('>')) {
        _index += 1;
        return;
      }
      if (_startsWith('/>')) {
        _fail('CIQUAL document root must not be self-closing');
      }
      _parseName();
      _skipWhitespace();
      _expect('=');
      _skipWhitespace();
      _parseQuoted();
    }
  }

  _XmlNode _parseElement(int depth) {
    if (depth > _maxDepth) {
      _fail('nesting exceeds $_maxDepth levels');
    }
    _expect('<');
    if (_startsWith('/') || _startsWith('!') || _startsWith('?')) {
      _fail('expected an element');
    }
    final name = _parseName();
    Map<String, String>? attributes;
    while (true) {
      _skipWhitespace();
      if (_startsWith('/>')) {
        _index += 2;
        return _XmlNode(name, attributes ?? const <String, String>{});
      }
      if (_startsWith('>')) {
        _index += 1;
        break;
      }
      final attributeName = _parseName();
      _skipWhitespace();
      _expect('=');
      _skipWhitespace();
      if (attributes?.containsKey(attributeName) ?? false) {
        _fail('duplicate attribute "$attributeName"');
      }
      (attributes ??= <String, String>{})[attributeName] = _parseQuoted();
    }

    final node = _XmlNode(name, attributes ?? const <String, String>{});
    while (true) {
      if (_index >= source.length) _fail('unclosed <$name>');
      if (_startsWith('</')) {
        _index += 2;
        final closing = _parseName();
        _skipWhitespace();
        _expect('>');
        if (closing != name) {
          _fail('mismatched closing tag </$closing> for <$name>');
        }
        return node;
      }
      if (_startsWith('<!--')) {
        _skipUntil('-->');
        continue;
      }
      if (_startsWith('<![CDATA[')) {
        _fail('CDATA sections are not supported');
      }
      if (_startsWith('<!')) {
        _fail('DOCTYPE declarations are not supported');
      }
      if (_startsWith('<')) {
        final next =
            _index + 1 < source.length ? source.codeUnitAt(_index + 1) : -1;
        if (_beginsMarkup(next)) {
          node.addChild(_parseElement(depth + 1));
        } else {
          // Official 2020 data contains unescaped '<' in text such as
          // "Panaché préemballé (<1° alc.)". A '<' that cannot begin markup is
          // source text, not a tag opening.
          node.text += '<';
          _index += 1;
        }
        continue;
      }
      final nextTag = source.indexOf('<', _index);
      final end = nextTag == -1 ? source.length : nextTag;
      node.text += _decodeEntities(source.substring(_index, end));
      _index = end;
    }
  }

  String _parseName() {
    if (_index >= source.length || !_isNameStart(source.codeUnitAt(_index))) {
      _fail('expected an XML name');
    }
    final start = _index;
    _index += 1;
    while (_index < source.length && _isNameChar(source.codeUnitAt(_index))) {
      _index += 1;
    }
    return source.substring(start, _index);
  }

  bool _beginsMarkup(int codeUnit) =>
      codeUnit == 0x2F ||
      codeUnit == 0x21 ||
      codeUnit == 0x3F ||
      _isNameStart(codeUnit);

  bool _isNameStart(int codeUnit) =>
      (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
      (codeUnit >= 0x61 && codeUnit <= 0x7A) ||
      codeUnit == 0x5F;

  bool _isNameChar(int codeUnit) =>
      _isNameStart(codeUnit) ||
      (codeUnit >= 0x30 && codeUnit <= 0x39) ||
      codeUnit == 0x2D ||
      codeUnit == 0x2E ||
      codeUnit == 0x3A;

  String _parseQuoted() {
    if (_index >= source.length) _fail('unterminated attribute');
    final quote = source[_index];
    if (quote != '"' && quote != "'") {
      _fail('attribute values must be quoted');
    }
    _index += 1;
    final end = source.indexOf(quote, _index);
    if (end == -1) _fail('unterminated attribute');
    final value = _decodeEntities(source.substring(_index, end));
    _index = end + 1;
    return value;
  }

  void _skipWhitespaceAndComments() {
    while (true) {
      _skipWhitespace();
      if (_startsWith('<!--')) {
        _skipUntil('-->');
        continue;
      }
      return;
    }
  }

  void _skipWhitespace() {
    while (_index < source.length && _isWhitespace(source.codeUnitAt(_index))) {
      _index += 1;
    }
  }

  bool _isWhitespace(int codeUnit) =>
      codeUnit == 0x20 ||
      codeUnit == 0x09 ||
      codeUnit == 0x0A ||
      codeUnit == 0x0D;

  bool _startsWith(String token) => source.startsWith(token, _index);

  void _skipUntil(String terminator) {
    final end = source.indexOf(terminator, _index);
    if (end == -1) _fail('unterminated construct');
    _index = end + terminator.length;
  }

  void _expect(String token) {
    if (!_startsWith(token)) _fail('expected "$token"');
    _index += token.length;
  }

  String _decodeEntities(String text) {
    if (!text.contains('&')) return text;
    final buffer = StringBuffer();
    var index = 0;
    while (index < text.length) {
      final ampersand = text.indexOf('&', index);
      if (ampersand == -1) {
        buffer.write(text.substring(index));
        break;
      }
      buffer.write(text.substring(index, ampersand));
      final match = _xmlEntity.matchAsPrefix(text, ampersand);
      if (match == null) {
        // Official 2020 text contains raw '&' (for example "M&M's",
        // "lettuce & tomato"). Treat only a non-entity '&' as text.
        final semicolon = text.indexOf(';', ampersand + 1);
        if (semicolon != -1 && semicolon - ampersand <= 32) {
          final candidate = text.substring(ampersand + 1, semicolon);
          if (candidate.startsWith('#') ||
              RegExp(r'^[A-Za-z][A-Za-z0-9]*$').hasMatch(candidate)) {
            _fail('unsupported XML entity "&$candidate;"');
          }
        }
        buffer.write('&');
        index = ampersand + 1;
        continue;
      }

      final entity = match.group(1)!;
      switch (entity) {
        case 'amp':
          buffer.write('&');
        case 'lt':
          buffer.write('<');
        case 'gt':
          buffer.write('>');
        case 'quot':
          buffer.write('"');
        case 'apos':
          buffer.write("'");
        default:
          final numeric = entity.startsWith('#');
          final int? codeUnit;
          if (entity.startsWith('#x') || entity.startsWith('#X')) {
            codeUnit = int.tryParse(entity.substring(2), radix: 16);
          } else if (numeric) {
            codeUnit = int.tryParse(entity.substring(1));
          } else {
            codeUnit = null;
          }
          if (codeUnit == null || !_validXmlCodePoint(codeUnit)) {
            _fail('invalid numeric XML entity');
          }
          buffer.writeCharCode(codeUnit);
      }
      index = match.end;
    }
    return buffer.toString();
  }

  bool _validXmlCodePoint(int codeUnit) =>
      codeUnit == 0x09 ||
      codeUnit == 0x0A ||
      codeUnit == 0x0D ||
      (codeUnit >= 0x20 && codeUnit <= 0xD7FF) ||
      (codeUnit >= 0xE000 && codeUnit <= 0xFFFD) ||
      (codeUnit >= 0x10000 && codeUnit <= 0x10FFFF);

  Never _fail(String message) =>
      throw FormatException('Invalid CIQUAL XML: $message');
}
