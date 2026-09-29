import 'dart:async';

import 'package:flutter/material.dart';

import '../notifications/notifications.dart';
import '../notifications/task_notifier.dart';
import '../protocol/relay_client.dart';
import '../protocol/zemote_client.dart';
import '../state/account_store.dart';
import '../state/app_session.dart';
import 'chat_page.dart';
import 'settings_page.dart';
import 'task_home_page.dart';
import 'theme.dart';

/// Mirrors `HC()` in the web client:
/// key = workspaceIdentity?.trim() || workspacePath.
String? workspaceKeyOf(Map<String, dynamic> w) {
  final identity = w['workspaceIdentity'];
  if (identity is String && identity.trim().isNotEmpty) {
    return identity.trim();
  }
  final path = w['workspacePath'];
  if (path is String && path.isNotEmpty) return path;
  for (final key in const ['workspaceKey', 'key', 'id']) {
    final v = w[key];
    if (v is String && v.isNotEmpty) return v;
  }
  return null;
}

String workspaceTitle(Map<String, dynamic> w) {
  final label = w['label'] as String?;
  if (label != null && label.isNotEmpty) return label;
  final path = w['workspacePath'] as String?;
  if (path != null && path.isNotEmpty) {
    final parts = path.split(RegExp(r'[\\/]'));
    return parts.lastWhere((p) => p.isNotEmpty, orElse: () => path);
  }
  final identity = w['workspaceIdentity'] as String?;
  if (identity != null && identity.isNotEmpty) return identity;
  return workspaceKeyOf(w) ?? '未知工作区';
}

/// Aggregated task activity per workspace, derived from the global task
/// lists (bootstrap / workspace-list-updated). Drives picker ordering and
/// the running/unread markers.
class WorkspaceActivity {
  int lastTaskAt = 0;
  int runningCount = 0;
  int unreadCount = 0;
}

/// Task workspace key: trimmed `workspaceIdentity` or `workspacePath` — the
/// same rule as [workspaceKeyOf]'s primary branches.
String? workspaceKeyOfTask(Map<dynamic, dynamic> t) {
  final identity = t['workspaceIdentity'];
  if (identity is String && identity.trim().isNotEmpty) return identity.trim();
  final path = t['workspacePath'];
  if (path is String && path.isNotEmpty) return path;
  return null;
}

Map<String, WorkspaceActivity> summarizeWorkspaceActivity(
    Iterable<dynamic> tasks) {
  final out = <String, WorkspaceActivity>{};
  for (final t in tasks) {
    if (t is! Map) continue;
    final key = workspaceKeyOfTask(t);
    if (key == null) continue;
    final activity = out.putIfAbsent(key, WorkspaceActivity.new);
    final updatedAt = t['updatedAt'];
    if (updatedAt is num && updatedAt > activity.lastTaskAt) {
      activity.lastTaskAt = updatedAt.toInt();
    }
    final status = '${t['displayStatus'] ?? t['status'] ?? ''}';
    if (status == 'running' || status == 'prewarming') activity.runningCount++;
    if (t['unreadAt'] != null) activity.unreadCount++;
  }
  return out;
}

int latestTaskTimeOf(
    Map<String, dynamic> w, Map<String, WorkspaceActivity> activityByKey) {
  final identity = w['workspaceIdentity'];
  if (identity is String && identity.trim().isNotEmpty) {
    return activityByKey[identity.trim()]?.lastTaskAt ?? 0;
  }
  final path = w['workspacePath'];
  if (path is String && path.isNotEmpty) {
    return activityByKey[path]?.lastTaskAt ?? 0;
  }
  return activityByKey[workspaceKeyOf(w)]?.lastTaskAt ?? 0;
}

/// Merges a (possibly partial) global task push into [current], keyed by
/// taskId; archived/deleted tasks drop out.
Map<String, Map<String, dynamic>> mergeGlobalTasks(
  Map<String, Map<String, dynamic>> current,
  List<dynamic> tasks,
) {
  final next = Map<String, Map<String, dynamic>>.of(current);
  for (final t in tasks) {
    if (t is! Map) continue;
    final id = '${t['taskId'] ?? ''}';
    if (id.isEmpty) continue;
    if (t['archived'] == true || t['deleted'] == true) {
      next.remove(id);
      continue;
    }
    next[id] = {...?next[id], ...t.cast<String, dynamic>()};
  }
  return next;
}

