import 'api.dart';

/// What kind of project a folder is.
enum ProjectKind { flutter, dart, androidGradle, gradle, node, rust, go, cmake, make, python, plain }

extension ProjectKindX on ProjectKind {
  String get title => switch (this) {
        ProjectKind.flutter => 'Flutter',
        ProjectKind.dart => 'Dart',
        ProjectKind.androidGradle => 'Android (Gradle)',
        ProjectKind.gradle => 'Gradle',
        ProjectKind.node => 'Node.js',
        ProjectKind.rust => 'Rust',
        ProjectKind.go => 'Go',
        ProjectKind.cmake => 'CMake',
        ProjectKind.make => 'Make',
        ProjectKind.python => 'Python',
        ProjectKind.plain => 'Папка',
      };

  bool get buildsApk => this == ProjectKind.flutter || this == ProjectKind.androidGradle;
}

class ProjectInfo {
  final ProjectKind kind;
  final List<String> rootNames;
  final bool hasNpmStart;
  final String? nodeMain;
  const ProjectInfo(this.kind, this.rootNames, {this.hasNpmStart = false, this.nodeMain});
}

Future<ProjectInfo> detectProject(Api api, String root) async {
  final names = (await api.list(root)).map((e) => e.name).toList();
  bool has(String n) => names.contains(n);

  if (has('pubspec.yaml')) {
    final pubspec = await api.read('$root/pubspec.yaml');
    final flutter = RegExp(r'sdk:\s*flutter').hasMatch(pubspec) || RegExp(r'^flutter\s*:', multiLine: true).hasMatch(pubspec);
    return ProjectInfo(flutter ? ProjectKind.flutter : ProjectKind.dart, names);
  }
  if (has('gradlew') || has('build.gradle') || has('build.gradle.kts') || has('settings.gradle') || has('settings.gradle.kts')) {
    var android = false;
    if (has('app')) {
      android = await api.exists('$root/app/src/main/AndroidManifest.xml');
    }
    return ProjectInfo(android ? ProjectKind.androidGradle : ProjectKind.gradle, names);
  }
  if (has('package.json')) {
    var start = false;
    String? main;
    try {
      final pj = await api.read('$root/package.json');
      start = RegExp(r'"start"\s*:').hasMatch(pj);
      main = RegExp(r'"main"\s*:\s*"([^"]+)"').firstMatch(pj)?.group(1);
    } catch (_) {}
    return ProjectInfo(ProjectKind.node, names, hasNpmStart: start, nodeMain: main);
  }
  if (has('Cargo.toml')) return ProjectInfo(ProjectKind.rust, names);
  if (has('go.mod')) return ProjectInfo(ProjectKind.go, names);
  if (has('CMakeLists.txt')) return ProjectInfo(ProjectKind.cmake, names);
  if (has('Makefile') || has('makefile')) return ProjectInfo(ProjectKind.make, names);
  if (has('requirements.txt') || has('pyproject.toml') || has('main.py')) return ProjectInfo(ProjectKind.python, names);
  return ProjectInfo(ProjectKind.plain, names);
}

/// A way to run/build something. Placeholders: {file} {name} {dir} {root}
class RunTarget {
  final String id;
  final String title;
  final String cmd;

  /// Tools that must exist in Termux.
  final List<String> needs;

  /// Project kinds this target belongs to (empty = file target).
  final List<ProjectKind> kinds;

  /// File extensions for "current file" targets.
  final List<String> exts;

  /// Sends 'r' / 'R' for hot reload / restart.
  final bool hotReload;

  const RunTarget(this.id, this.title, this.cmd,
      {this.needs = const [], this.kinds = const [], this.exts = const [], this.hotReload = false});
}

const _gradle = 'if [ -f gradlew ]; then chmod +x gradlew; ./gradlew';
const _gradleElse = 'else gradle';

