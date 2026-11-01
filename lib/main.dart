import 'package:flutter/material.dart';

import 'api.dart';
import 'ide_page.dart';
import 'native.dart';
import 'onboarding.dart';
import 'projects_page.dart';
import 'server_manager.dart';
import 'settings.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const IdeApp());
}

class IdeApp extends StatelessWidget {
  const IdeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Termux IDE',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF3DDC97),
        scaffoldBackgroundColor: const Color(0xFF1E1E1E),
        appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF252526)),
        cardTheme: const CardThemeData(color: Color(0xFF252526)),
      ),
      home: const Home(),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

enum _Stage { loading, onboarding, connecting, offline, ready }

class _HomeState extends State<Home> with WidgetsBindingObserver {
  Settings? _st;
  Api? _api;
  ServerManager? _server;
  _Stage _stage = _Stage.loading;
  ConnectStatus? _fail;
  String _msg = '';
  String? _project;
  List<String> _tools = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Termux may have been killed while we were in the background: reconnect quietly.
    if (state == AppLifecycleState.resumed && _stage == _Stage.ready) {
      _server?.ping().then((info) {
        if (info == null && mounted) _server!.connect();
      });
    }
  }

  Future<void> _boot() async {
    final st = await Settings.load(await Native.filesDir());
    _st = st;
    _api = Api(st.token);
    _server = ServerManager(_api!);
    if (!st.onboarded) {
      setState(() => _stage = _Stage.onboarding);
      return;
    }
    await _connect();
  }

  Future<void> _connect() async {
    setState(() {
      _stage = _Stage.connecting;
      _msg = 'Подключаюсь к Termux…';
    });
    final r = await _server!.connect(onStep: (s) {
      if (mounted) setState(() => _msg = s);
    });
    if (!mounted) return;
    if (r == ConnectStatus.ok) {
      await _loadTools();
      setState(() => _stage = _Stage.ready);
    } else {
      setState(() {
        _stage = _Stage.offline;
        _fail = r;
      });
    }
  }

  Future<void> _loadTools({bool refresh = false}) async {
    try {
      final info = await _api!.info(refresh: refresh);
      if (mounted) setState(() => _tools = info.tools);
    } catch (_) {}
  }

  void _onboarded(List<String> tools) {
    final st = _st!;
    st.onboarded = true;
    st.save();
    _tools = tools;
    _connect();
  }

  void _openProject(String path) {
    final st = _st!;
    st.addRecent(path);
    st.save();
    setState(() => _project = path);
  }

  @override
  Widget build(BuildContext context) {
    switch (_stage) {
      case _Stage.loading:
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      case _Stage.onboarding:
        return OnboardingPage(api: _api!, server: _server!, onDone: _onboarded);
      case _Stage.connecting:
        return Scaffold(
          body: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Image.asset('assets/branding/logo.png', width: 88, height: 88),
              const SizedBox(height: 24),
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(_msg),
            ]),
          ),
        );
      case _Stage.offline:
        return _offline();
      case _Stage.ready:
        if (_project != null) {
          return IdePage(
            key: ValueKey(_project),
            api: _api!,
            settings: _st!,
            root: _project!,
            tools: _tools,
            onClose: () {
              setState(() => _project = null);
              _loadTools();
            },
          );
        }
        return ProjectsPage(
          api: _api!,
          settings: _st!,
          tools: _tools,
          onOpen: _openProject,
          onShowGuide: () => setState(() => _stage = _Stage.onboarding),
          onToolsChanged: () => _loadTools(refresh: true),
        );
    }
  }

  Widget _offline() {
    final text = switch (_fail) {
      ConnectStatus.noTermux => 'Termux не установлен.',
      ConnectStatus.noPermission => 'Нет разрешения «Выполнять команды в Termux».',
      _ => 'Termux не отвечает.',
    };
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(24), children: [
          const SizedBox(height: 40),
          const Icon(Icons.link_off, size: 56, color: Colors.white38),
          const SizedBox(height: 16),
          Text(text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18)),
          const SizedBox(height: 8),
          const Text('Обычно помогает пройти настройку ещё раз — это быстро.',
              textAlign: TextAlign.center, style: TextStyle(color: Colors.white60)),
          const SizedBox(height: 24),
          FilledButton.icon(onPressed: _connect, icon: const Icon(Icons.refresh), label: const Text('Повторить')),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => setState(() => _stage = _Stage.onboarding),
            icon: const Icon(Icons.checklist),
            label: const Text('Пройти настройку'),
          ),
          if (_fail == ConnectStatus.noResponse)
            TextButton.icon(
              onPressed: ServerManager.showLog,
              icon: const Icon(Icons.bug_report_outlined),
              label: const Text('Диагностика в Termux'),
            ),
          if (_fail == ConnectStatus.noPermission)
            TextButton(onPressed: Native.openAppSettings, child: const Text('Открыть настройки приложения')),
        ]),
      ),
    );
  }
}
