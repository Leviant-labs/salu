import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

void main() {
  test('mass resolves directly to grams', () {
    final result = resolveQuantity(
      MassQuantity(150),
      PortionDefinition.massOnly,
    );
    expect(result, const ResolvedMass(150));
  });

  test('kilograms convert to grams', () {
    expect(MassQuantity.kilograms(1.5).grams, 1500);
  });

  test('volume needs the food density', () {
    const portions = PortionDefinition(densityGramsPerMillilitre: 1.03);
    final result = resolveQuantity(VolumeQuantity(200), portions);
    expect(result, isA<ResolvedMass>());
    expect((result as ResolvedMass).grams, closeTo(206, 1e-9));
  });

  test('volume without density is unresolvable and names the reason', () {
    final result =
        resolveQuantity(VolumeQuantity(200), PortionDefinition.massOnly);
    expect(result, isA<UnresolvableQuantity>());
    expect((result as UnresolvableQuantity).reason, contains('density'));
  });

  test('pieces need a recorded portion weight', () {
    final result = resolveQuantity(
      PieceQuantity(2),
      const PortionDefinition(portionGrams: 120),
    );
    expect(result, const ResolvedMass(240));
  });

  test('pieces without a portion weight are unresolvable', () {
    final result = resolveQuantity(
      PieceQuantity(2),
      const PortionDefinition(densityGramsPerMillilitre: 1),
    );
    expect(result, isA<UnresolvableQuantity>());
    expect((result as UnresolvableQuantity).reason, contains('portion weight'));
  });

  test('invalid declared conversions are refused, not trusted', () {
    final result = resolveQuantity(
      VolumeQuantity(100),
      const PortionDefinition(densityGramsPerMillilitre: 0),
    );
    expect(result, isA<UnresolvableQuantity>());
  });

  test('negative quantities are rejected at construction', () {
    expect(() => MassQuantity(-1), throwsArgumentError);
    expect(() => VolumeQuantity(double.nan), throwsArgumentError);
    expect(() => PieceQuantity(-0.5), throwsArgumentError);
  });
}
