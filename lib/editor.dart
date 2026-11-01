import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ---------------------------------------------------------------------------
// Syntax highlighting
// ---------------------------------------------------------------------------

class _Lang {
  final Set<String> keywords;
  final Set<String> controlKw;
  final bool slashComments; // // and /* */
  final bool hashComments; // #
  final bool tripleQuotes;
  const _Lang(this.keywords,
      {this.controlKw = const {}, this.slashComments = true, this.hashComments = false, this.tripleQuotes = false});
}

const _control = {'if', 'else', 'for', 'while', 'do', 'switch', 'case', 'return', 'break', 'continue', 'try', 'catch', 'finally', 'throw', 'when', 'yield', 'await', 'default'};

final _langs = <String, _Lang>{
  'dart': const _Lang({
    'abstract', 'as', 'assert', 'async', 'base', 'class', 'const', 'covariant', 'deferred', 'dynamic', 'enum', 'export',
    'extends', 'extension', 'external', 'factory', 'false', 'final', 'get', 'hide', 'implements', 'import', 'in', 'interface',
    'is', 'late', 'library', 'mixin', 'new', 'null', 'on', 'operator', 'part', 'required', 'rethrow', 'sealed', 'set', 'show',
    'static', 'super', 'sync', 'this', 'true', 'typedef', 'var', 'void', 'with', 'int', 'double', 'num', 'bool', 'String',
  }, controlKw: _control, tripleQuotes: true),
  'kotlin': const _Lang({
    'abstract', 'annotation', 'as', 'by', 'class', 'companion', 'const', 'constructor', 'data', 'enum', 'false', 'fun',
    'get', 'import', 'in', 'init', 'inline', 'interface', 'internal', 'is', 'lateinit', 'null', 'object', 'open', 'operator',
    'override', 'package', 'private', 'protected', 'public', 'sealed', 'set', 'super', 'suspend', 'this', 'true', 'typealias',
    'val', 'var', 'vararg',
  }, controlKw: _control, tripleQuotes: true),
  'java': const _Lang({
    'abstract', 'boolean', 'byte', 'char', 'class', 'const', 'double', 'enum', 'extends', 'false', 'final', 'float',
    'implements', 'import', 'instanceof', 'int', 'interface', 'long', 'native', 'new', 'null', 'package', 'private',
    'protected', 'public', 'short', 'static', 'super', 'synchronized', 'this', 'throws', 'transient', 'true', 'var', 'void',
    'volatile', 'record',
  }, controlKw: _control),
  'python': const _Lang({
    'and', 'as', 'assert', 'async', 'class', 'def', 'del', 'False', 'from', 'global', 'import', 'in', 'is', 'lambda', 'None',
    'nonlocal', 'not', 'or', 'pass', 'True', 'with', 'self',
  }, controlKw: {'if', 'elif', 'else', 'for', 'while', 'return', 'break', 'continue', 'try', 'except', 'finally', 'raise', 'yield', 'await', 'match', 'case'},
      slashComments: false, hashComments: true, tripleQuotes: true),
  'js': const _Lang({
    'async', 'class', 'const', 'debugger', 'delete', 'export', 'extends', 'false', 'function', 'import', 'in', 'instanceof',
    'let', 'new', 'null', 'of', 'super', 'this', 'true', 'typeof', 'undefined', 'var', 'void', 'with', 'from', 'interface',
    'type', 'enum', 'implements', 'private', 'public', 'readonly',
  }, controlKw: _control),
  'c': const _Lang({
    'auto', 'bool', 'char', 'class', 'const', 'constexpr', 'double', 'enum', 'extern', 'false', 'float', 'inline', 'int',
    'long', 'namespace', 'new', 'delete', 'nullptr', 'private', 'protected', 'public', 'register', 'short', 'signed',
    'sizeof', 'static', 'struct', 'template', 'this', 'true', 'typedef', 'typename', 'union', 'unsigned', 'using',
    'virtual', 'void', 'volatile', 'std', 'NULL',
  }, controlKw: _control),
  'shell': const _Lang({
    'export', 'local', 'function', 'echo', 'cd', 'source', 'set', 'unset', 'readonly', 'true', 'false', 'in',
  }, controlKw: {'if', 'then', 'else', 'elif', 'fi', 'for', 'while', 'do', 'done', 'case', 'esac', 'return', 'exit'},
      slashComments: false, hashComments: true),
  'yaml': const _Lang({'true', 'false', 'null', 'yes', 'no'}, slashComments: false, hashComments: true),
  'json': const _Lang({'true', 'false', 'null'}, slashComments: false),
  'xml': const _Lang({}, slashComments: false),
  'plain': const _Lang({}, slashComments: false),
};

