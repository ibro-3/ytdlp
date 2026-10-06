import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/download_options.dart';
import '../../core/models/playlist_info.dart';
import '../../core/models/settings_model.dart';
import '../../core/models/video_info.dart';
import '../../core/providers.dart';
import '../../core/utils/formatters.dart';
import 'batch_queue_controller.dart';

/// Queue several links at once.
///
/// Reached when a paste or a share contains more than one URL. Each link is
/// resolved independently, so one unavailable video shows its own error and the
/// rest still queue.
class BatchQueuePage extends ConsumerStatefulWidget {
  const BatchQueuePage({super.key});

  @override
  ConsumerState<BatchQueuePage> createState() => _BatchQueuePageState();
}

class _BatchQueuePageState extends ConsumerState<BatchQueuePage> {
  final Set<String> _selected = {};

  /// Enqueues every selected, resolved video with one shared quality choice.
  ///
  /// A batch has no per-video format list to pick from, so the quality comes
  /// from one chip row rather than a per-item picker — the same approach the
  /// playlist picker takes. Extra arguments and the file name template come
  /// from Settings, as they do for a single download.
  Future<void> _downloadAll(List<VideoInfo> videos) async {
    if (videos.isEmpty) return;
    final settings = ref.read(settingsControllerProvider);
    final quality = await showModalBottomSheet<_BatchQuality>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (context) => _BatchQualitySheet(settings: settings),
    );
    if (quality == null || !mounted) return;

