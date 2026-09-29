import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/ui/theme.dart';

/// Material 3 clamps modal bottom sheets to 640px by default, which centers
/// them with empty margins on tablets/desktop. Both app themes override the
/// constraint so sheets span the full width.
void main() {
  for (final (name, theme) in [
    ('light', buildLightTheme()),
    ('dark', buildDarkTheme()),
  ]) {
    testWidgets('modal bottom sheet spans full width ($name theme)',
        (tester) async {
      tester.view.physicalSize = const Size(1194 * 2, 834 * 2);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  builder: (_) => const SafeArea(
                    child: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        ListTile(title: Text('模型与模式')),
                      ]),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final screenWidth =
          tester.view.physicalSize.width / tester.view.devicePixelRatio;
      final sheetMaterial = tester.getRect(find
          .ancestor(of: find.text('模型与模式'), matching: find.byType(Material))
          .first);
      expect(sheetMaterial.left, 0.0,
          reason: '$name sheet should start at the left screen edge');
      expect(sheetMaterial.right, screenWidth,
          reason: '$name sheet should end at the right screen edge');
    });
  }
}
