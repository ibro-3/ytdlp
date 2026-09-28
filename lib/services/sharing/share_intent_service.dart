import 'dart:async';
import 'dart:io';

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

  final StreamController<String> _controller = StreamController.broadcast();
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
    if (!Platform.isAndroid) return;
    _subscription ??= ReceiveSharingIntent.instance.getMediaStream().listen(
      _handleBatch,
      onError: (_) {},
    );

    // A cold start from the share sheet does not emit on the stream, so the
    // initial payload has to be read explicitly.
    unawaited(_consumeInitial());
  }

  Future<void> _consumeInitial() async {
    try {
      final initial = await ReceiveSharingIntent.instance.getInitialMedia();
      if (initial.isEmpty) return;
      _handleBatch(initial);
      // Mark it consumed so a restart does not replay the same link.
      await ReceiveSharingIntent.instance.reset();
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