/// Authoritative full snapshot (bootstrap / workspace-list response):
/// replaces the store wholesale. Cleared fields (e.g. `unreadAt` dropped
/// after mark-read) must not linger from earlier partial merges.
Map<String, Map<String, dynamic>> replaceGlobalTasks(List<dynamic> tasks) {
  final next = <String, Map<String, dynamic>>{};
  for (final t in tasks) {
    if (t is! Map) continue;
    final id = '${t['taskId'] ?? ''}';
    if (id.isEmpty) continue;
    if (t['archived'] == true || t['deleted'] == true) continue;
    next[id] = t.cast<String, dynamic>();
  }
  return next;
}

/// Picker order: workspaces with newer task activity first. Ties (and
/// workspaces without task data) keep the desktop's original relative order
/// via the stable index sort.
List<Map<String, dynamic>> sortWorkspacesByTaskTime(
  List<dynamic> workspaces,
  Map<String, WorkspaceActivity> activityByKey,
) {
  final maps = [
    for (final w in workspaces)
      if (w is Map) w.cast<String, dynamic>(),
  ];
  final order = List<int>.generate(maps.length, (i) => i);
  order.sort((a, b) {
    final byTime = latestTaskTimeOf(maps[b], activityByKey)
        .compareTo(latestTaskTimeOf(maps[a], activityByKey));
    return byTime != 0 ? byTime : a.compareTo(b);
  });
  return [for (final i in order) maps[i]];
}

/// Multi-device shell: driven by [AppSession]. Shows the active device's
/// workspace/tasks/settings, with a device switcher to jump between
/// simultaneously-connected devices without reconnecting.
class MainShell extends StatefulWidget {
  final AppSession session;
  final AccountStore store;
  final VoidCallback onDisconnect;
  final VoidCallback onAddDevice;

  const MainShell({
    super.key,
    required this.session,
    required this.store,
    required this.onDisconnect,
    required this.onAddDevice,
  });

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onChanged);
    widget.store.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.session.removeListener(_onChanged);
    widget.store.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final client = widget.session.client;
    final account = widget.session.current;
    if (client == null || account == null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.link_off, size: 48, color: ZInk.ghost(context)),
              const SizedBox(height: 12),
              Text('当前设备已断开连接', style: TextStyle(color: ZInk.muted(context))),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: widget.onDisconnect,
                icon: const Icon(Icons.arrow_back),
                label: const Text('返回设备列表'),
              ),
            ],
          ),
        ),
      );
    }
    return _MainShellContent(
      key: ValueKey(account.id),
      client: client,
      account: account,
      session: widget.session,
      store: widget.store,
      onDisconnect: widget.onDisconnect,
      onAddDevice: widget.onAddDevice,
    );
  }
}

class _MainShellContent extends StatefulWidget {
  final ZemoteClient client;
  final Account account;
  final AppSession session;
  final AccountStore store;
  final VoidCallback onDisconnect;
  final VoidCallback onAddDevice;

  const _MainShellContent({
    super.key,
    required this.client,
    required this.account,
    required this.session,
    required this.store,
    required this.onDisconnect,
    required this.onAddDevice,
  });

  @override
  State<_MainShellContent> createState() => _MainShellContentState();
}

class _MainShellContentState extends State<_MainShellContent> {
  int _tab = 0;
  List<dynamic> _workspaces = const [];

