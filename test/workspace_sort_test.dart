import 'package:flutter_test/flutter_test.dart';
import 'package:zemote/ui/main_shell.dart';

WorkspaceActivity activity(
        {int lastTaskAt = 0, int runningCount = 0, int unreadCount = 0}) =>
    WorkspaceActivity()
      ..lastTaskAt = lastTaskAt
      ..runningCount = runningCount
      ..unreadCount = unreadCount;

void main() {
  test('sorts workspaces by latest task time, newest first', () {
    final a = {'workspacePath': '/repo/a'};
    final b = {'workspaceIdentity': 'ws-b', 'workspacePath': '/repo/b'};
    final c = {'workspacePath': '/repo/c'};
    final activityByKey = {
      '/repo/a': activity(lastTaskAt: 100),
      'ws-b': activity(lastTaskAt: 300),
    };
    expect(sortWorkspacesByTaskTime([c, a, b], activityByKey), [b, a, c]);
  });

  test('ties and workspaces without task data keep original order', () {
    final a = {'workspacePath': '/repo/a'};
    final b = {'workspacePath': '/repo/b'};
    final c = {'workspacePath': '/repo/c'};
    final activityByKey = {
      '/repo/a': activity(lastTaskAt: 100),
      '/repo/b': activity(lastTaskAt: 100),
    };
    expect(sortWorkspacesByTaskTime([c, a, b], activityByKey), [a, b, c]);
  });

  test('drops non-map entries', () {
    final sorted = sortWorkspacesByTaskTime([
      'junk',
      {'workspacePath': '/repo/a'},
    ], const {});
    expect(sorted, [
      {'workspacePath': '/repo/a'},
    ]);
  });

  test('workspaceIdentity trims before lookup', () {
    final w = {'workspaceIdentity': ' ws-b ', 'workspacePath': '/repo/b'};
    expect(latestTaskTimeOf(w, {'ws-b': activity(lastTaskAt: 42)}), 42);
  });

  test('summarizeWorkspaceActivity aggregates running/unread per workspace',
      () {
    final summary = summarizeWorkspaceActivity([
      {
        'taskId': '1',
        'workspacePath': '/w1',
        'updatedAt': 5,
        'displayStatus': 'running',
      },
      {'taskId': '2', 'workspacePath': '/w1', 'updatedAt': 7, 'unreadAt': 9},
      {'taskId': '3', 'workspaceIdentity': 'w2', 'displayStatus': 'prewarming'},
      {'taskId': '4', 'workspacePath': '/w1', 'displayStatus': 'completed'},
      'junk',
      {'workspaceIdentity': '   '},
    ]);
    expect(summary.length, 2);
    expect(summary['/w1']!.lastTaskAt, 7);
    expect(summary['/w1']!.runningCount, 1);
    expect(summary['/w1']!.unreadCount, 1);
    expect(summary['w2']!.runningCount, 1);
  });

  test('replaceGlobalTasks drops stale fields absent from the snapshot', () {
    var store = replaceGlobalTasks([
      {'taskId': '1', 'workspacePath': '/w1'},
    ]);
    store = mergeGlobalTasks(store, [
      {'taskId': '1', 'unreadAt': 9},
    ]);
    expect(store['1']!['unreadAt'], 9);
    // A fresh snapshot without unreadAt (task was read) must clear it.
    store = replaceGlobalTasks([
      {'taskId': '1', 'workspacePath': '/w1'},
    ]);
    expect(store['1']!.containsKey('unreadAt'), isFalse);
  });

  test('mergeGlobalTasks removes archived tasks and merges partial fields', () {
    final current = {
      '1': <String, dynamic>{'taskId': '1', 'workspacePath': '/w1'},
      '2': <String, dynamic>{'taskId': '2', 'workspacePath': '/w2'},
    };
    final merged = mergeGlobalTasks(current, [
      {'taskId': '1', 'archived': true},
      {'taskId': '2', 'displayStatus': 'running'},
    ]);
    expect(merged.containsKey('1'), isFalse);
    expect(merged['2']!['displayStatus'], 'running');
    expect(merged['2']!['workspacePath'], '/w2');
  });
}