const targets = <RunTarget>[
  // Flutter
  RunTarget('flutter_run', 'Flutter: run (на телефоне)', 'flutter run',
      needs: ['flutter'], kinds: [ProjectKind.flutter], hotReload: true),
  RunTarget('flutter_web', 'Flutter: web-server :8080',
      'flutter run -d web-server --web-port 8080 --web-hostname 127.0.0.1',
      needs: ['flutter'], kinds: [ProjectKind.flutter], hotReload: true),
  RunTarget('flutter_apk_debug', 'Flutter: собрать APK (debug)', 'flutter build apk --debug',
      needs: ['flutter'], kinds: [ProjectKind.flutter]),
  RunTarget('flutter_apk', 'Flutter: собрать APK (release)', 'flutter build apk --release',
      needs: ['flutter'], kinds: [ProjectKind.flutter]),
  RunTarget('flutter_pub', 'Flutter: pub get', 'flutter pub get', needs: ['flutter'], kinds: [ProjectKind.flutter]),
  RunTarget('flutter_analyze', 'Flutter: analyze', 'flutter analyze', needs: ['flutter'], kinds: [ProjectKind.flutter]),
  RunTarget('flutter_test', 'Flutter: test', 'flutter test', needs: ['flutter'], kinds: [ProjectKind.flutter]),
  // Dart
  RunTarget('dart_run', 'Dart: run', 'dart run', needs: ['dart'], kinds: [ProjectKind.dart]),
  RunTarget('dart_test', 'Dart: test', 'dart test', needs: ['dart'], kinds: [ProjectKind.dart]),
  RunTarget('dart_pub', 'Dart: pub get', 'dart pub get', needs: ['dart'], kinds: [ProjectKind.dart]),
  // Gradle
  RunTarget('gradle_debug', 'Gradle: assembleDebug (APK)', '$_gradle assembleDebug; $_gradleElse assembleDebug; fi',
      needs: ['java'], kinds: [ProjectKind.androidGradle]),
  RunTarget('gradle_run', 'Gradle: run', '$_gradle run; $_gradleElse run; fi',
      needs: ['java'], kinds: [ProjectKind.gradle]),
  RunTarget('gradle_build', 'Gradle: build', '$_gradle build; $_gradleElse build; fi',
      needs: ['java'], kinds: [ProjectKind.gradle, ProjectKind.androidGradle]),
  RunTarget('gradle_test', 'Gradle: test', '$_gradle test; $_gradleElse test; fi',
      needs: ['java'], kinds: [ProjectKind.gradle, ProjectKind.androidGradle]),
  // Node
  RunTarget('npm_start', 'npm start', 'npm start', needs: ['npm'], kinds: [ProjectKind.node]),
  RunTarget('node_main', 'Node: main', 'node "{main}"', needs: ['node'], kinds: [ProjectKind.node]),
  RunTarget('npm_install', 'npm install', 'npm install', needs: ['npm'], kinds: [ProjectKind.node]),
  // Others
  RunTarget('cargo_run', 'Cargo: run', 'cargo run', needs: ['cargo'], kinds: [ProjectKind.rust]),
  RunTarget('cargo_build', 'Cargo: build', 'cargo build', needs: ['cargo'], kinds: [ProjectKind.rust]),
  RunTarget('go_run', 'Go: run .', 'go run .', needs: ['go'], kinds: [ProjectKind.go]),
  RunTarget('go_build', 'Go: build', 'go build ./...', needs: ['go'], kinds: [ProjectKind.go]),
  RunTarget('cmake_build', 'CMake: собрать', 'cmake -S . -B build && cmake --build build',
      needs: ['cmake', 'clang'], kinds: [ProjectKind.cmake]),
  RunTarget('make', 'make', 'make', needs: ['make'], kinds: [ProjectKind.make]),
  RunTarget('python_main', 'Python: main.py', 'python main.py', needs: ['python'], kinds: [ProjectKind.python]),
  RunTarget('pip_install', 'pip install -r requirements.txt', 'pip install -r requirements.txt',
      needs: ['pip'], kinds: [ProjectKind.python]),
  // Current file
  RunTarget('python_file', 'Python: текущий файл', 'python "{file}"', needs: ['python'], exts: ['py']),
  RunTarget('node_file', 'Node.js: текущий файл', 'node "{file}"', needs: ['node'], exts: ['js', 'mjs', 'cjs']),
  RunTarget('dart_file', 'Dart: текущий файл', 'dart run "{file}"', needs: ['dart'], exts: ['dart']),
  RunTarget('kotlin_file', 'Kotlin: текущий файл',
      'kotlinc "{file}" -include-runtime -d "\$TMPDIR/{name}.jar" && java -jar "\$TMPDIR/{name}.jar"',
      needs: ['kotlinc', 'java'], exts: ['kt']),
  RunTarget('kotlin_script', 'Kotlin: скрипт', 'kotlinc -script "{file}"', needs: ['kotlinc'], exts: ['kts']),
  RunTarget('java_file', 'Java: текущий файл', 'java "{file}"', needs: ['java'], exts: ['java']),
  RunTarget('c_file', 'C: текущий файл', 'clang "{file}" -o "\$TMPDIR/{name}" -lm && "\$TMPDIR/{name}"',
      needs: ['clang'], exts: ['c']),
  RunTarget('cpp_file', 'C++: текущий файл',
      'clang++ -std=c++20 "{file}" -o "\$TMPDIR/{name}" && "\$TMPDIR/{name}"', needs: ['clang++'], exts: ['cpp', 'cc', 'cxx']),
  RunTarget('go_file', 'Go: текущий файл', 'go run "{file}"', needs: ['go'], exts: ['go']),
  RunTarget('rust_file', 'Rust: текущий файл', 'rustc "{file}" -o "\$TMPDIR/{name}" && "\$TMPDIR/{name}"',
      needs: ['rustc'], exts: ['rs']),
  RunTarget('ruby_file', 'Ruby: текущий файл', 'ruby "{file}"', needs: ['ruby'], exts: ['rb']),
  RunTarget('php_file', 'PHP: текущий файл', 'php "{file}"', needs: ['php'], exts: ['php']),
  RunTarget('bash_file', 'Bash: текущий файл', 'bash "{file}"', exts: ['sh', 'bash']),
];

