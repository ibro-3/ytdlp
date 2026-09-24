import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/models/settings_model.dart';
import '../../core/providers.dart';

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
