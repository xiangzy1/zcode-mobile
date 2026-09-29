import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zemote/protocol/automation_client.dart';
import 'package:zemote/protocol/channel_client.dart';
import 'package:zemote/protocol/conversation.dart';
import 'package:zemote/protocol/ipc_codec.dart';
import 'package:zemote/protocol/provider_settings.dart';
import 'package:zemote/protocol/zemote_client.dart';

const selected = ModelSelection('account:test', 'vendor/model', 'high');

Map<String, dynamic> viewFixture({int revision = 1}) => {
      'revision': revision,
      'preferredSelection': selected.toJson(),
      'effectiveSelection': selected.toJson(),
      'selectionIssue': null,
      'providers': [
        {
          'providerId': 'account:test',
          'providerName': 'Test',
          'models': [
            {
              'modelId': 'vendor/model',
              'config': {
                'optionSpecs': {
                  'reasoningLevel': {
                    'values': ['low', 'high']
                  }
                }
              }
            },
            {
              'modelId': 'other',
              'config': {
                'optionSpecs': {
                  'reasoningLevel': {
                    'values': ['medium', 'xhigh']
                  }
                }
              }
            },
          ]
        },
      ],
    };

class WireHarness {
  final calls = <({String channel, String method, List args})>[];
  final events = <String, int>{};
  late final ChannelClient channels;
  FutureOr<Object?> Function(String, List)? respond;

  WireHarness() {
    channels = ChannelClient(sendBody: (bytes) {
      final reader = ValueReader(bytes);
      final header = decodeValue(reader) as List;
      final args = decodeValue(reader);
      if (header[0] == ChannelClient.reqPromise) {
        final method = header[3] as String;
        calls.add((channel: header[2], method: method, args: args as List));
        Future.sync(() => respond?.call(method, args)).then((result) {
          final writer = ValueWriter();
          encodeValue(writer, [ChannelClient.resPromiseSuccess, header[1]]);
          encodeValue(writer, result);
          channels.handleMessage(writer.toBytes());
        });
      } else if (header[0] == ChannelClient.reqEventListen) {
        events[header[3]] = header[1];
      }
    });
    final writer = ValueWriter();
    encodeValue(writer, [ChannelClient.resInitialize, 0]);
    channels.handleMessage(writer.toBytes());
  }

  void event(String name, Object? value) {
    final writer = ValueWriter();
    encodeValue(writer, [ChannelClient.resEventFire, events[name]]);
    encodeValue(writer, value);
    channels.handleMessage(writer.toBytes());
  }
}

class TestBridge implements BridgeSession {
  @override
  final ChannelClient channels;
  @override
  final recovered = ValueNotifier<int>(0);
  @override
  final degraded = ValueNotifier<String?>(null);
  TestBridge(this.channels);
  ConversationTransport? _conversation;
  @override
  ConversationTransport conversation(Map<String, dynamic> scope,
          {void Function(String)? onLog}) =>
      _conversation ??=
          ConversationTransport(session: this, scope: scope, onLog: onLog);
  @override
  Future<void> waitHealthy(
      {Duration timeout = const Duration(seconds: 45)}) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('provider/model identity preserves slashes and model-specific levels',
      () {
    final view = ModelSelectionView(viewFixture());
    expect(ModelSelection.fromValue(selected.value, 'high')!.modelId,
        'vendor/model');
    expect(view.model('account:test/other')!.defaultSelection.reasoningLevel,
        'xhigh');
    expect(view.supports(const ModelSelection('account:test', 'other', 'high')),
        isFalse);
    expect(view.requireEffectiveSelection().toJson(), selected.toJson());
    final invalid = ModelSelectionView({
      ...viewFixture(),
      'selectionIssue': 'model-missing',
      'effectiveSelection': null
    });
    expect(invalid.requireEffectiveSelection, throwsStateError);
    final missing = ModelSelectionView({
      ...viewFixture(),
      'selectionIssue': 'selection-missing',
      'effectiveSelection': null
    });
    expect(missing.requireEffectiveSelection, throwsStateError);
  });

