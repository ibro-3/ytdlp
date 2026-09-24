import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/video_info.dart';
import '../../core/providers.dart';
import '../../core/utils/url_validator.dart';
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

  void _retry() {
    final url = _lastUrl;
    if (url == null) return;
    if (_urlController.text != url) _urlController.text = url;
    ref.read(homeControllerProvider.notifier).fetch(url: url);
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  void _submit() {
    final raw = _urlController.text.trim();
    if (!isValidUrl(raw)) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Enter a valid video URL (https://…)')),
        );
      return;
    }
    _lastUrl = raw;
    ref.read(homeControllerProvider.notifier).fetch(url: raw);
  }

  /// Fills the URL field from the clipboard and fetches immediately.
  ///
  /// Shared text often wraps the link in a sentence, so [extractUrl] pulls
  /// the URL out of whatever shape the clipboard holds.
  Future<void> _pasteFromClipboard() async {
    final messenger = ScaffoldMessenger.of(context);
    String? text;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      text = data?.text;
    } catch (_) {
      text = null;
    }
    final url = text == null ? null : extractUrl(text);
    if (url == null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('No link found in the clipboard')),
        );
      return;
    }
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

  /// Opens the format picker, then enqueues whatever the user chose.
  Future<void> _download(VideoInfo video) async {
    final settings = ref.read(settingsControllerProvider);
    final format = await showFormatPickerSheet(
      context,
      video: video,
      settings: settings,
    );
    if (format != null && mounted) _enqueue(video, format);
  }

  void _enqueue(VideoInfo video, Format format) {
    ref.read(downloadManagerProvider).enqueue(video: video, format: format);
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
                  _EmptyHint(
                    onExampleTap: (url) {
                      _urlController.text = url;
                      _submit();
                    },
                  ),
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
  const _EmptyHint({required this.onExampleTap});
  final ValueChanged<String> onExampleTap;

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
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                ActionChip(
                  label: const Text('Try a sample URL'),
                  avatar: const Icon(Icons.play_circle_outline, size: 18),
                  onPressed: () => onExampleTap(
                    'https://www.youtube.com/watch?v=jNQXAC9IVRw',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
