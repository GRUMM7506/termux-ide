// Agent panel: login-link parsing + end-to-end chat with fake `claude` / `codex` CLIs
// that print the same JSONL events as the real ones, through the real server.py.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termux_ide/agent.dart';
import 'package:termux_ide/api.dart';
import 'package:termux_ide/file_tree.dart';
import 'package:termux_ide/ide_page.dart';
import 'package:termux_ide/settings.dart';
import 'package:termux_ide/terminal_panel.dart';

const token = 'agent-token-0123456789abcdef';
const port = 8792;

late Process server;
late Directory home;

const fakeClaude = r'''#!/usr/bin/env bash
case "$1" in
  --version) echo "9.9.9 (Claude Code)"; exit 0 ;;
  auth) echo '{"loggedIn": true, "authMethod": "claude.ai", "subscriptionType": "max"}'; exit 0 ;;
esac
echo "$*" > "$HOME/claude-args.txt"
echo '{"type":"system","subtype":"init","session_id":"s-1","model":"fake-opus"}'
while IFS= read -r line; do
  case "$line" in *control_request*) continue ;; esac
  echo "$line" > "$HOME/claude-input.txt"
  echo '{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}'
  echo '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Создаю"}}}'
  echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Создаю файл"}]}}'
  echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Write","input":{"file_path":"'"$PWD"'/agent.txt","content":"hi"}}]}}'
  echo hi > agent.txt
  echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"File created"}]}}'
  echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Готово: создал agent.txt"}]}}'
  echo '{"type":"result","subtype":"success","is_error":false,"result":"Готово","session_id":"s-1","permission_denials":[{"tool_name":"Bash","tool_use_id":"t2","tool_input":{"command":"rm -rf build"}}]}'
done
''';

const fakeCodex = r'''#!/usr/bin/env bash
case "$1" in
  --version) echo "codex-cli 9.9.9"; exit 0 ;;
  login) echo "Logged in using ChatGPT"; exit 0 ;;
esac
echo "$*" > "$HOME/codex-args.txt"
echo '{"type":"thread.started","thread_id":"th-1"}'
echo '{"type":"turn.started"}'
echo '{"type":"item.started","item":{"id":"c1","type":"command_execution","command":"ls","aggregated_output":"","exit_code":null,"status":"in_progress"}}'
echo '{"type":"item.completed","item":{"id":"c1","type":"command_execution","command":"ls","aggregated_output":"main.sh\n","exit_code":0,"status":"completed"}}'
echo '{"type":"item.completed","item":{"id":"m1","type":"agent_message","text":"Codex ответил"}}'
echo '{"type":"turn.completed","usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1}}'
''';

Future<void> settle(WidgetTester t, bool Function() done, {int tries = 100}) async {
  for (var i = 0; i < tries && !done(); i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pump(const Duration(milliseconds: 50)); // lets the drawer animation finish
  }
}

void phone(WidgetTester t) {
  t.view.physicalSize = const Size(1080, 2340);
  t.view.devicePixelRatio = 2.625;
  addTearDown(t.view.reset);
}

void mockNative() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('termux_ide/native'),
    (call) async => switch (call.method) {
      'filesDir' => home.path,
      'isTermuxInstalled' || 'hasPermission' || 'ensurePermission' => true,
      _ => null,
    },
  );
}

Finder inAgent(Finder f) => find.descendant(of: find.byType(AgentPanel), matching: f);

