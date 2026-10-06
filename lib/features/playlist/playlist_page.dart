import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/collection_kind.dart';
import '../../core/models/download_options.dart';
import '../../core/models/playlist_info.dart';
import '../../core/models/playlist_paging.dart';
import '../../core/models/settings_model.dart';
import '../../core/models/video_info.dart';
import '../../core/providers.dart';
import '../../core/utils/formatters.dart';
import '../../services/ytdlp/ytdlp_service.dart';

/// Lets the user pick which entries of a playlist or channel to download.
///
/// Reached from the Download tab when a link resolves to a collection. Each
/// selected entry becomes its own queue task, so the download manager's
/// per-video progress, retry and cancel all keep working and one unavailable
/// video cannot fail the rest.
///
/// A large collection arrives one [PlaylistPaging.sliceSize] slice at a time,
/// so this page can grow its own listing: "load more" fetches the next slice
/// and appends it, keeping the entries already selected selected.
class PlaylistPage extends ConsumerStatefulWidget {
  const PlaylistPage({super.key, required this.playlist});

  final PlaylistInfo playlist;

  @override
  ConsumerState<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends ConsumerState<PlaylistPage> {
  /// Ids of the selected entries. Keyed by id rather than index so the set
  /// survives the list being reordered, filtered, or extended by a new slice.
  late final Set<String> _selected = {
    for (final e in widget.playlist.entries) e.id,
  };

  /// The listing as it stands, which starts as the slice the fetch returned and
  /// grows as slices are loaded.
  ///
  /// Kept in state rather than read from [PlaylistPage.playlist] because the
  /// incoming playlist is the *first slice* and is immutable; merging into a
  /// copy here is what keeps the loaded pages from being thrown away on a
  /// rebuild.
  late PlaylistInfo _playlist = widget.playlist;

  bool _loadingMore = false;

  /// Why the last "load more" failed, or null when there is nothing to report.
  ///
  /// Kept inline rather than as a snackbar because the failure belongs to the
  /// button that caused it: the user needs to know the list is still short, and
  /// a snackbar that has already gone is no help after a long network timeout.
  String? _loadError;

  final TextEditingController _search = TextEditingController();
  String _query = '';

  FormatKind _kind = FormatKind.video;
  int? _tier;

  late bool _writeSubs;
  late bool _includeAuto;
  late bool _embedSubs;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsControllerProvider);
    // Seeded from the saved defaults, exactly like the single-video sheet, so
    // a changed default takes effect on the next playlist download too.
    _kind = settings.defaultAudioOnly ? FormatKind.audio : FormatKind.video;
    _tier = _kind == FormatKind.audio
        ? settings.defaultAudioTier
        : settings.defaultVideoTier;
    // Flat entries carry no per-video subtitle list, so there is no language
    // picker here: the batch runs with whatever the saved defaults ask for.
    _writeSubs = settings.defaultWriteSubs;
    _includeAuto = settings.defaultIncludeAutoSubs;
    // Embedding needs ffprobe, not just ffmpeg — see VideoInfo.canPostprocess.
    _embedSubs = widget.playlist.canPostprocess && settings.defaultEmbedSubs;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Fetches the next slice of a collection too large to arrive at once, and
  /// appends it.
  ///
  /// Only entries the source has not been asked for yet are added: a slice
  /// boundary can land on an entry that was already seen (yt-dlp re-reads the
  /// tab), and a duplicated row would make the picker show the same video twice
  /// and queue it twice.
  Future<void> _loadMore() async {
    if (_loadingMore) return;
    setState(() {
      _loadingMore = true;
      _loadError = null;
    });
    try {
      final slice = await ref
          .read(ytdlpServiceProvider)
          .fetchPlaylistSlice(
            url: _playlist.webUrl,
            start: _playlist.paging.nextStart,
            hasFfmpeg: _playlist.hasFfmpeg,
            canPostprocess: _playlist.canPostprocess,
          );
      if (!mounted) return;
      final seen = {for (final e in _playlist.entries) e.id};
      final fresh = slice.entries.where((e) => seen.add(e.id)).toList();
      setState(() {
        _playlist = _playlist.copyWith(
          entries: [..._playlist.entries, ...fresh],
          // Paging comes from the *merge*, not from the slice: the slice
          // measures only itself, and the cursor has to account for every
          // slice fetched so far.
          paging: _playlist.paging.appended(slice.paging),
        );
        // A newly listed video joins selected, because that is the page's rule
        // for every video it shows — the picker opens with the whole collection
        // selected. Leaving new entries unselected would mean "download
        // everything", the one shortcut this page exists to offer, silently
        // stops covering everything after the first page.
        _selected.addAll(fresh.map((e) => e.id));
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _loadError = e is YtdlpException
            ? e.message
            : 'Could not load more videos ($e)';
      });
    }
  }