const customTarget = RunTarget('custom', 'Своя команда…', '');

RunTarget? targetById(String id) {
  if (id == 'custom') return customTarget;
  for (final t in targets) {
    if (t.id == id) return t;
  }
  return null;
}

String extOf(String? path) {
  if (path == null) return '';
  final name = path.split('/').last;
  return name.contains('.') ? name.split('.').last.toLowerCase() : '';
}

RunTarget? fileTarget(String? path) {
  final e = extOf(path);
  if (e.isEmpty) return null;
  for (final t in targets) {
    if (t.exts.contains(e)) return t;
  }
  return null;
}

/// The target chosen in "Авто" mode.
RunTarget? autoTarget(ProjectInfo p, String? activeFile) => switch (p.kind) {
      ProjectKind.flutter => targetById('flutter_run'),
      ProjectKind.dart => targetById('dart_run'),
      ProjectKind.androidGradle => targetById('gradle_debug'),
      ProjectKind.gradle => targetById('gradle_run'),
      ProjectKind.node => targetById(p.hasNpmStart ? 'npm_start' : 'node_main'),
      ProjectKind.rust => targetById('cargo_run'),
      ProjectKind.go => targetById('go_run'),
      ProjectKind.cmake => targetById('cmake_build'),
      ProjectKind.make => targetById('make'),
      ProjectKind.python => extOf(activeFile) == 'py' ? targetById('python_file') : targetById('python_main'),
      ProjectKind.plain => fileTarget(activeFile),
    };

/// Targets worth showing for this project and file.
List<RunTarget> relevantTargets(ProjectInfo p, String? activeFile) {
  final ft = fileTarget(activeFile);
  return [
    for (final t in targets)
      if (t.kinds.contains(p.kind)) t,
    if (ft != null && !ft.kinds.contains(p.kind)) ft,
  ];
}

List<String> missingTools(RunTarget t, List<String> tools) => [for (final n in t.needs) if (!tools.contains(n)) n];

String expandCmd(String cmd, {required String root, String? file, String? nodeMain}) {
  String q(String s) => s.replaceAll('"', r'\"');
  final f = file ?? '';
  final base = f.split('/').last;
  final name = base.contains('.') ? base.substring(0, base.lastIndexOf('.')) : base;
  final dir = f.contains('/') ? f.substring(0, f.lastIndexOf('/')) : root;
  return cmd
      .replaceAll('{file}', q(f))
      .replaceAll('{dir}', q(dir))
      .replaceAll('{name}', q(name.isEmpty ? 'main' : name))
      .replaceAll('{root}', q(root))
      .replaceAll('{main}', q(nodeMain ?? 'index.js'));
}