String languageForPath(String path) {
  final name = path.split('/').last.toLowerCase();
  final ext = name.contains('.') ? name.split('.').last : '';
  return switch (ext) {
    'dart' => 'dart',
    'kt' || 'kts' || 'gradle' || 'groovy' => 'kotlin',
    'java' => 'java',
    'py' => 'python',
    'js' || 'mjs' || 'ts' || 'jsx' || 'tsx' => 'js',
    'c' || 'h' || 'cpp' || 'cc' || 'cxx' || 'hpp' => 'c',
    'sh' || 'bash' || 'zsh' => 'shell',
    'yaml' || 'yml' => 'yaml',
    'json' || 'arb' => 'json',
    'xml' || 'html' || 'svg' => 'xml',
    _ => name == 'makefile' || name == 'dockerfile' ? 'shell' : 'plain',
  };
}

class CodeTheme {
  static const bg = Color(0xFF1E1E1E);
  static const gutterBg = Color(0xFF1A1A1A);
  static const gutterFg = Color(0xFF6E7681);
  static const text = Color(0xFFD4D4D4);
  static const keyword = Color(0xFF569CD6);
  static const control = Color(0xFFC586C0);
  static const string = Color(0xFFCE9178);
  static const comment = Color(0xFF6A9955);
  static const number = Color(0xFFB5CEA8);
  static const type = Color(0xFF4EC9B0);
  static const func = Color(0xFFDCDCAA);
  static const tag = Color(0xFF569CD6);
  static const attr = Color(0xFF9CDCFE);
}

/// TextEditingController that paints syntax colors.
class CodeController extends TextEditingController {
  String language;
  RegExp? _re;

  CodeController({super.text, required this.language}) {
    _buildRegex();
  }

  void setLanguage(String lang) {
    language = lang;
    _buildRegex();
    notifyListeners();
  }