  /// Global task summaries (keyed by taskId): merged from pushes, replaced
  /// wholesale by full snapshots (bootstrap / workspace-list refresh).
  Map<String, Map<String, dynamic>> _globalTasks = {};
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _activeWorkspace;
  BridgeSession? _bridge;
  bool _bridgeOpening = false;
  StreamSubscription? _updatedSub;
  TaskNotifier? _taskNotifier;
  AppLifecycleListener? _lifecycle;
  double _lastScrollOffset = 0;
  bool _navHidden = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: widget.client.pokeRelay);
    _updatedSub = widget.client.workspaceListUpdated.listen((result) {
      if (!mounted || result is! Map) return;
      final list = result['workspaces'];
      final tasks = result['tasks'];
      setState(() {
        if (list is List) _workspaces = list;
        if (tasks is List) _globalTasks = mergeGlobalTasks(_globalTasks, tasks);
      });
    });
    _load();
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _updatedSub?.cancel();
    _taskNotifier?.dispose();
    _bridge?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final bootstrap = await widget.client.bootstrap();
      if (!mounted) return;
      final list = bootstrap['workspaces'];
      final tasks = bootstrap['tasks'];
      setState(() {
        _workspaces = list is List ? list : const [];
        if (tasks is List) _globalTasks = replaceGlobalTasks(tasks);
        _loading = false;
      });
      // Auto-open single workspace (web mobile flow).
      if (_workspaces.length == 1 && _activeWorkspace == null) {
        final only = _workspaces.first;
        if (only is Map) {
          await _openWorkspace(only.cast<String, dynamic>());
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// Refreshes the authoritative global task snapshot. Runs when the picker
  /// becomes visible again: read/unread changes made inside a workspace
  /// (mark-read etc.) may not arrive as a workspace-list push, so returning
  /// to the list must re-fetch instead of trusting merged push state.
  Future<void> _refreshGlobalTasks() async {
    try {
      final result = await widget.client.listWorkspaces();
      if (!mounted || result is! Map) return;
      final list = result['workspaces'];
      final tasks = result['tasks'];
      setState(() {
        if (list is List) _workspaces = list;
        if (tasks is List) _globalTasks = replaceGlobalTasks(tasks);
      });
    } catch (_) {
      // Best effort: stale badges persist until the next refresh.
    }
  }

  Future<void> _openWorkspace(Map<String, dynamic> workspace) async {
    final key = workspaceKeyOf(workspace);
    if (key == null || _bridgeOpening) return;
    setState(() => _bridgeOpening = true);
    try {
      final session = await widget.client.openBridge(key);
      if (!mounted) {
        session.dispose();
        return;
      }
      setState(() {
        _bridge?.dispose();
        _taskNotifier?.dispose();
        _taskNotifier = null;
        _bridge = session;
        _activeWorkspace = workspace;
        _bridgeOpening = false;
      });
      _startTaskNotifier(session, workspace);
    } catch (e) {
      if (!mounted) return;
      setState(() => _bridgeOpening = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('打开工作区失败: $e')));
    }
  }

  /// Background task notifications: while tasks are running, a silent
  /// foreground-service notification shows live progress and completion
  /// alerts route back into the task's chat (Android only).
  void _startTaskNotifier(
      BridgeSession bridge, Map<String, dynamic> workspace) {
    if (!Notifications.isSupported || _taskNotifier != null) return;
    final scope = <String, dynamic>{
      'workspacePath': workspace['workspacePath'],
      if (workspace['workspaceIdentity'] != null)
        'workspaceIdentity': workspace['workspaceIdentity'],
    };
    final workspaceKey = workspaceKeyOf(workspace) ?? '';
    _taskNotifier = TaskNotifier(
      bridge: bridge,
      scope: scope,
      notifications: notificationsService,
      onOpenTask: (taskId, title) async {
        final navigator = Navigator.of(context);
        navigator.push(
          MaterialPageRoute(
            builder: (_) => ChatPage(
              session: bridge,
              scope: scope,
              workspaceKey: workspaceKey,
              sessionId: taskId,
              title: title,
            ),
          ),
        );
      },
    )..start();
  }

  void _closeBridge() {
    setState(() {
      _bridge?.dispose();
      _taskNotifier?.dispose();
      _taskNotifier = null;
      _bridge = null;
      _activeWorkspace = null;
    });
    // The picker is visible again — re-fetch task state so running/unread
    // markers reflect what happened inside the workspace.
    _refreshGlobalTasks();
  }

  void _showDeviceSwitcher() {
    showModalBottomSheet(
      context: context,
      builder: (context) => _DeviceSwitchSheet(
        session: widget.session,
        store: widget.store,
        onAddDevice: widget.onAddDevice,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bridge = _bridge;
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final body = PopScope(
      // Predictable back behavior instead of silently exiting:
      // settings tab -> tasks tab -> workspace picker -> confirm exit.
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_tab != 0) {
          setState(() => _tab = 0);
          return;
        }
        if (_bridge != null) {
          _closeBridge();
          return;
        }
        _confirmExit();
      },
      child: SafeArea(
        child: wide
            ? _wideLayout(bridge)
            : Column(
                children: [
                  _DeviceSwitcherBar(
                    account: widget.account,
                    onTap: _showDeviceSwitcher,
                  ),
                  _ConnectionBanner(client: widget.client),
                  Expanded(child: _content(bridge)),
                ],
              ),
      ),
    );
    if (wide) {
      return Scaffold(body: body);
    }
    return Scaffold(
      body: body,
      bottomNavigationBar: AnimatedSlide(
        offset: _navHidden ? const Offset(0, 1.2) : Offset.zero,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        child: _phoneNav(),
      ),
    );
  }

  /// Tablet layout: a persistent NavigationRail on the left, content on the
  /// right. Keeps the device switcher + connection banner above the content.
  Widget _wideLayout(BridgeSession? bridge) {
    return Row(
      children: [
        NavigationRail(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          labelType: NavigationRailLabelType.all,
          destinations: const [
            NavigationRailDestination(
              icon: Icon(Icons.forum_outlined),
              selectedIcon: Icon(Icons.forum),
              label: Text('任务'),
            ),
            NavigationRailDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: Text('设置'),
            ),
          ],
        ),
        const VerticalDivider(width: 1, thickness: 1),
        Expanded(
          child: Column(
            children: [
              _DeviceSwitcherBar(
                account: widget.account,
                onTap: _showDeviceSwitcher,
              ),
              _ConnectionBanner(client: widget.client),
              Expanded(child: _content(bridge)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _phoneNav() {
    return NavigationBar(
      selectedIndex: _tab,
      onDestinationSelected: (i) => setState(() => _tab = i),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.forum_outlined),
          selectedIcon: Icon(Icons.forum),
          label: '任务',
        ),
        NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings),
          label: '设置',
        ),
      ],
    );
  }

  Widget _content(BridgeSession? bridge) {
    final activity = summarizeWorkspaceActivity(_globalTasks.values);
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: switch (_tab) {
        0 => bridge == null
            ? _WorkspacePicker(
                workspaces: _workspaces,
                activityByKey: activity,
                loading: _loading || _bridgeOpening,
                error: _error,
                client: widget.client,
                onRefresh: _load,
                onOpen: _openWorkspace,
              )
            : TaskHomePage(
                key: ValueKey(workspaceKeyOf(_activeWorkspace ?? const {})),
                workspace: _activeWorkspace!,
                session: bridge,
                client: widget.client,
                workspaces: _workspaces,
                onSwitchWorkspace: _closeBridge,
              ),
        _ => SettingsPage(
            client: widget.client,
            bridge: bridge,
            onDisconnect: () {
              widget.session.disconnect(widget.account.id);
              widget.onDisconnect();
            },
            themeController: ThemeControllerProvider.of(context),
          ),
      },
    );
  }

  /// Hides the bottom nav while scrolling down the content, shows it again
  /// when scrolling up (mirrors common app behavior, issue #6).
  bool _onScroll(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    // Tablet layout uses a persistent NavigationRail, no bottom nav to hide.
    if (MediaQuery.sizeOf(context).width >= 720) return false;
    final delta = notification.metrics.pixels - _lastScrollOffset;
    _lastScrollOffset = notification.metrics.pixels;
    if (delta.abs() < 4) return false;
    final hide = delta > 0;
    if (hide != _navHidden) {
      setState(() => _navHidden = hide);
    }
    return false;
  }

  Future<void> _confirmExit() async {
    final exit = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('返回设备列表？'),
        content: const Text('连接会保持，稍后可直接回到当前设备'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('留在这里')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('返回')),
        ],
      ),
    );
    if (exit == true && mounted) {
      Navigator.of(context).pop();
    }
  }
}

