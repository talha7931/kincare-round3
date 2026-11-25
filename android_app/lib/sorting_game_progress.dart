import 'package:flutter/material.dart';

import 'app_theme.dart';

class SortingGameProgress extends StatelessWidget {
  final int categorizedCount;
  final int totalCount;
  final bool busy;
  final VoidCallback onFinish;

  const SortingGameProgress({
    super.key,
    required this.categorizedCount,
    required this.totalCount,
    required this.busy,
    required this.onFinish,
  });

  bool get canFinish => totalCount > 0 && categorizedCount == totalCount;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('$categorizedCount of $totalCount categorized',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: KinCareColors.forest)),
          if (!canFinish) ...[
            const SizedBox(height: KinCareSpace.x2),
            const Text('Items marked “Not grouped” still need a category.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 17, color: KinCareColors.textMuted)),
          ],
          const SizedBox(height: KinCareSpace.x3),
          SizedBox(
            height: KinCareSenior.controlHeight,
            child: FilledButton(
              onPressed: canFinish && !busy ? onFinish : null,
              child: Text(busy ? 'Saving your choices…' : 'Finish Sorting',
                  style: const TextStyle(
                      fontSize: 21, fontWeight: FontWeight.w700)),
            ),
          ),
          if (!canFinish) ...[
            const SizedBox(height: KinCareSpace.x2),
            const Text('Categorize every item before finishing.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 17, color: KinCareColors.textMuted)),
          ],
        ],
      );
}

Map<String, String> replaceSortingPlacement(
        Map<String, String> placements, String itemId, String categoryId) =>
    {
      ...placements,
      itemId: categoryId,
    };