  void _buildRegex() {
    final l = _langs[language] ?? _langs['plain']!;
    if (language == 'xml') {
      _re = RegExp(r'(<!--[\s\S]*?(?:-->|$))|("[^"\n]*"?)|(</?[\w:.-]+)|([\w:-]+(?==))');
      return;
    }
    final parts = <String>[
      if (l.slashComments) r'(/\*[\s\S]*?(?:\*/|$)|//[^\n]*)' else if (l.hashComments) r'(#[^\n]*)' else r'(\u0000)',
      if (l.tripleQuotes) r'("""[\s\S]*?(?:"""|$)|' "'''" r'[\s\S]*?(?:' "'''" r'|$)|"(?:\\.|[^"\\\n])*"?|' "'" r'(?:\\.|[^' "'" r'\\\n])*' "'" r'?)'
      else r'("(?:\\.|[^"\\\n])*"?|' "'" r'(?:\\.|[^' "'" r'\\\n])*' "'" r'?)',
      r'(\b(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)[fFlLuU]?\b)',
      r'(@\w+)',
      r'([A-Za-z_$][\w$]*)',
    ];
    _re = RegExp(parts.join('|'));
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final base = style ?? const TextStyle();
    if (text.length > 200000 || language == 'plain' || _re == null) {
      return TextSpan(style: base, text: text);
    }
    final l = _langs[language]!;
    final spans = <TextSpan>[];
    var last = 0;
    for (final m in _re!.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      final s = m[0]!;
      Color? c;
      if (language == 'xml') {
        if (m[1] != null) {
          c = CodeTheme.comment;
        } else if (m[2] != null) {
          c = CodeTheme.string;
        } else if (m[3] != null) {
          c = CodeTheme.tag;
        } else {
          c = CodeTheme.attr;
        }
      } else if (m[1] != null) {
        c = CodeTheme.comment;
      } else if (m[2] != null) {
        c = CodeTheme.string;
      } else if (m[3] != null) {
        c = CodeTheme.number;
      } else if (m[4] != null) {
        c = CodeTheme.func;
      } else {
        if (l.controlKw.contains(s)) {
          c = CodeTheme.control;
        } else if (l.keywords.contains(s)) {
          c = CodeTheme.keyword;
        } else if (_nextNonSpace(m.end) == '(') {
          c = CodeTheme.func;
        } else if (s[0].toUpperCase() == s[0] && s[0] != '_' && s[0] != r'$' && language != 'yaml') {
          c = CodeTheme.type;
        } else if (language == 'yaml' && _nextNonSpace(m.end) == ':') {
          c = CodeTheme.attr;
        }
      }
      spans.add(TextSpan(
        text: s,
        style: c == null ? null : TextStyle(color: c, fontStyle: c == CodeTheme.comment ? FontStyle.italic : null),
      ));
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return TextSpan(style: base, children: spans);
  }

  String? _nextNonSpace(int i) {
    while (i < text.length) {
      final ch = text[i];
      if (ch != ' ' && ch != '\t') return ch;
      i++;
    }
    return null;
  }

  /// Inserts [s] replacing the current selection.
  void insert(String s) {
    final sel = selection.isValid ? selection : TextSelection.collapsed(offset: text.length);
    final newText = text.replaceRange(sel.start, sel.end, s);
    value = TextEditingValue(text: newText, selection: TextSelection.collapsed(offset: sel.start + s.length));
  }

  void moveCursor(int delta) {
    final sel = selection.isValid ? selection : TextSelection.collapsed(offset: text.length);
    final o = (sel.extentOffset + delta).clamp(0, text.length);
    selection = TextSelection.collapsed(offset: o);
  }
}

/// Keeps indentation on Enter, adds a level after { ( [ :
class AutoIndentFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final t = newValue.text;
    final cur = newValue.selection.baseOffset;
    if (!newValue.selection.isCollapsed || cur <= 0 || cur > t.length) return newValue;
    if (t.length != oldValue.text.length + 1 || t[cur - 1] != '\n') return newValue;
    final from = cur - 2;
    final lineStart = from < 0 ? 0 : t.lastIndexOf('\n', from) + 1;
    final prev = t.substring(lineStart, cur - 1);
    var indent = RegExp(r'^[ \t]*').firstMatch(prev)![0]!;
    final trimmed = prev.trimRight();
    if (trimmed.endsWith('{') || trimmed.endsWith('(') || trimmed.endsWith('[') || trimmed.endsWith(':')) {
      indent += '  ';
    }
    if (indent.isEmpty) return newValue;
    final nt = t.replaceRange(cur, cur, indent);
    return TextEditingValue(text: nt, selection: TextSelection.collapsed(offset: cur + indent.length));
  }
}

// ---------------------------------------------------------------------------
// Editor widget
// ---------------------------------------------------------------------------

class CodeEditor extends StatefulWidget {
  final CodeController controller;
  final UndoHistoryController undo;
  final FocusNode focusNode;
  final double fontSize;
  final VoidCallback onSave;

  const CodeEditor({
    super.key,
    required this.controller,
    required this.undo,
    required this.focusNode,
    required this.fontSize,
    required this.onSave,
  });

  @override
  State<CodeEditor> createState() => _CodeEditorState();
}

class _CodeEditorState extends State<CodeEditor> {
  final _v = ScrollController();
  final _h = ScrollController();

  @override
  void dispose() {
    _v.dispose();
    _h.dispose();
    super.dispose();
  }

  TextStyle get _style => TextStyle(
        fontFamily: 'monospace',
        fontSize: widget.fontSize,
        height: 1.35,
        color: CodeTheme.text,
      );

