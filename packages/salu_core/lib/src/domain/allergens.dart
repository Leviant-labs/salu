/// Canonical EU Annex II (Regulation 1169/2011) allergen categories.
///
/// Exact alias matching only: ambiguous terms (such as "nuts" or "marisco")
/// remain unresolved so strict allergy checks fail closed rather than guess.
enum AllergenId {
  milk,
  egg,
  fish,
  crustacean,
  mollusc,
  peanut,
  treeNut,
  soy,
  wheatGluten,
  sesame,
  celery,
  mustard,
  lupin,
  sulphite,
}

extension AllergenIdLabel on AllergenId {
  String get label => switch (this) {
        AllergenId.milk => 'Milk',
        AllergenId.egg => 'Egg',
        AllergenId.fish => 'Fish',
        AllergenId.crustacean => 'Crustacean',
        AllergenId.mollusc => 'Mollusc',
        AllergenId.peanut => 'Peanut',
        AllergenId.treeNut => 'Tree nut',
        AllergenId.soy => 'Soy',
        AllergenId.wheatGluten => 'Wheat / gluten',
        AllergenId.sesame => 'Sesame',
        AllergenId.celery => 'Celery',
        AllergenId.mustard => 'Mustard',
        AllergenId.lupin => 'Lupin',
        AllergenId.sulphite => 'Sulphite',
      };
}

