import 'package:flutter/material.dart';

import '../../../core/models/settings_model.dart';
import '../../../core/models/video_info.dart';

/// Opens the download format picker as a bottom sheet.
///
/// Returns the chosen [Format], or `null` when the sheet is dismissed. The
/// initial pick is seeded from [settings] (`defaultAudioOnly` /
/// `defaultVideoTier`) every time the sheet opens, so a changed default
/// always takes effect on the next download.
Future<Format?> showFormatPickerSheet(
  BuildContext context, {
  required VideoInfo video,
  required AppSettings settings,
}) {
  return showModalBottomSheet<Format>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (context) => _FormatPickerSheet(video: video, settings: settings),
  );
}

class _FormatPickerSheet extends StatefulWidget {
  const _FormatPickerSheet({required this.video, required this.settings});

  final VideoInfo video;
  final AppSettings settings;

  @override
  State<_FormatPickerSheet> createState() => _FormatPickerSheetState();
}

class _FormatPickerSheetState extends State<_FormatPickerSheet> {
  late FormatKind _mode;
  Format? _videoSel;
  Format? _audioSel;

  bool get _hasVideo => widget.video.videoFormats.isNotEmpty;
  bool get _hasAudio => widget.video.audioFormats.isNotEmpty;

  @override
  void initState() {
    super.initState();
    final settings = widget.settings;
    // Audio wins when the user asked for audio-only, or when there are no
    // downloadable video streams (e.g. no ffmpeg to merge split streams).
    var mode = settings.defaultAudioOnly || !_hasVideo
        ? FormatKind.audio
        : FormatKind.video;
    if (mode == FormatKind.audio && !_hasAudio && _hasVideo) {
      mode = FormatKind.video;
    }
    _mode = mode;
    _videoSel = _hasVideo ? _defaultVideoFormat(widget.video, settings) : null;
    _audioSel = _hasAudio ? widget.video.audioFormats.first : null;
  }

  /// Picks the video format matching the saved default tier, falling back to
  /// Best when the requested tier is above the source's maximum.
  static Format _defaultVideoFormat(VideoInfo video, AppSettings settings) {
    final tier = settings.defaultVideoTier;
    if (tier != null) {
      for (final f in video.videoFormats) {
        if (f.tier == tier) return f;
      }
    }
    return video.videoFormats.first;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final options = _mode == FormatKind.video
        ? widget.video.videoFormats
        : widget.video.audioFormats;
    final selected = _mode == FormatKind.video ? _videoSel : _audioSel;
    final isVideoMode = _mode == FormatKind.video;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.video.title,
              style: theme.textTheme.titleMedium,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),
            SegmentedButton<FormatKind>(
              segments: [
                ButtonSegment(
                  value: FormatKind.video,
                  label: const Text('Video'),
                  icon: const Icon(Icons.videocam_outlined),
                  enabled: _hasVideo,
                ),
                ButtonSegment(
                  value: FormatKind.audio,
                  label: const Text('Audio'),
                  icon: const Icon(Icons.audiotrack_outlined),
                  enabled: _hasAudio,
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            // Explain a disabled Video segment instead of leaving the user
            // guessing why the picker landed on Audio.
            if (!_hasVideo && _hasAudio) ...[
              const SizedBox(height: 8),
              Text(
                'No downloadable video streams (needs ffmpeg to merge) — '
                'audio only.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              isVideoMode ? 'Quality' : 'Audio quality',
              style: theme.textTheme.labelMedium,
            ),
            const SizedBox(height: 8),
            // Scrollable so a long quality list can never push the Download
            // button off a short screen (or in landscape).
            Flexible(
              child: SingleChildScrollView(
                child: options.isEmpty
                    ? Text(
                        isVideoMode
                            ? 'No video streams available for this video.'
                            : 'No audio streams available for this video.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      )
                    : Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final f in options)
                            ChoiceChip(
                              label: Text(f.label),
                              // Always select, never toggle off, so a
                              // Download is always possible.
                              selected: selected?.selector == f.selector,
                              onSelected: (_) => setState(() {
                                if (isVideoMode) {
                                  _videoSel = f;
                                } else {
                                  _audioSel = f;
                                }
                              }),
                            ),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: selected == null
                    ? null
                    : () => Navigator.of(context).pop(selected),
                icon: const Icon(Icons.download),
                label: const Text('Download'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
