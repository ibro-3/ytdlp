import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:ytdlp/services/sharing/share_intent_service.dart';

/// A [SharedMediaFile] of type [type] carrying [path] as its payload.
SharedMediaFile _media(
  String path, {
  SharedMediaType type = SharedMediaType.url,
}) => SharedMediaFile(path: path, type: type);

SharedMediaFile _file(String path) => _media(path, type: SharedMediaType.file);

void main() {
  late StreamController<List<SharedMediaFile>> source;
  late ShareIntentService service;
  late List<Object> resets;

  setUp(() {
    source = StreamController<List<SharedMediaFile>>.broadcast();
    resets = [];
    service = ShareIntentService.forTesting(
      media: source.stream,
      initialMedia: () async => [],
      reset: () async => resets.add(Object()),
    );
  });

  tearDown(() async {
    await service.dispose();
    await source.close();
  });

  test('a shared URL is extracted out of its sentence', () async {
    service.init();
    final next = expectLater(service.urlStream, emits('https://example.com/v'));

    source.add([_media('check this out https://example.com/v')]);
    await next;
  });

  test('a shared file is not mistaken for a link', () async {
    service.init();
    // If a file slipped through, a URL would arrive on the stream.
    final received = <String>[];
    service.urlStream.listen(received.add);

    source.add([_file('/storage/emulated/0/Download/a.mp4')]);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(received, isEmpty);
  });

  test('text with no URL in it is dropped', () async {
    service.init();
    final received = <String>[];
    service.urlStream.listen(received.add);

    source.add([_media('look at this picture!')]);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(received, isEmpty);
  });

  test('a cold-start payload is replayed to the first listener', () async {
    await service.dispose();
    final pending = _media('https://example.com/cold');
    final service2 = ShareIntentService.forTesting(
      media: source.stream,
      initialMedia: () async => [pending],
      reset: () async => resets.add(Object()),
    );
    service2.init();

    expect(service2.urlStream.first, completion('https://example.com/cold'));
    await service2.dispose();
  });

  test(
    'cold-start payload is consumed once, so a restart does not replay it',
    () async {
      // The first listener drains the pending slot; a second listener must not
      // see the same URL again.
      await service.dispose();
      final pending = _media('https://example.com/once');
      final service2 = ShareIntentService.forTesting(
        media: source.stream,
        initialMedia: () async => [pending],
        reset: () async => resets.add(Object()),
      );
      service2.init();

      // Wait for the cold-start URL to flush through.
      service2.urlStream.listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // A new subscriber afterwards gets nothing replayed.
      final received = <String>[];
      service2.urlStream.listen(received.add);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(received, isEmpty);
      await service2.dispose();
    },
  );

  test('a payload that is not text or url is skipped', () async {
    service.init();
    final received = <String>[];
    service.urlStream.listen(received.add);

    source.add([
      _media('https://example.com/photo', type: SharedMediaType.image),
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(received, isEmpty);
  });

  test('reset is called on the initial payload', () async {
    await service.dispose();
    final service2 = ShareIntentService.forTesting(
      media: source.stream,
      initialMedia: () async => [_media('https://example.com/x')],
      reset: () async => resets.add(Object()),
    );
    service2.init();

    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(resets, hasLength(1));
    await service2.dispose();
  });
}