  /// Entries matching the search box, in playlist order.
  List<VideoInfo> get _visible {
    final all = _playlist.entries;
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all
        .where(
          (e) =>
              e.title.toLowerCase().contains(q) ||
              (e.author ?? '').toLowerCase().contains(q),
        )
        .toList();
  }

  /// Every visible entry is selected — the common case after filtering.
  bool get _allVisibleSelected =>
      _visible.isNotEmpty && _visible.every((e) => _selected.contains(e.id));

  void _selectAllVisible({required bool selected}) {
    setState(() {
      for (final e in _visible) {
        if (selected) {
          _selected.add(e.id);
        } else {
          _selected.remove(e.id);
        }
      }
    });
  }

  void _toggle(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  Format get _format => switch (_kind) {
    FormatKind.video => videoFormatForTier(
      _tier,
      hasFfmpeg: widget.playlist.hasFfmpeg,
    ),
    FormatKind.audio => audioFormatForTier(_tier),
  };

  /// The selected entries in playlist order, not selection order.
  List<VideoInfo> get _chosen =>
      _playlist.entries.where((e) => _selected.contains(e.id)).toList();

  void _download() {
    final chosen = _chosen;
    if (chosen.isEmpty) return;
    // A batch is all-or-nothing for embed options: an audio download cannot
    // embed subtitles, so it is forced off the same way the single-video sheet
    // forces it. Mirror that in the UI so the switch state matches what runs.
    final options = DownloadOptions(
      writeSubs: _writeSubs,
      includeAutoSubs: _includeAuto,
      embedSubs: _kind == FormatKind.video && _embedSubs,
      // One derived value for the whole batch, since every entry shares a kind.
      embedThumb: DownloadOptions.coverArtDefault(_kind),
    );
    final count = chosen.length;
    ref
        .read(downloadManagerProvider)
        .enqueuePlaylist(
          // The merged listing, not the original slice: id, title and folder
          // come from the collection's own metadata and are identical either
          // way, but passing the slice would make the grouping depend on which
          // page the user happened to download from.
          playlist: _playlist,
          selected: chosen,
          format: _format,
          options: options,
        );
    context.go('/queue');
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            'Queued $count video${count == 1 ? '' : 's'} from '
            '"${_playlist.title}"',
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final playlist = _playlist;
    final visible = _visible;
    final chosenCount = _selected.length;

    return Scaffold(
      appBar: AppBar(
        title: Text(playlist.kind.label),
        actions: [
          IconButton(
            onPressed: () => _selectAllVisible(selected: !_allVisibleSelected),
            icon: Icon(_allVisibleSelected ? Icons.deselect : Icons.select_all),
            tooltip: _allVisibleSelected ? 'Clear selection' : 'Select all',
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              children: [
                _buildHeader(playlist),
                _buildOptions(playlist),
                _buildSearch(visible.length),
                const Divider(height: 1),
                Expanded(
                  child: visible.isEmpty
                      ? const _NoMatches()
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          // One extra row for the "load more" footer. Counting
                          // it only when there is something to load keeps the
                          // list exactly as tall as its entries otherwise, so
                          // the complete-playlist case is unchanged.
                          itemCount: visible.length + (_buildsLoadMore ? 1 : 0),
                          itemBuilder: (context, i) {
                            if (i >= visible.length) {
                              return _buildLoadMore();
                            }
                            final entry = visible[i];
                            return _EntryRow(
                              entry: entry,
                              selected: _selected.contains(entry.id),
                              onToggle: () => _toggle(entry.id),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: _buildBottomBar(chosenCount),
    );
  }

  Widget _buildHeader(PlaylistInfo playlist) {
    final theme = Theme.of(context);
    final notice = playlist.paging.truncationNotice(playlist.count);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            playlist.title,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            [
              CollectionKind.contentsLabel(playlist.count),
              if (playlist.uploader != null) playlist.uploader!,
              if (playlist.totalDuration > 0)
                formatPlaylistDuration(playlist.totalDuration),
            ].join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          // The count above counts what is *listed*. When the listing is a
          // slice, this says so next to it — a 200-video channel shown as
          // "200 videos" with no caveat reads as the whole channel, and the
          // user has no way to learn otherwise.
          if (notice != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 15,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      notice,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Whether the footer row is needed.
  ///
  /// Only when there is genuinely another slice to ask for, or when the last
  /// attempt failed and the user needs the button back.
  bool get _buildsLoadMore => _playlist.paging.hasMore || _loadError != null;

  Widget _buildLoadMore() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_loadError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _loadError!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          OutlinedButton.icon(
            // Disabled while in flight so a double tap cannot fire two
            // requests for the same slice and duplicate its entries.
            onPressed: _loadingMore ? null : _loadMore,
            icon: _loadingMore
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.expand_more),
            label: Text(_loadingMore ? 'Loading…' : 'Load more'),
          ),
        ],
      ),
    );
  }

  Widget _buildSearch(int visibleCount) {
    final theme = Theme.of(context);
    final total = _playlist.count;
    final filtered = visibleCount != total;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _search,
            onChanged: (v) => setState(() => _query = v),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 20),
              hintText: 'Filter videos',
              border: const OutlineInputBorder(),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        _search.clear();
                        setState(() => _query = '');
                      },
                    ),
            ),
          ),
          if (filtered)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 4),
              child: Text(
                'Showing $visibleCount of $total',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildOptions(PlaylistInfo playlist) {
    final canEmbed = playlist.canPostprocess;
    final isAudio = _kind == FormatKind.audio;
    final tiers = isAudio
        ? AppSettings.audioTierOptions
        : AppSettings.videoTierOptions;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<FormatKind>(
            segments: const [
              ButtonSegment(
                value: FormatKind.video,
                icon: Icon(Icons.videocam_outlined),
                label: Text('Video'),
              ),
              ButtonSegment(
                value: FormatKind.audio,
                icon: Icon(Icons.audiotrack_outlined),
                label: Text('Audio'),
              ),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() {
              _kind = s.first;
              // The tier menus hold different units, so reset to the matching
              // default rather than carrying a height into a bitrate cap.
              final settings = ref.read(settingsControllerProvider);
              _tier = _kind == FormatKind.audio
                  ? settings.defaultAudioTier
                  : settings.defaultVideoTier;
            }),
          ),
          const SizedBox(height: 10),
          // One quality row per tier. A batch has no per-video format data, so
          // these are the saved tiers rather than the source's real streams.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final tier in tiers)
                ChoiceChip(
                  label: Text(
                    isAudio
                        ? AppSettings.audioTierLabel(tier)
                        : AppSettings.videoTierLabel(tier),
                  ),
                  selected: _tier == tier,
                  onSelected: (_) => setState(() => _tier = tier),
                ),
            ],
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _writeSubs,
            onChanged: (v) => setState(() => _writeSubs = v),
            title: const Text('Save subtitles'),
            subtitle: Text(
              _includeAuto
                  ? 'Including auto-generated captions, all languages'
                  : 'Manually authored tracks, all languages',
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _includeAuto,
            onChanged: _writeSubs
                ? (v) => setState(() => _includeAuto = v)
                : null,
            title: const Text('Include auto-generated captions'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _embedSubs,
            // Audio cannot carry a subtitle track, and embedding needs ffprobe.
            onChanged: (!isAudio && canEmbed)
                ? (v) => setState(() => _embedSubs = v)
                : null,
            title: const Text('Embed subtitles'),
            subtitle: Text(
              isAudio
                  ? 'Only available for video downloads'
                  : canEmbed
                  ? 'Puts the subtitle track inside the file'
                  : 'Needs ffmpeg and ffprobe, which are not both available',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(int chosenCount) {
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
                  chosenCount == 0
                      ? 'Nothing selected'
                      : '$chosenCount selected',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              FilledButton.icon(
                onPressed: chosenCount == 0 ? null : _download,
                icon: const Icon(Icons.download),
                label: Text(
                  chosenCount == 1 ? 'Download 1' : 'Download $chosenCount',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.entry,
    required this.selected,
    required this.onToggle,
  });

  final VideoInfo entry;
  final bool selected;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CheckboxListTile(
      value: selected,
      onChanged: (_) => onToggle(),
      controlAffinity: ListTileControlAffinity.leading,
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      title: Text(
        entry.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium,
      ),
      subtitle: entry.duration > 0
          ? Text(
              formatDuration(entry.duration),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : null,
      secondary: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 72,
          height: 41,
          child: entry.thumbnail == null
              ? ColoredBox(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: const Icon(Icons.movie_outlined, size: 18),
                )
              : CachedNetworkImage(
                  imageUrl: entry.thumbnail!,
                  fit: BoxFit.cover,
                  placeholder: (_, _) => ColoredBox(
                    color: theme.colorScheme.surfaceContainerHighest,
                  ),
                  errorWidget: (_, _, _) => ColoredBox(
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: const Icon(Icons.broken_image_outlined, size: 18),
                  ),
                ),
        ),
      ),
    );
  }
}

class _NoMatches extends StatelessWidget {
  const _NoMatches();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'No videos match that filter',
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}
