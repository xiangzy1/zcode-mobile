import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zemote/protocol/connection_params.dart';
import 'package:zemote/protocol/zemote_client.dart';

// Opt-in, read-only checks against the host behind a remote URL. Never prints
// credentials or provider configuration (which can contain API keys).
void main() {
  final path = Platform.environment['ZEMOTE_PROBE_URL_FILE'];
  test('current web protocol read-only host probe', () async {
    final params =
        ZemoteConnectionParams.parse(File(path!).readAsStringSync().trim())!;
    final client = ZemoteClient(params);
    addTearDown(client.dispose);
    await client.connect();
    await client.waitPaired(timeout: const Duration(seconds: 60));
    final bootstrap = await client.bootstrap();
    final workspaces = (bootstrap['workspaces'] as List).cast<Map>();
    final workspace = workspaces.firstWhere(
      (w) => '${w['workspacePath']}'.endsWith('/zemote'),
      orElse: () => workspaces.first,
    );
    final scope = <String, dynamic>{
      'workspacePath': workspace['workspacePath'],
      if (workspace['workspaceIdentity'] != null)
        'workspaceIdentity': workspace['workspaceIdentity'],
    };
    final bridge = await client
        .openBridge('${scope['workspaceIdentity'] ?? scope['workspacePath']}');
    final view = await bridge.channels.call('model-selection', 'getView', [
      {'selection': null}
    ]);
    expect(view, isA<Map>());
    expect(view['providers'], isA<List>());
    final transport = bridge.conversation(scope);
    final prep = await transport.prepareWorkspace(refresh: true);
    expect(prep.modelView!.models, isNotEmpty);
    for (final model in prep.modelView!.models) {
      final resolved =
          await transport.modelSelection(selection: model.defaultSelection);
      expect(resolved.requireEffectiveSelection().value, model.value);
    }
    // ignore: avoid_print
    print(
        'Verified ${prep.modelView!.models.length} models and their reasoning levels');
    final presentation = await bridge.channels
        .call('zcode-session', 'readWorkspacePresentation', [scope]);
    expect(presentation['slashCommands'], isA<List>());
    // ignore: avoid_print
    print(
        'presentation: keys=${presentation.keys}; mode=${presentation['mode']}');
    final settings =
        await bridge.channels.call('provider-settings', 'getView', []);
    expect(settings['providers'], isA<List>());
    final sessions = await transport.subscribeSessionsIndex();
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!sessions.state.ready && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(sessions.state.ready, isTrue);
      // ignore: avoid_print
      print('Verified web handshake and sessions-index snapshot');
    } finally {
      await sessions.dispose();
    }
  }, skip: path == null, timeout: const Timeout(Duration(minutes: 2)));
}
