/// New-project templates.
class ProjectTemplate {
  final String id;
  final String title;

  /// Tool required in Termux (matches LangPack.tool).
  final String? needs;

  /// Command run in the parent dir before files are written. {name} {pkg}
  final String? cmd;

  /// Files written relative to the new project dir. {name} is replaced.
  final Map<String, String> files;

  /// File opened after creation.
  final String? openFile;

  /// Only [a-z0-9_] allowed in the name.
  final bool strictName;

  const ProjectTemplate(this.id, this.title,
      {this.needs, this.cmd, this.files = const {}, this.openFile, this.strictName = false});
}

const templates = <ProjectTemplate>[
  ProjectTemplate('python', 'Python', needs: 'python', files: {
    'main.py': 'def main():\n    name = input("Как тебя зовут? ")\n    print(f"Привет, {name}!")\n\n\nif __name__ == "__main__":\n    main()\n',
  }, openFile: 'main.py'),
  ProjectTemplate('flutter', 'Flutter-приложение', needs: 'flutter',
      cmd: 'flutter create --org com.example --platforms android,web "{name}"', openFile: 'lib/main.dart', strictName: true),
  ProjectTemplate('dart', 'Dart (консоль)', needs: 'dart', cmd: 'dart create "{name}"', openFile: 'bin/{name}.dart', strictName: true),
  ProjectTemplate('kotlin_file', 'Kotlin (один файл)', needs: 'kotlinc', files: {
    'Main.kt': 'fun main() {\n    print("Как тебя зовут? ")\n    val name = readln()\n    println("Привет, \$name!")\n}\n',
  }, openFile: 'Main.kt'),
  ProjectTemplate('kotlin_gradle', 'Kotlin (Gradle)', needs: 'gradle',
      cmd: 'mkdir -p "{name}" && cd "{name}" && gradle init --type kotlin-application --dsl kotlin '
          '--project-name "{name}" --package "{pkg}" --use-defaults',
      strictName: true),
  ProjectTemplate('java', 'Java', needs: 'java', files: {
    'Main.java': 'import java.util.Scanner;\n\npublic class Main {\n    public static void main(String[] args) {\n'
        '        System.out.print("Как тебя зовут? ");\n        String name = new Scanner(System.in).nextLine();\n'
        '        System.out.println("Привет, " + name + "!");\n    }\n}\n',
  }, openFile: 'Main.java'),
  ProjectTemplate('c', 'C', needs: 'clang', files: {
    'main.c': '#include <stdio.h>\n\nint main(void) {\n    char name[64];\n    printf("Как тебя зовут? ");\n'
        '    fflush(stdout);\n    if (scanf("%63s", name) == 1) printf("Привет, %s!\\n", name);\n    return 0;\n}\n',
  }, openFile: 'main.c'),
  ProjectTemplate('cpp', 'C++', needs: 'clang', files: {
    'main.cpp': '#include <iostream>\n#include <string>\n\nint main() {\n    std::string name;\n'
        '    std::cout << "Как тебя зовут? ";\n    std::getline(std::cin, name);\n'
        '    std::cout << "Привет, " << name << "!" << std::endl;\n    return 0;\n}\n',
  }, openFile: 'main.cpp'),
  ProjectTemplate('node', 'Node.js', needs: 'node', files: {
    'package.json': '{\n  "name": "{name}",\n  "version": "1.0.0",\n  "main": "main.js",\n  "scripts": {\n    "start": "node main.js"\n  }\n}\n',
    'main.js': 'const readline = require("readline");\n\nconst rl = readline.createInterface({ input: process.stdin, output: process.stdout });\n'
        'rl.question("Как тебя зовут? ", (name) => {\n  console.log(`Привет, \${name}!`);\n  rl.close();\n});\n',
  }, openFile: 'main.js'),
  ProjectTemplate('go', 'Go', needs: 'go', cmd: 'mkdir -p "{name}" && cd "{name}" && go mod init "{name}"', files: {
    'main.go': 'package main\n\nimport "fmt"\n\nfunc main() {\n\tvar name string\n\tfmt.Print("Как тебя зовут? ")\n'
        '\tfmt.Scanln(&name)\n\tfmt.Printf("Привет, %s!\\n", name)\n}\n',
  }, openFile: 'main.go', strictName: true),
  ProjectTemplate('rust', 'Rust', needs: 'cargo', cmd: 'cargo new "{name}"', openFile: 'src/main.rs', strictName: true),
  ProjectTemplate('empty', 'Пустая папка'),
];