  test(
      'workspace catalog uses new services, deduplicates and invalidates on updates/recovery',
      () async {
    final wire = WireHarness();
    var revision = 1;
    wire.respond = (method, _) => method == 'getView'
        ? viewFixture(revision: revision)
        : {'mode': 'build', 'slashCommands': []};
    final bridge = TestBridge(wire.channels);
    final transport = ConversationTransport(
        session: bridge, scope: {'workspacePath': '/repo'});
    addTearDown(() {
      transport.dispose();
      bridge.recovered.dispose();
      wire.channels.dispose();
    });
    final preps = await Future.wait(
        [transport.prepareWorkspace(), transport.prepareWorkspace()]);
    expect(identical(preps[0], preps[1]), isTrue);
    expect(wire.calls.map((c) => '${c.channel}.${c.method}'),
        ['zcode-session.readWorkspacePresentation', 'model-selection.getView']);
    expect(preps.first.option('model')!.options, hasLength(2));
    expect(preps.first.option('thought_level')!.options.map((o) => o.value),
        ['low', 'high']);
    await transport.prepareWorkspace();
    expect(wire.calls, hasLength(2));
    revision = 2;
    wire.event('onDidChange', viewFixture(revision: revision));
    expect((await transport.prepareWorkspace()).modelView!.revision, 2);
    bridge.recovered.value++;
    await transport.prepareWorkspace();
    expect(wire.calls.where((c) => c.method == 'getView'), hasLength(3));
  });

  test('first input, normal sends and goals use structured modelSelection',
      () async {
    final wire = WireHarness();
    wire.respond = (method, _) => switch (method) {
          'helloConversationV4' => {'connectionId': 'connection'},
          'sendConversationCommandV4' => {
              'status': 'accepted',
              'result': {'sessionId': 'session'}
            },
          _ => null,
        };
    final bridge = TestBridge(wire.channels);
    final transport = ConversationTransport(
        session: bridge, scope: {'workspacePath': '/repo'});
    addTearDown(() {
      transport.dispose();
      bridge.recovered.dispose();
      wire.channels.dispose();
    });
    final config = {
      'modelSelection': selected.toJson(),
      'mode': 'edit',
      'planEnabled': true
    };
    await transport.createSession('/repo', firstText: 'hello', config: config);
    await transport.sendText('session', 'next', submissionConfig: config);
    await transport.sendGoalCommand('session', 'goal',
        submissionConfig: config);
    final hello = wire.calls
        .firstWhere((c) => c.method == 'initializeConversationV4')
        .args
        .single;
    expect(hello['clientKind'], 'web');
    expect(hello['appVersion'], 'unknown');
    final envelopes = wire.calls
        .where((c) => c.method == 'sendConversationCommandV4')
        .map((c) => c.args.single['envelope'] as Map)
        .toList();
    final first = envelopes.first['payload']['firstInput'];
    expect(first, {'text': 'hello', ...config});
    for (final envelope in envelopes.skip(1)) {
      expect(envelope['payload']['modelSelection'], selected.toJson());
      expect(envelope['payload']['planEnabled'], isTrue);
      expect(envelope['payload'].containsKey('thought'), isFalse);
    }
  });

  test('provider mutations preserve overlays and use positional web arguments',
      () async {
    final wire = WireHarness();
    wire.respond = (method, _) =>
        method == 'createPersonalProvider' ? {'providerId': 'personal'} : {};
    addTearDown(wire.channels.dispose);
    final client = ProviderSettingsClient(wire.channels);
    await client.setEnabled({
      'providerId': 'personal',
      'personalConfig': {
        'api': {
          'headers': {'x-test': 'value'}
        },
        'builtinModelIds': ['a'],
        'personalModelIds': ['b']
      }
    }, false);
    expect(wire.calls.single.args, [
      'personal',
      {
        'api': {
          'headers': {'x-test': 'value'}
        }
      },
      {'enabled': false}
    ]);
    await client.create(
        name: 'Test',
        baseUrl: 'https://example.com/v1',
        apiType: 'openai-responses',
        apiKey: 'test-only',
        models: ['vendor/model']);
    expect(wire.calls.last.args, ['personal', 'vendor/model', {}, true]);
    await client.delete('personal');
    expect(wire.calls.last.args, ['personal']);
    expect(wire.calls.every((c) => c.channel == 'provider-settings'), isTrue);
  });

  test('automations use modelSelection and host-wide listing', () async {
    final wire = WireHarness();
    wire.respond = (method, args) => method == 'listAllAutomations'
        ? []
        : {'automationId': 'test', ...args.first as Map};
    final bridge = TestBridge(wire.channels);
    addTearDown(() {
      bridge.recovered.dispose();
      wire.channels.dispose();
    });
    final client =
        AutomationClient(bridge: bridge, scope: {'workspacePath': '/repo'});
    await client.list();
    expect(wire.calls.single.args, isEmpty);
    final entry = await client.create(
        title: 'Test',
        prompt: 'Test',
        cronExpr: '0 * * * *',
        model: selected.modelId,
        provider: selected.providerId,
        mode: 'build',
        thoughtLevel: 'high',
        recurring: true,
        scheduleRule: {'unit': 'hour', 'interval': 1});
    final payload = wire.calls.last.args.single as Map;
    expect(payload['modelSelection'], selected.toJson());
    expect(payload.containsKey('thoughtLevel'), isFalse);
    expect(entry.model, 'vendor/model');
    expect(entry.thoughtLevel, 'high');
  });
}
