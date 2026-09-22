import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/video_info.dart';
import '../../core/providers.dart';
import '../../core/utils/url_validator.dart';
import 'home_controller.dart';
import 'widgets/video_info_card.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  final TextEditingController _urlController = TextEditingController();
  String? _lastUrl;

  FormatKind _mode = FormatKind.video;
  Format? _selectedVideo;
  Format? _selectedAudio;

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
        ..showSnackBar(const SnackBar(
            content: Text('Enter a valid video URL (https://…)')));
      return;
    }
    _lastUrl = raw;
    ref.read(homeControllerProvider.notifier).fetch(url: raw);
  }

  void _download(VideoInfo video) {
    final format = _mode == FormatKind.video ? _selectedVideo : _selectedAudio;
    if (format == null) return;
    ref.read(downloadManagerProvider).enqueue(video: video, format: format);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: const Text('Added to the download queue'),
        action: SnackBarAction(
            label: 'View', onPressed: () => context.go('/queue')),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(homeControllerProvider);
    final video = state.video;

    // Auto-pick first format when video arrives
    if (video != null) {
      if (_selectedVideo == null && video.videoFormats.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _selectedVideo == null) {
            setState(() => _selectedVideo = video.videoFormats.first);
          }
        });
      }
      if (_selectedAudio == null && video.audioFormats.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _selectedAudio == null) {
            setState(() => _selectedAudio = video.audioFormats.first);
          }
        });
      }
    }

    final selected =
        _mode == FormatKind.video ? _selectedVideo : _selectedAudio;
    final canDownload = video != null && selected != null && !state.isLoading;

    return Scaffold(
      appBar: AppBar(title: const Text('Download')),
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
                      onRetry: _lastUrl == null ? null : _submit)
                else if (video != null) ...[
                  VideoInfoCard(video: video),
                  const SizedBox(height: 16),
                  _FormatSelector(
                    mode: _mode,
                    video: video,
                    selectedVideo: _selectedVideo,
                    selectedAudio: _selectedAudio,
                    onModeChanged: (m) => setState(() => _mode = m),
                    onVideoSelected: (f) => setState(() => _selectedVideo = f),
                    onAudioSelected: (f) => setState(() => _selectedAudio = f),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: canDownload ? () => _download(video) : null,
                    icon: const Icon(Icons.download),
                    label: Text(selected == null
                        ? 'Select a format'
                        : 'Download ${selected.kind == FormatKind.audio ? 'audio' : 'video'}'),
                  ),
                ] else
                  _EmptyHint(onExampleTap: (url) {
                    _urlController.text = url;
                    _submit();
                  }),
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
        Text('Download videos',
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text('Powered by yt-dlp · YouTube, TikTok, Vimeo & more',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
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
        Consumer(builder: (context, ref, _) {
          final loading = ref.watch(homeControllerProvider).isLoading;
          return FilledButton.icon(
            onPressed: loading ? null : _submit,
            icon: loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.search),
            label: Text(loading ? 'Fetching…' : 'Fetch details'),
          );
        }),
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
            Text('Fetching video details…',
                style: Theme.of(context).textTheme.bodyMedium),
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
    final textStyle =
        Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onErrorContainer);
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
                  child: Text('Couldn\'t fetch video',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(color: scheme.onErrorContainer)),
                ),
                IconButton(
                  icon: Icon(Icons.copy, size: 18, color: scheme.onErrorContainer),
                  tooltip: 'Copy error',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: message));
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(const SnackBar(
                          content: Text('Error copied to clipboard')));
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
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
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
            Icon(Icons.video_file_outlined,
                size: 56, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('Paste a link to get started',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Text('Supports 1000+ sites via yt-dlp.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                ActionChip(
                  label: const Text('Try a sample URL'),
                  avatar: const Icon(Icons.play_circle_outline, size: 18),
                  onPressed: () => onExampleTap(
                      'https://www.youtube.com/watch?v=jNQXAC9IVRw'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FormatSelector extends StatelessWidget {
  const _FormatSelector({
    required this.mode,
    required this.video,
    required this.selectedVideo,
    required this.selectedAudio,
    required this.onModeChanged,
    required this.onVideoSelected,
    required this.onAudioSelected,
  });

  final FormatKind mode;
  final VideoInfo video;
  final Format? selectedVideo;
  final Format? selectedAudio;
  final ValueChanged<FormatKind> onModeChanged;
  final ValueChanged<Format> onVideoSelected;
  final ValueChanged<Format> onAudioSelected;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Format',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            SegmentedButton<FormatKind>(
              segments: const [
                ButtonSegment(
                    value: FormatKind.video,
                    label: Text('Video'),
                    icon: Icon(Icons.videocam_outlined)),
                ButtonSegment(
                    value: FormatKind.audio,
                    label: Text('Audio'),
                    icon: Icon(Icons.audiotrack_outlined)),
              ],
              selected: {mode},
              onSelectionChanged: (s) => onModeChanged(s.first),
            ),
            const SizedBox(height: 16),
            if (mode == FormatKind.video) ...[
              Text('Quality',
                  style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final f in video.videoFormats)
                    ChoiceChip(
                      label: Text(f.label),
                      selected: selectedVideo?.selector == f.selector,
                      onSelected: (_) => onVideoSelected(f),
                    ),
                ],
              ),
            ] else ...[
              Text('Audio',
                  style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final f in video.audioFormats)
                    ChoiceChip(
                      label: Text(f.label),
                      selected: selectedAudio?.selector == f.selector,
                      onSelected: (_) => onAudioSelected(f),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
