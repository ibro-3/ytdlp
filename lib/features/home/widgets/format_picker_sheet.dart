import 'package:flutter/material.dart';

import '../../../core/models/download_options.dart';
import '../../../core/models/settings_model.dart';
import '../../../core/models/video_info.dart';

/// What the user picked in the format sheet: a [Format] plus any subtitle
/// and thumbnail extras. `null` from [showFormatPickerSheet] means dismissed.
class FormatPickerResult {
  const FormatPickerResult({required this.format, required this.options});

  final Format format;
  final DownloadOptions options;
}

/// Opens the download format picker as a bottom sheet.
///
/// Returns the chosen [FormatPickerResult], or `null` when the sheet is
/// dismissed. The initial pick is seeded from [settings] (video tier, audio
/// tier/toggle, subtitle and thumbnail defaults) every time the sheet opens,
/// so a changed default always takes effect on the next download. Embed
/// options are only seeded when the video comes with ffmpeg.
Future<FormatPickerResult?> showFormatPickerSheet(
  BuildContext context, {
  required VideoInfo video,
  required AppSettings settings,
}) {
  return showModalBottomSheet<FormatPickerResult>(
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
  late bool _embedSubs;
  late bool _writeSubs;
  late bool _includeAuto;
  final Set<String> _subLangs = {};
  late bool _embedThumb;
  late bool _writeThumb;

  bool get _hasVideo => widget.video.videoFormats.isNotEmpty;
  bool get _hasAudio => widget.video.audioFormats.isNotEmpty;
  bool get _hasSubtitles => widget.video.subtitleTracks.isNotEmpty;

  /// Whether yt-dlp can postprocess here. Embed options are gated on this
  /// rather than on ffmpeg alone, because postprocessing additionally needs
  /// ffprobe — offering them without it yields "ffprobe not found".
  bool get _canEmbed => widget.video.canPostprocess;

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
    _audioSel = _hasAudio ? _defaultAudioFormat(widget.video, settings) : null;
    // Embed toggles only make sense when ffmpeg is actually reachable.
    _embedSubs = _canEmbed && settings.defaultEmbedSubs;
    _writeSubs = settings.defaultWriteSubs;
    _includeAuto = settings.defaultIncludeAutoSubs;
    _embedThumb = _canEmbed && settings.defaultEmbedThumb;
    _writeThumb = settings.defaultWriteThumb;
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

  /// Picks the audio tier matching the saved default (null = Best audio).
  static Format _defaultAudioFormat(VideoInfo video, AppSettings settings) {
    final tier = settings.defaultAudioTier;
    if (tier != null) {
      for (final f in video.audioFormats) {
        if (f.tier == tier) return f;
      }
    }
    return video.audioFormats.first;
  }

  DownloadOptions get _options => DownloadOptions(
    embedSubs: _mode == FormatKind.video && _embedSubs,
    writeSubs: _writeSubs,
    includeAutoSubs: _includeAuto,
    subLanguages: _subLangs.toList()..sort(),
    embedThumb: _embedThumb,
    writeThumb: _writeThumb,
  );

  void _patch(VoidCallback fn) => setState(fn);

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
              onSelectionChanged: (s) => _patch(() => _mode = s.first),
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
            // Everything but the Download button scrolls, so a long quality
            // list or extra options can never push it off a short screen
            // (or in landscape).
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isVideoMode ? 'Quality' : 'Audio quality',
                      style: theme.textTheme.labelMedium,
                    ),
                    const SizedBox(height: 8),
                    if (options.isEmpty)
                      Text(
                        isVideoMode
                            ? 'No video streams available for this video.'
                            : 'No audio streams available for this video.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      )
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final f in options)
                            ChoiceChip(
                              label: Text(f.label),
                              // Always select, never toggle off, so a
                              // Download is always possible.
                              selected: selected?.selector == f.selector,
                              onSelected: (_) => _patch(() {
                                if (isVideoMode) {
                                  _videoSel = f;
                                } else {
                                  _audioSel = f;
                                }
                              }),
                            ),
                        ],
                      ),
                    if (_hasSubtitles) ...[
                      const SizedBox(height: 20),
                      _sectionLabel(theme, 'Subtitles'),
                      const SizedBox(height: 4),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text('Save next to the file'),
                        subtitle: const Text('.srt or .vtt sidecar'),
                        value: _writeSubs,
                        onChanged: (v) => _patch(() => _writeSubs = v),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text('Embed in the file'),
                        subtitle: Text(
                          _canEmbed
                              ? (isVideoMode
                                    ? 'One file, no sidecars'
                                    : 'Not available for audio files')
                              : 'Needs ffmpeg (not available)',
                        ),
                        value: isVideoMode && _embedSubs,
                        onChanged: _canEmbed && isVideoMode
                            ? (v) => _patch(() => _embedSubs = v)
                            : null,
                      ),
                      if (_writeSubs || (isVideoMode && _embedSubs)) ...[
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: const Text('Include auto-generated'),
                          subtitle: const Text(
                            'Machine captions (marked "auto")',
                          ),
                          value: _includeAuto,
                          onChanged: (v) => _patch(() => _includeAuto = v),
                        ),
                        const SizedBox(height: 8),
                        _sectionLabel(theme, 'Languages'),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilterChip(
                              label: const Text('All available'),
                              selected: _subLangs.isEmpty,
                              onSelected: (_) =>
                                  _patch(() => _subLangs.clear()),
                            ),
                            for (final track in widget.video.subtitleTracks)
                              FilterChip(
                                label: Text(
                                  track.isAutoOnly
                                      ? '${track.name} (auto)'
                                      : track.name,
                                ),
                                selected: _subLangs.contains(track.lang),
                                onSelected: (v) => _patch(() {
                                  if (v) {
                                    _subLangs.add(track.lang);
                                  } else {
                                    _subLangs.remove(track.lang);
                                    // Deselecting the last language falls
                                    // back to "all available" — the chips
                                    // make that visible immediately.
                                  }
                                }),
                              ),
                          ],
                        ),
                      ],
                    ],
                    const SizedBox(height: 20),
                    _sectionLabel(theme, 'Thumbnail'),
                    const SizedBox(height: 4),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Embed as cover art'),
                      subtitle: Text(
                        _canEmbed
                            ? 'Shown in music apps and galleries'
                            : 'Needs ffmpeg (not available)',
                      ),
                      value: _embedThumb,
                      onChanged: _canEmbed
                          ? (v) => _patch(() => _embedThumb = v)
                          : null,
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Save .jpg next to the file'),
                      value: _writeThumb,
                      onChanged: (v) => _patch(() => _writeThumb = v),
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
                    : () => Navigator.of(context).pop(
                        FormatPickerResult(format: selected, options: _options),
                      ),
                icon: const Icon(Icons.download),
                label: const Text('Download'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(ThemeData theme, String label) => Text(
    label,
    style: theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.primary,
    ),
  );
}