/// Compact top bar showing the active device with a switcher entry.
class _DeviceSwitcherBar extends StatelessWidget {
  final Account account;
  final VoidCallback onTap;

  const _DeviceSwitcherBar({required this.account, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final host = account.params?.source.host ?? '';
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.desktop_windows_outlined,
                  size: 16, color: ZColors.primary),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  account.label,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (host.isNotEmpty) ...[
                const SizedBox(width: 4),
                Text(
                  host,
                  style: TextStyle(fontSize: 11, color: ZInk.faint(context)),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const Spacer(),
              Text('切换设备',
                  style: TextStyle(fontSize: 12, color: ZInk.muted(context))),
              Icon(Icons.swap_horiz, size: 16, color: ZInk.muted(context)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet: list all devices with per-device connect state; tap to
/// switch (or connect first). Non-active connected devices can be
/// disconnected individually.
class _DeviceSwitchSheet extends StatelessWidget {
  final AppSession session;
  final AccountStore store;
  final VoidCallback onAddDevice;

  const _DeviceSwitchSheet({
    required this.session,
    required this.store,
    required this.onAddDevice,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: AnimatedBuilder(
        animation: Listenable.merge([session, store]),
        builder: (context, _) {
          final accounts = store.accounts;
          final activeId = session.current?.id;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('设备列表',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ),
              ),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: accounts.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, indent: 16),
                  itemBuilder: (context, index) {
                    final account = accounts[index];
                    final isActive = account.id == activeId;
                    final connected = session.isConnected(account.id);
                    final connecting = session.connecting(account.id);
                    final error = session.errorOf(account.id);
                    return ListTile(
                      leading: Icon(
                        isActive
                            ? Icons.desktop_windows
                            : Icons.desktop_windows_outlined,
                        color: isActive ? ZColors.primary : ZInk.faint(context),
                      ),
                      title: Text(account.label,
                          style: TextStyle(
                              fontWeight: isActive
                                  ? FontWeight.w700
                                  : FontWeight.w400)),
                      subtitle: Text(
                        connecting
                            ? '正在连接…'
                            : error != null
                                ? '连接失败: $error'
                                : connected
                                    ? '已连接'
                                    : '未连接',
                        style: TextStyle(
                          fontSize: 11,
                          color: connecting
                              ? ZColors.warning
                              : error != null
                                  ? ZColors.danger
                                  : connected
                                      ? Colors.green
                                      : ZInk.faint(context),
                        ),
                      ),
                      trailing: isActive
                          ? const Icon(Icons.check_circle,
                              size: 18, color: ZColors.primary)
                          : connected
                              ? IconButton(
                                  icon: Icon(Icons.link_off,
                                      size: 18, color: ZInk.faint(context)),
                                  tooltip: '断开该设备',
                                  onPressed: () =>
                                      session.disconnect(account.id),
                                )
                              : connecting
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : null,
                      onTap: () async {
                        if (isActive) {
                          Navigator.pop(context);
                          return;
                        }
                        try {
                          await session.switchTo(account);
                          if (context.mounted) Navigator.pop(context);
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('连接失败: $e')));
                          }
                        }
                      },
                    );
                  },
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.add, color: ZColors.primary),
                title: const Text('添加设备'),
                onTap: () {
                  Navigator.pop(context);
                  onAddDevice();
                },
              ),
              const SizedBox(height: 8),
            ],
          );
        },
      ),
    );
  }
}

