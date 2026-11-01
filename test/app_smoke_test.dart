// End-to-end smoke tests: real server.py + real UI on a phone-sized screen.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termux_ide/api.dart';
import 'package:termux_ide/extensions.dart';
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

    // Terminal panel is open with the run tab.
    expect(find.text('Bash: текущий файл'), findsWidgets);

    // System back closes the project, even after the program has finished.
    await t.binding.handlePopRoute();
    await t.pump();
    expect(closed, isTrue);
    await t.pumpWidget(const SizedBox());
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
  });
}