  StrutStyle get _strut => StrutStyle(
        fontFamily: 'monospace',
        fontSize: widget.fontSize,
        height: 1.35,
        forceStrutHeight: true,
      );

  double _charWidth() {
    final tp = TextPainter(
      text: TextSpan(text: 'MMMMMMMMMM', style: _style),
      textDirection: TextDirection.ltr,
    )..layout();
    return tp.width / 10;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: CodeTheme.bg,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): widget.onSave,
          const SingleActivator(LogicalKeyboardKey.tab): () => widget.controller.insert('  '),
        },
        child: LayoutBuilder(builder: (context, box) {
          return ListenableBuilder(
            listenable: widget.controller,
            builder: (context, _) {
              final text = widget.controller.text;
              final lines = '\n'.allMatches(text).length + 1;
              var longest = 0;
              for (final l in text.split('\n')) {
                final len = l.length + '\t'.allMatches(l).length * 3;
                if (len > longest) longest = len;
              }
              final cw = _charWidth();
              final gutterW = math.max(3, '$lines'.length) * cw + 16;
              final contentW = math.max(box.maxWidth - gutterW, longest * cw + cw * 4 + 24);
              return Scrollbar(
                controller: _v,
                child: SingleChildScrollView(
                  controller: _v,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: box.maxHeight),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: gutterW,
                          color: CodeTheme.gutterBg,
                          padding: const EdgeInsets.only(top: 8, bottom: 300, right: 8),
                          child: Text(
                            List.generate(lines, (i) => '${i + 1}').join('\n'),
                            textAlign: TextAlign.right,
                            style: _style.copyWith(color: CodeTheme.gutterFg),
                            strutStyle: _strut,
                          ),
                        ),
                        Expanded(
                          child: SingleChildScrollView(
                            controller: _h,
                            scrollDirection: Axis.horizontal,
                            child: SizedBox(
                              width: contentW,
                              child: Padding(
                                padding: const EdgeInsets.only(left: 8, top: 8, bottom: 300),
                                child: TextField(
                                  controller: widget.controller,
                                  undoController: widget.undo,
                                  focusNode: widget.focusNode,
                                  maxLines: null,
                                  style: _style,
                                  strutStyle: _strut,
                                  decoration: null,
                                  cursorColor: Colors.white,
                                  keyboardType: TextInputType.multiline,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  smartDashesType: SmartDashesType.disabled,
                                  smartQuotesType: SmartQuotesType.disabled,
                                  textCapitalization: TextCapitalization.none,
                                  inputFormatters: [AutoIndentFormatter()],
                                  scrollPadding: const EdgeInsets.all(80),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        }),
      ),
    );
  }
}

/// Row of symbols that are hard to type on a phone keyboard.
class ExtraKeysBar extends StatelessWidget {
  final CodeController controller;
  final UndoHistoryController undo;
  final VoidCallback onSave;
  const ExtraKeysBar({super.key, required this.controller, required this.undo, required this.onSave});

  static const _keys = ['⇥', '{', '}', '(', ')', '[', ']', ';', ':', '"', "'", '=', '<', '>', '/', '\\', '|', '&', '!', '_', '-', '+', '*', '#', r'$', ',', '.'];

  @override
  Widget build(BuildContext context) {
    Widget btn(Widget child, VoidCallback onTap) => InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minWidth: 38),
            height: 40,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: child,
          ),
        );
    const ts = TextStyle(fontFamily: 'monospace', fontSize: 16, color: Colors.white);
    return Material(
      color: const Color(0xFF252526),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          btn(const Icon(Icons.undo, size: 20), () => undo.undo()),
          btn(const Icon(Icons.redo, size: 20), () => undo.redo()),
          btn(const Icon(Icons.save_outlined, size: 20), onSave),
          btn(const Icon(Icons.chevron_left, size: 22), () => controller.moveCursor(-1)),
          btn(const Icon(Icons.chevron_right, size: 22), () => controller.moveCursor(1)),
          for (final k in _keys) btn(Text(k, style: ts), () => controller.insert(k == '⇥' ? '  ' : k)),
        ]),
      ),
    );
  }
}
