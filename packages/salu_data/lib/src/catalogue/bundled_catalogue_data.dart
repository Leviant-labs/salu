import 'package:salu_core/salu_core.dart';

// Source: U.S. Department of Agriculture, Agricultural Research Service,
// FoodData Central, Standard Reference Legacy (April 2018).
// CSV: https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_sr_legacy_food_csv_2018-04.zip
// Terms: https://fdc.nal.usda.gov/api-guide#bkmk-6 (public domain / CC0 1.0).
// Record lookup: https://fdc.nal.usda.gov/food-details/<FDC ID>/nutrients
//
// Salu selects generic staples, produce, legumes, dairy, meat and seafood,
// including Portuguese kitchen staples (e.g. bacalhau, sardinha, favas,
// couve, azeite, amêijoas), as well as tofu, quinoa, cassava, plantain and two
// sourced dishes (hummus and falafel). These are USDA reference foods, not
// Portuguese survey data, branded products, or estimates for local recipes.
// Display names and Portuguese/English search aliases are Salu editorial text;
// a broad alias helps locate a food, not establish an equivalent preparation.
//
// Join food.csv to food_nutrient.csv by fdc_id and map derivation_id via
// food_nutrient_derivation.csv. The values below are the published amounts per
// 100 g edible portion, unchanged. Only derivation A (Analytical) is marked
// measured; other or unspecified derivations are conservatively marked
// estimated with the source code. Blank amounts stay unknown. No portion sizes,
// densities, allergen declarations, or dietary claims are supplied here.

const bundledCatalogueDataset = 'usda-fdc-sr-legacy';
const bundledCatalogueDatasetVersion = '2018-04';
const bundledCatalogueLicence = 'CC0-1.0';

typedef BundledCatalogueEntry = ({Food food, List<String> aliases});

/// The small built-in set indexed by stable local ID. Aliases are not DB fields.
final bundledCatalogueEntries = Map<String, BundledCatalogueEntry>.unmodifiable(
  Map.fromEntries([
    for (final line in _rows.trim().split('\n'))
      if (!line.startsWith('#')) _parseEntry(line),
  ]),
);

const _keys = [
  NutrientKey.energyKcal, // FDC 1008
  NutrientKey.proteinG, // 1003
  NutrientKey.carbohydrateG, // 1005, total carbohydrate by difference
  NutrientKey.fatG, // 1004
  NutrientKey.fiberG, // 1079
  NutrientKey.saturatedFatG, // 1258
  NutrientKey.sugarsG, // 2000
  NutrientKey.sodiumMg, // 1093
];

MapEntry<String, BundledCatalogueEntry> _parseEntry(String line) {
  final fields = line.split('|');
  final fdcId = fields[0];
  final id = 'bundled-fdc-$fdcId';
  final prep = fields[1];
  final amounts = fields[4].split(' ');
  final derivations = fields[5].split(' ');
  final food = Food(
    id: id,
    name: fields[2],
    source: FoodSource(
      dataset: bundledCatalogueDataset,
      datasetId: fdcId,
      datasetVersion: bundledCatalogueDatasetVersion,
      licence: bundledCatalogueLicence,
    ),
    preparation: switch (prep) {
      'r' => Preparation.raw,
      'c' || 'd' => Preparation.cooked,
      _ => Preparation.unspecified,
    },
    per100g: NutrientProfile({
      for (var i = 0; i < _keys.length; i++)
        if (amounts[i] != '-')
          _keys[i]: _nutrient(double.parse(amounts[i]), derivations[i]),
    }),
    isComposite: prep == 'd',
  );
  return MapEntry(id, (food: food, aliases: fields[3].split(';')));
}

NutrientValue _nutrient(double amount, String derivation) => derivation == 'A'
    ? NutrientMeasured(amount)
    : NutrientEstimated(amount, basis: '$bundledCatalogueDataset:$derivation');

