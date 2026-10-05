import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/collection_kind.dart';
import '../../core/models/download_options.dart';
import '../../core/models/playlist_info.dart';
import '../../core/models/video_info.dart';
import '../../core/providers.dart';
import '../../core/utils/url_validator.dart';
import '../../services/sharing/share_intent_service.dart';
import '../queue/batch_queue_controller.dart';
import 'home_controller.dart';
import 'widgets/format_picker_sheet.dart';
import 'widgets/video_info_card.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  final TextEditingController _urlController = TextEditingController();
  String? _lastUrl;
  StreamSubscription<String>? _shareSub;

  void _retry() {
    final url = _lastUrl;
    if (url == null) return;
    if (_urlController.text != url) _urlController.text = url;
    ref.read(homeControllerProvider.notifier).fetch(url: url);
  }

  @override
  void initState() {
    super.initState();
    // A link shared from another app's share sheet is treated exactly like a
    // pasted one: fill the field and fetch immediately.
    _shareSub = ShareIntentService.instance.urlStream.listen(_onSharedUrl);
  }

  @override
  void dispose() {
    _shareSub?.cancel();
    _urlController.dispose();
    super.dispose();
  }

  /// Fills the URL field from a share intent and fetches it right away.
  ///
  /// A share carrying several links goes to the batch queue, same as a paste.
  void _onSharedUrl(String text) {
    if (!mounted) return;
    final urls = extractUrls(text);
    if (urls.isEmpty) return;
    if (urls.length > 1) {
      _openBatch(urls);
      return;
    }
    final url = urls.first;
    _urlController
      ..text = url
      ..selection = TextSelection.collapsed(offset: url.length);
    _submit();
  }

  /// Fills the URL field from the clipboard and fetches immediately.
  ///
  /// Shared text often wraps the link in a sentence, so the extractor pulls the
  /// URLs out of whatever shape the clipboard holds. A paste containing several
  /// links goes to the batch queue instead of silently taking only the first.
  Future<void> _pasteFromClipboard() async {
    final messenger = ScaffoldMessenger.of(context);
    String? text;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      text = data?.text;
    } catch (_) {
      text = null;
    }
    final urls = text == null ? const <String>[] : extractUrls(text);
    if (urls.isEmpty) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('No link found in the clipboard')),
        );
      return;
    }
    if (urls.length > 1) {
      await _openBatch(urls);
      return;
    }
    final url = urls.first;
    if (_urlController.text == url) {
      // Already pasted — don't re-fetch on every tap.
      _submit();
      return;
    }
    _urlController
      ..text = url
      ..selection = TextSelection.collapsed(offset: url.length);
    _submit();
  }

  /// Resolves several links at once and hands them to the batch queue.
  Future<void> _openBatch(List<String> urls) async {
    final controller = ref.read(batchQueueControllerProvider.notifier);
    // Navigate first so the list is visible while it fills in, rather than
    // blocking on a dialog.
    context.push('/queue/batch');
    await controller.resolveAll(urls);
  }

  /// A multi-line or multi-link paste in the search field.
  void _submit() {
    final raw = _urlController.text.trim();
    final urls = extractUrls(raw);
    if (urls.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Enter a valid video URL (https://…)')),
        );
      return;
    }
    if (urls.length > 1) {
      _urlController.clear();
      _openBatch(urls);
      return;
    }
    final url = urls.first;
    _lastUrl = url;
    ref.read(homeControllerProvider.notifier).fetch(url: url);
  }

  /// Opens the format picker, then enqueues whatever the user chose.
  Future<void> _download(VideoInfo video) async {
    final settings = ref.read(settingsControllerProvider);
    final templates = ref.read(templateStoreProvider).templates;
    final result = await showFormatPickerSheet(
      context,
      video: video,
      settings: settings,
      templates: templates,
    );
    if (result != null && mounted) {
      _enqueue(video, result.format, result.options);
    }
  }

  /// Queues a download with the settings' own arguments and file name.
  ///
  /// Neither is overridable per download any more; `DownloadManager` resolves
  /// both from the stored settings when the task is spawned.
  void _enqueue(VideoInfo video, Format format, DownloadOptions options) {
    ref
        .read(downloadManagerProvider)
        .enqueue(video: video, format: format, options: options);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Added to the download queue'),
          action: SnackBarAction(
            label: 'View',
            onPressed: () => context.go('/queue'),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(homeControllerProvider);
    final video = state.video;
    final playlist = state.playlist;
    final hasFormats =
        video != null &&
        (video.videoFormats.isNotEmpty || video.audioFormats.isNotEmpty);

    return Scaffold(
      appBar: AppBar(title: const Text('Download')),
      // Shortcut for the common case: you copied a link in another app.
      floatingActionButton: FloatingActionButton(
        onPressed: _pasteFromClipboard,
        tooltip: 'Paste a link from the clipboard',
        child: const Icon(Icons.content_paste),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
              children: [
                _buildHero(context),
                const SizedBox(height: 12),
                _buildUrlBar(),
                const SizedBox(height: 16),
                if (state.isLoading)
                  const _FetchingCard()
                else if (state.error != null)
                  _ErrorCard(
                    message: state.error!,
                    onRetry: _lastUrl == null ? null : _retry,
                  )
                else if (playlist != null)
                  _PlaylistSummary(playlist: playlist)
                else if (video != null) ...[
                  VideoInfoCard(video: video),
                  const SizedBox(height: 16),
                  // One button: format + quality live in the bottom sheet.
                  FilledButton.icon(
                    onPressed: hasFormats ? () => _download(video) : null,
                    icon: const Icon(Icons.download),
                    label: const Text('Download'),
                  ),
                  if (!hasFormats) ...[
                    const SizedBox(height: 8),
                    Text(
                      'No downloadable formats for this video.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ] else
                  const _EmptyHint(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHero(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Download videos',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Powered by yt-dlp · YouTube, TikTok, Vimeo & more',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildUrlBar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SearchBar(
          controller: _urlController,
          hintText: 'Paste a video URL',
          leading: const Icon(Icons.link),
          trailing: [
            ListenableBuilder(
              listenable: _urlController,
              builder: (context, _) => _urlController.text.isEmpty
                  ? const SizedBox.shrink()
                  : IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => _urlController.clear(),
                    ),
            ),
          ],
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 10),
        Consumer(
          builder: (context, ref, _) {
            final loading = ref.watch(homeControllerProvider).isLoading;
            return FilledButton.icon(
              onPressed: loading ? null : _submit,
              icon: loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.search),
              label: Text(loading ? 'Fetching…' : 'Fetch details'),
            );
          },
        ),
      ],
    );
  }
}

/// Shown when a link resolves to a collection — a playlist or a channel —
/// rather than a single video.
///
/// A collection cannot go straight to the format sheet: there is no single set
/// of formats, and downloading the whole thing unprompted could be hundreds of
/// videos. This card states what was found and hands off to the picker.
///
/// A channel gets its own wording because "download everything from this
/// channel" is the intent behind pasting a channel link, and because a channel
/// is listed in slices: the count chip says how much of it is actually loaded,
/// so the user finds out before the picker rather than after.
class _PlaylistSummary extends StatelessWidget {
  const _PlaylistSummary({required this.playlist});

  final PlaylistInfo playlist;

  /// A channel is the one collection whose total the app cannot assume, so
  /// only a channel gets the up-front caveat.
  bool get _isChannel => playlist.kind == CollectionKind.channel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final truncated = playlist.paging.hasMore;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      _isChannel ? Icons.tv : Icons.playlist_play,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        playlist.title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Chip(
                      label: Text(
                        // A channel whose full size is unknown must not claim
                        // its loaded count as the channel's size.
                        truncated && playlist.paging.totalCount == null
                            ? '${CollectionKind.contentsLabel(playlist.count)} so far'
                            : CollectionKind.contentsLabel(playlist.count),
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                    if (playlist.uploader != null && !_isChannel)
                      Chip(
                        avatar: const Icon(Icons.person_outline, size: 16),
                        label: Text(playlist.uploader!),
                        visualDensity: VisualDensity.compact,
                      ),
                    if (playlist.totalDuration > 0)
                      Chip(
                        avatar: const Icon(Icons.schedule, size: 16),
                        label: Text(
                          formatPlaylistDuration(playlist.totalDuration),
                        ),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
                if (truncated)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      playlist.paging.truncationNotice(playlist.count) ?? 'This channel has more videos than fit on one screen.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () => context.push('/download/playlist', extra: playlist),
          icon: _isChannel
              ? const Icon(Icons.download)
              : const Icon(Icons.playlist_add_check),
          // The button is the shortcut the plan asks for: one tap from a pasted
          // channel link to the picker with everything already selected. It
          // stops *at* the picker rather than queueing, because on a channel
          // that is still only partly listed "everything" means "everything
          // loaded", and that is a decision worth a screen.
          label: Text(_isChannel ? 'Download everything' : 'Choose videos'),
        ),
        const SizedBox(height: 8),
        Text(
          _isChannel
              ? 'Opens the picker with everything selected. Load more to reach '
                    'the rest of the channel, or deselect what you don\'t want.'
              : 'Pick which ones to download. They are queued individually, '
                    'grouped into one folder named after the playlist.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _FetchingCard extends StatelessWidget {
  const _FetchingCard();
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const LinearProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              'Fetching video details…',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textStyle = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: scheme.onErrorContainer);
    final isMissingBinary = message.contains('yt-dlp binary not found');
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline, color: scheme.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Couldn\'t fetch video',
                    style: Theme.of(context).textTheme.titleSmall
                        ?.copyWith(color: scheme.onErrorContainer),
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.copy,
                    size: 18,
                    color: scheme.onErrorContainer,
                  ),
                  tooltip: 'Copy error',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: message));
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(
                        const SnackBar(
                          content: Text('Error copied to clipboard'),
                        ),
                      );
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(message, style: textStyle),
            if (isMissingBinary) ...[
              const SizedBox(height: 12),
              Text(
                'Quick fix: run the app on desktop (flutter run -d linux, uses '
                'the system yt-dlp) or bundle a binary — see tool/fetch_binaries.sh '
                'and the README.',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onErrorContainer),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(
              Icons.video_file_outlined,
              size: 56,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              'Paste a link to get started',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Text(
              'Supports 1000+ sites via yt-dlp.',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