class _WorkspacePicker extends StatelessWidget {
  final List<dynamic> workspaces;
  final Map<String, WorkspaceActivity> activityByKey;
  final bool loading;
  final String? error;
  final ZemoteClient client;
  final Future<void> Function() onRefresh;
  final Future<void> Function(Map<String, dynamic>) onOpen;

  const _WorkspacePicker({
    required this.workspaces,
    required this.activityByKey,
    required this.loading,
    required this.error,
    required this.client,
    required this.onRefresh,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    // Non-map entries are dropped by the sort helper, so the list length
    // and the item count stay consistent.
    final ordered = sortWorkspacesByTaskTime(workspaces, activityByKey);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
          child: Row(
            children: [
              const Expanded(
                child: Text('选择工作区',
                    style:
                        TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
              ),
              _ConnectionDot(client: client),
              IconButton(icon: const Icon(Icons.refresh), onPressed: onRefresh),
            ],
          ),
        ),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : error != null
                  ? Center(child: Text('加载失败: $error'))
                  : ordered.isEmpty
                      ? Center(
                          child: Text('桌面端没有打开的工作区',
                              style: TextStyle(color: ZInk.faint(context))))
                      : ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: ordered.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            final workspace = ordered[index];
                            final key = workspaceKeyOf(workspace);
                            final activity =
                                key == null ? null : activityByKey[key];
                            final kind = '${workspace['kind'] ?? ''}';
                            return Card(
                              child: InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: key == null
                                    ? null
                                    : () => onOpen(workspace),
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 40,
                                        height: 40,
                                        decoration: BoxDecoration(
                                          color: ZColors.primary
                                              .withValues(alpha: 0.15),
                                          borderRadius:
                                              BorderRadius.circular(10),
                                        ),
                                        child: const Icon(Icons.folder_outlined,
                                            color: ZColors.primary, size: 20),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              workspaceTitle(workspace),
                                              style: const TextStyle(
                                                  fontSize: 15,
                                                  fontWeight: FontWeight.w600),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              [
                                                if (kind.isNotEmpty) kind,
                                                '${workspace['workspacePath'] ?? ''}',
                                              ].join(' · '),
                                              style: TextStyle(
                                                  fontSize: 11,
                                                  color: ZInk.faint(context)),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (activity != null) ...[
                                        if (activity.runningCount > 0) ...[
                                          const SizedBox(width: 8),
                                          _WorkspaceMarker(
                                            icon: Icons.sync,
                                            label:
                                                '${activity.runningCount} 运行中',
                                            color: ZColors.running,
                                          ),
                                        ],
                                        if (activity.unreadCount > 0) ...[
                                          const SizedBox(width: 8),
                                          _WorkspaceMarker(
                                            label: '${activity.unreadCount} 未读',
                                            color: ZColors.warning,
                                          ),
                                        ],
                                      ],
                                      Icon(Icons.chevron_right,
                                          color: ZInk.ghost(context)),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
        ),
      ],
    );
  }
}