void main() {
  group('findLoginUrl', () {
    test('plain link', () {
      expect(findLoginUrl('Open this:\r\nhttps://claude.ai/oauth/authorize?code=true&client_id=abc\r\n'),
          'https://claude.ai/oauth/authorize?code=true&client_id=abc');
    });
    test('link hard-wrapped by the TUI, with colors', () {
      const out = '\x1B[2mBrowser didn\'t open? Use the url below\x1B[22m\r\n'
          '\x1B[36mhttps://claude.com/cai/oauth/authorize?code=true&client_id=9d1c\x1B[39m\r\n'
          '\x1B[36m250a-e61b-44d9&state=xyz\x1B[39m\r\n'
          '\r\nPaste code here if prompted >';
      expect(findLoginUrl(out), 'https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9&state=xyz');
    });
    test('codex link, other links ignored', () {
      expect(findLoginUrl('see https://example.com/x\nhttps://auth.openai.com/oauth/authorize?a=1 \n'),
          'https://auth.openai.com/oauth/authorize?a=1');
      expect(findLoginUrl('nothing here https://github.com/x'), isNull);
    });
  });

  group('agent e2e', () {
    setUpAll(() async {
      HttpOverrides.global = null;
      home = await Directory.systemTemp.createTemp('tide-agent');
      final bin = Directory('${home.path}/fakebin')..createSync();
      for (final e in {'claude': fakeClaude, 'codex': fakeCodex}.entries) {
        File('${bin.path}/${e.key}').writeAsStringSync(e.value);
      }
      await Process.run('chmod', ['+x', '${bin.path}/claude', '${bin.path}/codex']);
      final proj = Directory('${home.path}/projects/demo')..createSync(recursive: true);
      File('${proj.path}/main.sh').writeAsStringSync('echo hi\n');
      server = await Process.start('python3', ['assets/termux/server.py', token, '$port'], environment: {
        ...Platform.environment,
        'HOME': home.path,
        'PATH': '${bin.path}:${Platform.environment['PATH']}',
      });
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

    tearDownAll(() => server.kill());

    test('server reports agent status', () async {
      final s = await Api(token, port: port).agentStatus();
      expect(s['claude']!.installed, isTrue);
      expect(s['claude']!.loggedIn, isTrue);
      expect(s['claude']!.detail, contains('max'));
      expect(s['codex']!.loggedIn, isTrue);
    });

    Future<void> openIde(WidgetTester t) async {
      phone(t);
      mockNative();
      final api = Api(token, port: port);
      final st = (await t.runAsync(() => Settings.load(home.path)))!;
      await t.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: IdePage(api: api, settings: st, root: '${home.path}/projects/demo', tools: const [], onClose: () {}),
      ));
      await settle(t, () => find.byTooltip('Агент').evaluate().isNotEmpty);
      await t.tap(find.byTooltip('Агент'));
      await settle(t, () => inAgent(find.byType(TextField)).evaluate().isNotEmpty);
      await t.pump(const Duration(milliseconds: 600)); // drawer fully open
      expect(inAgent(find.byType(TextField)), findsOneWidget, reason: 'agent chat did not open');
    }

    Future<void> closeIde(WidgetTester t) async {
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 6));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    }

    testWidgets('Claude Code: chat, tool call, file written, denial', (t) async {
      await openIde(t);
      expect(find.text('Задача для Claude Code…'), findsOneWidget);
      await t.enterText(inAgent(find.byType(TextField)), 'Создай файл');
      await t.tap(find.byTooltip('Отправить'));
      await settle(t, () => find.textContaining('Готово: создал agent.txt').evaluate().isNotEmpty);
      expect(find.textContaining('Готово: создал agent.txt'), findsOneWidget);
      expect(find.text('Новый файл'), findsOneWidget);
      expect(find.textContaining('rm -rf build'), findsOneWidget);
      expect(File('${home.path}/projects/demo/agent.txt').existsSync(), isTrue);
      final args = File('${home.path}/claude-args.txt').readAsStringSync();
      expect(args, contains('--output-format stream-json'));
      expect(args, contains('--permission-mode auto'));
      expect(File('${home.path}/claude-input.txt').readAsStringSync(), contains('Создай файл'));
      await closeIde(t);
    });

    testWidgets('DeX / big window: agent docks on the right, shortcuts work', (t) async {
      t.view.physicalSize = const Size(1920, 1080);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      mockNative();
      final api = Api(token, port: port);
      final st = (await t.runAsync(() => Settings.load(home.path)))!;
      await t.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: IdePage(api: api, settings: st, root: '${home.path}/projects/demo', tools: const [], onClose: () {}),
      ));
      await settle(t, () => find.text('main.sh').evaluate().isNotEmpty);
      expect(find.byType(FileTree), findsOneWidget, reason: 'file tree on the left');
      expect(find.text('Агент'), findsNothing, reason: 'no agent tab on the left when it can dock');

      await t.tap(find.byTooltip('Агент'));
      await settle(t, () => inAgent(find.byType(TextField)).evaluate().isNotEmpty);
      expect(find.byType(AgentPanel), findsOneWidget);
      expect(find.byType(FileTree), findsOneWidget, reason: 'files stay visible next to the agent');

      // Ctrl+B hides the side bar, Ctrl+Shift+A closes the agent column.
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump();
      await t.pump();
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyB);
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyA);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pump();
      expect(find.byType(FileTree), findsNothing);
      expect(find.byType(AgentPanel), findsNothing);
      await closeIde(t);
    });

    testWidgets('Codex: chat with command output', (t) async {
      await openIde(t);
      await t.tap(find.text('Codex'));
      await settle(t, () => find.text('Задача для Codex…').evaluate().isNotEmpty);
      await t.enterText(inAgent(find.byType(TextField)), 'Покажи файлы');
      await t.tap(find.byTooltip('Отправить'));
      await settle(t, () => find.textContaining('Codex ответил').evaluate().isNotEmpty);
      expect(find.textContaining('Codex ответил'), findsOneWidget);
      expect(find.text('Команда'), findsOneWidget);
      final args = File('${home.path}/codex-args.txt').readAsStringSync();
      expect(args, contains('exec --json --skip-git-repo-check -s workspace-write'));
      expect(args, contains('Покажи файлы'));
      await closeIde(t);
    });
  });
}