String normalizeAllergenText(String text) {
  final folded = _foldLatinDiacritics(text.toLowerCase());
  return folded
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String _foldLatinDiacritics(String input) {
  final buffer = StringBuffer();
  for (final code in input.runes) {
    buffer.write(_diacriticMap[code] ?? String.fromCharCode(code));
  }
  return buffer.toString();
}

const _diacriticMap = <int, String>{
  0x00E0: 'a', // à
  0x00E1: 'a', // á
  0x00E2: 'a', // â
  0x00E3: 'a', // ã
  0x00E4: 'a', // ä
  0x00E5: 'a', // å
  0x00E7: 'c', // ç
  0x00E8: 'e', // è
  0x00E9: 'e', // é
  0x00EA: 'e', // ê
  0x00EB: 'e', // ë
  0x00EC: 'i', // ì
  0x00ED: 'i', // í
  0x00EE: 'i', // î
  0x00EF: 'i', // ï
  0x00F1: 'n', // ñ
  0x00F2: 'o', // ò
  0x00F3: 'o', // ó
  0x00F4: 'o', // ô
  0x00F5: 'o', // õ
  0x00F6: 'o', // ö
  0x00F8: 'o', // ø
  0x00F9: 'u', // ù
  0x00FA: 'u', // ú
  0x00FB: 'u', // û
  0x00FC: 'u', // ü
  0x00FD: 'y', // ý
  0x00FF: 'y', // ÿ
};

const Map<String, AllergenId> _aliases = {
  // Milk
  'milk': AllergenId.milk,
  'dairy': AllergenId.milk,
  'milk protein': AllergenId.milk,
  'lactose': AllergenId.milk,
  'leite': AllergenId.milk,
  'lacticinios': AllergenId.milk,
  'laticinios': AllergenId.milk,
  'lacteos': AllergenId.milk,
  'produtos lacteos': AllergenId.milk,
  'iogurte': AllergenId.milk,
  'yogurt': AllergenId.milk,
  'yoghurt': AllergenId.milk,
  'queijo': AllergenId.milk,
  'cheese': AllergenId.milk,
  // Egg
  'egg': AllergenId.egg,
  'eggs': AllergenId.egg,
  'ovo': AllergenId.egg,
  'ovos': AllergenId.egg,
  'clara de ovo': AllergenId.egg,
  'gema de ovo': AllergenId.egg,
  // Fish
  'fish': AllergenId.fish,
  'peixe': AllergenId.fish,
  'peixes': AllergenId.fish,
  'sardinha': AllergenId.fish,
  'sardinhas': AllergenId.fish,
  'sardine': AllergenId.fish,
  'sardines': AllergenId.fish,
  'atum': AllergenId.fish,
  'tuna': AllergenId.fish,
  'bacalhau': AllergenId.fish,
  'cod': AllergenId.fish,
  'salmao': AllergenId.fish,
  'salmon': AllergenId.fish,
  'anchova': AllergenId.fish,
  'anchovas': AllergenId.fish,
  'anchovy': AllergenId.fish,
  'anchovies': AllergenId.fish,
  // Crustacean
  'crustacean': AllergenId.crustacean,
  'crustaceans': AllergenId.crustacean,
  'crustacean shellfish': AllergenId.crustacean,
  'crustaceo': AllergenId.crustacean,
  'crustaceos': AllergenId.crustacean,
  'camarao': AllergenId.crustacean,
  'camaroes': AllergenId.crustacean,
  'shrimp': AllergenId.crustacean,
  'prawn': AllergenId.crustacean,
  'prawns': AllergenId.crustacean,
  'gamba': AllergenId.crustacean,
  'gambas': AllergenId.crustacean,
  'lagosta': AllergenId.crustacean,
  'lobster': AllergenId.crustacean,
  'caranguejo': AllergenId.crustacean,
  'crab': AllergenId.crustacean,
  'sapateira': AllergenId.crustacean,
  'lavagante': AllergenId.crustacean,
  // Mollusc
  'mollusc': AllergenId.mollusc,
  'molluscs': AllergenId.mollusc,
  'mollusk': AllergenId.mollusc,
  'mollusks': AllergenId.mollusc,
  'molusco': AllergenId.mollusc,
  'moluscos': AllergenId.mollusc,
  'ameijoa': AllergenId.mollusc,
  'ameijoas': AllergenId.mollusc,
  'clam': AllergenId.mollusc,
  'clams': AllergenId.mollusc,
  'mexilhao': AllergenId.mollusc,
  'mexilhoes': AllergenId.mollusc,
  'mussel': AllergenId.mollusc,
  'mussels': AllergenId.mollusc,
  'ostra': AllergenId.mollusc,
  'ostras': AllergenId.mollusc,
  'oyster': AllergenId.mollusc,
  'oysters': AllergenId.mollusc,
  'lula': AllergenId.mollusc,
  'lulas': AllergenId.mollusc,
  'squid': AllergenId.mollusc,
  'polvo': AllergenId.mollusc,
  'octopus': AllergenId.mollusc,
  'vieira': AllergenId.mollusc,
  'vieiras': AllergenId.mollusc,
  'scallop': AllergenId.mollusc,
  'scallops': AllergenId.mollusc,
  'berbigao': AllergenId.mollusc,
  // Peanut
  'peanut': AllergenId.peanut,
  'peanuts': AllergenId.peanut,
  'amendoim': AllergenId.peanut,
  'amendoins': AllergenId.peanut,
  'manteiga de amendoim': AllergenId.peanut,
  'peanut butter': AllergenId.peanut,
  // Tree nut (explicitly excludes generic "nuts")
  'treenut': AllergenId.treeNut,
  'tree nut': AllergenId.treeNut,
  'tree nuts': AllergenId.treeNut,
  'frutos de casca rija': AllergenId.treeNut,
  'fruto de casca rija': AllergenId.treeNut,
  'almond': AllergenId.treeNut,
  'almonds': AllergenId.treeNut,
  'amendoa': AllergenId.treeNut,
  'amendoas': AllergenId.treeNut,
  'hazelnut': AllergenId.treeNut,
  'hazelnuts': AllergenId.treeNut,
  'avela': AllergenId.treeNut,
  'avelas': AllergenId.treeNut,
  'walnut': AllergenId.treeNut,
  'walnuts': AllergenId.treeNut,
  'noz': AllergenId.treeNut,
  'nozes': AllergenId.treeNut,
  'cashew': AllergenId.treeNut,
  'cashews': AllergenId.treeNut,
  'caju': AllergenId.treeNut,
  'castanha de caju': AllergenId.treeNut,
  'pecan': AllergenId.treeNut,
  'pecans': AllergenId.treeNut,
  'noz peca': AllergenId.treeNut,
  'nozes peca': AllergenId.treeNut,
  'brazil nut': AllergenId.treeNut,
  'brazil nuts': AllergenId.treeNut,
  'castanha do para': AllergenId.treeNut,
  'castanha do brasil': AllergenId.treeNut,
  'pistachio': AllergenId.treeNut,
  'pistachios': AllergenId.treeNut,
  'pistacio': AllergenId.treeNut,
  'pistacios': AllergenId.treeNut,
  'pistache': AllergenId.treeNut,
  'macadamia': AllergenId.treeNut,
  'macadamias': AllergenId.treeNut,
  'noz de macadamia': AllergenId.treeNut,
  // Soy
  'soy': AllergenId.soy,
  'soya': AllergenId.soy,
  'soybean': AllergenId.soy,
  'soybeans': AllergenId.soy,
  'soja': AllergenId.soy,
  'rebentos de soja': AllergenId.soy,
  'tofu': AllergenId.soy,
  'edamame': AllergenId.soy,
  // Wheat / gluten (EU 1169/2011 cereals containing gluten)
  'wheatgluten': AllergenId.wheatGluten,
  'wheat gluten': AllergenId.wheatGluten,
  'wheat': AllergenId.wheatGluten,
  'gluten': AllergenId.wheatGluten,
  'cereals containing gluten': AllergenId.wheatGluten,
  'cereais que contem gluten': AllergenId.wheatGluten,
  'trigo': AllergenId.wheatGluten,
  'cevada': AllergenId.wheatGluten,
  'barley': AllergenId.wheatGluten,
  'centeio': AllergenId.wheatGluten,
  'rye': AllergenId.wheatGluten,
  'espelta': AllergenId.wheatGluten,
  'spelt': AllergenId.wheatGluten,
  'kamut': AllergenId.wheatGluten,
  'aveia': AllergenId.wheatGluten,
  'oats': AllergenId.wheatGluten,
  'oat': AllergenId.wheatGluten,
  // Sesame
  'sesame': AllergenId.sesame,
  'sesame seed': AllergenId.sesame,
  'sesame seeds': AllergenId.sesame,
  'sesamo': AllergenId.sesame,
  'sementes de sesamo': AllergenId.sesame,
  'gergelim': AllergenId.sesame,
  'tahini': AllergenId.sesame,
  // Celery
  'celery': AllergenId.celery,
  'celeriac': AllergenId.celery,
  'aipo': AllergenId.celery,
  // Mustard
  'mustard': AllergenId.mustard,
  'mostarda': AllergenId.mustard,
  'semente de mostarda': AllergenId.mustard,
  'sementes de mostarda': AllergenId.mustard,
  // Lupin
  'lupin': AllergenId.lupin,
  'lupine': AllergenId.lupin,
  'lupins': AllergenId.lupin,
  'lupini': AllergenId.lupin,
  'tremoco': AllergenId.lupin,
  'tremocos': AllergenId.lupin,
  // Sulphite
  'sulphite': AllergenId.sulphite,
  'sulphites': AllergenId.sulphite,
  'sulfite': AllergenId.sulphite,
  'sulfites': AllergenId.sulphite,
  'sulfitos': AllergenId.sulphite,
  'sulfito': AllergenId.sulphite,
  'dioxido de enxofre': AllergenId.sulphite,
  'sulphur dioxide': AllergenId.sulphite,
  'sulfur dioxide': AllergenId.sulphite,
};

AllergenId? resolveAllergen(String text) {
  final normalized = normalizeAllergenText(text);
  if (normalized.isEmpty) return null;
  return _aliases[normalized];
}

({Set<AllergenId> known, List<String> unresolved}) resolveStrictAllergens(
  Iterable<String> terms,
) {
  final known = <AllergenId>{};
  final unresolved = <String>[];
  for (final raw in terms) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) continue;
    final resolved = resolveAllergen(trimmed);
    if (resolved != null) {
      known.add(resolved);
    } else if (!unresolved.contains(trimmed)) {
      unresolved.add(trimmed);
    }
  }
  return (
    known: Set.unmodifiable(known),
    unresolved: List.unmodifiable(unresolved),
  );
}
