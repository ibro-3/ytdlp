import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/core/models/playlist_info.dart';
import 'package:ytdlp/core/models/video_info.dart';
import 'package:ytdlp/core/providers.dart';
import 'package:ytdlp/features/queue/batch_queue_controller.dart';
import 'package:ytdlp/services/ytdlp/binary_manager.dart';
import 'package:ytdlp/services/ytdlp/ytdlp_service.dart';

VideoInfo _video(String id) => VideoInfo(
  id: id,
  title: 'Video $id',
  webUrl: 'https://example.com/$id',
  videoFormats: const [
    Format(kind: FormatKind.video, label: 'Best', selector: 'b'),
  ],
);

/// Resolves from a fixed table so no process or network is involved.
class _FakeService extends YtdlpService {
  /// [results] maps a URL to either a video id, `'playlist'`, or is absent
  /// entirely to mean "this URL fails".
  _FakeService(this.results) : super(BinaryManager());

  final Map<String, String> results;

  final List<String> requested = [];

  /// Per-URL delay, so ordering and partial-progress can be tested.
  Duration delay = Duration.zero;

  @override
  Future<FetchResult> fetch(String url) async {
    requested.add(url);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final outcome = results[url];
    if (outcome == null) {
      throw const YtdlpException('Video unavailable.');
    }
    if (outcome == 'playlist') {
      return PlaylistResult(
        PlaylistInfo(
          id: 'PL1',
          title: 'A Playlist',
          webUrl: url,
          entries: [_video('e0')],
        ),
      );
    }
    return VideoResult(_video(outcome));
  }
}

/// Fails a designated URL on its first request and resolves it on every one
/// after that, so a retry can be observed recovering while the surrounding batch
/// is still resolving.
class _RetryingService extends YtdlpService {
  _RetryingService({required this.flakyUrl, this.delay = Duration.zero})
    : super(BinaryManager());

  final String flakyUrl;
  bool _failedOnce = false;

  /// Per-request delay, so a run is still in flight when the retry starts.
  final Duration delay;

  @override
  Future<FetchResult> fetch(String url) async {
    await Future<void>.delayed(delay);
    if (url == flakyUrl && !_failedOnce) {
      _failedOnce = true;
      throw const YtdlpException('Video unavailable.');
    }
    return VideoResult(_video(url));
  }
}

/// Fails until [succeed] is set, for testing a retry that actually recovers.
class _FlakyService extends YtdlpService {
  _FlakyService() : super(BinaryManager());

  bool succeed = false;
  int calls = 0;

  @override
  Future<FetchResult> fetch(String url) async {
    calls++;
    if (!succeed) throw const YtdlpException('Video unavailable.');
    return VideoResult(_video('a1'));
  }
}

