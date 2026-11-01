import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Small JSON settings file in the app's private files dir.
class Settings {
  final File _file;
  String token = '';
  bool onboarded = false;
  double fontSize = 14;
  List<String> recent = [];

  /// Run target per project: 'auto' (default), a target id, or 'custom'.
  Map<String, String> targetByProject = {};
  Map<String, String> customCmdByProject = {};

  /// AI agent panel per project: agent, access mode, model, session ids.
  Map<String, Map<String, String>> agentByProject = {};

  Settings._(this._file);

  /// App files dir (agent chat history lives next to settings.json).
  String get dir => _file.parent.path;

  static Future<Settings> load(String filesDir) async {
    final s = Settings._(File('$filesDir/settings.json'));
    try {
      final m = jsonDecode(await s._file.readAsString()) as Map<String, dynamic>;
      s.token = (m['token'] as String?) ?? '';
      s.onboarded = m['onboarded'] == true;
      s.fontSize = (m['fontSize'] as num?)?.toDouble() ?? 14;
      s.recent = ((m['recent'] as List?) ?? []).cast<String>();
      s.targetByProject = ((m['target'] as Map?) ?? {}).cast<String, String>();
      s.customCmdByProject = ((m['customCmd'] as Map?) ?? {}).cast<String, String>();
      s.agentByProject = ((m['agent'] as Map?) ?? {})
          .map((k, v) => MapEntry(k as String, (v as Map).cast<String, String>()));
    } catch (_) {}
    if (s.token.length < 16) {
      final r = Random.secure();
      s.token = List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
      await s.save();
    }
    return s;
  }

  void addRecent(String path) {
    recent.remove(path);
    recent.insert(0, path);
    if (recent.length > 12) recent = recent.sublist(0, 12);
  }

  Future<void> save() => _file.writeAsString(jsonEncode({
        'token': token,
        'onboarded': onboarded,
        'fontSize': fontSize,
        'recent': recent,
        'target': targetByProject,
        'customCmd': customCmdByProject,
        'agent': agentByProject,
      }));
}
