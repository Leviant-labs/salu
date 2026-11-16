import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/rewards/rewards_screen.dart';
import 'package:salu_data/salu_data.dart';
import 'offline_flows_test.dart' as helpers;

Future<void> reveal(WidgetTester tester, Finder finder) async {
  final scrollable = find.byType(Scrollable).first;
  tester.state<ScrollableState>(scrollable).position.jumpTo(0);
  await tester.pump();
  await tester.scrollUntilVisible(finder, 250, scrollable: scrollable);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('locked cosmetics are not selectable and the surface stays humane',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await helpers.pump(tester, db, const RewardsScreen());

    expect(find.text('Rewards'), findsOneWidget);
    expect(find.text('How rewards work'), findsOneWidget);
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel('Companion wearing Everyday companion'),
        findsOneWidget);
    semantics.dispose();
    await reveal(tester,
        find.textContaining('No missed day, streak, intake, weight or fasting outcome removes'));
    expect(
        find.textContaining(
            'No missed day, streak, intake, weight or fasting outcome removes'),
        findsOneWidget);

    await reveal(
        tester, find.text('Planning apron'));
    expect(
        find.textContaining('Locked: Earn by recording a planning reward.'),
        findsOneWidget);
    await tester.tap(find.text('Planning apron'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(
        (await LocalWorkspace(db).read('preferences', 'app'))
            ?.data['rewardCosmetic'],
        isNull);

    await reveal(tester,
        find.textContaining('Earned cosmetics stay available across missed days'));
    expect(
        find.textContaining(
            'Earned cosmetics stay available across missed days'),
        findsOneWidget);
  });

  testWidgets('earned cosmetic persists across reloads and missed days',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = LocalWorkspace(db);
    await workspace.reward('engagement:2026-01-01');
    await workspace.reward('planning:2026-01-01');
    await helpers.pump(tester, db, const RewardsScreen());

    await reveal(tester, find.text('Planning apron'));
    await tester.tap(find.text('Planning apron'));
    await tester.pumpAndSettle();
    expect(
        (await LocalWorkspace(db).read('preferences', 'app'))!
            .data['rewardCosmetic'],
        'planning-apron');

    // A locked item cannot replace the selection.
    await reveal(tester, find.text('Check-in badge'));
    await tester.tap(find.text('Check-in badge'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(
        (await LocalWorkspace(db).read('preferences', 'app'))!
            .data['rewardCosmetic'],
        'planning-apron');

    // Reloading without adding any new event keeps the earned selection, even
    // though days have been missed by definition.
    await tester.pumpWidget(const SizedBox.shrink());
    await helpers.pump(tester, db, const RewardsScreen());
    expect(
        (await LocalWorkspace(db).read('preferences', 'app'))!
            .data['rewardCosmetic'],
        'planning-apron');
    final semantics = tester.ensureSemantics();
    await reveal(tester, find.bySemanticsLabel('Companion wearing Planning apron'));
    expect(find.bySemanticsLabel('Companion wearing Planning apron'),
        findsOneWidget);
    semantics.dispose();
  });

  testWidgets('missing reward kinds keep their cosmetics locked',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await LocalWorkspace(db).reward('engagement:stable');
    await helpers.pump(tester, db, const RewardsScreen());

    await reveal(tester, find.text('Check-in badge'));
    expect(find.textContaining('Locked: Earn by recording a check-in reward.'),
        findsOneWidget);
    await reveal(tester, find.text('Learning cap'));
    expect(find.textContaining('Locked: Earn by recording a learning reward.'),
        findsOneWidget);
    await reveal(tester, find.text('Celebration'));
    expect(
        find.textContaining(
            'Locked: Earn with any 5 allowed engagement reward events.'),
        findsOneWidget);
  });

  testWidgets(
      'explicit engagement, learning and return actions earn once and persist',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await helpers.pump(tester, db, const RewardsScreen());

    await reveal(tester, find.text('I have read this'));
    await tester.tap(find.text('I have read this'));
    await tester.pumpAndSettle();
    // Retrying the same explicit action is idempotent.
    await reveal(tester, find.text('I have read this'));
    await tester.tap(find.text('I have read this'));
    await tester.pumpAndSettle();

    await reveal(tester, find.text('I am returning after a break'));
    await tester.tap(find.text('I am returning after a break'));
    await tester.pumpAndSettle();

    await reveal(tester, find.text('Acknowledge engagement'));
    await tester.tap(find.text('Acknowledge engagement'));
    await tester.pumpAndSettle();

    final ids = {
      for (final reward in await LocalWorkspace(db).list('reward')) reward.id
    };
    expect(ids, {
      'learning:record-reading-ack',
      'return:voluntary-after-break',
      'engagement:companion-check-in'
    });
    for (final reward in await LocalWorkspace(db).list('reward')) {
      expect(reward.data, {'engagement': true});
    }

    await reveal(tester, find.text('Learning cap'));
    await tester.tap(find.text('Learning cap'));
    await tester.pumpAndSettle();
    expect(
        (await LocalWorkspace(db).read('preferences', 'app'))!
            .data['rewardCosmetic'],
        'learning-cap');

    await reveal(tester, find.text('Returning star'));
    await tester.tap(find.text('Returning star'));
    await tester.pumpAndSettle();
    expect(
        (await LocalWorkspace(db).read('preferences', 'app'))!
            .data['rewardCosmetic'],
        'returning-star');

    await reveal(tester, find.text('Engagement bell'));
    await tester.tap(find.text('Engagement bell'));
    await tester.pumpAndSettle();
    expect(
        (await LocalWorkspace(db).read('preferences', 'app'))!
            .data['rewardCosmetic'],
        'engagement-bell');

    await tester.pumpWidget(const SizedBox.shrink());
    await helpers.pump(tester, db, const RewardsScreen());
    expect(
        (await LocalWorkspace(db).read('preferences', 'app'))!
            .data['rewardCosmetic'],
        'engagement-bell');
    final semantics = tester.ensureSemantics();
    await reveal(tester, find.bySemanticsLabel('Companion wearing Engagement bell'));
    expect(find.bySemanticsLabel('Companion wearing Engagement bell'),
        findsOneWidget);
    semantics.dispose();
  });

  testWidgets('pt-PT rewards copy and selection are localized',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await LocalWorkspace(db).reward('planning:2026-01-01');
    await helpers.pump(tester, db, const RewardsScreen(), pt: true, scale: 2);

    expect(find.text('Recompensas'), findsOneWidget);
    expect(find.text('Como funcionam as recompensas'), findsOneWidget);
    await reveal(tester, find.textContaining('Nenhum dia em falta'));
    expect(find.textContaining('Nenhum dia em falta'), findsOneWidget);
    await reveal(tester, find.text('Já li isto'));
    expect(find.text('Já li isto'), findsOneWidget);
    await reveal(tester, find.text('Estou a regressar após uma pausa'));
    expect(find.text('Estou a regressar após uma pausa'), findsOneWidget);
    await reveal(tester, find.text('Assinalar participação'));
    expect(find.text('Assinalar participação'), findsOneWidget);

    await reveal(tester, find.text('Avental de planeamento'));
    await tester.tap(find.text('Avental de planeamento'));
    await tester.pumpAndSettle();
    expect(
        (await LocalWorkspace(db).read('preferences', 'app'))!
            .data['rewardCosmetic'],
        'planning-apron');
  });
}