/// Running/unread pill on a workspace card (same visual language as the
/// task-list status pill).
class _WorkspaceMarker extends StatelessWidget {
  final IconData? icon;
  final String label;
  final Color color;

  const _WorkspaceMarker({this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 10, color: color),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(
                fontSize: 10, color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _ConnectionBanner extends StatelessWidget {
  final ZemoteClient client;

  const _ConnectionBanner({required this.client});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<RelayState>(
      valueListenable: client.relay.stateListenable,
      builder: (context, state, _) {
        final (color, icon, text) = switch (state) {
          RelayState.reconnecting => (
              ZColors.warning,
              Icons.sync,
              '连接中断，正在自动重连…'
            ),
          RelayState.error => (
              ZColors.danger,
              Icons.error_outline,
              '连接失败，请返回设备页重连'
            ),
          RelayState.kicked => (
              ZColors.danger,
              Icons.error_outline,
              '连接已被其他终端挤下线'
            ),
          RelayState.waiting => (
              ZColors.running,
              Icons.hourglass_top,
              '等待桌面端确认配对…'
            ),
          _ => (Colors.transparent, Icons.check, ''),
        };
        if (text.isEmpty) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          color: color.withValues(alpha: 0.15),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(text, style: TextStyle(fontSize: 12, color: color)),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ConnectionDot extends StatelessWidget {
  final ZemoteClient client;

  const _ConnectionDot({required this.client});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<RelayState>(
      valueListenable: client.relay.stateListenable,
      builder: (context, state, _) {
        final (color, text) = switch (state) {
          RelayState.paired => (ZColors.success, '已连接'),
          RelayState.reconnecting => (ZColors.warning, '重连中'),
          RelayState.error || RelayState.kicked => (ZColors.danger, '异常'),
          _ => (ZColors.running, '连接中'),
        };
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(text, style: TextStyle(fontSize: 11, color: color)),
            ],
          ),
        );
      },
    );
  }
}
