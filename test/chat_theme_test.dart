import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/ui/theme.dart';

double _luminanceDifference(Color a, Color b) =>
    (a.computeLuminance() - b.computeLuminance()).abs();

void main() {
  testWidgets('chat panels have readable light-theme contrast', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(
      theme: buildLightTheme(),
      home: Builder(builder: (value) {
        context = value;
        return const SizedBox();
      }),
    ));

    expect(
      _luminanceDifference(ZInk.solid(context), ZInk.reasoningPanel(context)),
      greaterThan(0.45),
    );
    expect(
      _luminanceDifference(ZInk.solid(context), ZInk.panel(context)),
      greaterThan(0.45),
    );
  });

  testWidgets('chat panels have readable dark-theme contrast', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(
      theme: buildDarkTheme(),
      home: Builder(builder: (value) {
        context = value;
        return const SizedBox();
      }),
    ));

    expect(
      _luminanceDifference(ZInk.solid(context), ZInk.reasoningPanel(context)),
      greaterThan(0.45),
    );
    expect(
      _luminanceDifference(ZInk.solid(context), ZInk.panel(context)),
      greaterThan(0.45),
    );
  });

  testWidgets('chip labels have explicit ink contrasting the fill', (tester) async {
    // A colorless chipTheme.labelStyle used to fall back to a white label at
    // paint time — invisible on the light chip fill. The label style must
    // carry an explicit color with real contrast against both fills.
    for (final (name, theme) in [
      ('light', buildLightTheme()),
      ('dark', buildDarkTheme()),
    ]) {
      late BuildContext context;
      await tester.pumpWidget(MaterialApp(
        theme: theme,
        home: Builder(builder: (value) {
          context = value;
          return const SizedBox();
        }),
      ));

      final label = Theme.of(context).chipTheme.labelStyle;
      expect(label?.color, isNotNull,
          reason: '$name chip labelStyle must set an explicit color');
      expect(
        _luminanceDifference(label!.color!, theme.chipTheme.backgroundColor!),
        greaterThan(0.25),
        reason: '$name chip label must contrast the unselected fill',
      );
      expect(
        _luminanceDifference(label.color!, theme.chipTheme.selectedColor!),
        greaterThan(0.1),
        reason: '$name chip label must contrast the selected fill',
      );
    }
  });
}
