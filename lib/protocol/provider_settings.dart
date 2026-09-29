import 'channel_client.dart';

/// Settings writes use personal overlays, never a replacement of the effective
/// provider (which also contains host-owned account configuration).
class ProviderSettingsClient {
  final ChannelClient channels;
  const ProviderSettingsClient(this.channels);

  Future<Map> getView({bool refresh = false}) async {
    final result = await channels.call(Channels.providerSettings,
        refresh ? 'refresh' : 'getView', refresh ? ['settings-manual'] : []);
    if (result is! Map || result['providers'] is! List) {
      throw const FormatException('Invalid provider-settings view');
    }
    return result;
  }

  Future<void> setEnabled(Map provider, bool enabled) async {
    final overlay =
        Map<String, dynamic>.from(provider['personalConfig'] as Map? ?? {});
    overlay.remove('builtinModelIds');
    overlay.remove('personalModelIds');
    await channels
        .call(Channels.providerSettings, 'savePersonalProviderOverlay', [
      provider['providerId'],
      overlay,
      {'enabled': enabled},
    ]);
  }

  Future<void> delete(String providerId) async {
    await channels.call(
        Channels.providerSettings, 'deletePersonalProvider', [providerId]);
  }

  Future<void> create(
      {required String name,
      required String baseUrl,
      required String apiType,
      required String apiKey,
      required List<String> models}) async {
    final created = await channels
        .call(Channels.providerSettings, 'createPersonalProvider', [
      {'providerName': name},
    ]);
    final id = created is Map ? created['providerId'] : null;
    if (id is! String || id.isEmpty)
      throw const FormatException('Missing providerId');
    try {
      await channels
          .call(Channels.providerSettings, 'savePersonalProviderOverlay', [
        id,
        {
          'api': {'type': apiType, 'baseUrl': baseUrl},
          'access': {'type': 'api-key', 'apiKey': apiKey}
        },
        {'enabled': true},
      ]);
      for (final model in models.toSet()) {
        await channels.call(Channels.providerSettings, 'addPersonalModel',
            [id, model, {}, true]);
      }
    } catch (_) {
      // Creation is multi-step, like the web settings editor. Keep the partial
      // provider visible so it can be inspected/deleted; do not retry creation.
      throw StateError('供应商已创建，但配置未完成，请刷新检查（$id）');
    }
  }
}
