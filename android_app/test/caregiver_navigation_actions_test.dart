import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kincare_android/caregiver_navigation_actions.dart';

void main() {
  for (final seniorMode in [false, true]) {
    testWidgets(
      'navigation fits a 360px mobile app bar (seniorMode: $seniorMode)',
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              title: const Text('KinCare'),
              actions: [
                CaregiverNavigationActions(
                  seniorMode: seniorMode,
                  caregiverSection: 'profiles',
                  onSectionSelected: (_) {},
                  onToggleMode: () {},
                  onSignOut: () {},
                ),
              ],
            ),
            body: const SizedBox.expand(),
          ),
        ));

        expect(tester.takeException(), isNull);
        expect(find.byTooltip('Open navigation menu'), findsOneWidget);
      },
    );
  }
}
