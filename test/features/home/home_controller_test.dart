import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ytdlp/core/models/playlist_info.dart';
import 'package:ytdlp/core/models/video_info.dart';
import 'package:ytdlp/core/providers.dart';
import 'package:ytdlp/features/home/home_controller.dart';
import 'package:ytdlp/services/ytdlp/binary_manager.dart';
import 'package:ytdlp/services/ytdlp/ytdlp_service.dart';

const _videoUrl = 'https://example.com/watch?v=x';
const _playlistUrl = 'https://example.com/playlist?list=x';

class _FakeYtdlp extends YtdlpService {
  _FakeYtdlp(this.behavior) : super(FakeBinaryManager());

  int calls = 0;
  final Future<FetchResult> Function(String) behavior;

  @override
  Future<FetchResult> fetch(String url) {
    calls++;
    return behavior(url);
  }
}

/// The controller reads `ytdlpServiceProvider`, which needs a real
/// `BinaryManager` — fake only what `YtdlpService.fetch` reaches, and supply the
/// one method we override.
class FakeBinaryManager extends BinaryManager {}

VideoInfo _video() => VideoInfo(
  id: 'x',
  title: 'A video',
  webUrl: _videoUrl,
  duration: 10,
  videoFormats: const [],
);

PlaylistInfo _playlist() =>
    const PlaylistInfo(id: 'p', title: 'A list', webUrl: _playlistUrl);

void main() {
  test('fetch sets video content for a single-video link', () async {
    final ytdlp = _FakeYtdlp((_) async => VideoResult(_video()));
    final container = ProviderContainer(
      overrides: [ytdlpServiceProvider.overrideWithValue(ytdlp)],
    );
    addTearDown(container.dispose);

    final controller = container.read(homeControllerProvider.notifier);
    await controller.fetch(url: _videoUrl);

    final state = container.read(homeControllerProvider);
    expect(state.isLoading, isFalse);
    expect(state.error, isNull);
    expect(state.video?.title, 'A video');
    expect(state.playlist, isNull);
  });

  test('fetch maps a playlist result to playlist content', () async {
    final ytdlp = _FakeYtdlp((_) async => PlaylistResult(_playlist()));
    final container = ProviderContainer(
      overrides: [ytdlpServiceProvider.overrideWithValue(ytdlp)],
    );
    addTearDown(container.dispose);

    final controller = container.read(homeControllerProvider.notifier);
    await controller.fetch(url: _playlistUrl);

    final state = container.read(homeControllerProvider);
    expect(state.playlist?.title, 'A list');
    expect(state.video, isNull);
    expect(state.error, isNull);
  });

  test('fetch surfaces the engine error text, not a bare exception', () async {
    final ytdlp = _FakeYtdlp(
      (_) async => throw YtdlpException('Video unavailable'),
    );
    final container = ProviderContainer(
      overrides: [ytdlpServiceProvider.overrideWithValue(ytdlp)],
    );
    addTearDown(container.dispose);

    final controller = container.read(homeControllerProvider.notifier);
    await controller.fetch(url: _videoUrl);

    expect(container.read(homeControllerProvider).error, 'Video unavailable');
    expect(container.read(homeControllerProvider).content, isNull);
  });

  test('a newer fetch supersedes the older one — no stale overwrite', () async {
    // A slow first response and a fast second one: what the user sees must be
    // the answer to the *current* input, not whichever landed last.
    final ytdlp = _FakeYtdlp((url) async {
      if (url == 'slow') {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return VideoResult(_video());
      }
      return PlaylistResult(_playlist());
    });
    final container = ProviderContainer(
      overrides: [ytdlpServiceProvider.overrideWithValue(ytdlp)],
    );
    addTearDown(container.dispose);

    final controller = container.read(homeControllerProvider.notifier);
    await controller.fetch(url: 'slow');
    await controller.fetch(url: 'fast');

    expect(container.read(homeControllerProvider).playlist, isNotNull);
    expect(container.read(homeControllerProvider).video, isNull);
  });

  test('an older request failing must not clear a newer success', () async {
    final ytdlp = _FakeYtdlp((url) async {
      if (url == 'slow') {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        throw YtdlpException('slow failure');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return VideoResult(_video());
    });
    final container = ProviderContainer(
      overrides: [ytdlpServiceProvider.overrideWithValue(ytdlp)],
    );
    addTearDown(container.dispose);

    final controller = container.read(homeControllerProvider.notifier);
    await controller.fetch(url: 'slow');
    await controller.fetch(url: 'fast');

    expect(container.read(homeControllerProvider).video, isNotNull);
    expect(container.read(homeControllerProvider).error, isNull);
  });

  test('reset returns to a clean state and cancels in-flight work', () async {
    final ytdlp = _FakeYtdlp((url) async {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      return VideoResult(_video());
    });
    final container = ProviderContainer(
      overrides: [ytdlpServiceProvider.overrideWithValue(ytdlp)],
    );
    addTearDown(container.dispose);

    final controller = container.read(homeControllerProvider.notifier);
    final pending = controller.fetch(url: _videoUrl);
    controller.reset();
    expect(container.read(homeControllerProvider).content, isNull);
    expect(container.read(homeControllerProvider).error, isNull);
    expect(container.read(homeControllerProvider).isLoading, isFalse);
    await pending;
    // The late result from the cancelled request must not resurrect the state.
    expect(container.read(homeControllerProvider).content, isNull);
  });
}
