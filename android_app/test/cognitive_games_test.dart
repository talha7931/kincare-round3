import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kincare_android/cognitive_game_rules.dart';
import 'package:kincare_android/sorting_game_progress.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Odd One Out rounds have four choices and one expected object',
      () async {
    final content = jsonDecode(
      await rootBundle.loadString('assets/cognitive_games.json'),
    ) as Map<String, dynamic>;
    final rounds =
        (content['odd_one_out'] as List).cast<Map<String, dynamic>>();
    expect(rounds.length, greaterThanOrEqualTo(3));
    for (final round in rounds) {
      final items = (round['items'] as List).cast<Map<String, dynamic>>();
      expect(items, hasLength(4));
      expect(round['explanation'], isNotEmpty);
      expect(
        items.where((item) => item['id'] == round['expected_item_id']),
        hasLength(1),
      );
    }
  });

  test('sorting objects use one of the two listed categories', () async {
    final content = jsonDecode(
      await rootBundle.loadString('assets/cognitive_games.json'),
    ) as Map<String, dynamic>;
    final sorting = content['everyday_object_sorting'] as Map<String, dynamic>;
    final categories = (sorting['categories'] as List)
        .cast<Map<String, dynamic>>()
        .map((row) => row['id'])
        .toSet();
    final items = (sorting['items'] as List).cast<Map<String, dynamic>>();
    expect(categories, hasLength(2));
    expect(items, isNotEmpty);
    for (final item in items) {
      expect(categories, contains(item['category_id']));
    }
  });

  test('structured activity response correctness is exact and non-clinical',
      () {
    expect(oddOneOutIsCorrect('chair', 'chair'), isTrue);
    expect(oddOneOutIsCorrect('apple', 'chair'), isFalse);
    expect(sortingIsCorrect('fruit', 'fruit'), isTrue);
    expect(sortingIsCorrect('vegetable', 'fruit'), isFalse);
  });

  test('canonical activity keys are accepted by the elderly game router', () {
    expect(isCognitiveGameActivityKey(oddOneOutActivityKey), isTrue);
    expect(
        isCognitiveGameActivityKey(everydayObjectSortingActivityKey), isTrue);
    expect(isCognitiveGameActivityKey('odd'), isFalse);
    expect(isCognitiveGameActivityKey('sorting'), isFalse);
  });

  test('speech uses the selected profile locale and Hindi bundled content',
      () async {
    expect(speechLocale('hi'), 'hi-IN');
    expect(speechLocale('hi-IN'), 'hi-IN');
    expect(speechLocale('mr'), 'mr-IN');
    expect(speechLocale(null), 'hi-IN');
    expect(speechLocale('en'), 'en-IN');

    final content = jsonDecode(
      await rootBundle.loadString('assets/cognitive_games.json'),
    ) as Map<String, dynamic>;
    final rounds =
        (content['odd_one_out'] as List).cast<Map<String, dynamic>>();
    expect(
      spokenText(
        ((rounds.first['spoken'] as Map)['hi'] as Map)['instruction'],
        'hi',
      ),
      contains('फल'),
    );
    final sorting = content['everyday_object_sorting'] as Map<String, dynamic>;
    expect(
      spokenText(
        ((sorting['spoken'] as Map)['hi'] as Map)['instruction'],
        'hi',
      ),
      contains('हर चीज़'),
    );
  });

  for (final count in [0, 1, 5, 6]) {
    testWidgets('sorting progress $count of 6 gates Finish Sorting',
        (tester) async {
      var finished = false;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SortingGameProgress(
        categorizedCount: count,
        totalCount: 6,
        busy: false,
        onFinish: () => finished = true,
      ))));
      expect(find.text('$count of 6 categorized'), findsOneWidget);
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed != null, count == 6);
      if (count == 6) {
        await tester.tap(find.text('Finish Sorting'));
        expect(finished, isTrue);
      } else {
        expect(find.text('Categorize every item before finishing.'),
            findsOneWidget);
      }
    });
  }

  test('sorting can move an assigned item to a different category', () {
    final updated = replaceSortingPlacement(
        {'apple': 'fruit', 'carrot': 'vegetable'}, 'apple', 'vegetable');
    expect(updated, {'apple': 'vegetable', 'carrot': 'vegetable'});
  });
}
