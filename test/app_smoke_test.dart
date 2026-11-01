// End-to-end smoke tests: real server.py + real UI on a phone-sized screen.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:termux_ide/api.dart';
import 'package:termux_ide/extensions.dart';
import 'package:termux_ide/git.dart';
import 'package:termux_ide/ide_page.dart';
import 'package:termux_ide/main.dart';
import 'package:termux_ide/projects_page.dart';
import 'package:termux_ide/settings.dart';

const token = 'test-token-0123456789abcdef';
const port = 8791;

late Process server;
late Directory home;

Future<void> settle(WidgetTester t, bool Function() done, {int tries = 80}) async {
  for (var i = 0; i < tries && !done(); i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pump();
  }
}

void phone(WidgetTester t) {
  t.view.physicalSize = const Size(1080, 2340);
  t.view.devicePixelRatio = 2.625;
  addTearDown(t.view.reset);
}

void mockNative({bool termux = true}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('termux_ide/native'),
    (call) async => switch (call.method) {
      'filesDir' => home.path,
      'isTermuxInstalled' => termux,
      'hasPermission' || 'ensurePermission' => true,
      _ => null,
    },
  );
}

void main() {
  setUpAll(() async {
    HttpOverrides.global = null; // allow real sockets to the test server
    home = await Directory.systemTemp.createTemp('tide');
    final proj = Directory('${home.path}/projects/hello')..createSync(recursive: true);
    File('${proj.path}/main.sh').writeAsStringSync('echo "hello from termux ide"\n');
    server = await Process.start('python3', ['assets/termux/server.py', token, '$port'],
        environment: {...Platform.environment, 'HOME': home.path});
    server.stdout.listen((d) => stdout.add(d));
    server.stderr.listen((d) => stderr.add(d));
    final api = Api(token, port: port);
    for (var i = 0; i < 50; i++) {
      try {
        await api.info();
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
  });

  tearDownAll(() {
    server.kill();
  });

  testWidgets('onboarding renders and moves to setup', (t) async {
    phone(t);
    mockNative(termux: false);
    await t.pumpWidget(const IdeApp());
    await settle(t, () => find.text('Начать настройку (≈2 минуты)').evaluate().isNotEmpty);
    expect(find.text('Termux IDE'), findsWidgets);
    await t.tap(find.text('Начать настройку (≈2 минуты)'));
    await settle(t, () => find.text('Установи Termux').evaluate().isNotEmpty);
    expect(find.text('Установи Termux'), findsOneWidget);
    expect(find.text('F-Droid'), findsOneWidget);
  });

  testWidgets('projects page and extensions page render', (t) async {
    phone(t);
    mockNative();
    final api = Api(token, port: port);
    final st = (await t.runAsync(() => Settings.load(home.path)))!;
    final tools = (await t.runAsync(() => api.info()))!.tools;
    await t.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: ProjectsPage(
        api: api, settings: st, tools: tools,
        onOpen: (_) {}, onShowGuide: () {}, onToolsChanged: () {},
      ),
    ));
    await t.pump();
    expect(find.text('Новый проект'), findsOneWidget);

    await t.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: ExtensionsPage(api: api)));
    await settle(t, () => find.text('Python').evaluate().isNotEmpty);
    expect(find.text('Python'), findsOneWidget);
    expect(find.text('Kotlin'), findsOneWidget);
  });

  testWidgets('terminal keeps the keyboard when it opens (portrait) and Enter works', (t) async {
    phone(t);
    mockNative();
    final api = Api(token, port: port);
    final st = (await t.runAsync(() => Settings.load(home.path)))!;
    final tools = (await t.runAsync(() => api.info()))!.tools;
    final root = '${home.path}/projects/hello';
    await t.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: IdePage(api: api, settings: st, root: root, tools: tools, onClose: () {}),
    ));
    await settle(t, () => find.textContaining('Авто').evaluate().isNotEmpty);

    // Open a shell and focus it.
    await t.tap(find.byTooltip('Терминал'));
    await settle(t, () => find.byType(TerminalView).evaluate().isNotEmpty);
    await t.tap(find.byType(TerminalView));
    await t.pump(const Duration(milliseconds: 400)); // let xterm's double-tap timer expire
    final before = t.state(find.byType(TerminalView));
    expect(t.testTextInput.hasAnyClients, isTrue);

    // The on-screen keyboard appears: the terminal must NOT be re-created.
    t.view.viewInsets = const FakeViewPadding(bottom: 1100);
    await t.pump();
    await t.pump();
    expect(identical(t.state(find.byType(TerminalView)), before), isTrue);
    expect(t.testTextInput.hasAnyClients, isTrue);

    // Type a command with the soft keyboard and press Enter (Android sends "newline").
    t.testTextInput.enterText('echo typed-ok > typed.txt');
    await t.pump();
    await t.testTextInput.receiveAction(TextInputAction.newline);
    var created = false;
    for (var i = 0; i < 60 && !created; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
      await t.pump();
      created = (await t.runAsync(() => api.exists('$root/typed.txt')))!;
    }
    expect(created, isTrue, reason: 'command typed in the terminal was not executed');
    final content = (await t.runAsync(() => api.read('$root/typed.txt')))!;
    expect(content.trim(), 'typed-ok');

    await t.pumpWidget(const SizedBox());
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
  });

  test('git: status, stage, commit, diff, log, branches', () async {
    final api = Api(token, port: port);
    final root = '${home.path}/projects/gitdemo';
    await api.mkdir(root);
    await api.exec('git init -q -b main && git config user.email t@example.com && git config user.name Tester', cwd: root);
    await api.write('$root/a.txt', 'one\n');
    await api.write('$root/dir/b.py', 'print(1)\n');

    final g = GitController(api, root);
    await g.refresh();
    expect(g.isRepo, isTrue);
    expect(g.status.branch, 'main');
    expect(g.status.hasCommits, isFalse);
    expect(g.status.changes.map((c) => c.path).toSet(), {'a.txt', 'dir/b.py'});
    expect(g.colorFor('$root/dir', true), isNotNull);

    await g.stage(g.status.changes.firstWhere((c) => c.path == 'a.txt'));
    await g.refresh();
    expect(g.status.staged.single.path, 'a.txt');
    await g.unstageAll(); // before the first commit this uses `git rm --cached`
    await g.refresh();
    expect(g.status.staged, isEmpty);

    await g.stageAll();
    await g.commit('Первый коммит "с кавычками"', home.path);
    await g.refresh();
    expect(g.status.hasCommits, isTrue);
    expect(g.count, 0);

    await api.write('$root/a.txt', 'one\ntwo\n');
    await g.refresh();
    final ch = g.status.changes.single;
    expect(ch.kind, GitKind.modified);
    expect(await g.diff(ch), contains('+two'));
    await g.stage(ch);
    await g.refresh();
    await g.unstage(g.status.staged.single);
    await g.refresh();
    await g.discard(g.status.changes.single);
    await g.refresh();
    expect(g.count, 0);

    final log = await g.log();
    expect(log.single.subject, 'Первый коммит "с кавычками"');
    await g.createBranch('feature/x');
    await g.refresh();
    expect(g.status.branch, 'feature/x');
    expect(await g.branches(), containsAll(['main', 'feature/x']));
    await g.checkout('main');
    await g.refresh();
    expect(g.status.branch, 'main');
  });

  testWidgets('git panel renders changes in the drawer', (t) async {
    phone(t);
    mockNative();
    final api = Api(token, port: port);
    final root = '${home.path}/projects/gitdemo';
    await t.runAsync(() => api.write('$root/new_file.dart', 'void main() {}\n'));
    final st = (await t.runAsync(() => Settings.load(home.path)))!;
    final tools = (await t.runAsync(() => api.info()))!.tools;
    await t.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: IdePage(api: api, settings: st, root: root, tools: tools, onClose: () {}),
    ));
    await settle(t, () => find.textContaining(' main*').evaluate().isNotEmpty);
    expect(find.textContaining(' main*'), findsOneWidget); // branch + dirty marker in the run bar

    await t.tap(find.byTooltip('Open navigation menu'));
    await settle(t, () => find.text('Git').evaluate().isNotEmpty, tries: 20);
    await t.tap(find.text('Git'));
    await settle(t, () => find.text('new_file.dart').evaluate().isNotEmpty);
    expect(find.text('Коммит'), findsOneWidget);
    expect(find.textContaining('ИЗМЕНЕНИЯ'), findsOneWidget);

    await t.pumpWidget(const SizedBox());
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
  });

  testWidgets('IDE: detects project, runs file in a real PTY', (t) async {
    phone(t);
    mockNative();
    final api = Api(token, port: port);
    final st = (await t.runAsync(() => Settings.load(home.path)))!;
    final tools = (await t.runAsync(() => api.info()))!.tools;
    var closed = false;
    await t.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: IdePage(
        api: api,
        settings: st,
        root: '${home.path}/projects/hello',
        tools: tools,
        onClose: () => closed = true,
      ),
    ));

    // Auto-detection picks "Bash: current file" once main.sh is opened.
    await settle(t, () => find.textContaining('Авто · Bash').evaluate().isNotEmpty);
    expect(find.textContaining('Авто · Bash'), findsOneWidget);
    expect(find.text('main.sh'), findsWidgets);

    await t.tap(find.byTooltip('Запуск'));
    List<Map<String, dynamic>> sessions = [];
    for (var i = 0; i < 80; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
      await t.pump();
      final res = await t.runAsync(() async {
        final c = HttpClient();
        final req = await c.getUrl(Uri.parse('http://127.0.0.1:$port/api/sessions'));
        req.headers.set('x-token', token);
        final body = await (await req.close()).transform(utf8.decoder).join();
        c.close();
        return body;
      });
      sessions = ((jsonDecode(res!) as Map<String, dynamic>)['sessions'] as List).cast<Map<String, dynamic>>();
      if (sessions.any((s) => s['running'] == false && s['code'] == 0)) break;
    }
    expect(sessions.where((s) => s['code'] == 0 && '${s['title']}'.startsWith('Bash')), isNotEmpty);

    // Terminal panel is open with the run tab (the UI may lag behind the server a bit).
    await settle(t, () => find.text('Bash: текущий файл').evaluate().isNotEmpty);
    expect(find.text('Bash: текущий файл'), findsWidgets);

    // System back closes the project, even after the program has finished.
    await t.binding.handlePopRoute();
    await t.pump();
    expect(closed, isTrue);
    await t.pumpWidget(const SizedBox());
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
  });
}

