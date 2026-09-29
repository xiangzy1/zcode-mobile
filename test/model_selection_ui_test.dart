import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zemote/ui/chat_page.dart';
import 'package:zemote/ui/theme.dart';

import 'web_protocol_contract_test.dart'
    show WireHarness, TestBridge, viewFixture;

void main() {
  testWidgets('model choice remains local and updates reasoning choices',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final wire = WireHarness();
    wire.respond = (method, args) => switch (method) {
          'getView' => viewFixture(),
          'readWorkspacePresentation' => {'mode': 'build', 'slashCommands': []},
          'list' => [],
          _ => null,
        };
    final bridge = TestBridge(wire.channels);
    final transport = bridge.conversation({'workspacePath': '/repo'});
    await tester.pumpWidget(MaterialApp(
        theme: buildLightTheme(),
        home: ChatPage(
          session: bridge,
          scope: const {'workspacePath': '/repo'},
          workspaceKey: '/repo',
          title: 'Test',
        )));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('模型 / 模式'));
    await tester.pumpAndSettle();
    expect(find.text('vendor/model'), findsOneWidget);
    expect(find.text('high'), findsOneWidget);
    await tester.tap(find.text('other'));
    await tester.pumpAndSettle();
    expect(find.text('high'), findsNothing);
    expect(find.text('xhigh'), findsOneWidget);
    expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'xhigh'))
            .selected,
        isTrue);
    await tester.tap(find.text('medium'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'medium'))
            .selected,
        isTrue);
    expect(wire.calls.any((c) => c.method == 'sendConversationCommandV4'),
        isFalse);
    // A host catalog event refreshes an already-open modal route too.
    wire.respond = (method, args) => switch (method) {
          'getView' => {...viewFixture(revision: 2), 'providers': []},
          'readWorkspacePresentation' => {'mode': 'build', 'slashCommands': []},
          _ => [],
        };
    wire.event('onDidChange', {'revision': 2});
    await tester.pumpAndSettle();
    expect(find.text('暂无可用模型，请在模型供应商中配置'), findsOneWidget);
    expect(find.text('当前模型或思考等级已不可用，请重新选择'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    transport.dispose();
    bridge.recovered.dispose();
    wire.channels.dispose();
  });
}