void main() {
  late _FakeService service;

  setUp(() => service = _FakeService(const {}));

  BatchQueueController controller(ProviderContainer c) =>
      c.read(batchQueueControllerProvider.notifier);

  Future<ProviderContainer> container() async {
    final c = ProviderContainer(
      overrides: [ytdlpServiceProvider.overrideWithValue(service)],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('resolves every URL in a paste', () async {
    service = _FakeService({
      'https://a.example.com/1': 'a1',
      'https://a.example.com/2': 'a2',
      'https://a.example.com/3': 'a3',
    });
    final c = await container();
    final notifier = controller(c);

    await notifier.resolveAll([
      'https://a.example.com/1',
      'https://a.example.com/2',
      'https://a.example.com/3',
    ]);

    final state = c.read(batchQueueControllerProvider);
    expect(state.total, 3);
    expect(state.ready, 3);
    expect(state.failed, 0);
    expect(state.videos.map((v) => v.id), ['a1', 'a2', 'a3']);
    expect(state.isResolving, isFalse);
  });

  test('one failure does not affect the others', () async {
    // The whole point of batching: a bad link must not cost the good ones.
    // An absent entry in the table means "this URL fails".
    service = _FakeService({'https://ok.example.com/1': 'ok'});
    final c = await container();

    await controller(c)
        .resolveAll(['https://ok.example.com/1', 'https://bad.example.com/2']);

    final state = c.read(batchQueueControllerProvider);
    expect(state.ready, 1);
    expect(state.failed, 1);
    expect(state.videos.single.id, 'ok');
    expect(
      state.items.last.error,
      contains('Video unavailable'),
      reason: 'the failure explains itself',
    );
  });

  test('a playlist is surfaced rather than auto-downloaded', () async {
    service = _FakeService({
      'https://a.example.com/1': 'a1',
      'https://p.example.com/pl': 'playlist',
    });
    final c = await container();

    await controller(c)
        .resolveAll(['https://a.example.com/1', 'https://p.example.com/pl']);

    final state = c.read(batchQueueControllerProvider);
    // Only the video is offered for enqueue; the playlist needs its own picker.
    expect(state.videos.map((v) => v.id), ['a1']);
    final playlist = state.items.singleWhere((i) => i.isPlaylist).playlist;
    expect(playlist?.title, 'A Playlist');
  });

  test('an empty list clears the batch', () async {
    final c = await container();
    await controller(c).resolveAll(const []);
    final state = c.read(batchQueueControllerProvider);
    expect(state.total, 0);
    expect(state.isResolving, isFalse);
  });

  test('items fill in progressively', () async {
    service = _FakeService({
      'https://a.example.com/1': 'a1',
      'https://a.example.com/2': 'a2',
    });
    // Slow enough that the first item is observed resolved while later ones
    // are still loading, which is what makes a long paste feel responsive.
    service.delay = const Duration(milliseconds: 30);
    final c = await container();

    final notifier = controller(c);
    final future = notifier.resolveAll([
      'https://a.example.com/1',
      'https://a.example.com/2',
    ]);

    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(c.read(batchQueueControllerProvider).isResolving, isTrue);
    expect(c.read(batchQueueControllerProvider).ready, greaterThanOrEqualTo(0));

    await future;
    expect(c.read(batchQueueControllerProvider).ready, 2);
  });

  test('a superseded run does not resurrect stale results', () async {
    service = _FakeService({
      'https://a.example.com/1': 'a1',
      'https://b.example.com/2': 'b2',
    });
    service.delay = const Duration(milliseconds: 20);
    final c = await container();
    final notifier = controller(c);

    // Start a slow run, then immediately supersede it with a different one.
    final first = notifier.resolveAll(['https://a.example.com/1']);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    await notifier.resolveAll(['https://b.example.com/2']);
    await first;

    final state = c.read(batchQueueControllerProvider);
    expect(state.items.map((i) => i.url), [
      'https://b.example.com/2',
    ], reason: 'the newer run wins entirely');
  });

  test('retryOne re-resolves just that item', () async {
    // Starts failing, then succeeds — the transient case a retry exists for.
    // The same fake instance is reused with its table swapped, because the
    // provider captured the service when the container was created.
    final flaky = _FlakyService();
    final c = ProviderContainer(
      overrides: [ytdlpServiceProvider.overrideWithValue(flaky)],
    );
    addTearDown(c.dispose);
    final notifier = controller(c);

    await notifier.resolveAll(['https://a.example.com/1']);
    expect(c.read(batchQueueControllerProvider).failed, 1);

    flaky.succeed = true;
    await notifier.retryOne(0);
    expect(c.read(batchQueueControllerProvider).ready, 1);
    expect(flaky.calls, 2, reason: 'exactly one extra fetch');
  });

  test('retryOne does not strand the rest of a batch in loading', () async {
    // The regression this guards: retryOne used to bump the same token the
    // resolve-all loop watched, so the loop bailed and every item after the
    // retried one stayed `loading` with no fetch in flight — a spinner that
    // never resolves, with nothing left to resolve it.
    const flaky = 'https://b.example.com/2';
    // 40ms per URL, resolved in order: 'a' settles at ~40ms, 'b' fails at ~80ms,
    // 'c' is still in flight at ~90ms. Retrying there is exactly the window the
    // old code got wrong — the retry is what used to kill the loop before 'c'.
    const perUrl = Duration(milliseconds: 40);
    final c = ProviderContainer(
      overrides: [
        ytdlpServiceProvider.overrideWithValue(
          _RetryingService(flakyUrl: flaky, delay: perUrl),
        ),
      ],
    );
    addTearDown(c.dispose);
    final notifier = controller(c);
    final pending = notifier.resolveAll([
      'https://a.example.com/1',
      'https://b.example.com/2',
      'https://c.example.com/3',
    ]);
    await Future<void>.delayed(perUrl + perUrl + const Duration(milliseconds: 10));
    expect(
      c.read(batchQueueControllerProvider).items[1].status,
      BatchItemStatus.failed,
      reason: 'the middle item failed on the first pass',
    );
    await notifier.retryOne(1);
    await pending;

    final state = c.read(batchQueueControllerProvider);
    expect(
      state.items.where((i) => i.status == BatchItemStatus.loading),
      isEmpty,
      reason: 'nothing is left spinning',
    );
    expect(state.ready, 3, reason: 'all three resolved, retry included');
    expect(state.failed, 0);
    expect(state.isResolving, isFalse);
  });

  test('retryOne ignores an item that did not fail', () async {
    service = _FakeService({'https://a.example.com/1': 'a1'});
    final c = await container();
    final notifier = controller(c);
    await notifier.resolveAll(['https://a.example.com/1']);
    final before = service.requested.length;

    await notifier.retryOne(0);
    expect(
      service.requested.length,
      before,
      reason: 'no extra fetch for an already-resolved item',
    );
  });

  test('removeAt drops one item', () async {
    service = _FakeService({
      'https://a.example.com/1': 'a1',
      'https://a.example.com/2': 'a2',
    });
    final c = await container();
    final notifier = controller(c);
    await notifier.resolveAll([
      'https://a.example.com/1',
      'https://a.example.com/2',
    ]);

    notifier.removeAt(0);
    final state = c.read(batchQueueControllerProvider);
    expect(state.total, 1);
    expect(state.videos.single.id, 'a2');
  });

  test('removeAt ignores an out-of-range index', () async {
    final c = await container();
    controller(c).removeAt(3);
    controller(c).removeAt(-1);
    expect(c.read(batchQueueControllerProvider).total, 0);
  });

  test('clearFinished keeps only the still-loading items', () async {
    service = _FakeService({'https://a.example.com/1': 'a1'});
    final c = await container();
    final notifier = controller(c);
    await notifier.resolveAll([
      'https://a.example.com/1',
      'https://bad.example.com/2',
    ]);

    notifier.clearFinished();
    final state = c.read(batchQueueControllerProvider);
    expect(state.total, 0, reason: 'both had settled, so both are dropped');
    expect(state.isResolving, isFalse);
  });

  test('clear empties the batch', () async {
    service = _FakeService({'https://a.example.com/1': 'a1'});
    final c = await container();
    final notifier = controller(c);
    await notifier.resolveAll(['https://a.example.com/1']);

    notifier.clear();
    final state = c.read(batchQueueControllerProvider);
    expect(state.total, 0);
    expect(state.videos, isEmpty);
  });

  test('every URL is fetched exactly once', () async {
    service = _FakeService({
      'https://a.example.com/1': 'a1',
      'https://a.example.com/2': 'a2',
    });
    final c = await container();
    await controller(c)
        .resolveAll(['https://a.example.com/1', 'https://a.example.com/2']);
    expect(service.requested, hasLength(2));
    expect(service.requested.toSet(), hasLength(2));
  });
}
