import 'package:flutter_test/flutter_test.dart';
import 'package:zemote/ui/main_shell.dart';

void main() {
  test('sorts workspaces by latest task time, newest first', () {
    final a = {'workspacePath': '/repo/a'};
    final b = {'workspaceIdentity': 'ws-b', 'workspacePath': '/repo/b'};
    final c = {'workspacePath': '/repo/c'};
    final times = {'/repo/a': 100, 'ws-b': 300};
    expect(sortWorkspacesByTaskTime([c, a, b], times), [b, a, c]);
  });

  test('ties and workspaces without task data keep original order', () {
    final a = {'workspacePath': '/repo/a'};
    final b = {'workspacePath': '/repo/b'};
    final c = {'workspacePath': '/repo/c'};
    final times = {'/repo/a': 100, '/repo/b': 100};
    expect(sortWorkspacesByTaskTime([c, a, b], times), [a, b, c]);
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
    expect(latestTaskTimeOf(w, {'ws-b': 42}), 42);
  });
}
