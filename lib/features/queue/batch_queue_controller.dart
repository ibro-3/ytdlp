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

  List<BatchItem> get playlists => [
    for (final i in items)
      if (i.isPlaylist) i,
  ];

  bool get canEnqueue => videos.isNotEmpty;

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
  /// Guards against a superseded run: a second "resolve all" while the first is
  /// still fetching discards the first's results.
  int _run = 0;

  @override
  BatchState build() => const BatchState();

  /// Replaces the batch with [urls] and resolves each one.
  Future<void> resolveAll(List<String> urls) async {
    if (urls.isEmpty) {
      state = const BatchState();
      return;
    }
    final run = ++_run;
    state = BatchState(
      items: [
        for (final u in urls)
          BatchItem(url: u, status: BatchItemStatus.loading),
      ],
      isResolving: true,
    );

    // Sequential rather than concurrent: yt-dlp is a subprocess per URL, and a
    // large paste fired all at once would spawn dozens of them and thrash the
    // device. Results are written back per item, so the list fills in
    // progressively.
    for (var i = 0; i < urls.length; i++) {
      if (run != _run) return; // A newer run superseded this one.
      await _resolveOne(i, urls[i]);
      if (run != _run) return;
    }
    if (run != _run) return;
    state = state.copyWith(isResolving: false);
  }

  Future<void> _resolveOne(int index, String url) async {
    // Captured before the await so a later run can be detected after it.
    final run = _run;
    // Marked loading up front so the row shows a spinner; the result below
    // replaces it.
    state = state.copyWith(
      items: _replace(
        index,
        BatchItem(url: url, status: BatchItemStatus.loading),
      ),
    );
    try {
      final result = await ref.read(ytdlpServiceProvider).fetch(url);
      if (run != _run) return;
      state = state.copyWith(
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
      if (run != _run) return;
      final message = e is YtdlpException ? e.message : e.toString();
      state = state.copyWith(
        items: _replace(
          index,
          BatchItem(url: url, status: BatchItemStatus.failed, error: message),
        ),
      );
    }
  }

  /// Retries one failed item, leaving the rest of the batch alone.
  Future<void> retryOne(int index) async {
    final item = state.items[index];
    if (item.status != BatchItemStatus.failed) return;
    _run++;
    state = state.copyWith(
      items: _replace(
        index,
        BatchItem(url: item.url, status: BatchItemStatus.loading),
      ),
      isResolving: true,
    );
    await _resolveOne(index, item.url);
    if (state.isResolving) state = state.copyWith(isResolving: false);
  }

  /// Removes one item from the batch.
  void removeAt(int index) {
    if (index < 0 || index >= state.items.length) return;
    // Invalidate any in-flight fetch so a late result cannot resurrect it.
    _run++;
    final next = [...state.items]..removeAt(index);
    state = state.copyWith(items: next, isResolving: false);
  }

  /// Discards resolved and failed items, keeping the ones still loading.
  void clearFinished() {
    // Bumping the run id discards any in-flight result, so a late fetch cannot
    // repopulate an item the user just cleared.
    _run++;
    final next = [
      for (final i in state.items)
        if (i.status == BatchItemStatus.loading) i,
    ];
    state = state.copyWith(items: next, isResolving: next.isNotEmpty);
  }

  void clear() {
    _run++;
    state = const BatchState();
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
