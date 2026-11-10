// Unit tests for ConsoleService.suggestionsFor (terminal suggestions).
// No widgets, no device: works on a temp project directory.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pyrunner/models.dart';
import 'package:pyrunner/services/console_service.dart';
import 'package:pyrunner/services/project_service.dart';
import 'package:pyrunner/services/python_service.dart';

void main() {
  late Directory tmp;
  late ConsoleService console;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pyrunner-suggest-');
    await File('${tmp.path}/main.py').writeAsString('print(1)\n');
    await File('${tmp.path}/requirements.txt')
        .writeAsString('requests\n');
    await Directory('${tmp.path}/utils').create();
    await File('${tmp.path}/utils/helper.py').writeAsString('');
    console = ConsoleService(
      project: Project(name: 't', path: tmp.path),
      python: PythonService(),
      projects: ProjectService(),
    );
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('empty input gives no suggestions', () {
    expect(console.suggestionsFor(''), isEmpty);
  });

  test('commands are suggested by prefix', () {
    final inserts = console.suggestionsFor('py').map((s) => s.insert);
    expect(inserts, containsAll(['python', 'python -m']));
  });

  test('pip install -r requirements.txt is suggested', () {
    final inserts =
        console.suggestionsFor('pip install -r r').map((s) => s.insert);
    expect(inserts, contains('pip install -r requirements.txt'));
  });

  test('python file names are suggested from the project', () {
    final inserts =
        console.suggestionsFor('python m').map((s) => s.insert);
    expect(inserts, contains('python main.py'));
  });

  test('cd only suggests directories', () {
    final inserts = console.suggestionsFor('cd u').map((s) => s.insert);
    expect(inserts, contains('cd utils/'));
    expect(inserts.any((s) => s.contains('main.py')), isFalse);
  });

  test('history entries are suggested most recent first', () async {
    await console.execute('echo hello');
    await console.execute('echo world');
    final inserts =
        console.suggestionsFor('echo').map((s) => s.insert).toList();
    expect(inserts.first, 'echo world');
    expect(inserts, contains('echo hello'));
  });

  test('REPL exits cleanly on exit()', () async {
    await console.execute('python');
    expect(console.replMode, isTrue);
    await console.execute('exit()');
    expect(console.replMode, isFalse);
  });
}
