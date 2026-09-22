import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/download_task.dart';
import '../../core/models/video_info.dart';
import '../../core/providers.dart';
import '../../core/utils/formatters.dart';

class QueuePage extends ConsumerWidget {
  const QueuePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(downloadManagerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Queue')),
      body: AnimatedBuilder(
        animation: manager,
        builder: (context, _) {
          final tasks = manager.tasks;
          if (tasks.isEmpty) {
            return const _EmptyQueue();
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            itemCount: tasks.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, i) => _TaskCard(task: tasks[i]),
          );
        },
      ),
    );
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
            Icon(Icons.download_done_outlined,
                size: 56, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('Nothing downloading',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Text('Add a video from the Download tab.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class _TaskCard extends ConsumerWidget {
  const _TaskCard({required this.task});
  final DownloadTask task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(downloadManagerProvider);
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    final isDownloading = task.status == DownloadStatus.downloading ||
        task.status == DownloadStatus.queued;
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
                      Text(task.video.title,
                          style: theme.textTheme.titleSmall,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 2),
                      Text(task.format.label,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant)),
                      if (task.video.duration > 0)
                        Text(formatDuration(task.video.duration),
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (isDownloading) ...[
              LinearProgressIndicator(
                  value: task.progress == 0 ? null : task.progress),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text('${(task.progress * 100).toStringAsFixed(1)}%',
                      style: theme.textTheme.labelMedium),
                  const SizedBox(width: 12),
                  if (task.speed != null)
                    Text(task.speed!,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.onSurfaceVariant)),
                  const Spacer(),
                  if (task.eta != null)
                    Text('ETA ${task.eta}',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ] else if (isDone) ...[
              Row(
                children: [
                  Icon(Icons.check_circle, size: 16, color: scheme.primary),
                  const SizedBox(width: 6),
                  Text('Completed',
                      style: theme.textTheme.labelMedium
                          ?.copyWith(color: scheme.primary)),
                  const Spacer(),
                  if (task.filePath != null)
                    Flexible(
                      child: Text(task.filePath!.split('/').last,
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                ],
              ),
            ] else if (isFailed) ...[
              Row(
                children: [
                  Icon(Icons.error_outline, size: 16, color: scheme.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(task.error ?? 'Failed',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.error),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ] else if (task.status == DownloadStatus.canceled) ...[
              Text('Canceled',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: scheme.onSurfaceVariant)),
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
                    onPressed: () => manager.openTask(task),
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('Open'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => manager.shareTask(task),
                    icon: const Icon(Icons.share_outlined, size: 18),
                    label: const Text('Share'),
                  ),
                  IconButton(
                    onPressed: () => manager.deleteTask(task),
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
              ],
            ),
          ],
        ),
      ),
    );
  }
}
