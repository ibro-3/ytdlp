import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/models/command_template.dart';
import '../../core/models/output_template.dart';
import '../../core/models/settings_model.dart';
import '../../core/models/video_info.dart';
import '../../core/models/yt_prefs.dart';
import '../../core/providers.dart';
import '../../services/settings/template_store.dart';
import '../../services/ytdlp/arg_tokenizer.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  String? _version;
  bool _versionLoading = false;
  bool _updating = false;
  String? _engineMessage;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _patch(AppSettings next) =>
      ref.read(settingsControllerProvider.notifier).patch(next);

  static String _audioTierLabel(int? t) => switch (t) {
    null => 'Best audio',
    192 => 'High',
    128 => 'Medium',
    96 => 'Low',
    _ => '$t',
  };

  Future<void> _loadVersion() async {
    setState(() {
      _versionLoading = true;
      _engineMessage = null;
    });
    try {
      final v = await ref.read(binaryManagerProvider).ytdlpVersion();
      if (mounted) setState(() => _version = v);
    } catch (e) {
      if (mounted) setState(() => _engineMessage = e.toString());
    } finally {
      if (mounted) setState(() => _versionLoading = false);
    }
  }

  /// Updates yt-dlp from its fixed upstream source — there is nothing to
  /// configure, so this is just the button.
  Future<void> _updateEngine() async {
    setState(() {
      _updating = true;
      _engineMessage = null;
    });
    try {
      final v = await ref.read(binaryManagerProvider).updateYtdlp();
      if (mounted) {
        setState(() {
          _version = v;
          _engineMessage = 'Updated — yt-dlp $v';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _engineMessage = e.toString());
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  Future<void> _pickDownloadFolder() async {
    final messenger = ScaffoldMessenger.of(context);
    String? picked;
    try {
      picked = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose download folder',
      );
    } catch (_) {
      picked = null; // Picker unavailable (e.g. no platform tooling).
    }
    if (picked == null || picked.isEmpty) return; // Cancelled or unsupported.
    final problem = await _validateWritableFolder(picked);
    if (problem != null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(problem)));
      return;
    }
    await _patch(
      ref.read(settingsControllerProvider).copyWith(downloadRoot: picked),
    );
  }

  void _resetDownloadFolder() =>
      _patch(ref.read(settingsControllerProvider).copyWith(downloadRoot: ''));

  /// Imports a Netscape-format `cookies.txt`.
  ///
  /// The file is copied into the app's support directory so the picked path
  /// can't stop resolving (Android pickers hand back cache paths, and desktop
  /// users may pick a file on removable media), then yt-dlp is pointed at the
  /// copy via `--cookies`.
  Future<void> _pickCookiesFile() async {
    final messenger = ScaffoldMessenger.of(context);
    PlatformFile? picked;
    try {
      picked = await FilePicker.pickFile(
        dialogTitle: 'Choose cookies.txt',
        type: FileType.custom,
        allowedExtensions: const ['txt'],
      );
    } catch (_) {
      picked = null; // Picker unavailable on this platform.
    }
    if (picked == null) return; // Cancelled.

    List<int>? bytes;
    try {
      bytes = await picked.readAsBytes();
    } catch (_) {
      final path = picked.path;
      if (path == null) {
        bytes = null;
      } else {
        try {
          bytes = await File(path).readAsBytes();
        } catch (_) {
          bytes = null;
        }
      }
    }
    if (bytes == null || bytes.isEmpty) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text("Couldn't read that file")),
        );
      return;
    }
    if (!_looksLikeCookieJar(bytes)) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text(
              'That does not look like a cookies.txt (Netscape format)',
            ),
          ),
        );
      return;
    }
    try {
      final support = await getApplicationSupportDirectory();
      final target = File('${support.path}/cookies.txt');
      await target.parent.create(recursive: true);
      await target.writeAsBytes(bytes, flush: true);
      await _patch(
        ref.read(settingsControllerProvider).copyWith(cookiesPath: target.path),
      );
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Cookies saved')));
    } catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text("Couldn't save the cookies: $e")),
        );
    }
  }

  /// A cookie jar starts with `# Netscape HTTP Cookie File` or a row of
  /// tab-separated fields; anything else is rejected before it reaches
  /// yt-dlp, which would otherwise fail every download with a parse error.
  static bool _looksLikeCookieJar(List<int> bytes) {
    String text;
    try {
      text = utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return false;
    }
    for (final line in const LineSplitter().convert(text)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('#')) {
        if (trimmed.contains('Netscape HTTP Cookie File')) return true;
        continue;
      }
      // domain \t flag \t path \t secure \t expiry \t name \t value
      return trimmed.split('\t').length >= 7;
    }
    return false;
  }

  /// A picked folder must be a real, writable filesystem path — yt-dlp runs
  /// as a child process and can only write by path (not via SAF `content://`).
  static Future<String?> _validateWritableFolder(String path) async {
    if (path.startsWith('content://')) {
      return 'That location can\'t be used — pick a folder on this device.';
    }
    final probe = File(
      p.join(
        path,
        '.ytdlp-write-test-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    try {
      await probe.writeAsString('ok');
      try {
        await probe.delete();
      } catch (_) {}
      return null;
    } catch (_) {
      return 'The app can\'t write to that folder. Pick another one, '
          'or reset to the default.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsControllerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
              children: [
                _Section(
                  title: 'Appearance',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SegmentedButton<ThemeMode>(
                        segments: const [
                          ButtonSegment(
                            value: ThemeMode.system,
                            label: Text('System'),
                            icon: Icon(Icons.settings_suggest_outlined),
                          ),
                          ButtonSegment(
                            value: ThemeMode.light,
                            label: Text('Light'),
                            icon: Icon(Icons.light_mode_outlined),
                          ),
                          ButtonSegment(
                            value: ThemeMode.dark,
                            label: Text('Dark'),
                            icon: Icon(Icons.dark_mode_outlined),
                          ),
                        ],
                        selected: {settings.themeMode},
                        onSelectionChanged: (s) =>
                            _patch(settings.copyWith(themeMode: s.first)),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Theme color',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          for (final (name, value) in AppSettings.seedOptions)
                            _SeedSwatch(
                              name: name,
                              color: Color(value),
                              selected: settings.seedColor == value,
                              onTap: () =>
                                  _patch(settings.copyWith(seedColor: value)),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _Section(
                  title: 'Downloads',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.folder_outlined),
                        title: const Text('Download folder'),
                        subtitle: Text(
                          settings.downloadRoot.isEmpty
                              ? 'Default (platform Downloads folder)'
                              : settings.downloadRoot,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (settings.downloadRoot.isNotEmpty)
                              IconButton(
                                icon: const Icon(Icons.refresh),
                                tooltip: 'Reset to default',
                                onPressed: _resetDownloadFolder,
                              ),
                            IconButton(
                              icon: const Icon(Icons.folder_open),
                              tooltip: settings.downloadRoot.isEmpty
                                  ? 'Choose folder'
                                  : 'Change folder',
                              onPressed: _pickDownloadFolder,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Videos and audio are saved in separate Video/ and '
                        'Audio/ subfolders. Playlist entries later group into '
                        'one folder per playlist inside the matching one.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Default video quality',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final t in AppSettings.videoTierOptions)
                            ChoiceChip(
                              label: Text(t == null ? 'Best quality' : '${t}p'),
                              selected: settings.defaultVideoTier == t,
                              onSelected: (_) => _patch(
                                settings.copyWith(defaultVideoTier: () => t),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Default audio quality',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final t in AppSettings.audioTierOptions)
                            ChoiceChip(
                              label: Text(_audioTierLabel(t)),
                              selected: settings.defaultAudioTier == t,
                              onSelected: (_) => _patch(
                                settings.copyWith(defaultAudioTier: () => t),
                              ),
                            ),
                        ],
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Audio only by default'),
                        subtitle: const Text(
                          'Pre-select M4A audio when opening the download '
                          'format sheet',
                        ),
                        value: settings.defaultAudioOnly,
                        onChanged: (v) =>
                            _patch(settings.copyWith(defaultAudioOnly: v)),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Subtitle & thumbnail defaults',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                      const SizedBox(height: 4),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text('Subtitles next to the file'),
                        subtitle: const Text('.srt/.vtt sidecar'),
                        value: settings.defaultWriteSubs,
                        onChanged: (v) =>
                            _patch(settings.copyWith(defaultWriteSubs: v)),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text('Embed subtitles'),
                        subtitle: const Text('Only when ffmpeg is available'),
                        value: settings.defaultEmbedSubs,
                        onChanged: (v) =>
                            _patch(settings.copyWith(defaultEmbedSubs: v)),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text('Include auto-generated captions'),
                        subtitle: const Text('Machine captions, marked "auto"'),
                        value: settings.defaultIncludeAutoSubs,
                        onChanged: (v) => _patch(
                          settings.copyWith(defaultIncludeAutoSubs: v),
                        ),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text('Embed thumbnail as cover art'),
                        subtitle: const Text('Only when ffmpeg is available'),
                        value: settings.defaultEmbedThumb,
                        onChanged: (v) =>
                            _patch(settings.copyWith(defaultEmbedThumb: v)),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text('Save thumbnail (.jpg)'),
                        subtitle: const Text('Next to the media file'),
                        value: settings.defaultWriteThumb,
                        onChanged: (v) =>
                            _patch(settings.copyWith(defaultWriteThumb: v)),
                      ),
                      const SizedBox(height: 16),
                      _AdvancedSettings(settings: settings, onPatch: _patch),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.cookie_outlined),
                        title: const Text('Cookies (optional)'),
                        subtitle: Text(
                          settings.cookiesPath.isEmpty
                              ? 'Off — some sites need a cookies.txt to allow '
                                    'downloads'
                              : p.basename(settings.cookiesPath),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (settings.cookiesPath.isNotEmpty)
                              IconButton(
                                icon: const Icon(Icons.close),
                                tooltip: 'Remove cookies',
                                onPressed: () =>
                                    _patch(settings.copyWith(cookiesPath: '')),
                              ),
                            IconButton(
                              icon: const Icon(Icons.folder_open),
                              tooltip: settings.cookiesPath.isEmpty
                                  ? 'Choose cookies.txt'
                                  : 'Change cookies.txt',
                              onPressed: _pickCookiesFile,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _Section(
                  title: 'Engine',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.terminal_outlined),
                        title: const Text('yt-dlp'),
                        subtitle: Text(
                          _versionLoading
                              ? 'Checking…'
                              : _version == null
                              ? 'Not installed'
                              : 'v$_version',
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.refresh),
                          tooltip: 'Check version',
                          onPressed: _versionLoading ? null : _loadVersion,
                        ),
                      ),
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        onPressed: _updating ? null : _updateEngine,
                        icon: _updating
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.system_update_outlined),
                        label: Text(_updating ? 'Updating…' : 'Update yt-dlp'),
                      ),
                      if (_engineMessage != null) ...[
                        const SizedBox(height: 8),
                        SelectableText(
                          _engineMessage!,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _Section(
                  title: 'Notifications',
                  child: Column(
                    children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Download notifications'),
                        subtitle: const Text(
                          'Progress and completion alerts (Android 13+ asks for permission)',
                        ),
                        value: settings.notificationsEnabled,
                        onChanged: (v) async {
                          var enable = v;
                          if (v && Platform.isAndroid) {
                            enable = await ref
                                .read(notificationServiceProvider)
                                .requestPermission();
                            if (!enable && context.mounted) {
                              ScaffoldMessenger.of(context)
                                ..hideCurrentSnackBar()
                                ..showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Notification permission was denied. '
                                      'Allow it in system settings to get '
                                      'download alerts.',
                                    ),
                                  ),
                                );
                            }
                          }
                          await _patch(
                            settings.copyWith(notificationsEnabled: enable),
                          );
                        },
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FilledButton.tonalIcon(
                          onPressed: () {
                            ref
                                .read(notificationServiceProvider)
                                .showDone(
                                  taskId:
                                      'test-${DateTime.now().millisecondsSinceEpoch}',
                                  title: 'Notifications work',
                                  success: true,
                                  detail: 'You will see progress here during downloads.',
                                );
                            ScaffoldMessenger.of(context)
                              ..hideCurrentSnackBar()
                              ..showSnackBar(
                                const SnackBar(
                                  content: Text('Test notification sent'),
                                ),
                              );
                          },
                          icon: const Icon(Icons.notifications_outlined),
                          label: const Text('Send test notification'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Extra yt-dlp flags and the output template.
///
/// Collapsed by default: the escape hatch is powerful and easy to get wrong,
/// and the common case is that none of it is needed. Expanding it is how a
/// user discovers the field exists at all.
class _AdvancedSettings extends ConsumerStatefulWidget {
  const _AdvancedSettings({required this.settings, required this.onPatch});

  final AppSettings settings;
  final Future<void> Function(AppSettings) onPatch;

  @override
  ConsumerState<_AdvancedSettings> createState() => _AdvancedSettingsState();
}

class _AdvancedSettingsState extends ConsumerState<_AdvancedSettings> {
  final TextEditingController _args = TextEditingController();
  final TextEditingController _template = TextEditingController();
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _syncFromSettings();
  }

  /// Seeds the fields from persisted settings, once.
  ///
  /// Done in initState rather than build because the fields are free text: a
  /// rebuild while the user is mid-word must not rewrite what they typed.
  void _syncFromSettings() {
    if (_loaded) return;
    _args.text = widget.settings.extraArgs;
    _template.text = widget.settings.outputTemplate;
    _loaded = true;
  }

  @override
  void dispose() {
    _args.dispose();
    _template.dispose();
    super.dispose();
  }

  List<ArgIssue> get _issues => validateExtraArgs(_args.text);

  List<String> get _templateIssues {
    final t = OutputTemplate(_template.text);
    if (t.raw.trim().isEmpty) return const [];
    if (!t.isUsable) {
      return [
        'Must include ${OutputTemplate.extField} so the app can tell the media '
            'file from a subtitle or thumbnail sidecar.',
      ];
    }
    return const [];
  }

  bool get _valid =>
      !_issues.any((i) => i.isBlocking) && _templateIssues.isEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final store = ref.watch(templateStoreProvider);
    final issues = _issues;
    final templateErrors = _templateIssues;

    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      title: const Text('Advanced'),
      subtitle: Text(
        widget.settings.extraArgs.trim().isEmpty &&
                widget.settings.outputTemplate.trim().isEmpty
            ? 'Extra yt-dlp flags and file naming'
            : 'Custom flags and template set',
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text('Extra yt-dlp flags', style: theme.textTheme.labelMedium),
        ),
        const SizedBox(height: 4),
        Text(
          'Added to every download. Flags the app sets itself — output path, '
          'format, playlist — are ignored so a download cannot escape its '
          'folder.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _args,
          minLines: 1,
          maxLines: 4,
          onChanged: (_) => setState(() {}),
          style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          decoration: InputDecoration(
            isDense: true,
            hintText: '--concurrent-fragments 4 --embed-metadata',
            border: const OutlineInputBorder(),
            errorText: issues.where((i) => i.isBlocking).firstOrNull?.message,
          ),
        ),
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
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                'Saved templates',
                style: theme.textTheme.labelMedium,
              ),
            ),
            if (store.templates.isNotEmpty)
              TextButton(
                onPressed: () => store.clear(),
                child: const Text('Clear all'),
              ),
          ],
        ),
        const SizedBox(height: 4),
        if (store.templates.isEmpty)
          Text(
            'None saved yet.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in store.templates)
                InputChip(
                  label: Text(t.name),
                  onPressed: () => setState(() => _args.text = t.args),
                  onDeleted: () => store.remove(t.name),
                  deleteButtonTooltipMessage: 'Delete ${t.name}',
                ),
            ],
          ),
        const SizedBox(height: 8),
        _SaveTemplateButton(args: _args.text, store: store),
        const SizedBox(height: 24),
        _YtPrefsSection(settings: widget.settings, onPatch: widget.onPatch),
        const SizedBox(height: 24),
        Align(
          alignment: Alignment.centerLeft,
          child: Text('File name template', style: theme.textTheme.labelMedium),
        ),
        const SizedBox(height: 4),
        Text(
          'yt-dlp output template. Must end in an extension so the app can tell '
          'the media file from its sidecars.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _template,
          onChanged: (_) => setState(() {}),
          style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          decoration: InputDecoration(
            isDense: true,
            hintText: OutputTemplate.defaultTemplate,
            border: const OutlineInputBorder(),
            errorText: templateErrors.isEmpty ? null : templateErrors.first,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Example: ${OutputTemplate(_template.text).preview(video: _sampleVideo)}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            fontFamily: 'monospace',
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (field, label) in OutputTemplate.knownFields)
              ActionChip(
                label: Text(label),
                onPressed: () => setState(() => _insertField(field)),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                describeTemplate(_template.text),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            TextButton(
              onPressed: () => setState(() => _template.text = ''),
              child: const Text('Reset'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          onPressed: _valid
              ? () => widget.onPatch(
                  widget.settings.copyWith(
                    extraArgs: _args.text,
                    outputTemplate: _template.text,
                  ),
                )
              : null,
          icon: const Icon(Icons.save_outlined),
          label: const Text('Save advanced settings'),
        ),
      ],
    );
  }

  /// Appends a field token at the caret, so a half-typed template is not
  /// destroyed by tapping a chip.
  void _insertField(String field) {
    final text = _template.text;
    _template.text = '$text$field';
    _template.selection = TextSelection.collapsed(
      offset: _template.text.length,
    );
  }
}

/// First-class yt-dlp capability controls.
///
/// Split from the raw extra-args field because each of these has a value that
/// must be *right* rather than merely typed: a fragment count that is too high
/// fails a download outright, and a conversion into a container that cannot
/// hold the chosen extras silently drops them.
class _YtPrefsSection extends ConsumerWidget {
  const _YtPrefsSection({required this.settings, required this.onPatch});

  final AppSettings settings;
  final Future<void> Function(AppSettings) onPatch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = settings.ytPrefs;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // Patches only the prefs, so a change here cannot clobber an unrelated
    // setting like the download folder.
    void patch(YtPrefs next) => onPatch(settings.copyWith(ytPrefs: next));

    // Postprocessing needs ffprobe, not just ffmpeg — the same gate the format
    // sheet's embed toggles use. Resolved asynchronously so the section paints
    // immediately and the toggles enable once the probe is known.
    return FutureBuilder<bool>(
      future: _canPostprocess(ref),
      builder: (context, snapshot) {
        final canPost = snapshot.data ?? false;
        // Shown when postprocessing is configured but the capability is
        // missing, since the flags are then silently dropped.
        final unavailableButOn = prefs.needsPostprocessing && !canPost;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'yt-dlp capabilities',
                style: theme.textTheme.labelMedium,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Common flags as controls. Everything here is also available as a '
              'raw flag below, but these validate their own values.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Text('Speed', style: theme.textTheme.labelSmall),
            _intSlider(
              context,
              label: 'Parallel fragments',
              value: prefs.concurrentFragments,
              min: 1,
              max: YtPrefs.maxConcurrentFragments,
              // A low cap is the point: 16 fragments on a phone can fail the
              // download outright for a few percent of throughput.
              helper: prefs.concurrentFragments == 1
                  ? "yt-dlp's default. Raise it to download DASH/HLS "
                        'fragments in parallel.'
                  : 'Higher can fail on a memory-constrained device.',
              onChanged: (v) => patch(prefs.copyWith(concurrentFragments: v)),
            ),
            _textField(
              theme: theme,
              label: 'Rate limit',
              hint: 'e.g. 2M, 500K — empty for no limit',
              value: prefs.limitRate,
              onChanged: (v) => patch(prefs.copyWith(limitRate: v.trim())),
            ),
            _intField(
              theme: theme,
              label: 'Delay between requests (s)',
              value: prefs.sleepRequests,
              onChanged: (v) => patch(prefs.copyWith(sleepRequests: v)),
            ),
            const Divider(height: 28),
            Text('Post-processing', style: theme.textTheme.labelSmall),
            _postprocessingNote(theme, canPost),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Convert to audio only'),
              subtitle: Text(
                !canPost
                    ? 'Needs ffmpeg and ffprobe (not available)'
                    : 'Re-encodes the audio into another container',
              ),
              value: prefs.extractAudio,
              onChanged: canPost
                  ? (v) => patch(prefs.copyWith(extractAudio: v))
                  : null,
            ),
            if (prefs.extractAudio)
              _choiceChips(
                context,
                label: 'Audio format',
                options: YtPrefs.audioFormats,
                selected: prefs.audioFormat,
                onChanged: (v) => patch(prefs.copyWith(audioFormat: v)),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Remux (no re-encode)'),
              subtitle: Text(
                !canPost
                    ? 'Needs ffmpeg and ffprobe (not available)'
                    : 'Change container without re-encoding — quality is kept',
              ),
              value: prefs.remuxVideo.isNotEmpty,
              onChanged: canPost
                  ? (v) => patch(prefs.copyWith(remuxVideo: v ? 'mkv' : ''))
                  : null,
            ),
            if (prefs.remuxVideo.isNotEmpty)
              _choiceChips(
                context,
                label: 'Remux target',
                options: YtPrefs.remuxFormats,
                selected: prefs.remuxVideo,
                onChanged: (v) => patch(prefs.copyWith(remuxVideo: v)),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Embed metadata'),
              subtitle: Text(
                !canPost
                    ? 'Needs ffmpeg and ffprobe (not available)'
                    : 'Title, artist and date in the file',
              ),
              value: prefs.embedMetadata,
              onChanged: canPost
                  ? (v) => patch(prefs.copyWith(embedMetadata: v))
                  : null,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Embed chapters'),
              value: prefs.embedChapters,
              onChanged: canPost
                  ? (v) => patch(prefs.copyWith(embedChapters: v))
                  : null,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Remove sponsor segments'),
              subtitle: Text(
                !canPost
                    ? 'Needs ffmpeg and ffprobe (not available)'
                    : 'Cuts out SponsorBlock segments',
              ),
              value: prefs.sponsorblockRemove,
              onChanged: canPost
                  ? (v) => patch(prefs.copyWith(sponsorblockRemove: v))
                  : null,
            ),
            if (unavailableButOn)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Post-processing is switched on but ffprobe is not '
                  'available, so these flags are left off the command line.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.error,
                  ),
                ),
              ),
            const Divider(height: 28),
            Text('Network', style: theme.textTheme.labelSmall),
            _textField(
              theme: theme,
              label: 'Proxy',
              hint: 'socks5://host:port — empty for none',
              value: prefs.proxy,
              onChanged: (v) => patch(prefs.copyWith(proxy: v.trim())),
            ),
            _textField(
              theme: theme,
              label: 'Referer',
              hint: 'Some hosts require one',
              value: prefs.referer,
              onChanged: (v) => patch(prefs.copyWith(referer: v.trim())),
            ),
            const Divider(height: 28),
            Text('Behaviour', style: theme.textTheme.labelSmall),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Record livestreams from the start'),
              value: prefs.liveFromStart,
              onChanged: (v) => patch(prefs.copyWith(liveFromStart: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Skip already-downloaded videos'),
              subtitle: const Text(
                'Keeps a ledger in the app folder and skips anything in it',
              ),
              value: prefs.downloadArchive,
              onChanged: (v) => patch(prefs.copyWith(downloadArchive: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Write without a .part file'),
              subtitle: const Text(
                'No resume after a failure, but the file is visible while '
                'downloading',
              ),
              value: prefs.noPart,
              onChanged: (v) => patch(prefs.copyWith(noPart: v)),
            ),
          ],
        );
      },
    );
  }

  /// Resolves ffprobe availability without blocking the first frame.
  static Future<bool> _canPostprocess(WidgetRef ref) async {
    try {
      return await ref.read(binaryManagerProvider).hasFfprobe();
    } catch (_) {
      return false;
    }
  }

  Widget _postprocessingNote(ThemeData theme, bool canPost) {
    if (canPost) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        'These run through ffmpeg and ffprobe, which are not both available '
        'here, so they are disabled.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _intSlider(
    BuildContext context, {
    required String label,
    required int value,
    required int min,
    required int max,
    required String helper,
    required ValueChanged<int> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label: $value', style: Theme.of(context).textTheme.bodyMedium),
        Slider(
          value: value.toDouble().clamp(min.toDouble(), max.toDouble()),
          min: min.toDouble(),
          max: max.toDouble(),
          divisions: max - min,
          label: '$value',
          onChanged: (v) => onChanged(v.round()),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            helper,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Widget _textField({
    required ThemeData theme,
    required String label,
    required String hint,
    required String value,
    required ValueChanged<String> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextFormField(
        initialValue: value,
        onChanged: onChanged,
        decoration: InputDecoration(
          isDense: true,
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _intField({
    required ThemeData theme,
    required String label,
    required int value,
    required ValueChanged<int> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextFormField(
        initialValue: '$value',
        keyboardType: TextInputType.number,
        onChanged: (v) => onChanged(int.tryParse(v.trim()) ?? 0),
        decoration: InputDecoration(
          isDense: true,
          labelText: label,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _choiceChips(
    BuildContext context, {
    required String label,
    required List<String> options,
    required String selected,
    required ValueChanged<String> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final o in options)
                ChoiceChip(
                  label: Text(o.toUpperCase()),
                  selected: selected == o,
                  onSelected: (_) => onChanged(o),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Stand-in used to render the template preview, since the Settings page has
/// no specific video to show.
const _sampleVideo = VideoInfo(
  id: 'dQw4w9WgXcQ',
  title: 'Example Video Title',
  webUrl: 'https://example.com/watch',
  author: 'Example Channel',
  uploadDate: null,
);

/// Saves the current extra-args field as a named template.
class _SaveTemplateButton extends ConsumerStatefulWidget {
  const _SaveTemplateButton({required this.args, required this.store});

  final String args;
  final TemplateStore store;

  @override
  ConsumerState<_SaveTemplateButton> createState() =>
      _SaveTemplateButtonState();
}

class _SaveTemplateButtonState extends ConsumerState<_SaveTemplateButton> {
  final TextEditingController _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty || widget.args.trim().isEmpty) return;
    final issues = validateExtraArgs(widget.args);
    if (issues.any((i) => i.isBlocking)) return;
    final ok = await widget.store.save(
      CommandTemplate(name: name, args: widget.args.trim()),
    );
    if (!mounted) return;
    _name.clear();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            ok ? 'Saved template "$name"' : 'Could not save the template',
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final canSave =
        _name.text.trim().isNotEmpty &&
        widget.args.trim().isNotEmpty &&
        !validateExtraArgs(widget.args).any((i) => i.isBlocking);
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _name,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'Template name',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filledTonal(
          onPressed: canSave ? _save : null,
          icon: const Icon(Icons.bookmark_add_outlined),
          tooltip: 'Save these flags as a template',
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _SeedSwatch extends StatelessWidget {
  const _SeedSwatch({
    required this.name,
    required this.color,
    required this.selected,
    required this.onTap,
  });
  final String name;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: selected
                  ? Border.all(
                      color: Theme.of(context).colorScheme.onSurface,
                      width: 3,
                    )
                  : null,
            ),
            child: selected
                ? const Icon(Icons.check, color: Colors.white)
                : null,
          ),
          const SizedBox(height: 4),
          Text(name, style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
  }
}
