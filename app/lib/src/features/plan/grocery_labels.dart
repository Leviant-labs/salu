import 'package:flutter/widgets.dart';

import '../../ui_support.dart';

/// Shopping labels for the exact INSA ingredients used by the starter meals.
/// These are display-only: source names, preparation and quantities stay intact.
String groceryShoppingName(BuildContext context, String foodId, String fallback) {
  const names = <String, (String, String)>{
    '1': ('Drinking water', 'Água potável'),
    '11': ('Skinless chicken breast (raw)', 'Peito de frango sem pele (cru)'),
    '76': ('Plain semi-fat yogurt', 'Iogurte natural meio-gordo'),
    '83': ('Eggs', 'Ovos'),
    '284': ('Skinless turkey breast (raw)', 'Peito de peru sem pele (cru)'),
    '395': ('Olive oil', 'Azeite'),
    '401': ('Brown rice (dry)', 'Arroz integral (cru)'),
    '402': ('Long-grain rice (dry)', 'Arroz agulha (cru)'),
    '403': ('Ready-cooked plain rice', 'Arroz branco já cozido'),
    '418': ('Small pasta (dry)', 'Massa miúda (crua)'),
    '433': ('Whole-wheat bread', 'Pão integral'),
    '444': ('Oats', 'Flocos de aveia'),
    '532': ('Cooked white beans', 'Feijão branco cozido'),
    '536': ('Cooked chickpeas', 'Grão-de-bico cozido'),
    '538': ('Cooked lentils', 'Lentilhas cozidas'),
    '545': ('Plain tofu', 'Tofu simples'),
    '550': ('Broccoli', 'Brócolos'),
    '585': ('Potatoes', 'Batatas'),
    '597': ('Onion', 'Cebola'),
    '600': ('Carrots', 'Cenouras'),
    '608': ('Spinach', 'Espinafres'),
    '611': ('Cucumber', 'Pepino'),
    '615': ('Tomatoes', 'Tomates'),
    '624': ('Avocado', 'Abacate'),
    '636': ('Bananas', 'Bananas'),
    '661': ('Lemon', 'Limão'),
    '662': ('Apples', 'Maçãs'),
    '676': ('Strawberries', 'Morangos'),
    '680': ('Pears', 'Peras'),
    '697': ('Almonds', 'Amêndoas'),
    '699': ('Peanuts', 'Amendoins'),
    '814': ('Tuna in oil', 'Atum em óleo'),
    '876': ('Salmon (raw)', 'Salmão (cru)'),
    '966': ('Hake (raw)', 'Pescada (crua)'),
    '240002': ('Cooked red beans', 'Feijão encarnado cozido'),
  };
  if (!foodId.startsWith('insa-bdca:')) return fallback;
  final label = names[foodId.substring('insa-bdca:'.length)];
  return label == null ? fallback : tr(context, label.$1, label.$2);
}

/// The requirement is cooked weight, not an estimate of uncooked rice to buy.
String? groceryPreparationNote(BuildContext context, String foodId) =>
    foodId == 'insa-bdca:403'
        ? tr(context,
            'Cooked weight; buy ready-cooked rice or prepare it separately. No dry weight is estimated.',
            'Peso cozido; compre arroz já cozido ou prepare-o à parte. Não é estimado o peso em cru.')
        : null;
