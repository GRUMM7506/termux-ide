import 'package:flutter_test/flutter_test.dart';
import 'package:termux_ide/runner.dart';

void main() {
  test('file targets by extension', () {
    expect(fileTarget('/a/b/main.py')?.id, 'python_file');
    expect(fileTarget('/a/Main.kt')?.id, 'kotlin_file');
    expect(fileTarget('/a/x.cpp')?.id, 'cpp_file');
    expect(fileTarget('/a/README.md'), isNull);
  });

  test('auto target by project kind', () {
    const flutter = ProjectInfo(ProjectKind.flutter, ['pubspec.yaml', 'lib']);
    expect(autoTarget(flutter, '/p/lib/main.dart')?.id, 'flutter_run');
    const plain = ProjectInfo(ProjectKind.plain, ['main.c']);
    expect(autoTarget(plain, '/p/main.c')?.id, 'c_file');
    expect(autoTarget(plain, null), isNull);
    const node = ProjectInfo(ProjectKind.node, ['package.json'], hasNpmStart: true);
    expect(autoTarget(node, null)?.id, 'npm_start');
  });

  test('command expansion', () {
    final c = expandCmd('kotlinc "{file}" -d "\$TMPDIR/{name}.jar"', root: '/p', file: '/p/src/Main.kt');
    expect(c, 'kotlinc "/p/src/Main.kt" -d "\$TMPDIR/Main.jar"');
  });

  test('missing tools', () {
    final t = targetById('kotlin_file')!;
    expect(missingTools(t, ['java']), ['kotlinc']);
    expect(missingTools(t, ['java', 'kotlinc']), isEmpty);
  });
}
