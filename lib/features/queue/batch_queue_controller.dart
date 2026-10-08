import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/playlist_info.dart';
import '../../core/models/video_info.dart';
import '../../core/providers.dart';
import '../../services/ytdlp/ytdlp_service.dart';

/// Outcome of resolving one URL in a batch.
enum BatchItemStatus { pending, loading, ready, failed }

/// One URL's place in a batch queue.
class BatchItem {
  const BatchItem({
    required this.url,
    this.status = BatchItemStatus.pending,
    this.video,
    this.playlist,
    this.error,
  });

  final String url;
  final BatchItemStatus status;
  final VideoInfo? video;
  final PlaylistInfo? playlist;
  final String? error;

  /// A playlist cannot join a batch: each entry has to be chosen by the user,
  /// so it is surfaced rather than silently downloading the whole thing.
  bool get isPlaylist => playlist != null;

  BatchItem copyWith({
    BatchItemStatus? status,
    VideoInfo? video,
    PlaylistInfo? playlist,
    String? error,
  }) {
    return BatchItem(
      url: url,
      status: status ?? this.status,
      video: video ?? this.video,
      playlist: playlist ?? this.playlist,
      error: error ?? this.error,
    );
  }
}

class BatchState {
  const BatchState({this.items = const [], this.isResolving = false});

  final List<BatchItem> items;
  final bool isResolving;

  int get total => items.length;
  int get ready => items.where((i) => i.video != null).length;
  int get failed =>
      items.where((i) => i.status == BatchItemStatus.failed).length;

  /// Items that can be enqueued right now: resolved videos, plus playlists the
  /// user has to open separately.
  List<VideoInfo> get videos => [
    for (final i in items)
      if (i.video != null) i.video!,
  ];

  BatchState copyWith({List<BatchItem>? items, bool? isResolving}) {
    return BatchState(
      items: items ?? this.items,
      isResolving: isResolving ?? this.isResolving,
    );
  }
}

/// Resolves several URLs at once, so a paste with three links becomes three
/// downloads instead of only the first one.
///
/// Each URL is fetched independently and one failure does not affect the
/// others, which is the whole point: a bad link in a pasted list should not
/// cost the good ones.
class BatchQueueController extends Notifier<BatchState> {
  /// Bumped when the whole batch is replaced or emptied.
  ///
  /// Only a wholesale replacement may abort the [resolveAll] loop — the list it
  /// is walking no longer describes what the user asked for. Per-item edits used
  /// to bump this too, which made [retryOne] abort the loop and strand every
  /// item after the retried one at `loading` with no fetch in flight, so their
  /// spinners never resolved.
  int _batchRun = 0;

  /// Bumped when individual items disappear.
  ///
  /// Discards a late result for an item that is no longer in the list, without
  /// disturbing the loop resolving the rest of the batch.
  int _itemEpoch = 0;

  @override
  BatchState build() => const BatchState();

  /// Replaces the batch with [urls] and resolves each one.
  Future<void> resolveAll(List<String> urls) async {
    if (urls.isEmpty) {
      _batchRun++;
      _itemEpoch++;
      state = const BatchState();
      return;
    }
    final run = ++_batchRun;
    _itemEpoch++;
    _write(
      items: [
        for (final u in urls)
          BatchItem(url: u, status: BatchItemStatus.loading),
      ],
    );

    // Sequential rather than concurrent: yt-dlp is a subprocess per URL, and a
    // large paste fired all at once would spawn dozens of them and thrash the
    // device. Results are written back per item, so the list fills in
    // progressively.
    for (var i = 0; i < urls.length; i++) {
      if (run != _batchRun) return; // The batch was replaced or cleared.
      await _resolveOne(i, urls[i], run);
      if (run != _batchRun) return;
    }
    // Nothing is loading any more, unless a per-item retry is still in flight —
    // so this is derived rather than forced false, which would hide that.
    _write();
  }

  /// Fetches one URL into [index].
  ///
  /// Takes the batch token explicitly rather than reading it, so a per-item
  /// retry can join the run already in progress instead of superseding it.
  Future<void> _resolveOne(int index, String url, int run) async {
    // Captured before the await so a later edit can be detected after it.
    final epoch = _itemEpoch;
    // Marked loading up front so the row shows a spinner; the result below
    // replaces it.
    _write(
      items: _replace(
        index,
        BatchItem(url: url, status: BatchItemStatus.loading),
      ),
    );
    try {
      final result = await ref.read(ytdlpServiceProvider).fetch(url);
      if (epoch != _itemEpoch || run != _batchRun) return;
      _write(
        items: _replace(index, switch (result) {
          VideoResult(:final video) => BatchItem(
            url: url,
            status: BatchItemStatus.ready,
            video: video,
          ),
          PlaylistResult(:final playlist) => BatchItem(
            url: url,
            status: BatchItemStatus.ready,
            playlist: playlist,
          ),
        }),
      );
    } catch (e) {
      if (epoch != _itemEpoch || run != _batchRun) return;
      final message = e is YtdlpException ? e.message : e.toString();
      _write(
        items: _replace(
          index,
          BatchItem(url: url, status: BatchItemStatus.failed, error: message),
        ),
      );
    }
  }

  /// Retries one failed item, leaving the rest of the batch alone.
  ///
  /// Joins the run already in progress instead of superseding it, so a batch
  /// that is still resolving its remaining items keeps going. Only this item's
  /// result is guarded, by the shared `_itemEpoch` check inside [_resolveOne].
  Future<void> retryOne(int index) async {
    final item = state.items[index];
    if (item.status != BatchItemStatus.failed) return;
    await _resolveOne(index, item.url, _batchRun);
  }

  /// Removes one item from the batch.
  void removeAt(int index) {
    if (index < 0 || index >= state.items.length) return;
    // Invalidate any in-flight fetch so a late result cannot resurrect the
    // removed item — but not the batch run, which is still resolving the rest.
    _itemEpoch++;
    final next = [...state.items]..removeAt(index);
    _write(items: next);
  }

  /// Discards resolved and failed items, keeping the ones still loading.
  void clearFinished() {
    // A run in progress walks the list by index, so the list changing under it
    // stops it outright — hence the batch bump. The items it was going to
    // resolve are kept, but demoted from `loading` to `pending`: nothing is
    // fetching them any more, and leaving them `loading` would show a spinner
    // that nothing will ever resolve.
    _batchRun++;
    _itemEpoch++;
    _write(
      items: [
        for (final i in state.items)
          if (i.status == BatchItemStatus.loading) BatchItem(url: i.url),
      ],
    );
  }

  void clear() {
    _batchRun++;
    _itemEpoch++;
    state = const BatchState();
  }

  /// Publishes [items], deriving `isResolving` from them.
  ///
  /// Deriving rather than tracking the flag alongside every mutation means it
  /// cannot drift: an item left `loading` by a superseded run keeps the
  /// indicator honest instead of the whole batch claiming to be idle.
  void _write({List<BatchItem>? items}) {
    final next = items ?? state.items;
    state = state.copyWith(
      items: next,
      isResolving: next.any((i) => i.status == BatchItemStatus.loading),
    );
  }

  List<BatchItem> _replace(int index, BatchItem item) {
    final next = [...state.items];
    if (index < 0 || index >= next.length) return next;
    next[index] = item;
    return next;
  }
}

final batchQueueControllerProvider =
    NotifierProvider<BatchQueueController, BatchState>(
      BatchQueueController.new,
    );
