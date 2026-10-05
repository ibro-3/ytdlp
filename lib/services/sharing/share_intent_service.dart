import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../../core/utils/url_validator.dart';

/// Delivers links shared into the app from another app's share sheet.
///
/// Android's share sheet lets a user send a URL from a browser, a message or
/// any app that exposes an ACTION_SEND intent. This service captures those
/// intents, pulls a URL out of the shared text, and exposes it as a stream the
/// Download tab listens to.
///
/// The intent that launched the app (cold start from the share sheet) is
/// handled too, so sharing into a closed app works. It is consumed via
/// `reset()` afterwards so the same link is not delivered twice.
///
/// Desktop has no share-target concept, so the service is inert there rather
/// than throwing from the unimplemented platform channel.
class ShareIntentService {
  ShareIntentService._();

  static final ShareIntentService instance = ShareIntentService._();

  /// Builds a service driven by an arbitrary payload source instead of the
  /// platform channel.
  ///
  /// Only Android can deliver a URL this way and only Android delivers it in
  /// production, so the platform check lives in [init] rather than being baked
  /// into the constructor — otherwise the URL extraction, the cold-start
  /// buffering and the `reset()` bookkeeping would be untestable off-device.
  @visibleForTesting
  factory ShareIntentService.forTesting({
    required Stream<List<SharedMediaFile>> media,
    Future<List<SharedMediaFile>> Function()? initialMedia,
    Future<void> Function()? reset,
  }) {
    final service = ShareIntentService._();
    service._media = media;
    service._initialMedia = initialMedia;
    service._reset = reset;
    return service;
  }

  final StreamController<String> _controller = StreamController.broadcast();

  /// The payload source. Defaults to the plugin's share stream; a test can
  /// supply its own so the whole extraction path runs without a platform
  /// channel.
  Stream<List<SharedMediaFile>>? _media;
  Future<List<SharedMediaFile>> Function()? _initialMedia;
  Future<void> Function()? _reset;

  StreamSubscription<List<SharedMediaFile>>? _subscription;

  /// A link that arrived before anything listened.
  ///
  /// A cold start from the share sheet resolves the initial intent in `main()`
  /// — before the Download tab mounts — and a broadcast stream drops events
  /// with no subscriber, so the URL is held here and replayed to the first
  /// listener.
  String? _pending;

  /// URLs shared into the app, already validated by [extractUrl].
  Stream<String> get urlStream {
    // A new subscriber means a fresh mount of the Download tab, which is a
    // consumer that still wants the link it was launched with.
    final pending = _pending;
    if (pending != null) {
      _pending = null;
      scheduleMicrotask(() => _controller.add(pending));
    }
    return _controller.stream;
  }

  /// Whether this platform can receive shared links at all.
  static bool get isSupported => Platform.isAndroid || Platform.isIOS;

  /// Starts listening. Safe to call more than once; only Android can deliver
  /// a URL this way, iOS is left to the clipboard flow.
  void init() {
    // A test-supplied source is not platform-gated: the point of the seam is to
    // exercise the extraction path on any host.
    if (_media == null && !Platform.isAndroid) return;
    _subscription ??= (_media ?? ReceiveSharingIntent.instance.getMediaStream())
        .listen(_handleBatch, onError: (_) {});

    // A cold start from the share sheet does not emit on the stream, so the
    // initial payload has to be read explicitly.
    unawaited(_consumeInitial());
  }

  Future<void> _consumeInitial() async {
    try {
      final initial =
          await (_initialMedia?.call() ??
              ReceiveSharingIntent.instance.getInitialMedia());
      if (initial.isEmpty) return;
      _handleBatch(initial);
      // Mark it consumed so a restart does not replay the same link.
      await (_reset?.call() ?? ReceiveSharingIntent.instance.reset());
    } catch (_) {
      // A missing or unavailable channel must never stop the app from starting.
    }
  }

  void _handleBatch(List<SharedMediaFile> media) {
    for (final item in media) {
      // `text` carries a shared string (the common "share a link" case) and
      // `url` a bare link; both hold the text we need to extract from.
      if (item.type != SharedMediaType.text &&
          item.type != SharedMediaType.url) {
        continue;
      }
      // Shared text is usually a sentence wrapping the link, not a bare URL.
      final url = extractUrl(item.path);
      if (url == null) continue;
      // With no listener yet, hold the URL so the first subscriber gets it.
      if (_controller.hasListener) {
        _controller.add(url);
      } else {
        _pending = url;
      }
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    _pending = null;
    await _controller.close();
  }
}
