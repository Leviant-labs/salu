import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/onboarding/onboarding_screen.dart';

void main() {
  test('whole-grain cap note appears only for relevant lipid and cap cases', () {
    expect(
        shouldShowWholeGrainCapNote(
            conditions: const {'highCholesterol': true},
            maximumCookingMinutes: 30,
            mealLabels: const ['lunch']),
        isTrue);
    expect(
        shouldShowWholeGrainCapNote(
            conditions: const {'highTriglycerides': true},
            maximumCookingMinutes: 15,
            mealLabels: const ['dinner']),
        isTrue);
    expect(
        shouldShowWholeGrainCapNote(
            conditions: const {'highCholesterol': true},
            maximumCookingMinutes: 45,
            mealLabels: const ['lunch']),
        isFalse,
        reason: '45 minutes includes the raw brown-rice recipes');
    expect(
        shouldShowWholeGrainCapNote(
            conditions: const {},
            maximumCookingMinutes: 30,
            mealLabels: const ['lunch']),
        isFalse);
    expect(
        shouldShowWholeGrainCapNote(
            conditions: const {'highCholesterol': true},
            maximumCookingMinutes: 30,
            mealLabels: const ['breakfast', 'snack']),
        isFalse,
        reason: 'the note is about main-meal rice options');
    expect(
        shouldShowWholeGrainCapNote(
            conditions: const {'highCholesterol': true},
            maximumCookingMinutes: null,
            mealLabels: const ['lunch']),
        isFalse);
  });
}
