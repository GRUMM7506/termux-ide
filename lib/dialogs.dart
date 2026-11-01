import 'package:flutter/material.dart';

import 'api.dart';

Future<String?> prompt(BuildContext context, String title,
    {String initial = '', String? hint, bool multiline = false}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 480,
        child: TextField(
          controller: c,
          autofocus: true,
          minLines: multiline ? 2 : 1,
          maxLines: multiline ? 6 : 1,
          autocorrect: false,
          enableSuggestions: false,
          style: const TextStyle(fontFamily: 'monospace'),
          decoration: InputDecoration(hintText: hint),
          onSubmitted: multiline ? null : (v) => Navigator.pop(ctx, v),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('OK')),
      ],
    ),
  );
}

/// Returns the index of the chosen option or null if dismissed.
Future<int?> askChoice(BuildContext context, String title, List<String> options) {
  return showDialog<int>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title, style: const TextStyle(fontSize: 18)),
      actions: [
        for (var i = options.length - 1; i >= 0; i--)
          i == 0
              ? FilledButton(onPressed: () => Navigator.pop(ctx, i), child: Text(options[i]))
              : TextButton(onPressed: () => Navigator.pop(ctx, i), child: Text(options[i])),
      ],
    ),
  );
}

/// Folder browser over the Termux file system.
Future<String?> pickFolder(BuildContext context, Api api, String start) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => _FolderPicker(api: api, start: start),
  );
}

class _FolderPicker extends StatefulWidget {
  final Api api;
  final String start;
  const _FolderPicker({required this.api, required this.start});

  @override
  State<_FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<_FolderPicker> {
  late String dir = widget.start;
  List<FsEntry> items = [];
  String? error;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    setState(() => loading = true);
    try {
      items = (await widget.api.list(dir)).where((e) => e.dir).toList();
      error = null;
    } catch (e) {
      items = [];
      error = '$e';
    }
    if (mounted) setState(() => loading = false);
  }

  void _go(String d) {
    dir = d;
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final up = dir.contains('/') && dir != '/' ? dir.substring(0, dir.lastIndexOf('/')) : null;
    return AlertDialog(
      title: Text(dir, style: const TextStyle(fontSize: 14, fontFamily: 'monospace')),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      content: SizedBox(
        width: 480,
        height: 420,
        child: loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(children: [
                if (error != null) Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
                if (up != null && up.isNotEmpty)
                  ListTile(leading: const Icon(Icons.arrow_upward), title: const Text('..'), onTap: () => _go(up)),
                for (final e in items)
                  ListTile(
                    leading: const Icon(Icons.folder, color: Color(0xFFDCB67A)),
                    title: Text(e.name),
                    onTap: () => _go(e.path),
                  ),
              ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(context, dir), child: const Text('Открыть эту папку')),
      ],
    );
  }
}
