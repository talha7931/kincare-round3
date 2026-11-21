import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kincare_android/cognitive_game_rules.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Odd One Out rounds have four choices and one expected object', () async {
    final content = jsonDecode(
      await rootBundle.loadString('assets/cognitive_games.json'),
    ) as Map<String, dynamic>;
    final rounds = (content['odd_one_out'] as List).cast<Map<String, dynamic>>();
    expect(rounds.length, greaterThanOrEqualTo(3));
    for (final round in rounds) {
      final items = (round['items'] as List).cast<Map<String, dynamic>>();
      expect(items, hasLength(4));
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

  test('structured activity response correctness is exact and non-clinical', () {
    expect(oddOneOutIsCorrect('chair', 'chair'), isTrue);
    expect(oddOneOutIsCorrect('apple', 'chair'), isFalse);
    expect(sortingIsCorrect('fruit', 'fruit'), isTrue);
    expect(sortingIsCorrect('vegetable', 'fruit'), isFalse);
  });
}
