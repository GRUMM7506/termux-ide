import 'package:flutter/material.dart';

import 'api.dart';

/// Lazy-loaded file tree of a project.
class FileTree extends StatefulWidget {
  final Api api;
  final String root;
  final String? activePath;
  final void Function(String path) onOpen;
  final void Function(FsEntry entry) onMenu;

  /// Right click (mouse): context menu at the pointer.
  final void Function(FsEntry entry, Offset position)? onContextMenu;
  final void Function(String dir) onNewFile;
  final void Function(String dir) onNewFolder;

  /// Git colors for entries (null = default) and a listenable to repaint on change.
  final Color? Function(String path, bool dir)? colorFor;
  final Listenable? decorations;

  const FileTree({
    super.key,
    required this.api,
    required this.root,
    required this.onOpen,
    required this.onMenu,
    this.onContextMenu,
    required this.onNewFile,
    required this.onNewFolder,
    this.activePath,
    this.colorFor,
    this.decorations,
  });

  @override
  State<FileTree> createState() => FileTreeState();
}

class FileTreeState extends State<FileTree> {
  final Map<String, List<FsEntry>> _children = {};
  final Set<String> _expanded = {};
  final Set<String> _loading = {};
  String? _error;

  static const _dim = {'build', '.dart_tool', '.gradle', '.idea', 'node_modules', '__pycache__', '.git'};

  @override
  void initState() {
    super.initState();
    _expanded.add(widget.root);
    Future.microtask(() => _load(widget.root));
  }

  @override
  void didUpdateWidget(covariant FileTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.root != widget.root) {
      _children.clear();
      _expanded
        ..clear()
        ..add(widget.root);
      Future.microtask(() => _load(widget.root));
    }
  }

  Future<void> _load(String dir) async {
    setState(() => _loading.add(dir));
    try {
      final list = await widget.api.list(dir);
      _children[dir] = list;
      _error = null;
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _loading.remove(dir));
  }

  /// Reloads all expanded folders (after create/delete/build).
  Future<void> refresh([String? dir]) async {
    if (dir != null) {
      await _load(dir);
      return;
    }
    for (final d in _expanded.toList()) {
      await _load(d);
    }
  }

  void _toggle(FsEntry e) {
    final open = !_expanded.contains(e.path);
    setState(() => open ? _expanded.add(e.path) : _expanded.remove(e.path));
    if (open && !_children.containsKey(e.path)) _load(e.path);
  }

  List<(FsEntry, int)> _flatten() {
    final out = <(FsEntry, int)>[];
    void walk(String dir, int depth) {
      for (final e in _children[dir] ?? const <FsEntry>[]) {
        out.add((e, depth));
        if (e.dir && _expanded.contains(e.path)) walk(e.path, depth + 1);
      }
    }

    walk(widget.root, 0);
    return out;
  }

  IconData _icon(FsEntry e) {
    if (e.dir) return _expanded.contains(e.path) ? Icons.folder_open : Icons.folder;
    final ext = e.name.contains('.') ? e.name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'dart' || 'kt' || 'kts' || 'java' || 'py' || 'js' || 'ts' || 'c' || 'cpp' || 'h' || 'sh' => Icons.code,
      'yaml' || 'yml' || 'json' || 'xml' || 'gradle' || 'properties' || 'toml' => Icons.settings_outlined,
      'md' || 'txt' => Icons.description_outlined,
      'png' || 'jpg' || 'jpeg' || 'webp' || 'svg' => Icons.image_outlined,
      'apk' || 'jar' || 'aab' => Icons.android,
      _ => Icons.insert_drive_file_outlined,
    };
  }

  @override
  Widget build(BuildContext context) {
    final items = _flatten();
    final name = widget.root.split('/').last;
    return Container(
      color: const Color(0xFF1B1B1C),
      child: Column(children: [
        Container(
          height: 40,
          padding: const EdgeInsets.only(left: 12),
          color: const Color(0xFF252526),
          child: Row(children: [
            Expanded(
              child: Text(name.toUpperCase(),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: .5)),
            ),
            IconButton(
              tooltip: 'Новый файл',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              onPressed: () => widget.onNewFile(widget.root),
              icon: const Icon(Icons.note_add_outlined),
            ),
            IconButton(
              tooltip: 'Новая папка',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              onPressed: () => widget.onNewFolder(widget.root),
              icon: const Icon(Icons.create_new_folder_outlined),
            ),
            IconButton(
              tooltip: 'Обновить',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              onPressed: refresh,
              icon: const Icon(Icons.refresh),
            ),
          ]),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
          ),
        Expanded(
          child: ListenableBuilder(
           listenable: widget.decorations ?? const AlwaysStoppedAnimation(0),
           builder: (context, _) => ListView.builder(
            itemCount: items.length,
            itemBuilder: (_, i) {
              final (e, depth) = items[i];
              final active = e.path == widget.activePath;
              final dim = _dim.contains(e.name) || e.name.startsWith('.');
              return Material(
                color: active ? const Color(0xFF37373D) : Colors.transparent,
                child: InkWell(
                  onTap: () => e.dir ? _toggle(e) : widget.onOpen(e.path),
                  onLongPress: () => widget.onMenu(e),
                  onSecondaryTapUp: (d) => widget.onContextMenu != null
                      ? widget.onContextMenu!(e, d.globalPosition)
                      : widget.onMenu(e),
                  child: Padding(
                    padding: EdgeInsets.only(left: 8.0 + depth * 14, top: 6, bottom: 6, right: 8),
                    child: Row(children: [
                      SizedBox(
                        width: 16,
                        child: e.dir
                            ? Icon(_expanded.contains(e.path) ? Icons.expand_more : Icons.chevron_right, size: 16)
                            : null,
                      ),
                      const SizedBox(width: 2),
                      if (_loading.contains(e.path))
                        const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      else
                        Icon(_icon(e), size: 16, color: e.dir ? const Color(0xFFDCB67A) : const Color(0xFF9CDCFE)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          e.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            color: widget.colorFor?.call(e.path, e.dir) ?? (dim ? Colors.white38 : Colors.white),
                          ),
                        ),
                      ),
                    ]),
                  ),
                ),
              );
            },
           ),
          ),
        ),
      ]),
    );
  }
}