    final manager = ref.read(downloadManagerProvider);
    for (final video in videos) {
      manager.enqueue(
        video: video,
        format: quality.format,
        options: quality.options,
      );
    }
    if (!mounted) return;
    context.go('/queue');
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text('Queued ${videos.length} download(s)')),
      );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(batchQueueControllerProvider);
    final selectedVideos = [
      for (final item in state.items)
        if (item.video != null && _selected.contains(item.url)) item.video!,
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Queue links'),
        actions: [
          IconButton(
            onPressed: () =>
                ref.read(batchQueueControllerProvider.notifier).clear(),
            icon: const Icon(Icons.clear_all),
            tooltip: 'Clear the list',
          ),
        ],
      ),
      body: state.total == 0
          ? const _NothingToDo()
          : Column(
              children: [
                _buildSelectionBar(state, selectedVideos),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    itemCount: state.items.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) => _BatchRow(
                      item: state.items[i],
                      selected: _selected.contains(state.items[i].url),
                      onToggle: () => setState(() {
                        final url = state.items[i].url;
                        if (!_selected.remove(url)) _selected.add(url);
                      }),
                      onRetry: () => ref
                          .read(batchQueueControllerProvider.notifier)
                          .retryOne(i),
                      onRemove: () => _removeAt(state, i),
                      onOpenPlaylist: (playlist) =>
                          context.push('/download/playlist', extra: playlist),
                    ),
                  ),
                ),
              ],
            ),
      bottomNavigationBar: state.total == 0
          ? null
          : _buildBottomBar(state, selectedVideos),
    );
  }

  /// Drops one row, keeping the selection set in step.
  ///
  /// Without this the only way to get rid of a single bad link in a large paste
  /// was to clear the whole list, losing every good one alongside it.
  void _removeAt(BatchState state, int index) {
    final url = state.items[index].url;
    ref.read(batchQueueControllerProvider.notifier).removeAt(index);
    setState(() => _selected.remove(url));
  }

  Widget _buildSelectionBar(BatchState state, List<VideoInfo> selected) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              state.isResolving
                  ? 'Fetching details… ${state.ready}/${state.total}'
                  : '${state.ready} of ${state.total} ready'
                        '${state.failed > 0 ? ' · ${state.failed} failed' : ''}',
              style: theme.textTheme.bodySmall,
            ),
          ),
          TextButton(
            onPressed: () => setState(() {
              if (_selected.length == state.videos.length) {
                _selected.clear();
              } else {
                _selected
                  ..clear()
                  ..addAll(state.videos.map((v) => v.webUrl));
              }
            }),
            child: Text(
              _selected.length == state.videos.length && state.videos.isNotEmpty
                  ? 'Select none'
                  : 'Select all',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(BatchState state, List<VideoInfo> selected) {
    final theme = Theme.of(context);
    return Material(
      elevation: 3,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${selected.length} selected',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              FilledButton.icon(
                onPressed: selected.isEmpty
                    ? null
                    : () => _downloadAll(selected),
                icon: const Icon(Icons.download),
                label: Text(
                  selected.length == 1
                      ? 'Download 1'
                      : 'Download ${selected.length}',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The single quality + extras choice applied to a whole batch.
class _BatchQuality {
  const _BatchQuality({required this.format, required this.options});
  final Format format;
  final DownloadOptions options;
}

class _BatchQualitySheet extends StatefulWidget {
  const _BatchQualitySheet({required this.settings});
  final AppSettings settings;

  @override
  State<_BatchQualitySheet> createState() => _BatchQualitySheetState();
}

class _BatchQualitySheetState extends State<_BatchQualitySheet> {
  late FormatKind _kind;
  late int? _tier;
  late bool _writeSubs;

  @override
  void initState() {
    super.initState();
    _kind = widget.settings.defaultAudioOnly
        ? FormatKind.audio
        : FormatKind.video;
    _tier = _kind == FormatKind.audio
        ? widget.settings.defaultAudioTier
        : widget.settings.defaultVideoTier;
    _writeSubs = widget.settings.defaultWriteSubs;
  }

  String _tierLabel(int? tier) => _kind == FormatKind.audio
      ? AppSettings.audioTierLabel(tier)
      : AppSettings.videoTierLabel(tier);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tiers = _kind == FormatKind.audio
        ? AppSettings.audioTierOptions
        : AppSettings.videoTierOptions;
    final format = _kind == FormatKind.audio
        ? audioFormatForTier(_tier)
        : videoFormatForTier(_tier, hasFfmpeg: true);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Quality for all', style: theme.textTheme.titleMedium),
            const SizedBox(height: 16),
            SegmentedButton<FormatKind>(
              segments: const [
                ButtonSegment(
                  value: FormatKind.video,
                  label: Text('Video'),
                  icon: Icon(Icons.videocam_outlined),
                ),
                ButtonSegment(
                  value: FormatKind.audio,
                  label: Text('Audio'),
                  icon: Icon(Icons.audiotrack_outlined),
                ),
              ],
              selected: {_kind},
              onSelectionChanged: (s) => setState(() {
                _kind = s.first;
                _tier = _kind == FormatKind.audio
                    ? widget.settings.defaultAudioTier
                    : widget.settings.defaultVideoTier;
              }),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final tier in tiers)
                  ChoiceChip(
                    label: Text(_tierLabel(tier)),
                    selected: _tier == tier,
                    onSelected: (_) => setState(() => _tier = tier),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Save subtitles'),
              value: _writeSubs,
              onChanged: (v) => setState(() => _writeSubs = v),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => Navigator.pop(
                  context,
                  _BatchQuality(
                    format: format,
                    options: DownloadOptions(
                      writeSubs: _writeSubs,
                      // Derived, matching the single-video sheet: audio links
                      // get cover art, video links do not.
                      embedThumb: DownloadOptions.coverArtDefault(_kind),
                    ),
                  ),
                ),
                icon: const Icon(Icons.check),
                label: const Text('Use this for all'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One link's state in the batch list.
class _BatchRow extends StatelessWidget {
  const _BatchRow({
    required this.item,
    required this.selected,
    required this.onToggle,
    required this.onRetry,
    required this.onRemove,
    required this.onOpenPlaylist,
  });

  final BatchItem item;
  final bool selected;
  final VoidCallback onToggle;
  final VoidCallback onRetry;

  /// Drops this row. Available for every state, so one bad link does not mean
  /// clearing the whole paste.
  final VoidCallback onRemove;

  /// Opens the playlist picker for a link that turned out to be a playlist.
  final ValueChanged<PlaylistInfo> onOpenPlaylist;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListTile(
      // An unresolved row is not selectable, so it says why rather than
      // presenting a checkbox that silently does nothing. `Tooltip` wrapping the
      // whole thing, because `Checkbox` itself has no `tooltip` parameter.
      leading: item.video == null
          ? Tooltip(
              message: 'Resolve this link first',
              child: Checkbox(value: selected, onChanged: null),
            )
          : Checkbox(
              value: selected,
              onChanged: (_) => onToggle(),
            ),
      title: Text(
        item.video?.title ?? item.url,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium,
      ),
      subtitle: _buildSubtitle(theme, scheme),
      trailing: _buildTrailing(scheme),
    );
  }

  Widget _buildSubtitle(ThemeData theme, ColorScheme scheme) {
    if (item.status == BatchItemStatus.loading) {
      return const LinearProgressIndicator();
    }
    if (item.error != null) {
      return Text(
        item.error!,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
      );
    }
    if (item.isPlaylist) {
      return Text(
        'Playlist · ${item.playlist!.count} videos — choose which to get',
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      );
    }
    final video = item.video;
    // `pending` is an unresolved URL with nothing in flight: the only way to get
    // here is clearing a batch mid-resolve, which keeps the still-loading rows
    // without a fetch. Forcing the null would throw on a perfectly ordinary state.
    if (video == null) {
      return Text(
        'Not resolved yet',
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      );
    }
    return Text(
      [
        if (video.author != null) video.author,
        if (video.duration > 0) formatDuration(video.duration),
        '${video.videoFormats.length} video / ${video.audioFormats.length} audio',
      ].join(' · '),
      style: theme.textTheme.bodySmall?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    );
  }

  Widget _buildTrailing(ColorScheme scheme) {
    // Remove is offered first and unconditionally, so a bad link can be dropped
    // whatever its state. Everything after it is a second action, which is why
    // this is a row of buttons rather than a single trailing slot.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: onRemove,
          icon: const Icon(Icons.close),
          tooltip: 'Remove this link',
        ),
        if (item.error != null)
          IconButton(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            tooltip: 'Try again',
          )
        else if (item.playlist case final playlist?)
          IconButton(
            onPressed: () => onOpenPlaylist(playlist),
            icon: const Icon(Icons.playlist_play),
            tooltip: 'Choose videos from this playlist',
          )
        else if (item.status != BatchItemStatus.loading)
          _buildThumbnail(scheme),
      ],
    );
  }

  /// Non-null so it can sit in a `Row`'s children directly.
  ///
  /// A null return would need a spread or a filter in the caller, and the
  /// `if/else if` chain in [_buildTrailing] has to produce one element per
  /// branch — an `if` element without an `else` would silently drop it.
  Widget _buildThumbnail(ColorScheme scheme) {
    final video = item.video;
    if (video == null) return const SizedBox.shrink();
    final thumb = video.thumbnail;
    if (thumb == null) {
      return Icon(
        video.videoFormats.isNotEmpty
            ? Icons.videocam_outlined
            : Icons.audiotrack_outlined,
        color: scheme.onSurfaceVariant,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 64,
        height: 38,
        child: CachedNetworkImage(
          imageUrl: thumb,
          fit: BoxFit.cover,
          errorWidget: (_, _, _) =>
              ColoredBox(color: scheme.surfaceContainerHighest),
        ),
      ),
    );
  }
}

class _NothingToDo extends StatelessWidget {
  const _NothingToDo();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.playlist_add, size: 56, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              'No links to queue',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Text(
              'Paste several links on the Download tab to queue them together.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
