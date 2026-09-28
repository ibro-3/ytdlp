import 'package:flutter/material.dart';

import '../../../core/models/command_template.dart';
import '../../../core/models/download_options.dart';
import '../../../core/models/output_template.dart';
import '../../../core/models/settings_model.dart';
import '../../../core/models/video_info.dart';
import '../../../services/ytdlp/arg_tokenizer.dart';

/// What the user picked in the format sheet: a [Format] plus any subtitle
/// and thumbnail extras. `null` from [showFormatPickerSheet] means dismissed.
class FormatPickerResult {
  const FormatPickerResult({
    required this.format,
    required this.options,
    this.extraArgs,
    this.outputTemplate,
  });

  final Format format;
  final DownloadOptions options;

  /// A one-off argument override typed into the sheet's Advanced section.
  /// Empty means "use the Settings default", so the normal path is unaffected.
  final String? extraArgs;

  /// A one-off output template. Empty means "use the Settings default".
  final String? outputTemplate;
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
  List<CommandTemplate> templates = const [],
}) {
  return showModalBottomSheet<FormatPickerResult>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (context) => _FormatPickerSheet(
      video: video,
      settings: settings,
      templates: templates,
    ),
  );
}

class _FormatPickerSheet extends StatefulWidget {
  const _FormatPickerSheet({
    required this.video,
    required this.settings,
    this.templates = const [],
  });

  final VideoInfo video;
  final AppSettings settings;

  /// Saved argument templates offered as chips. Empty is fine — the field is
  /// still freely editable.
  final List<CommandTemplate> templates;

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

  /// One-off extra arguments for this download, seeded from Settings and
  /// pre-filled with the arguments of the chosen template when there is one.
  late final TextEditingController _extraArgs = TextEditingController(
    text: widget.settings.extraArgs,
  );

  /// The saved template whose arguments are currently in the field, so its
  /// chip can show as selected. Empty when the text was edited by hand.
  late String _activeTemplate = _templateNameFor(widget.settings.extraArgs);

  /// Name of the saved template matching [args], or '' when it is custom text.
  String _templateNameFor(String args) {
    if (args.trim().isEmpty) return '';
    for (final t in widget.templates) {
      if (t.args.trim() == args.trim()) return t.name;
    }
    return '';
  }

  List<ArgIssue> get _extraArgsIssues => validateExtraArgs(_extraArgs.text);

  bool get _extraArgsBlocked => _extraArgsIssues.any((i) => i.isBlocking);

  /// Output template for this download. Starts empty so the Settings default
  /// applies unless the user actually edits it; the sheet is one-off, so it
  /// never writes the value back to Settings.
  final TextEditingController _template = TextEditingController();

  bool get _hasVideo => widget.video.videoFormats.isNotEmpty;
  bool get _hasAudio => widget.video.audioFormats.isNotEmpty;
  bool get _hasSubtitles => widget.video.subtitleTracks.isNotEmpty;

  /// Whether yt-dlp can postprocess here. Embed options are gated on this
  /// rather than on ffmpeg alone, because postprocessing additionally needs
  /// ffprobe — offering them without it yields "ffprobe not found".
  bool get _canEmbed => widget.video.canPostprocess;

  /// Whether a cover image survives the postprocessing the user's yt-dlp
  /// preferences ask for.
  ///
  /// `--extract-audio` into WAV, for instance, has nowhere to put cover art, so
  /// yt-dlp would drop it without reporting anything. Not a toggle any more —
  /// this decides whether to say so, because an audio download that silently
  /// loses its cover art looks like a bug.
  bool get _canTargetEmbedThumb => widget.settings.ytPrefs.canEmbedThumbnail;

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
    // Derived, not offered: audio tracks get cover art, video files do not.
    embedThumb: DownloadOptions.coverArtDefault(_mode),
  );

  @override
  void dispose() {
    _extraArgs.dispose();
    _template.dispose();
    super.dispose();
  }

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
                    // Cover art is derived from the mode rather than offered as
                    // a toggle, but it is conditional on ffmpeg and on the
                    // target container, so it is still worth saying out loud
                    // when it will not happen.
                    if (!isVideoMode) ...[
                      const SizedBox(height: 8),
                      Text(
                        !_canEmbed
                            ? 'The thumbnail is not embedded: this needs ffmpeg '
                                  'and ffprobe.'
                            : !_canTargetEmbedThumb
                            ? 'The chosen conversion cannot hold cover art, so '
                                  'the thumbnail is left out.'
                            : 'The thumbnail is embedded as cover art.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    _sectionLabel(theme, 'Advanced'),
                    const SizedBox(height: 8),
                    _buildExtraArgs(theme),
                    const SizedBox(height: 20),
                    _sectionLabel(theme, 'File name'),
                    const SizedBox(height: 8),
                    _buildOutputTemplate(theme),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                // A malformed argument field is refused rather than silently
                // dropped, since the user would not get the download they
                // asked for.
                onPressed:
                    selected == null ||
                        _extraArgsBlocked ||
                        _templateIssues.isNotEmpty
                    ? null
                    : () => Navigator.of(context).pop(
                        FormatPickerResult(
                          format: selected,
                          options: _options,
                          extraArgs: _extraArgs.text,
                          outputTemplate: _template.text,
                        ),
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

  /// Extra yt-dlp flags for this download only.
  ///
  /// The field starts from the Settings default, so most users never touch it;
  /// saved templates fill it in as chips. Validation runs on every keystroke so
  /// a syntax error is visible before the Download button is pressed.
  Widget _buildExtraArgs(ThemeData theme) {
    final scheme = theme.colorScheme;
    final issues = _extraArgsIssues;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _extraArgs,
          onChanged: (_) => setState(() => _activeTemplate = ''),
          minLines: 1,
          maxLines: 3,
          style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'e.g. --concurrent-fragments 4 --embed-metadata',
            border: const OutlineInputBorder(),
            errorText: issues.where((i) => i.isBlocking).firstOrNull?.message,
          ),
        ),
        if (widget.templates.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in widget.templates)
                ChoiceChip(
                  label: Text(t.name),
                  selected: _activeTemplate == t.name,
                  onSelected: (_) => _patch(() {
                    _extraArgs.text = t.args;
                    _activeTemplate = t.name;
                  }),
                ),
            ],
          ),
        ],
        for (final issue in issues.where((i) => !i.isBlocking))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 14,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    issue.message,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// The output template for this download, with a live preview.
  ///
  /// Only offered when it differs from the saved default: changing it here
  /// affects one download, while Settings holds the persistent value.
  Widget _buildOutputTemplate(ThemeData theme) {
    final current = widget.settings.outputTemplate;
    final template = OutputTemplate(_template.text);
    final issues = _templateIssues;
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _template,
          onChanged: (_) => setState(() {}),
          style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          decoration: InputDecoration(
            isDense: true,
            hintText: OutputTemplate.defaultTemplate,
            border: const OutlineInputBorder(),
            errorText: issues.isEmpty ? null : issues.first,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Saves as: ${template.preview(video: widget.video)}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            fontFamily: 'monospace',
            color: scheme.onSurfaceVariant,
          ),
        ),
        if (current.trim().isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            'Your default template is different and will be restored if you '
            'clear this field.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  List<String> get _templateIssues {
    final t = OutputTemplate(_template.text);
    if (t.raw.trim().isEmpty) return const [];
    if (!t.isUsable) {
      return [
        'Include ${OutputTemplate.extField} so the app can tell the media '
            'file from its sidecars.',
      ];
    }
    return const [];
  }
}
