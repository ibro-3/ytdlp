import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/models/download_task.dart';
import '../../core/models/video_info.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme_context.dart';
import '../../core/utils/formatters.dart';
import '../../services/downloads/download_manager.dart';
import '../../widgets/app_full_width.dart';
import '../../widgets/platform/platform.dart';

class QueuePage extends ConsumerWidget {
  const QueuePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(downloadManagerProvider);
    return AppScaffold(
      title: 'Queue',
      actions: [
        // Flexible, so the menu yields width to the title on a narrow screen
        // instead of the toolbar overflowing. App bar actions are laid out at
        // their intrinsic width, so without this the counts plus two chips and
        // two buttons can exceed the bar.
        Flexible(
          child: AnimatedBuilder(
            animation: manager,
            builder: (context, _) => _QueueMenu(manager: manager),
          ),
        ),
      ],
      body: AnimatedBuilder(
        animation: manager,
        builder: (context, _) {
          final tasks = manager.tasks;
          if (tasks.isEmpty) {
            return const _EmptyQueue();
          }
          return AppFullWidth(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              itemCount: tasks.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, i) {
                final task = tasks[i];
                // Reordering only means something for a task that is
                // waiting. A held one is not: releasing it puts it at the
                // back of the queue, so its arrows would promise an ordering
                // the scheduler would not honour.
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
        // Flexible so the counts yield first on a narrow screen rather than
        // overflowing the app bar: the counts are the least urgent thing here.
        if (parts.isNotEmpty)
          Flexible(
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                parts.join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.textStyles.labelMedium,
              ),
            ),
          ),
        // Queue-wide and per-task holds are different things, so the chips say
        // which is in force rather than both just reading "Paused".
        if (manager.isPaused)
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: Chip(
              avatar: Icon(Icons.pause, size: 16),
              label: Text('All held'),
              visualDensity: VisualDensity.compact,
            ),
          )
        else if (manager.pausedCount > 0)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Chip(
              avatar: const Icon(Icons.pause, size: 16),
              label: Text('${manager.pausedCount} held'),
              visualDensity: VisualDensity.compact,
            ),
          ),
        IconButton(
          onPressed: manager.tasks.isEmpty ? null : manager.togglePause,
          icon: Icon(manager.isPaused ? Icons.play_arrow : Icons.pause),
          // Named as the *queue* explicitly, because each card now has its own
          // pause and the two are easy to confuse.
          tooltip: manager.isPaused
              ? 'Resume every held download'
              : 'Hold back everything still waiting',
        ),
        // Hidden rather than shown-and-empty: with nothing to clear and nothing to
        // cancel — every task dismissed, say — tapping the overflow opened a
        // blank sheet with no way out but the bar.
        if (hasFinished || hasWork)
          AppMenuButton<String>(
            icon: Icons.more_vert,
            tooltip: 'More queue actions',
            onSelected: (v) => _onSelect(context, v),
            items: [
              if (hasFinished)
                AppMenuItem(
                  value: 'clear',
                  label: 'Clear finished (${manager.finishedCount})',
                ),
              if (hasWork)
                const AppMenuItem(value: 'cancel_all', label: 'Cancel all'),
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
        unawaited(_confirmCancelAll(context, manager));
    }
  }

