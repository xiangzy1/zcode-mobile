import 'package:flutter/material.dart';

import '../protocol/provider_settings.dart';
import '../protocol/zemote_client.dart';
import 'theme.dart';

/// Provider settings from the current host registry.
class ModelProvidersPage extends StatefulWidget {
  final BridgeSession session;

  const ModelProvidersPage({super.key, required this.session});

  @override
  State<ModelProvidersPage> createState() => _ModelProvidersPageState();
}

class _ModelProvidersPageState extends State<ModelProvidersPage> {
  List<Map<String, dynamic>> _providers = const [];
  bool _loading = true;
  String? _error;
  void Function()? _cancelChanges;
  ProviderSettingsClient get _client =>
      ProviderSettingsClient(widget.session.channels);

  @override
  void initState() {
    super.initState();
    _listen();
    widget.session.recovered.addListener(_recovered);
    _load();
  }

  void _listen() {
    _cancelChanges = widget.session.channels
        .addEventListener('provider-settings', 'onDidChange', (_) => _load());
  }

  void _recovered() {
    _cancelChanges?.call();
    _listen();
    _load();
  }

  @override
  void dispose() {
    _cancelChanges?.call();
    widget.session.recovered.removeListener(_recovered);
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final view = await _client.getView();
      final res = view['providers'];
      if (mounted) {
        setState(() {
          _providers = res is List
              ? res
                  .whereType<Map>()
                  .map((e) => e.cast<String, dynamic>())
                  .toList()
              : const [];
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _toggle(Map<String, dynamic> provider, bool enabled) async {
    try {
      await _client.setEnabled(provider, enabled);
      await _load();
    } catch (e) {
      _toast('切换失败: $e');
    }
  }

  Future<void> _delete(Map<String, dynamic> provider) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除模型供应商？'),
        content: Text('将删除「${provider['providerName']}」'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: ZColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _client.delete(provider['providerId'] as String);
    } catch (e) {
      _toast('删除失败: $e');
      return;
    }
    await _load();
  }

  void _toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _showAddSheet() async {
    final added = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const _AddProviderSheet(),
    );
    if (added == null) return;
    try {
      await _client.create(
          name: added['name'],
          baseUrl: added['baseUrl'],
          apiType: added['apiType'],
          apiKey: added['apiKey'],
          models: List<String>.from(added['models']));
      await _load();
      _toast('已添加供应商');
    } catch (e) {
      _toast('添加失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('模型供应商'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddSheet,
        icon: const Icon(Icons.add),
        label: const Text('添加'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('加载失败: $_error'))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: _providers.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final p = _providers[index];
                      final enabled = p['enabled'] == true;
                      final endpoints = p['effectiveConfig']?['api'];
                      final baseUrl = endpoints is Map
                          ? '${endpoints['baseUrl'] ?? ''}'
                          : '';
                      final models =
                          p['models'] is List ? p['models'] as List : [];
                      final disabledReason =
                          p['systemDisabledReason'] as String?;
                      return Card(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${p['providerName'] ?? p['providerId']}',
                                      style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      [
                                        '${p['effectiveConfig']?['api']?['type'] ?? ''}',
                                        if (models.isNotEmpty)
                                          '${models.length} 个模型',
                                        baseUrl,
                                        if (!enabled && disabledReason != null)
                                          '停用: $disabledReason',
                                      ].where((s) => s.isNotEmpty).join(' · '),
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: ZInk.faint(context)),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              Switch(
                                value: enabled,
                                onChanged: p['effectiveConfig']?['access']
                                            ?['type'] ==
                                        'zhipu-account'
                                    ? null
                                    : (v) => _toggle(p, v),
                              ),
                              IconButton(
                                icon: Icon(Icons.delete_outline,
                                    size: 18, color: ZInk.faint(context)),
                                onPressed: p['effectiveConfig']?['group'] ==
                                        'standard-personal'
                                    ? () => _delete(p)
                                    : null,
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}

class _AddProviderSheet extends StatefulWidget {
  const _AddProviderSheet();

  @override
  State<_AddProviderSheet> createState() => _AddProviderSheetState();
}

class _AddProviderSheetState extends State<_AddProviderSheet> {
  final _nameController = TextEditingController();
  final _baseUrlController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _modelsController = TextEditingController();
  String _apiFormat = 'anthropic-messages';

  static const _formats = [
    'anthropic-messages',
    'openai-chat-completions',
    'openai-responses',
  ];

  @override
  void dispose() {
    _nameController.dispose();
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _modelsController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim();
    final baseUrl = _baseUrlController.text.trim();
    if (name.isEmpty || baseUrl.isEmpty) return;
    final modelIds = _modelsController.text
        .split(RegExp(r'[,\n]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    Navigator.pop(context, {
      'name': name,
      'baseUrl': baseUrl,
      'apiType': _apiFormat,
      'apiKey': _apiKeyController.text.trim(),
      'models': modelIds,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 20, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('添加模型供应商',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
                labelText: '名称', hintText: '例如 My Provider'),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _apiFormat,
            decoration: const InputDecoration(labelText: 'API 格式'),
            items: [
              for (final f in _formats)
                DropdownMenuItem(value: f, child: Text(f)),
            ],
            onChanged: (v) => setState(() => _apiFormat = v ?? _apiFormat),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _baseUrlController,
            decoration: const InputDecoration(
                labelText: 'Base URL',
                hintText: 'https://api.example.com/api/anthropic'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _apiKeyController,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'API Key（可选）'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _modelsController,
            maxLines: 2,
            decoration: const InputDecoration(
                labelText: '模型 ID（逗号分隔）', hintText: 'GLM-5.2, GLM-5-Turbo'),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _submit,
              child: const Text('保存'),
            ),
          ),
        ],
      ),
    );
  }
}
