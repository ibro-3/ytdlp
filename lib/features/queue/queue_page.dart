import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/models/download_task.dart';
import '../../core/models/video_info.dart';
import '../../core/providers.dart';
import '../../core/utils/formatters.dart';
import '../../services/downloads/download_manager.dart';

class QueuePage extends ConsumerWidget {
  const QueuePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(downloadManagerProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Queue'),
        actions: [
          AnimatedBuilder(
            animation: manager,
            builder: (context, _) => _QueueMenu(manager: manager),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: manager,
        builder: (context, _) {
          final tasks = manager.tasks;
          if (tasks.isEmpty) {
            return const _EmptyQueue();
          }
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                itemCount: tasks.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, i) {
                  final task = tasks[i];
                  // Reordering only means something for a task that is
                  // waiting, so the handles are offered only for those.
                  final canReorder = task.status == DownloadStatus.queued;
                  return _TaskCard(
                    task: task,
                    onMoveUp: canReorder
                        ? () => manager.reorder(task.id, -1)
                        : null,
                    onMoveDown: canReorder
                        ? () => manager.reorder(task.id, 1)
                        : null,
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Overflow menu: pause/resume, clear finished, cancel all.
class _QueueMenu extends StatelessWidget {
  const _QueueMenu({required this.manager});

  final DownloadManager manager;

  @override
  Widget build(BuildContext context) {
    final hasWork = manager.queuedCount + manager.activeCount > 0;
    final hasFinished = manager.finishedCount > 0;
    final parts = <String>[
      if (manager.activeCount > 0) '${manager.activeCount} active',
      if (manager.queuedCount > 0) '${manager.queuedCount} queued',
    ];

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The counts stay visible while paused — a paused queue still has
        // running work, and hiding the numbers would make it look empty.
        if (parts.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              parts.join(' · '),
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        if (manager.isPaused)
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: Chip(
              avatar: Icon(Icons.pause, size: 16),
              label: Text('Paused'),
              visualDensity: VisualDensity.compact,
            ),
          ),
        IconButton(
          onPressed: manager.tasks.isEmpty ? null : manager.togglePause,
          icon: Icon(manager.isPaused ? Icons.play_arrow : Icons.pause),
          tooltip: manager.isPaused ? 'Resume the queue' : 'Pause the queue',
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          onSelected: (v) => _onSelect(context, v),
          itemBuilder: (context) => [
            if (hasFinished)
              PopupMenuItem(
                value: 'clear',
                child: Text('Clear finished (${manager.finishedCount})'),
              ),
            if (hasWork)
              const PopupMenuItem(
                value: 'cancel_all',
                child: Text('Cancel all'),
              ),
          ],
        ),
      ],
    );
  }

  void _onSelect(BuildContext context, String value) {
    switch (value) {
      case 'clear':
        manager.clearFinished();
      case 'cancel_all':
        // Destructive enough to confirm: it kills in-flight downloads.
        _confirmCancelAll(context, manager);
    }
  }

  Future<void> _confirmCancelAll(
    BuildContext context,
    DownloadManager manager,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel all downloads?'),
        content: Text(
          manager.activeCount > 0
              ? '${manager.activeCount} running and '
                    '${manager.queuedCount} queued will be canceled. '
                    'Partial downloads are kept so you can retry them.'
              : '${manager.queuedCount} queued will be canceled.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep going'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancel all'),
          ),
        ],
      ),
    );
    if (ok == true) manager.cancelAll();
  }
}

class _EmptyQueue extends StatelessWidget {
  const _EmptyQueue();
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.download_done_outlined,
              size: 56,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              'Nothing downloading',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Text(
              'Add a video from the Download tab.',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskCard extends ConsumerWidget {
  const _TaskCard({required this.task, this.onMoveUp, this.onMoveDown});

  final DownloadTask task;

  /// Reorder handlers; null for a task that is not waiting in the queue.
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(downloadManagerProvider);
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    // Split apart because a waiting task and a running one need different
    // affordances: only a running one has progress to show or a process to
    // cancel.
    final isQueued = task.status == DownloadStatus.queued;
    final isRunning = task.status == DownloadStatus.downloading;
    final isDownloading = isQueued || isRunning;
    final isDone = task.status == DownloadStatus.completed;
    final isFailed = task.status == DownloadStatus.failed;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    task.format.kind == FormatKind.video
                        ? Icons.videocam_outlined
                        : Icons.audiotrack_outlined,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.video.title,
                        style: theme.textTheme.titleSmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        task.format.label,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      if (task.video.duration > 0)
                        Text(
                          formatDuration(task.video.duration),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      // A playlist entry says where it came from, since its
                      // file lands in that folder.
                      if (task.playlistTitle != null)
                        Text(
                          task.playlistTitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.primary,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // A waiting task has made no progress yet, so it shows a static
            // "Waiting" label rather than an indeterminate bar — an animating
            // spinner on a dozen queued items reads as twelve active
            // downloads, and it never settles.
            if (isQueued)
              Row(
                children: [
                  Icon(
                    Icons.schedule,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Waiting to start',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              )
            else if (isRunning) ...[
              LinearProgressIndicator(
                // Deterministic once yt-dlp reports any progress; indeterminate
                // only for the moment before the first line arrives.
                value: task.progress == 0 ? null : task.progress,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(
                    '${(task.progress * 100).toStringAsFixed(1)}%',
                    style: theme.textTheme.labelMedium,
                  ),
                  const SizedBox(width: 12),
                  if (task.speed != null)
                    Text(
                      task.speed!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  const Spacer(),
                  if (task.eta != null)
                    Text(
                      'ETA ${task.eta}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ] else if (isDone) ...[
              Row(
                children: [
                  Icon(Icons.check_circle, size: 16, color: scheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    'Completed',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.primary,
                    ),
                  ),
                  const Spacer(),
                  if (task.filePath != null)
                    Flexible(
                      child: Text(
                        p.basename(task.filePath!),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
              if (task.warning != null) ...[
                const SizedBox(height: 6),
                Text(
                  task.warning!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.tertiary,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ] else if (isFailed) ...[
              Row(
                children: [
                  Icon(Icons.error_outline, size: 16, color: scheme.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      task.error ?? 'Failed',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.error,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ] else if (task.status == DownloadStatus.canceled) ...[
              Text(
                'Canceled',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (isDownloading)
                  FilledButton.tonalIcon(
                    onPressed: () => manager.cancel(task.id),
                    icon: const Icon(Icons.close, size: 18),
                    label: const Text('Cancel'),
                  )
                else if (isDone) ...[
                  FilledButton.tonalIcon(
                    onPressed: () => _open(context, manager, task),
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('Open'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _share(context, manager, task),
                    icon: const Icon(Icons.share_outlined, size: 18),
                    label: const Text('Share'),
                  ),
                  IconButton(
                    onPressed: () => _delete(context, manager, task),
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Delete file',
                  ),
                ] else if (isFailed) ...[
                  FilledButton.tonalIcon(
                    onPressed: () => manager.retry(task),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Retry'),
                  ),
                  OutlinedButton(
                    onPressed: () => manager.dismiss(task.id),
                    child: const Text('Dismiss'),
                  ),
                ] else ...[
                  OutlinedButton(
                    onPressed: () => manager.dismiss(task.id),
                    child: const Text('Dismiss'),
                  ),
                ],
                // Reorder is only meaningful while a task is still waiting;
                // a running download has already been started.
                if (onMoveUp != null || onMoveDown != null) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: onMoveUp,
                    icon: const Icon(Icons.arrow_upward, size: 18),
                    tooltip: 'Move earlier in the queue',
                  ),
                  IconButton(
                    onPressed: onMoveDown,
                    icon: const Icon(Icons.arrow_downward, size: 18),
                    tooltip: 'Move later in the queue',
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _open(
    BuildContext context,
    DownloadManager manager,
    DownloadTask task,
  ) async {
    final ok = await manager.openTask(task);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Could not open the file (it may be missing).'),
          ),
        );
    }
  }

  Future<void> _share(
    BuildContext context,
    DownloadManager manager,
    DownloadTask task,
  ) async {
    final ok = await manager.shareTask(task);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Could not share the file.')),
        );
    }
  }

  Future<void> _delete(
    BuildContext context,
    DownloadManager manager,
    DownloadTask task,
  ) async {
    final ok = await manager.deleteTask(task);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text(
              'Could not delete the file — the library entry was kept.',
            ),
          ),
        );
    }
  }
}