  Future<void> _confirmCancelAll(
    BuildContext context,
    DownloadManager manager,
  ) async {
    final ok = await showAppConfirm(
      context,
      title: 'Cancel all downloads?',
      message:
          // Paused tasks are included in the count, since cancelAll takes them
          // too — leaving them out would make the dialog understate the effect.
          '${[if (manager.activeCount > 0) '${manager.activeCount} running', if (manager.queuedCount > 0) '${manager.queuedCount} queued', if (manager.pausedCount > 0) '${manager.pausedCount} held'].join(' and ')} will be canceled. Partial downloads are kept so you '
          'can retry them.',
      confirmLabel: 'Cancel all',
      cancelLabel: 'Keep going',
      destructive: true,
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
    final scheme = context.colors;
    final theme = context.textStyles;

    // Split apart because a waiting task and a running one need different
    // affordances: only a running one has progress to show or a process to
    // cancel.
    final isQueued = task.status == DownloadStatus.queued;
    final isRunning = task.status == DownloadStatus.downloading;
    final isPaused = task.status == DownloadStatus.paused;
    final isDone = task.status == DownloadStatus.completed;
    final isFailed = task.status == DownloadStatus.failed;
    final isCanceled = task.status == DownloadStatus.canceled;

    return AppCard(
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
                      style: theme.titleSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      task.format.label,
                      style: theme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (task.video.duration > 0)
                      Text(
                        formatDuration(task.video.duration),
                        style: theme.labelSmall?.copyWith(
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
                        style: theme.labelSmall?.copyWith(
                          color: scheme.primary,
                        ),
                      ),
                  ],
                ),
              ),
              _buildActions(context, manager, task),
            ],
          ),
          const SizedBox(height: 12),
          // A waiting task has made no progress yet, so it shows a static
          // "Waiting" label rather than an indeterminate bar — an animating
          // spinner on a dozen queued items reads as twelve active
          // downloads, and it never settles.
          if (isPaused)
            Row(
              children: [
                Icon(Icons.pause, size: 14, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    // A held download keeps its progress: the .part file is
                    // still on disk, so resuming continues rather than
                    // starting over.
                    task.progress > 0
                        ? 'Paused at ${(task.progress * 100).toStringAsFixed(1)}%'
                        : 'Paused',
                    style: theme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            )
          else if (isQueued)
            Row(
              children: [
                Icon(Icons.schedule, size: 14, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(
                  'Waiting to start',
                  style: theme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            )
          else if (isRunning) ...[
            AppLinearProgress(
              // Deterministic once yt-dlp reports any progress; indeterminate
              // only for the moment before the first line arrives.
              value: task.progress == 0 ? null : task.progress,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  '${(task.progress * 100).toStringAsFixed(1)}%',
                  style: theme.labelMedium,
                ),
                const SizedBox(width: 12),
                if (task.speed != null)
                  Text(
                    task.speed!,
                    style: theme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                const Spacer(),
                if (task.eta != null)
                  Text(
                    'ETA ${task.eta}',
                    style: theme.labelSmall?.copyWith(
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
                  style: theme.labelMedium?.copyWith(color: scheme.primary),
                ),
                const Spacer(),
                if (task.filePath != null)
                  Flexible(
                    child: Text(
                      p.basename(task.filePath!),
                      style: theme.labelSmall?.copyWith(
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
                style: theme.labelSmall?.copyWith(color: scheme.tertiary),
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
                    style: theme.labelSmall?.copyWith(color: scheme.error),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ] else if (isCanceled) ...[
            Text(
              'Canceled',
              style: theme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }

  /// The card's action icons, in the top-right corner beside the title.
  ///
  /// Icon-only: these are per-task actions on a card that may be one of dozens
  /// in a list, and labelled buttons make a long queue mostly buttons. The
  /// tooltips carry the names, and the icons are distinct enough to read at a
  /// glance.
  ///
  /// Two rows rather than one, so a completed card (open, share, delete) and a
  /// queued one (pause, cancel, move up, move down) both fit a narrow phone
  /// without the row overflowing.
  Widget _buildActions(
    BuildContext context,
    DownloadManager manager,
    DownloadTask task,
  ) {
    final isQueued = task.status == DownloadStatus.queued;
    final isRunning = task.status == DownloadStatus.downloading;
    final isDownloading = isQueued || isRunning;
    final isPaused = task.status == DownloadStatus.paused;
    final isDone = task.status == DownloadStatus.completed;
    final isFailed = task.status == DownloadStatus.failed;
    final isCanceled = task.status == DownloadStatus.canceled;

    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isDownloading) ...[
                AppIconButton(
                  onPressed: () => manager.pauseTask(task.id),
                  icon: Icons.pause,
                  tooltip: 'Pause this download',
                ),
                AppIconButton(
                  onPressed: () => manager.cancel(task.id),
                  icon: Icons.close,
                  tooltip: 'Cancel this download',
                ),
              ] else if (isPaused) ...[
                AppIconButton(
                  onPressed: () => manager.resumeTask(task.id),
                  icon: Icons.play_arrow,
                  tooltip: 'Resume this download',
                ),
                AppIconButton(
                  onPressed: () => manager.cancel(task.id),
                  icon: Icons.close,
                  tooltip: 'Cancel this download',
                ),
              ] else if (isDone) ...[
                AppIconButton(
                  onPressed: () => _open(context, manager, task),
                  icon: Icons.play_arrow,
                  tooltip: 'Open the file',
                ),
                AppIconButton(
                  onPressed: () => _share(context, manager, task),
                  icon: Icons.share_outlined,
                  tooltip: 'Share the file',
                ),
                AppIconButton(
                  onPressed: () => _delete(context, manager, task),
                  icon: Icons.delete_outline,
                  tooltip: 'Delete file',
                ),
              ] else if (isFailed || isCanceled) ...[
                // Retry covers a canceled download too: its partial is kept,
                // so this continues rather than re-downloading.
                AppIconButton(
                  onPressed: () => manager.retry(task),
                  icon: Icons.refresh,
                  tooltip: 'Try again',
                ),
                AppIconButton(
                  onPressed: () => manager.dismiss(task.id),
                  icon: Icons.close,
                  tooltip: 'Remove from the queue',
                ),
              ] else
                AppIconButton(
                  onPressed: () => manager.dismiss(task.id),
                  icon: Icons.close,
                  tooltip: 'Remove from the queue',
                ),
            ],
          ),
          // Reorder is only meaningful while a task is still waiting; a running
          // download has already been started, so its arrows would promise an
          // ordering the scheduler would not honour.
          if (onMoveUp != null || onMoveDown != null)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIconButton(
                  onPressed: onMoveUp,
                  icon: Icons.arrow_upward,
                  tooltip: 'Move earlier in the queue',
                ),
                AppIconButton(
                  onPressed: onMoveDown,
                  icon: Icons.arrow_downward,
                  tooltip: 'Move later in the queue',
                ),
              ],
            ),
        ],
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
      context.showToast('Could not open the file (it may be missing).');
    }
  }

  Future<void> _share(
    BuildContext context,
    DownloadManager manager,
    DownloadTask task,
  ) async {
    final ok = await manager.shareTask(task);
    if (!ok && context.mounted) {
      context.showToast('Could not share the file.');
    }
  }

  Future<void> _delete(
    BuildContext context,
    DownloadManager manager,
    DownloadTask task,
  ) async {
    final ok = await manager.deleteTask(task);
    if (!ok && context.mounted) {
      // False means the file could not be removed: `deleteTask` returns before
      // touching the task or its history record, so nothing is lost — the card
      // and its library entry are both still there. The old copy-pasted text
      // ("the library entry was kept") implied the card went away; it did not.
      context.showToast('Could not delete the download.');
    }
  }
}