// FDC ID | prep (r raw, c cooked, u unspecified, d cooked dish) | display name
// | aliases (semicolon-separated) | per-100 g amounts in _keys order
// | original derivation codes in the same order (? = unspecified, - = missing)
const _rows = '''
# Fruit and vegetables
171688|r|Apple, raw, with skin|maçã;maçã com casca|52 0.26 13.81 0.17 2.4 0.028 10.39 1|NC A NC A A NC A A
173944|r|Banana, raw|banana crua|89 1.09 22.84 0.33 2.6 0.112 12.23 1|NC A NC A A NC A A
169097|r|Orange, raw|laranja|47 0.94 11.75 0.12 2.4 0.015 9.35 0|NC ? NC ? ? ? O ?
169118|r|Pear, raw|pera;pêra|57 0.36 15.23 0.14 3.1 0.022 9.75 1|NC A NC A A ? A A
171705|r|Avocado, raw|abacate|160 2 8.53 14.66 6.7 2.126 0.66 7|NC A NC A A NC A A
170457|r|Tomato, red, raw|tomate;tomate cru|18 0.88 3.89 0.2 1.2 0.028 2.63 5|NC JO NC JO JA NC NC JA
170000|r|Onion, raw|cebola|40 1.1 9.34 0.1 1.7 0.042 4.24 4|NC JO NC JO ? NC NC JA
169230|r|Garlic, raw|alho|149 6.36 33.06 0.5 2.1 0.089 1 17|NC ? NC ? ? ? T ?
170393|r|Carrot, raw|cenoura|41 0.93 9.58 0.24 2.8 0.032 4.74 69|NC JO NC JO A NC NC JA
170379|r|Broccoli, raw|brócolos;brócolis|34 2.82 6.64 0.37 2.6 0.114 1.7 33|NC JO NC JO JA NC NC JO
170026|r|Potato, raw, with skin|batata;batata crua com casca|77 2.05 17.49 0.09 2.1 0.025 0.82 6|NC A NC A A NC A ?
168482|r|Sweet potato, raw|batata-doce;batata-doce crua|86 1.57 20.12 0.05 3 0.018 4.18 55|NC A NC A ? NC NC A
170406|r|Collard greens, raw|couve;couve-galega crua|32 3.02 5.42 0.61 4 0.055 0.46 17|NC A NC A JA BFFN BFSN JA
170407|c|Collard greens, boiled, drained, no added salt|couve cozida;couve-galega cozida|33 2.71 5.65 0.72 4 0.047 0.4 15|NC A NC A A BFSN O JA
168216|c|Green plantain, boiled|banana-pão verde cozida;banana-da-terra verde cozida|121 1.09 29.15 0.08 2.6 0.072 2.25 2|NC A NC A A NC A A
169985|r|Cassava, raw|mandioca;yuca|160 1.36 38.06 0.28 1.8 0.074 1.7 14|NC A NC A A ? T A
# Grains, legumes and pantry
169757|c|White long-grain rice, cooked, unenriched, no added salt|arroz;arroz branco cozido|130 2.69 28.17 0.28 0.4 0.077 0.05 1|NC ? NC ? ? ? BFZN ?
169756|r|White long-grain rice, raw, unenriched|arroz cru;arroz branco cru|365 7.13 79.95 0.66 1.3 0.18 0.12 5|NC ? NC ? ? ? BFZN ?
168917|c|Quinoa, cooked|quinoa cozida|120 4.4 21.3 1.92 2.8 0.231 0.87 7|NC A NC A A BFSN O A
169705|u|Oats, dry|aveia|389 16.89 66.27 6.9 10.6 1.217 - 2|NC ? NC ? ? ? - ?
168928|c|Pasta, cooked, unenriched, no added salt|massa;massa cozida|158 5.8 30.86 0.93 1.8 0.176 0.56 1|NC A NC A A NC A A
169700|c|Couscous, cooked|cuscuz;cuscuz cozido|112 3.79 23.22 0.16 1.4 0.029 0.1 5|NC ? NC ? ? ? BFSN ?
173757|c|Chickpeas, boiled, no added salt|grão-de-bico;grão-de-bico cozido;garbanzo beans|164 8.86 27.42 2.59 7.6 0.269 4.8 7|NC ? NC ? ? ? T ?
172421|c|Lentils, boiled, no added salt|lentilhas;lentilhas cozidas|116 9.02 20.13 0.38 7.9 0.053 1.8 2|NC ? NC ? ? ? T ?
175194|c|Red kidney beans, boiled, no added salt|feijão vermelho;feijão vermelho cozido|127 8.67 22.8 0.5 7.4 0.072 0.32 2|NC ? NC ? ? ? BFSN ?
175203|c|White beans, boiled, no added salt|feijão branco;feijão branco cozido|139 9.73 25.09 0.35 6.3 0.091 0.34 6|NC ? NC ? ? ? BFSN ?
170378|c|Young broad beans, boiled, drained, no added salt|favas;favas cozidas;young fava beans|62 4.8 10.1 0.5 3.6 0.142 - 41|NC ? NC ? BFSN ? - ?
171413|u|Olive oil|azeite|884 0 0 100 0 13.808 0 2|NC A NC O ? NC Z A
169094|u|Ripe olives, canned|azeitonas;azeitonas maduras em conserva|116 0.84 6.04 10.9 1.6 2.279 0 735|NC ? NC MA MA NC Z A
172475|r|Tofu, firm, raw, made with calcium sulfate|tofu firme|144 17.27 2.78 8.72 2.3 1.261 - 14|NC ? NC ? BFZN ? - ?
172688|u|Whole-wheat bread, commercially prepared|pão integral;wholemeal bread|252 12.45 42.71 3.5 6 0.722 4.34 455|NC A NC A A NC A A
170567|u|Almonds|amêndoas|579 21.15 21.55 49.93 12.5 3.802 4.35 1|NC A NC A A NC ? A
174277|u|Soy sauce, soy and wheat (shoyu)|molho de soja;shoyu|53 8.14 4.93 0.57 0.8 0.073 0.4 5493|NC A NC A ? ? ? A
# Seafood, meat, eggs and dairy
174190|u|Atlantic cod, dried and salted|bacalhau;bacalhau seco salgado;salt cod|290 62.82 0 2.37 0 0.462 0 7027|NC ? Z ? Z ? Z ?
171956|c|Atlantic cod, cooked with dry heat|bacalhau fresco cozinhado;fresh cod cooked|105 22.83 0 0.86 0 0.168 0 78|NC ? Z ? Z ? Z ?
175139|u|Atlantic sardines, canned in oil, drained, with bone|sardinha;sardinhas em óleo|208 24.62 0 11.45 0 1.528 0 307|NC ? Z ? Z ? Z O
173709|u|Light tuna, canned in water, drained|atum;atum ao natural|86 19.44 0 0.96 0 0.211 0 247|NC A Z A Z NC Z A
175168|c|Farmed Atlantic salmon, cooked with dry heat|salmão;salmão cozinhado|206 22.1 0 12.35 0 2.397 0 61|NC ? Z ? Z NC BFZN ?
171975|c|Clams, mixed species, cooked with moist heat|amêijoas;amêijoas cozidas|148 25.55 5.13 1.95 0 0.188 - 1202|NC ? NC ? Z ? - O
171477|c|Chicken breast, roasted, meat only|peito de frango;peito de frango assado|165 31.02 0 3.57 0 1.01 0 74|NC ? Z ? Z ? Z ?
168250|c|Pork tenderloin, roasted, lean only|lombinho de porco;lombinho de porco assado|143 26.17 0 3.51 0 1.198 0 57|NC A Z A Z NC Z A
173424|c|Egg, whole, hard-boiled|ovo;ovo cozido|155 12.58 1.12 10.61 0 3.267 1.12 124|NC ? NC ? Z ? NR ?
172205|u|Milk, 2% fat, no added vitamins A or D|leite;leite 2%|50 3.3 4.8 1.98 0 1.257 5.06 47|NC A NC JO Z NC A A
171304|u|Greek yogurt, plain, whole milk|iogurte grego;iogurte grego natural|97 9 3.98 5 0 2.395 4 35|NC ? NC ? ? NC ? ?
173420|u|Feta cheese|queijo feta|265 14.21 3.88 21.49 0 13.3 0 1139|NC ? NC LC ? LC LC LC
# Prepared dishes (source-specific home-prepared versions)
172454|d|Hummus, home-prepared|húmus;homus;houmous|177 4.86 20.12 8.59 4 1.141 0.27 242|NC RA RA RA RA RA RA RA
172455|d|Falafel, home-prepared|faláfel|333 13.31 31.84 17.8 - 2.383 - 294|NC ? NC ? - ? - ?
# Additional international staples (same USDA source and edition)
168153|r|Kiwifruit, green, raw|kiwi;quivi|61 1.14 14.66 0.52 3 0.029 8.99 3|NC A NC A A NC A A
168177|r|Asian pear, raw|pera asiática;nashi|42 0.5 10.65 0.23 3.6 0.012 7.05 0|NC ? NC ? ? ? O ?
168409|r|Cucumber, raw, with peel|pepino|15 0.65 3.63 0.11 0.5 0.037 1.67 2|NC A NC JO ? NC NC ?
168411|c|Edamame, frozen, prepared|soja verde|121 11.91 8.91 5.2 5.2 0.62 2.18 6|NC A NC A A NC A A
168462|r|Spinach, raw|espinafres;espinafre|23 2.86 3.63 0.39 2.2 0.063 0.42 79|NC ? NC ? ? NC NC ?
168871|c|Millet, cooked|milhete cozido;painço cozido|119 3.51 23.67 1 1.3 0.172 0.13 2|NC ? NC ? ? ? BFSN ?
168927|u|Pasta, dry, unenriched|massa seca|371 13.04 74.67 1.51 3.2 0.277 2.67 6|NC A NC A A NC A A
169228|r|Eggplant, raw|beringela;aubergine|25 0.98 5.88 0.18 3 0.034 3.53 2|NC JO NC JA JA ? ? JA
169251|r|White mushrooms, raw|cogumelos brancos|22 3.09 3.26 0.34 1 0.05 1.98 5|NC JO NC JO JO NC JO JO
169291|r|Zucchini, raw, with skin|curgete;courgette|17 1.21 3.11 0.32 1 0.084 2.5 8|NC JO NC JA JA NC NC JA
169910|r|Mango, raw|manga|60 0.82 14.98 0.38 1.6 0.092 13.66 1|NC A NC A A ? ? A
170108|r|Red sweet pepper, raw|pimento vermelho|26 0.99 6.03 0.3 2.1 0.059 4.2 4|NC A NC A BFSN NC ? BFSN
170150|u|Sesame seeds, whole, dried|sementes de sésamo;gergelim|573 17.73 23.45 49.67 11.8 6.957 0.3 11|NC ? NC ? ? ? A ?
170162|r|Cashew nuts, raw|caju|553 18.22 30.19 43.85 3.3 7.783 5.91 12|NC A NC O BFSN NC A A
170287|c|Bulgur, cooked|bulgur cozido|83 3.08 18.58 0.24 4.5 0.042 0.1 5|NC ? NC ? ? ? BFSN ?
170392|u|Cabbage kimchi|kimchi;kimchi de couve|15 1.1 2.4 0.5 1.6 0.067 1.06 498|NC T NC T T NC BFSN T
170460|u|Canned tomato puree, no added salt|puré de tomate;polpa de tomate|38 1.65 8.98 0.21 1.9 0.029 4.83 28|NC JO NC JA JA NC ? JA
170554|u|Chia seeds, dried|sementes de chia|486 16.54 42.12 30.74 34.4 3.33 - 16|NC A NC A AI NC - JA
170845|u|Mozzarella, whole milk|muçarela;mozzarela|299 22.17 2.4 22.14 0 13.9 0 486|NC A NC LC ? LC LC LC
170848|u|Parmesan, hard|parmesão;parmigiano|392 35.75 3.22 25 0 14.85 0.11 1175|NC ? NC LC ? LC LC LC
170923|u|Cumin seed|cominhos|375 17.81 44.24 22.27 10.5 1.535 2.25 168|NC ? NC ? ? ? A ?
171284|u|Plain whole milk yogurt|iogurte natural; yogurt|61 3.47 4.66 3.25 0 2.096 4.66 46|NC ? NC ? ? ? NR ?
171329|u|Paprika|colorau;pimentão doce|282 14.14 53.99 12.89 34.9 2.14 10.34 68|NC A NC A A NC A A
171971|c|Shrimp, cooked with moist heat|camarão cozido;prawns cooked|119 22.78 1.52 1.7 0 0.521 0 947|NC RA RA RA RA RA RA RA
172231|u|Turmeric, ground|curcuma;açafrão das índias|312 9.68 67.14 3.25 22.7 1.838 3.21 27|NC A NC A A NC A A
172442|u|Miso|pasta de miso;missô|198 12.79 25.37 6.01 5.4 1.025 6.2 3728|NC JA NC JA ? JO NC JA
172467|c|Tempeh, cooked|tempeh cozido|195 19.91 7.62 11.38 - 3.4 - 14|NC A NC A - NC - A
173241|u|Corn tortillas, ready to heat, no added salt|tortilha de milho|222 5.7 46.6 2.5 5.2 0.334 - 11|NC ? ? ? ? ? - ?
173735|c|Black beans, cooked, no added salt|feijão preto cozido|132 8.86 23.71 0.54 8.7 0.139 0.32 1|NC ? NC ? ? ? BFSN ?
174030|r|Ground beef, 90% lean, raw|carne de vaca picada|176 20 0 10 0 3.927 0 66|NC AR Z AR Z NC Z AR
174183|u|European anchovies, canned in oil, drained|anchovas em conserva|210 28.89 0 9.71 0 2.203 0 3668|NC ? Z ? Z ? Z ?
''';
