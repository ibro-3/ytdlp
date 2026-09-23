import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/models/download_record.dart';
import '../../core/providers.dart';
import '../../core/utils/formatters.dart';

class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  /// Async existence cache so rows don't stat the filesystem in `build`.
  final Map<String, bool> _exists = {};
  final Set<String> _pending = {};

  void _checkExists(String path) {
    if (_pending.contains(path)) return;
    _pending.add(path);
    File(path)
        .exists()
        .then((ok) {
          if (!mounted) return;
          setState(() => _exists[path] = ok);
        })
        .catchError((_) {
          if (!mounted) return;
          setState(() => _exists[path] = false);
        });
  }

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(historyServiceProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          if (history.records.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: 'Clear history',
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Clear history?'),
                    content: const Text(
                      'This removes all entries from the library list. Files on disk are not deleted.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Clear'),
                      ),
                    ],
                  ),
                );
                if (ok == true) {
                  await history.clear();
                }
              },
            ),
        ],
      ),
      body: AnimatedBuilder(
        animation: history,
        builder: (context, _) {
          final records = history.records;
          if (records.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.video_library_outlined,
                      size: 56,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'No downloads yet',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Completed downloads will appear here.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            itemCount: records.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, i) {
              final r = records[i];
              _checkExists(r.filePath);
              final exists = _exists[r.filePath] ?? true;
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: r.thumbnail == null
                            ? Container(
                                width: 72,
                                height: 48,
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                                child: const Icon(
                                  Icons.movie_outlined,
                                  size: 24,
                                ),
                              )
                            : CachedNetworkImage(
                                imageUrl: r.thumbnail!,
                                width: 72,
                                height: 48,
                                fit: BoxFit.cover,
                                errorWidget: (_, _, _) => Container(
                                  width: 72,
                                  height: 48,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHighest,
                                  child: const Icon(
                                    Icons.broken_image_outlined,
                                  ),
                                ),
                              ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              r.title,
                              style: Theme.of(context).textTheme.titleSmall,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              [
                                if (r.author != null) r.author!,
                                formatDate(r.createdAt),
                                if (r.size > 0) formatBytes(r.size),
                                if (!exists) 'file missing',
                              ].join(' · '),
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      PopupMenuButton<String>(
                        onSelected: (v) => _onMenu(context, r, v),
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                            value: 'open',
                            child: Text('Open'),
                          ),
                          const PopupMenuItem(
                            value: 'share',
                            child: Text('Share'),
                          ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('Delete'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _onMenu(
    BuildContext context,
    DownloadRecord r,
    String action,
  ) async {
    switch (action) {
      case 'open':
        final fileExists = await File(r.filePath).exists();
        if (!fileExists) {
          _showSnack('This file is no longer on the device.');
          return;
        }
        try {
          await OpenFilex.open(r.filePath);
        } catch (_) {
          _showSnack('Could not open the file.');
        }
        break;
      case 'share':
        final fileExists = await File(r.filePath).exists();
        if (!fileExists) {
          _showSnack('This file is no longer on the device.');
          return;
        }
        try {
          await SharePlus.instance.share(
            ShareParams(title: r.title, files: [XFile(r.filePath)]),
          );
        } catch (_) {
          _showSnack('Could not share the file.');
        }
        break;
      case 'delete':
        await _confirmDelete(r);
        break;
    }
  }

  Future<void> _confirmDelete(DownloadRecord r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete?'),
        content: Text(
          'Remove "${r.title}" from history and delete the file if it still exists?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final file = File(r.filePath);
    var fileGone = true;
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      fileGone = false;
    }
    if (!fileGone) {
      _showSnack('Could not delete the file — the library entry was kept.');
      return;
    }
    final history = ref.read(historyServiceProvider);
    await history.remove(r.id);
  }
}
