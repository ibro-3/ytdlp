import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/models/download_record.dart';
import '../../core/models/library_filter.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme_context.dart';
import '../../core/utils/formatters.dart';
import '../../services/downloads/folder_scanner.dart';
import '../../services/downloads/history_service.dart';
import '../../widgets/app_full_width.dart';
import '../../widgets/platform/platform.dart';

class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key, this.probeExists});

  /// The existence probe, injectable so the batching can be asserted.
  ///
  /// Follows the seam pattern the rest of the app uses (`downloadsDirProvider`,
  /// `cookieSupportDirProvider`, `ForegroundService.forTesting`): the thing that
  /// talks to the platform is a parameter, so a test can count the calls rather
  /// than infer them from the screen. Production leaves this null and gets the
  /// real filesystem.
  final Future<bool> Function(String path)? probeExists;

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage>
    with WidgetsBindingObserver {
  /// Async existence cache so rows don't stat the filesystem in `build`.
  final Map<String, bool> _exists = {};

  /// The set of paths the current page has already probed.
  ///
  /// This is what makes the check re-runnable rather than once-per-process:
  /// [_scheduleExistenceCheck] compares the paths the view now shows against it
  /// and re-probes when they differ. A set that was only ever added to — as this
  /// was — meant a file deleted while the page sat open kept showing as present
  /// for the rest of the session, and tapping Open on it failed.
  Set<String> _probed = {};

  /// Guards against scheduling a probe pass more than once per frame.
  bool _probeScheduled = false;

  final TextEditingController _search = TextEditingController();
  String _query = '';
  LibraryFilter _filter = LibraryFilter.all;
  LibrarySort _sort = LibrarySort.newest;
  LibraryGrouping _grouping = LibraryGrouping.none;

  /// Files found in the download folder that the library has no record of.
  /// Null until a scan has run, so "not scanned" is distinguishable from
  /// "scanned and found nothing".
  List<DiscoveredFile>? _discovered;
  bool _scanning = false;

  /// Why the last scan failed, if it did. Null after a successful one.
  String? _scanError;

  @override
  void initState() {
    super.initState();
    // Files leave the library from outside the app — a file manager, another
    // app, a computer over MTP — and the tab stays alive inside the shell's
    // indexed stack, so nothing else would ever notice.
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _search.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the foreground is the one moment a whole batch of deletions
    // has plausibly happened, so the whole cache is worth throwing away then —
    // and only then, since re-probing on every rebuild would undo the batching.
    if (state == AppLifecycleState.resumed) _refreshExistence();
  }

  /// Reads the cached answer, defaulting to "present".
  ///
  /// A pure read: the probing is scheduled from [_scheduleExistenceCheck]
  /// after the frame, never spawned here. Spawning it from `build` fired one
  /// `File.exists` and one `setState` per row, so the first frame of a large
  /// library caused that many full list rebuilds.
  bool _existsFor(String path) => _exists[path] ?? true;

  /// Probes every path in [paths], in one pass, once the frame is done.
  ///
  /// Deduplicated and batched: the results land in a single `setState`, so a
  /// library of N rows costs one rebuild rather than N. A path whose answer is
  /// already cached is skipped, which keeps the repeated calls from `build`
  /// (a filter change, a search keystroke, a history notification) cheap.
  ///
  /// Returns early when the set is unchanged, which is what lets this be called
  /// unconditionally from `build` instead of from an effect that would have to
  /// mirror every way the view can change.
  void _scheduleExistenceCheck(List<String> paths) {
    final wanted = paths.where((p) => p.isNotEmpty).toSet();
    if (setEquals(wanted, _probed)) return;
    _probed = wanted;
    if (_probeScheduled) return;
    _probeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _probeScheduled = false;
      if (!mounted) return;
      unawaited(_probeExistence(wanted));
    });
  }

  Future<void> _probeExistence(Set<String> wanted) async {
    final probe = widget.probeExists ?? (path) => File(path).exists();
    final results = <String, bool>{};
    // Sequential rather than parallel on purpose: an unbounded fan-out of
    // hundreds of `stat` syscalls at once is what makes a large library stall,
    // and these are microseconds each.
    for (final path in wanted) {
      if (_exists.containsKey(path)) {
        results[path] = _exists[path]!;
        continue;
      }
      try {
        results[path] = await probe(path);
      } catch (_) {
        results[path] = false;
      }
    }
    if (!mounted) return;
    setState(() => _exists.addAll(results));
  }

  /// Re-runs the existence check, discarding what was cached.
  ///
  /// Called when something outside the app may have changed the files: adopting
  /// a scanned file, and coming back to the foreground. Without this the first
  /// answer would stand for the life of the process.
  ///
  /// Both maps have to go, not just the "already probed" set: the probe pass
  /// reuses whatever answer [_exists] still holds, so clearing one and not the
  /// other would leave the stale value exactly where it was.
  ///
  /// Rebuilds too, because clearing the set changes nothing on screen until
  /// [build] runs again — and `build` is what schedules the probe.
  void _refreshExistence() {
    if (!mounted) return;
    setState(() {
      _probed = {};
      _exists.clear();
    });
  }

  void _patch(void Function() fn) => setState(fn);

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(historyServiceProvider);
    return AppScaffold(
      title: 'Library',
      actions: [
        if (history.records.isNotEmpty)
          AppIconButton(
            onPressed: _scanning ? null : _scanFolder,
            icon: Icons.drive_folder_upload_outlined,
            tooltip: 'Find files in the download folder',
          ),
        if (history.records.isNotEmpty)
          AppMenuButton<String>(
            icon: Icons.sort,
            tooltip: 'Sort and group',
            onSelected: _applyViewOption,
            items: [
              for (final s in LibrarySort.values)
                AppMenuItem(
                  value: 'sort:${s.name}',
                  label: s.label,
                  checked: _sort == s,
                ),
              for (final f in LibraryFilter.values)
                AppMenuItem(
                  value: 'filter:${f.name}',
                  label: f.label,
                  checked: _filter == f,
                ),
              for (final g in LibraryGrouping.values)
                AppMenuItem(
                  value: 'group:${g.name}',
                  label: g.label,
                  checked: _grouping == g,
                ),
            ],
          ),
        if (history.records.isNotEmpty)
          AppIconButton(
            icon: Icons.delete_sweep_outlined,
            tooltip: 'Clear history',
            onPressed: () => _confirmClearHistory(history),
          ),
      ],
      body: AnimatedBuilder(
        animation: history,
        builder: (context, _) {
          final all = history.records;
          if (all.isEmpty) {
            return const _EmptyLibrary();
          }
          final view = buildLibraryView(
            records: all,
            query: _query,
            filter: _filter,
            sort: _sort,
            grouping: _grouping,
          );
          if (view.isEmpty) {
            return _NoMatches(query: _query, onClear: _clearFilters);
          }
          final rows = _rowsFor(view);
          // Scheduled rather than fired from the builder: the paths are now
          // collected and probed in one pass after the frame.
          _scheduleExistenceCheck([
            for (final row in rows)
              if (row is _RecordRow) row.record.filePath,
          ]);
          return Column(
            children: [
              _buildSearchBar(view),
              if (_scanError != null)
                _ScanErrorBanner(
                  message: _scanError!,
                  onRetry: _scanning ? null : _scanFolder,
                )
              else if (_discovered != null && _discovered!.isNotEmpty)
                _DiscoveredBanner(files: _discovered!, onAdopt: _adopt),
              Expanded(
                child: AppFullWidth(
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    itemCount: rows.length,
                    itemBuilder: (context, i) => switch (rows[i]) {
                      _HeaderRow(:final group) => _PlaylistHeader(group: group),
                      _RecordRow(:final record) => _RecordCard(
                        record: record,
                        exists: _existsFor(record.filePath),
                      ),
                      _SpacerRow() => const SizedBox(height: 8),
                    },
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Flattens [view] into the rows the list renders.
  ///
  /// Data rather than widgets so the list can be lazy: a builder that only
  /// materialises the rows on screen. The previous shape built every row
  /// eagerly — and with each one a `cached_network_image` and its own existence
  /// probe — which is what made a large library slow to open.
  static List<_Row> _rowsFor(LibraryView view) => [
    for (final group in view.groups) ...[
      _HeaderRow(group),
      for (final r in group.records) _RecordRow(r),
      const _SpacerRow(),
    ],
    for (final r in view.loose) _RecordRow(r),
  ];

  /// Scans the download folder for media the library does not know about.
  ///
  /// Read-only: a discovered file is offered, never added to history
  /// automatically, so "Clear history" stays a real reset.
  Future<void> _scanFolder() async {
    setState(() {
      _scanning = true;
      _scanError = null;
    });
    try {
      final root = await ref.read(downloadsDirProvider)();
      final known = {
        for (final r in ref.read(historyServiceProvider).records) r.filePath,
      };
      final found = await const FolderScanner().scan(
        root: root,
        knownPaths: known,
      );
      if (!mounted) return;
      setState(() {
        _discovered = found;
        _scanning = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // Reported rather than silently shown as "nothing found": an unreadable
        // folder and an empty one look identical otherwise, and the user has no
        // reason to go looking for the difference.
        _discovered = const [];
        _scanError = 'Could not scan the download folder: $e';
        _scanning = false;
      });
    }
  }

  /// Adds a discovered file to the library so it can be opened and shared like
  /// any other download.
  Future<void> _adopt(DiscoveredFile file) async {
    try {
      final stat = await File(file.path).stat();
      await ref
          .read(historyServiceProvider)
          .add(
            DownloadRecord(
              // Derived from the path, so re-scanning cannot create a
              // duplicate for a file that is already there.
              id: 'ext-${file.path.hashCode.toUnsigned(32)}',
              videoId: '',
              title: file.guessedTitle,
              filePath: file.path,
              size: stat.size,
              createdAt: stat.modified,
            ),
          );
      if (!mounted) return;
      setState(() {
        // Adopted files leave the "new" list: they are in the library now.
        _discovered = [
          for (final f in _discovered ?? const <DiscoveredFile>[])
            if (f.path != file.path) f,
        ];
      });
      // The new row is already known to exist — it was just adopted — but the
      // scanner may have found several, and a previously missing file that has
      // since been restored by something outside the app is worth catching here
      // too. Throwing the cache away re-probes the whole view in one pass.
      _refreshExistence();
      _showSnack('Added to the library');
    } catch (_) {
      _showSnack('Could not add that file to the library');
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    context.showToast(message);
  }

  void _clearFilters() {
    _search.clear();
    setState(() {
      _query = '';
      _filter = LibraryFilter.all;
      _grouping = LibraryGrouping.none;
    });
  }

  /// Applies one of the sort/filter/group menu values, which are encoded as
  /// `kind:name` so a single menu handler can cover all three enums.
  void _applyViewOption(String value) {
    final parts = value.split(':');
    if (parts.length != 2) return;
    setState(() {
      // Each lookup falls back to the current value. The names come from the
      // enums themselves so they cannot normally disagree, but `byName` throws
      // outright on an unknown name, and a persisted view option written by a
      // different build is exactly the case that would then crash the tab.
      switch (parts[0]) {
        case 'sort':
          _sort = _byName(LibrarySort.values, parts[1], _sort);
        case 'filter':
          _filter = _byName(LibraryFilter.values, parts[1], _filter);
        case 'group':
          _grouping = _byName(LibraryGrouping.values, parts[1], _grouping);
      }
    });
  }

  /// [names] entry matching [name], or [fallback] when there is none.
  static T _byName<T extends Enum>(List<T> names, String name, T fallback) {
    for (final candidate in names) {
      if (candidate.name == name) return candidate;
    }
    return fallback;
  }

  Widget _buildSearchBar(LibraryView view) {
    final theme = context.textStyles;
    final scheme = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        children: [
          AppTextField(
            controller: _search,
            placeholder: 'Search downloads',
            onChanged: (v) => _patch(() => _query = v),
            prefix: const Icon(Icons.search, size: 20),
            suffix: _query.isEmpty
                ? null
                : AppIconButton(
                    icon: Icons.close,
                    tooltip: 'Clear search',
                    onPressed: () => _patch(() {
                      _search.clear();
                      _query = '';
                    }),
                  ),
          ),
          const SizedBox(height: 8),
          // A running total, so a filter that hides most of the library is
          // obvious rather than looking like data loss.
          Row(
            children: [
              Expanded(
                child: Text(
                  view.total == 1
                      ? '1 download'
                      : '${view.total} downloads · ${formatBytes(view.totalSize)}',
                  style: theme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              for (final f in LibraryFilter.values)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: AppChoiceChip(
                    label: f.label,
                    selected: _filter == f,
                    onSelected: (_) => _patch(() => _filter = f),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClearHistory(HistoryService history) async {
    final ok = await showAppConfirm(
      context,
      title: 'Clear history?',
      message:
          'This removes all entries from the library list. Files on disk are '
          'not deleted.',
      confirmLabel: 'Clear',
    );
    if (ok == true) await history.clear();
  }
}

/// One download in the library, with its actions behind a popup menu.
/// One row of the library list: a section header, a download, or the gap
/// after a section.
///
/// Sealed so the builder's pattern match is exhaustive and adding a row kind
/// is a compile error rather than a silently unstyled one.
sealed class _Row {
  const _Row();
}

class _HeaderRow extends _Row {
  const _HeaderRow(this.group);
  final PlaylistGroup group;
}

class _RecordRow extends _Row {
  const _RecordRow(this.record);
  final DownloadRecord record;
}

class _SpacerRow extends _Row {
  const _SpacerRow();
}

class _RecordCard extends StatelessWidget {
  const _RecordCard({required this.record, required this.exists});

  final DownloadRecord record;
  final bool exists;

  @override
  Widget build(BuildContext context) {
    final theme = context.textStyles;
    final scheme = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 72,
                height: 48,
                child: record.thumbnail == null
                    ? ColoredBox(
                        color: scheme.surfaceContainerHighest,
                        child: Icon(
                          isAudioRecord(record)
                              ? Icons.audiotrack_outlined
                              : Icons.movie_outlined,
                          size: 24,
                        ),
                      )
                    : CachedNetworkImage(
                        imageUrl: record.thumbnail!,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) => ColoredBox(
                          color: scheme.surfaceContainerHighest,
                          child: const Icon(Icons.broken_image_outlined),
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
                    record.title,
                    style: theme.titleSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (record.author != null) record.author!,
                      formatDate(record.createdAt),
                      if (record.size > 0) formatBytes(record.size),
                      if (!exists) 'file missing',
                    ].join(' · '),
                    style: theme.labelSmall?.copyWith(
                      color: exists ? scheme.onSurfaceVariant : scheme.error,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _RecordMenu(record: record),
          ],
        ),
      ),
    );
  }
}

/// Actions for one library entry. A separate widget so each row's menu is its
/// own, rather than rebuilt for every row on every history change.
class _RecordMenu extends ConsumerWidget {
  const _RecordMenu({required this.record});

  final DownloadRecord record;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppMenuButton<String>(
      icon: Icons.more_vert,
      tooltip: 'Actions',
      onSelected: (v) => _handle(context, ref, v),
      items: const [
        AppMenuItem(value: 'open', label: 'Open'),
        AppMenuItem(value: 'share', label: 'Share'),
        AppMenuItem(value: 'delete', label: 'Delete'),
      ],
    );
  }

  Future<void> _handle(
    BuildContext context,
    WidgetRef ref,
    String action,
  ) async {
    switch (action) {
      case 'open':
        if (!await File(record.filePath).exists()) {
          if (context.mounted) {
            _notify(context, 'This file is no longer on the device.');
          }
          return;
        }
        try {
          await OpenFilex.open(record.filePath);
        } catch (_) {
          if (context.mounted) _notify(context, 'Could not open the file.');
        }
      case 'share':
        if (!await File(record.filePath).exists()) {
          if (context.mounted) {
            _notify(context, 'This file is no longer on the device.');
          }
          return;
        }
        try {
          await SharePlus.instance.share(
            ShareParams(title: record.title, files: [XFile(record.filePath)]),
          );
        } catch (_) {
          if (context.mounted) _notify(context, 'Could not share the file.');
        }
      case 'delete':
        if (await _confirm(context) == true && context.mounted) {
          await _deleteFile(context, ref);
        }
    }
  }

  /// Same as the page's own [_showSnack], but for a caller holding a
  /// `BuildContext` rather than the page's State — a row's own menu. Two
  /// identical helpers in one file is exactly the drift this replaces.
  static void _notify(BuildContext context, String message) {
    if (!context.mounted) return;
    context.showToast(message);
  }

  Future<bool?> _confirm(BuildContext context) {
    return showAppConfirm(
      context,
      title: 'Delete?',
      message:
          'Remove "${record.title}" from history and delete the file if it '
          'still exists?',
      confirmLabel: 'Delete',
      destructive: true,
    );
  }

  Future<void> _deleteFile(BuildContext context, WidgetRef ref) async {
    final file = File(record.filePath);
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // The record is kept, because it still points at a real file.
      if (context.mounted) {
        _notify(
          context,
          'Could not delete the file — the library entry was kept.',
        );
      }
      return;
    }
    await ref.read(historyServiceProvider).remove(record.id);
  }
}

/// Header for a playlist section, with its entry count and total size.
class _PlaylistHeader extends StatelessWidget {
  const _PlaylistHeader({required this.group});

  final PlaylistGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = context.textStyles;
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: Row(
        children: [
          Icon(Icons.playlist_play, size: 18, color: colors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              group.title,
              style: theme.titleSmall?.copyWith(color: colors.primary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            '${group.records.length} · ${formatBytes(group.totalSize)}',
            style: theme.labelSmall?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary();

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    final text = context.textStyles;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.video_library_outlined,
              size: 56,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text('No downloads yet', style: text.titleSmall),
            const SizedBox(height: 6),
            Text(
              'Completed downloads will appear here.',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when a search or filter hides everything, so an empty list reads as
/// "nothing matched" rather than "nothing downloaded".
class _NoMatches extends StatelessWidget {
  const _NoMatches({required this.query, required this.onClear});

  final String query;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = context.textStyles;
    final colors = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off, size: 48, color: colors.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              query.trim().isEmpty
                  ? 'Nothing matches this filter'
                  : 'Nothing matches "$query"',
              style: theme.titleSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            AppButton(
              onPressed: onClear,
              variant: AppButtonVariant.tonal,
              child: const Text('Clear search and filters'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Banner listing media found in the download folder that the library does not
/// know about — copied in from a computer, written by another app, or left
/// behind when history was cleared.
///
/// Adopting is explicit so clearing history stays a real reset: nothing joins
/// the library without the user saying so.
/// Shown when a folder scan failed, instead of an empty "nothing found".
class _ScanErrorBanner extends StatelessWidget {
  const _ScanErrorBanner({required this.message, required this.onRetry});

  final String message;

  /// Null while a retry is already running.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = context.textStyles;
    final scheme = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: AppCard(
        color: scheme.errorContainer,
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: theme.bodySmall?.copyWith(
                  color: scheme.onErrorContainer,
                ),
              ),
            ),
            AppButton(
              onPressed: onRetry,
              variant: AppButtonVariant.plain,
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiscoveredBanner extends StatelessWidget {
  const _DiscoveredBanner({required this.files, required this.onAdopt});

  final List<DiscoveredFile> files;
  final ValueChanged<DiscoveredFile> onAdopt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Card(
        color: theme.colorScheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.folder_open,
                    size: 18,
                    color: theme.colorScheme.onSecondaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${files.length} file(s) in the download folder are not '
                      'in the library',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Capped: a large folder is summarised rather than dumped into
              // the page.
              for (final f in files.take(5))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(
                    f.guessedTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  subtitle: Text(
                    '${f.group} · ${formatBytes(f.size)}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                  trailing: AppButton(
                    onPressed: () => onAdopt(f),
                    variant: AppButtonVariant.plain,
                    child: const Text('Add'),
                  ),
                ),
              if (files.length > 5)
                Text(
                  'and ${files.length - 5} more',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSecondaryContainer,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
