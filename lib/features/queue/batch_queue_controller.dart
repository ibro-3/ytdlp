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
    this.id = 0,
    this.status = BatchItemStatus.pending,
    this.video,
    this.playlist,
    this.error,
  });

  final String url;

  /// Identity of this row within a batch, assigned by the controller when the
  /// row is created (`0` only for rows built outside the controller, e.g. by
  /// tests seeding a state).
  ///
  /// A fetch is tied to the id it was started for, and its result is applied
  /// by looking that id up again rather than by a fixed index. That is what
  /// makes removing one row safe while others are in flight: a shared epoch
  /// bumped by [BatchQueueController.removeAt] used to discard the awaited
  /// result of *every* in-flight row, stranding them at `loading` forever.
  final int id;
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
      // Identity is preserved, never changed through a copy.
      id: id,
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

  /// Source of the ids handed out to new rows. Never reused, so an id still
  /// found in the state always means "this exact row".
  int _nextId = 0;

  @override
  BatchState build() => const BatchState();

  /// Replaces the batch with [urls] and resolves each one.
  Future<void> resolveAll(List<String> urls) async {
    if (urls.isEmpty) {
      _batchRun++;
      state = const BatchState();
      return;
    }
    final run = ++_batchRun;
    final items = [
      for (final u in urls)
        BatchItem(url: u, id: ++_nextId, status: BatchItemStatus.loading),
    ];
    _write(items: items);

    // Sequential rather than concurrent: yt-dlp is a subprocess per URL, and a
    // large paste fired all at once would spawn dozens of them and thrash the
    // device. Results are written back per item, so the list fills in
    // progressively.
    //
    // The plan is walked by id rather than by index: an item removed mid-run
    // shifts every later index, so writing by index would resolve URL 3 into
    // the row that now belongs to URL 4. Residents with an id never shift.
    for (final planned in items) {
      if (run != _batchRun) return; // The batch was replaced or cleared.
      await _resolveOne(planned.id, planned.url, run);
      if (run != _batchRun) return;
    }
    // Nothing is loading any more, unless a per-item retry is still in flight —
    // so this is derived rather than forced false, which would hide that.
    _write();
  }

  /// Fetches one URL into the row carrying [id].
  ///
  /// Takes the batch token explicitly rather than reading it, so a per-item
  /// retry can join the run already in progress instead of superseding it.
  Future<void> _resolveOne(int id, String url, int run) async {
    // Marked loading up front so the row shows a spinner; the result below
    // replaces it. The row is written where it lives *now*, and the id travels
    // with it so the result can find it again however the list shifts.
    final index = _indexOf(id, url);
    if (index == -1) return; // Removed before its turn came up.
    _write(
      items: _replace(
        index,
        BatchItem(id: id, url: url, status: BatchItemStatus.loading),
      ),
    );
    try {
      final result = await ref.read(ytdlpServiceProvider).fetch(url);
      final at = _indexOf(id, url);
      // Discarded when the row is gone (removed, batch replaced) — a late
      // result must not resurrect a row the user took away, least of all on
      // top of whichever row now occupies its old index.
      if (at == -1 || run != _batchRun) return;
      _write(
        items: _replace(at, switch (result) {
          VideoResult(:final video) => BatchItem(
            id: id,
            url: url,
            status: BatchItemStatus.ready,
            video: video,
          ),
          PlaylistResult(:final playlist) => BatchItem(
            id: id,
            url: url,
            status: BatchItemStatus.ready,
            playlist: playlist,
          ),
        }),
      );
    } catch (e) {
      final at = _indexOf(id, url);
      if (at == -1 || run != _batchRun) return;
      final message = e is YtdlpException ? e.message : e.toString();
      _write(
        items: _replace(
          at,
          BatchItem(
            id: id,
            url: url,
            status: BatchItemStatus.failed,
            error: message,
          ),
        ),
      );
    }
  }

  /// Retries one failed item, leaving the rest of the batch alone.
  ///
  /// Joins the run already in progress instead of superseding it, so a batch
  /// that is still resolving its remaining items keeps going. Only this
  /// item's result is guarded, by its id surviving in the state.
  Future<void> retryOne(int index) async {
    // Bounds-checked: an index goes stale the moment a row is removed or the
    // finished rows are cleared, and `state.items[index]` would throw
    // RangeError on a tap that raced that removal.
    if (index < 0 || index >= state.items.length) return;
    final item = state.items[index];
    if (item.status != BatchItemStatus.failed) return;
    await _resolveOne(item.id, item.url, _batchRun);
  }

  /// Removes one item from the batch.
  void removeAt(int index) {
    if (index < 0 || index >= state.items.length) return;
    // No shared token is bumped here. Each fetch is invalidated by its own id:
    // a row that disappears simply stops being found for write-back, so its
    // late result is discarded without touching any other row's in-flight
    // fetch. Bumping one counter used to do exactly that — every other
    // pending result was dropped, its row stayed `loading` forever, and the
    // derived `isResolving` never cleared.
    final next = [...state.items]..removeAt(index);
    _write(items: next);
  }

  /// Discards resolved and failed items, keeping the ones still loading.
  void clearFinished() {
    // A run in progress is stopped outright (the batch token is bumped), and
    // the items it had not reached yet are kept but demoted from `loading` to
    // `pending`: nothing is fetching them any more, and leaving them `loading`
    // would show a spinner that nothing will ever resolve.
    _batchRun++;
    _write(
      items: [
        for (final i in state.items)
          if (i.status == BatchItemStatus.loading)
            BatchItem(id: i.id, url: i.url),
      ],
    );
  }

  void clear() {
    _batchRun++;
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

  /// Where the row carrying [id] (and [url], because seeded rows can share the
  /// placeholder id `0`) currently lives, or -1 when it is gone — which is
  /// itself the answer: a fetch whose row vanished has nowhere to write.
  int _indexOf(int id, String url) =>
      state.items.indexWhere((i) => i.id == id && i.url == url);
}

final batchQueueControllerProvider =
    NotifierProvider<BatchQueueController, BatchState>(
      BatchQueueController.new,
    );
