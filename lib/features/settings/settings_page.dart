import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../core/models/command_template.dart';
import '../../core/models/cookie_browser.dart';
import '../../core/models/cookie_profiles.dart';
import '../../core/models/output_template.dart';
import '../../core/models/settings_model.dart';
import '../../core/models/video_info.dart';
import '../../core/models/yt_prefs.dart';
import '../../core/models/youtube_prefs.dart';
import '../../core/providers.dart';
import '../../services/cookies/cookie_jar.dart';
import '../../services/settings/backup_service.dart';
import '../../services/settings/template_store.dart';
import '../../services/updates/app_update_service.dart';
import 'cookie_domains_page.dart';
import '../../services/ytdlp/arg_tokenizer.dart';
import '../../services/ytdlp/binary_manager.dart';
import '../../services/ytdlp/ejs_installer.dart';
import '../../widgets/tab_carousel.dart';

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

  /// The app itself, alongside the engine above it. This is a separate check:
  /// the yt-dlp updater can say "current" while the app build itself is behind
  /// the latest release.
  AppUpdateResult? _appUpdate;
  bool _checkingAppUpdate = false;
  String? _appUpdateError;

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _checkAppUpdate();
  }

  Future<void> _checkAppUpdate() async {
    if (_checkingAppUpdate) return;
    setState(() {
      _checkingAppUpdate = true;
      _appUpdateError = null;
    });
    try {
      final result = await AppUpdater().check();
      if (mounted) setState(() => _appUpdate = result);
    } catch (e) {
      if (mounted) setState(() => _appUpdateError = e.toString());
    } finally {
      if (mounted) setState(() => _checkingAppUpdate = false);
    }
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
  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Writes settings and templates to a JSON file the user chose.
  Future<void> _exportBackup() async {
    final backup = ref.read(backupServiceProvider);
    final stamp = DateTime.now().toIso8601String().split('T').first;
    final bytes = utf8.encode(backup.export().encode());
    Uri? target;
    try {
      target = await FilePicker.saveFile(
        dialogTitle: 'Save settings backup',
        fileName: 'ytdlp-settings-$stamp.json',
        bytes: bytes,
        mimeType: 'application/json',
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
    } catch (_) {
      target = null; // Picker unavailable on this platform.
    }
    if (target == null) return; // Cancelled, or the platform cannot save.
    // A file:// target can also be written directly, which covers the case
    // where the platform reports a path but wrote nothing.
    if (target.scheme == 'file' && target.toFilePath() != target.path) {
      final file = File.fromUri(target);
      if (!await file.exists()) {
        try {
          await file.writeAsBytes(bytes, flush: true);
        } catch (_) {}
      }
    }
    if (mounted) _say('Settings saved');
  }

  /// Restores settings and templates from a backup file.
  ///
  /// Destructive, so it asks first: restoring replaces the current preferences
  /// rather than merging into them.
  Future<void> _importBackup() async {
    PlatformFile? picked;
    try {
      picked = await FilePicker.pickFile(
        dialogTitle: 'Choose a settings backup',
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
    } catch (_) {
      picked = null;
    }
    if (picked == null) return;

    // Read via the path, not readAsString: on Android a picker's cached path
    // can already be gone, and reading the real file works either way.
    String? raw;
    final pickedPath = picked.path;
    if (pickedPath != null) {
      try {
        raw = await File(pickedPath).readAsString();
      } catch (_) {
        raw = null;
      }
    }
    if (raw == null) {
      _say("Couldn't read that file");
      return;
    }

    final backup = ref.read(backupServiceProvider);
    // Decoded before asking, so an unrelated JSON file is rejected with a clear
    // message rather than after a scary "replace everything?" prompt.
    final parsed = SettingsBackup.decode(raw);
    if (parsed == null) {
      _say("That isn't a YTDL settings backup");
      return;
    }

    // Checked before the await, so the dialog is shown on a live context.
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Replace settings?'),
        content: Text(
          'This replaces your current preferences'
          '${parsed.templates.isEmpty ? '' : ' and ${parsed.templates.length} '
                    'saved template(s)'} with the ones in the backup.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    if (!await backup.restore(parsed)) {
      _say("That backup is from a newer version of the app");
      return;
    }
    // The settings service caches its value, so it has to re-read the box for
    // the new preferences to take effect.
    ref.read(settingsServiceProvider).init();
    if (!mounted) return;
    setState(() {});
    _say('Settings restored');
  }

  /// Copies a support report to the clipboard.
  ///
  /// The clipboard rather than a file, because the point is to paste it into an
  /// issue: hand-transcribing versions and paths is why most reports are
  /// unanswerable.
  Future<void> _copyDiagnostics() async {
    final report = await ref.read(diagnosticsServiceProvider).build();
    if (!mounted) return;
    try {
      await Clipboard.setData(ClipboardData(text: report.text));
      if (mounted) _say('Diagnostics copied — paste them into a bug report');
    } catch (_) {
      if (mounted) _say("Couldn't reach the clipboard");
    }
  }

  /// can't stop resolving (Android pickers hand back cache paths, and desktop
  /// users may pick a file on removable media), then yt-dlp is pointed at the
  /// copy via `--cookies`.
  ///
  /// The import is stored twice: once as the source, exactly as picked and never
  /// rewritten, and once as the generated jar yt-dlp reads — the source minus
  /// whatever the user has switched off. Keeping the original is what makes a
  /// switch reversible; rewriting the import in place would not be.
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
    final text = utf8.decode(bytes, allowMalformed: true);
    if (!CookieJar.looksLikeCookieJar(text)) {
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
      final service = await ref.read(cookieJarServiceProvider.future);
      final settings = ref.read(settingsControllerProvider);
      final result = await service.importSource(
        text,
        // Pruned against the new jar, so a switch the user made on a site that
        // is not in this file cannot withhold anything here.
        disabled: settings.cookieDisabledDomains.toSet(),
      );
      if (result.wroteSomething) {
        // Only now: pointing `cookiesPath` at a file the refusal declined to
        // write would hand yt-dlp a path to nothing, and the download would
        // fail with a file-not-found rather than anything the user can act on.
        await _patch(
          settings.copyWith(
            cookiesPath: result.path,
            cookieSourcePath: service.sourcePath,
          ),
        );
      }
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              result.wroteSomething
                  ? 'Cookies saved — ${result.sites} '
                        '${result.sites == 1 ? "site" : "sites"}'
                  : result.reason ?? 'Nothing was saved',
            ),
          ),
        );
    } catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text("Couldn't save the cookies: $e")),
        );
    }
  }

  /// Clears the settings and deletes both jars.
  ///
  /// Deleting matters as much as clearing: a withdrawn login left readable on
  /// disk is a credential the user believes they removed.
  ///
  /// The browser source goes too. It is still a cookie source, so clearing only
  /// the jar would leave yt-dlp sending a login the user has just asked to stop
  /// sending — the button would say "removed" and mean nothing.
  Future<void> _removeCookies(AppSettings settings) async {
    final service = await ref.read(cookieJarServiceProvider.future);
    await service.remove();
    await _patch(
      settings.copyWith(
        cookiesPath: '',
        cookieSourcePath: '',
        cookieDisabledDomains: const [],
        cookieBrowser: '',
        cookieBrowserProfile: '',
        cookieBrowserRootPath: '',
      ),
    );
  }

  /// Points the app at the folder a browser keeps its profiles in.
  ///
  /// Only ever the folder, never a profile: the profile *names* inside it are
  /// read by the app and passed to yt-dlp by name, because yt-dlp splits its
  /// browser specification on `:` and a path cannot survive that. See
  /// `cookie_browser.dart`.
  Future<void> _pickBrowserProfileRoot() async {
    final messenger = ScaffoldMessenger.of(context);
    String? picked;
    var failed = false;
    try {
      picked = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose the folder holding your browser profiles',
      );
    } catch (_) {
      // On Linux this needs zenity or kdialog installed. Swallowing it would
      // leave a tap that does nothing at all, which reads as a broken app
      // rather than a missing helper.
      failed = true;
    }
    if (failed) {
      _say(
        "The folder picker could not be opened. On Linux it needs zenity or "
        'kdialog installed; you can still use the browser without choosing a '
        'profile folder.',
      );
      return;
    }
    if (picked == null) return; // Cancelled.

    final names = profileNamesIn(picked);
    if (names.isEmpty) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(ProfileProblem.notAProfileRoot.message!)),
        );
      return;
    }
    final settings = ref.read(settingsControllerProvider);
    await _patch(settings.copyWith(cookieBrowserRootPath: picked));
  }

  /// Which cookie source a configuration resolves to.
  CookieSource _cookieSourceOf(AppSettings settings) => resolveCookieSource(
    cookiesPath: settings.cookiesPath,
    cookieBrowser: settings.cookieBrowser,
  );

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
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _NetworkSection(settings: settings, onPatch: _patch),
                const SizedBox(height: 12),
                _PostProcessingSection(settings: settings, onPatch: _patch),
                const SizedBox(height: 12),
                _QueueSection(settings: settings, onPatch: _patch),
                const SizedBox(height: 12),
                _AdvancedSettings(settings: settings, onPatch: _patch),
                const SizedBox(height: 12),
                _Section(
                  title: 'Privacy & data',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.cookie_outlined),
                        title: const Text('Cookies (optional)'),
                        subtitle: Text(
                          _cookieSourceOf(settings) == CookieSource.browser
                              ? 'Set aside — the browser is the source now'
                              : settings.cookiesPath.isEmpty
                              ? 'Off — some sites need a cookies.txt to allow '
                                    'downloads'
                              : settings.cookieDisabledDomains.isEmpty
                              ? 'On — every site in the file is sent'
                              : 'On — ${settings.cookieDisabledDomains.length} '
                                    '${settings.cookieDisabledDomains.length == 1 ? "site" : "sites"} '
                                    'switched off',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (settings.cookiesPath.isNotEmpty) ...[
                              IconButton(
                                icon: const Icon(Icons.tune),
                                tooltip:
                                    _cookieSourceOf(settings) ==
                                        CookieSource.browser
                                    ? 'Choose which sites are sent — not '
                                          'available for a browser'
                                    : 'Choose which sites are sent',
                                onPressed: () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => const CookieDomainsPage(),
                                  ),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.close),
                                tooltip: 'Remove cookies',
                                onPressed: () => _removeCookies(settings),
                              ),
                            ] else if (settings.cookieBrowser.isNotEmpty) ...[
                              // A browser source is a cookie source too, so it
                              // needs its own way out; the jar buttons above
                              // only appear once a jar exists.
                              IconButton(
                                icon: const Icon(Icons.close),
                                tooltip: 'Stop using browser cookies',
                                onPressed: () => _patch(
                                  settings.copyWith(
                                    cookieBrowser: '',
                                    cookieBrowserProfile: '',
                                  ),
                                ),
                              ),
                            ],
                            IconButton(
                              icon: const Icon(Icons.folder_open),
                              tooltip: settings.cookiesPath.isEmpty
                                  ? 'Choose cookies.txt'
                                  : 'Change cookies.txt',
                              onPressed: _pickCookiesFile,
                            ),
                          ],
                        ),
                        // The tile itself stays non-navigable so the trailing
                        // buttons are the only way in: a tap target covering
                        // the row would swallow the import button on the right.
                      ),
                      const SizedBox(height: 12),
                      _BrowserCookieSection(
                        settings: settings,
                        onPatch: _patch,
                        onBrowse: _pickBrowserProfileRoot,
                      ),
                      const SizedBox(height: 12),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.save_alt_outlined),
                        title: const Text('Back up settings'),
                        subtitle: const Text(
                          'Saves preferences and argument templates to a file',
                        ),
                        onTap: _exportBackup,
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.settings_backup_restore),
                        title: const Text('Restore from a backup'),
                        onTap: _importBackup,
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.bug_report_outlined),
                        title: const Text('Copy diagnostics'),
                        subtitle: const Text(
                          'Versions, paths and settings for a bug report. '
                          'Never includes cookies',
                        ),
                        onTap: _copyDiagnostics,
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
                      const Divider(height: 24),
                      _AppUpdateRow(
                        result: _appUpdate,
                        checking: _checkingAppUpdate,
                        error: _appUpdateError,
                        onRetry: _checkAppUpdate,
                      ),
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

class _AdvancedSettingsState extends ConsumerState<_AdvancedSettings>
    with SingleTickerProviderStateMixin {
  final TextEditingController _args = TextEditingController();
  final TextEditingController _template = TextEditingController();
  bool _loaded = false;

  /// The carousel's pages: the yt-dlp flags, then the file name template.
  static const List<String> _pages = ['Flags', 'File name'];
  final PageController _pageController = PageController();

  /// Drives the [TabBar] strip, and is moved by a page swipe so the strip
  /// always shows which page is up.
  late final TabController _tabController = TabController(
    length: _pages.length,
    vsync: this,
  );

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
    _pageController.dispose();
    _tabController.dispose();
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
        // A TabBar rather than a bare swipe: a carousel with no visible tab
        // strip is undiscoverable, and the strip is also what makes it obvious
        // that the template moved rather than disappeared.
        TabBar(
          controller: _tabController,
          tabs: [for (final title in _pages) Tab(text: title)],
          onTap: (i) => _pageController.animateToPage(
            i,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          ),
        ),
        const SizedBox(height: 12),
        // Sized from the pages' own laid-out heights, because a PageView is
        // unbounded vertically. See [TabCarousel] for why the height is
        // measured rather than hard-coded.
        TabCarousel(
          controller: _pageController,
          pages: [
            for (var i = 0; i < _pages.length; i++)
              _buildPage(i, theme, scheme),
          ],
          fallbackHeight: _fallbackHeight,
          onPageChanged: (i) => _tabController.index = i,
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
          // Names the other page too, since one button now commits both.
          label: const Text('Save advanced settings'),
        ),
      ],
    );
  }

  /// Height used until a page reports its own, and if one never does.
  ///
  /// Only the raw flags, the saved-template chips and the YouTube section are
  /// in here now — the capability controls moved to their own top-level
  /// sections — so the flags page is a few hundred pixels rather than the
  /// thousand-plus this used to need. Deliberately generous anyway: on the
  /// first frame this is all the carousel has, so too small a value would
  /// briefly clip a page. Once measured it is replaced by the real content
  /// height, and a short page simply has space under it.
  static const double _fallbackHeight = 700;

  Widget _buildPage(int index, ThemeData theme, ColorScheme scheme) =>
      switch (index) {
        1 => _buildTemplatePage(theme, scheme),
        _ => _buildFlagsPage(theme, scheme),
      };

  Widget _buildFlagsPage(ThemeData theme, ColorScheme scheme) {
    final store = ref.watch(templateStoreProvider);
    final issues = _issues;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
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
        _YoutubeSection(settings: widget.settings, onPatch: widget.onPatch),
      ],
    );
  }

  /// The file name page: everything about the output template, and nothing
  /// else, so it is short enough not to need scrolling on most screens.
  Widget _buildTemplatePage(ThemeData theme, ColorScheme scheme) {
    final templateErrors = _templateIssues;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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

/// A dense labelled text field, the one every free-text setting uses.
Widget _prefField({
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

/// A whole-number text field, for the few values that have no sensible slider.
Widget _prefIntField({
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

/// A chip row picking one of a fixed set of values.
Widget _prefChips(
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

/// A slider whose current value is named in a label above it.
Widget _prefSlider(
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
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ),
    ],
  );
}

/// Patches only the yt-dlp prefs, so a change in one section cannot clobber an
/// unrelated setting like the download folder.
void _patchPrefs(
  AppSettings settings,
  Future<void> Function(AppSettings) onPatch,
  YtPrefs next,
) {
  onPatch(settings.copyWith(ytPrefs: next));
}

/// Resolves ffprobe availability without blocking the first frame.
Future<bool> _canPostprocess(WidgetRef ref) async {
  try {
    return await ref.read(binaryManagerProvider).hasFfprobe();
  } catch (_) {
    return false;
  }
}

/// How the app reaches the network, and how hard it pushes.
class _NetworkSection extends ConsumerWidget {
  const _NetworkSection({required this.settings, required this.onPatch});

  final AppSettings settings;
  final Future<void> Function(AppSettings) onPatch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = settings.ytPrefs;
    final theme = Theme.of(context);
    void patch(YtPrefs next) => _patchPrefs(settings, onPatch, next);

    return _Section(
      title: 'Network',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Route every download through a proxy, and pace requests so a busy '
            'host is not hammered.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          _prefField(
            label: 'Proxy',
            hint: 'socks5://host:port — empty for none',
            value: prefs.proxy,
            onChanged: (v) => patch(prefs.copyWith(proxy: v.trim())),
          ),
          _prefField(
            label: 'Referer',
            hint: 'Some hosts require one',
            value: prefs.referer,
            onChanged: (v) => patch(prefs.copyWith(referer: v.trim())),
          ),
          _prefField(
            label: 'Rate limit',
            hint: 'e.g. 2M, 500K — empty for no limit',
            value: prefs.limitRate,
            onChanged: (v) => patch(prefs.copyWith(limitRate: v.trim())),
          ),
          _prefSlider(
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
          _prefIntField(
            label: 'Delay between requests (s)',
            value: prefs.sleepRequests,
            onChanged: (v) => patch(prefs.copyWith(sleepRequests: v)),
          ),
          _prefIntField(
            label: 'Request retries',
            value: prefs.retries,
            onChanged: (v) => patch(prefs.copyWith(retries: v)),
          ),
          _prefIntField(
            label: 'Fragment retries',
            value: prefs.fragmentRetries,
            onChanged: (v) => patch(prefs.copyWith(fragmentRetries: v)),
          ),
          Text(
            'Retries are clamped to ${YtPrefs.minRetries}–'
            '${YtPrefs.maxRetries}. A raw --retries in the extra-arguments '
            'field still wins: yt-dlp lets the last occurrence of a flag '
            'take effect.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Unmetered connections only'),
            subtitle: Text(
              'New downloads wait for Wi-Fi or Ethernet. A download '
              'already running is never interrupted.',
              style: theme.textTheme.bodySmall,
            ),
            value: settings.wifiOnly,
            onChanged: (v) => onPatch(settings.copyWith(wifiOnly: v)),
          ),
        ],
      ),
    );
  }
}

/// Everything that runs through ffmpeg after the bytes are down.
///
/// A real top-level section rather than a divider buried in the Advanced
/// carousel: these are common choices, they are the ones that silently do
/// nothing without ffprobe, and burying them is why the carousel was over a
/// thousand pixels tall.
class _PostProcessingSection extends ConsumerWidget {
  const _PostProcessingSection({required this.settings, required this.onPatch});

  final AppSettings settings;
  final Future<void> Function(AppSettings) onPatch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = settings.ytPrefs;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    void patch(YtPrefs next) => _patchPrefs(settings, onPatch, next);

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
        return _Section(
          title: 'Post-processing',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'ffmpeg rewrites the file after it downloads: converting the '
                'container, or writing tags into it. Each of these needs ffmpeg '
                'and ffprobe.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (!canPost)
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  child: Text(
                    'ffprobe is not available here, so these are disabled.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.error,
                    ),
                  ),
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
                _prefChips(
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
                  !canPost ? 'Needs ffmpeg and ffprobe (not available)' : 'Change container without re-encoding — quality is kept',
                ),
                value: prefs.remuxVideo.isNotEmpty,
                onChanged: canPost
                    ? (v) => patch(prefs.copyWith(remuxVideo: v ? 'mkv' : ''))
                    : null,
              ),
              if (prefs.remuxVideo.isNotEmpty)
                _prefChips(
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
            ],
          ),
        );
      },
    );
  }
}

/// How the queue itself behaves: how many run at once, what survives a
/// restart, and how a download is written to disk.
class _QueueSection extends ConsumerWidget {
  const _QueueSection({required this.settings, required this.onPatch});

  final AppSettings settings;
  final Future<void> Function(AppSettings) onPatch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = settings.ytPrefs;
    return _Section(
      title: 'Queue',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<int?>(
            initialValue: settings.maxConcurrency,
            isExpanded: true,
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Simultaneous downloads',
              helperText:
                  'Higher values can slow a phone down; 1–2 suits most '
                  'connections',
              border: OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem(
                value: null,
                child: Text('Automatic (1 on mobile, 2 on desktop)'),
              ),
              for (
                var n = AppSettings.concurrencyMin;
                n <= AppSettings.concurrencyMax;
                n++
              )
                DropdownMenuItem(value: n, child: Text('$n')),
            ],
            onChanged: (v) =>
                onPatch(settings.copyWith(maxConcurrencySetter: () => v)),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: settings.maxQueueSize,
            isExpanded: true,
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Remembered queue entries',
              helperText:
                  'How many downloads survive an app restart. Raise it for '
                  'large playlists',
              border: OutlineInputBorder(),
            ),
            items: [
              for (
                var n = AppSettings.queueSizeMin;
                n <= AppSettings.queueSizeMax;
                n += 10
              )
                DropdownMenuItem(value: n, child: Text('$n')),
            ],
            onChanged: (v) => onPatch(settings.copyWith(maxQueueSize: v ?? 50)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Record livestreams from the start'),
            value: prefs.liveFromStart,
            onChanged: (v) => _patchPrefs(
              settings,
              onPatch,
              prefs.copyWith(liveFromStart: v),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Skip already-downloaded videos'),
            subtitle: const Text(
              'Keeps a ledger in the app folder and skips anything in it',
            ),
            value: prefs.downloadArchive,
            onChanged: (v) => _patchPrefs(
              settings,
              onPatch,
              prefs.copyWith(downloadArchive: v),
            ),
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
            onChanged: (v) =>
                _patchPrefs(settings, onPatch, prefs.copyWith(noPart: v)),
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

/// `--cookies-from-browser`, which reads the user's existing browser login
/// instead of a jar they had to export by hand.
///
/// Desktop only, and disabled with the reason shown everywhere the app gates a
/// control it cannot honour — the same shape as the ffmpeg-gated post-processing
/// switches. A control that is merely hidden would leave a user with a working
/// browser wondering whether this app can do it at all.
class _BrowserCookieSection extends StatelessWidget {
  const _BrowserCookieSection({
    required this.settings,
    required this.onPatch,
    required this.onBrowse,
  });

  final AppSettings settings;
  final void Function(AppSettings) onPatch;
  final VoidCallback onBrowse;

  /// Why this cannot be used here, or null when it can.
  static String? unavailableReason() => cookieBrowserBlock(
    isWeb: kIsWeb,
    isMobile: Platform.isAndroid || Platform.isIOS,
    isMacOS: Platform.isMacOS,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final blocked = unavailableReason();
    final selected = CookieBrowser.byArgument(settings.cookieBrowser);
    final source = resolveCookieSource(
      cookiesPath: settings.cookiesPath,
      cookieBrowser: settings.cookieBrowser,
    );

    final profiles = settings.cookieBrowserRootPath.isEmpty
        ? const <String>[]
        : profileNamesIn(settings.cookieBrowserRootPath);
    final profileProblem = checkProfileName(settings.cookieBrowserProfile);

    return _Section(
      title: 'Browser cookies (desktop)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (blocked != null)
            Text(blocked, style: theme.textTheme.bodySmall)
          else ...[
            Text(
              'Reads the login you already have in a browser, so there is no '
              'jar to export. yt-dlp decrypts it itself — the app never sees '
              'a cookie value.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'yt-dlp can only read Chromium cookies on Linux when its '
              'decryption extras are installed; if a download fails with a '
              'decryption error, that is what is missing.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: selected?.argument ?? '',
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Browser',
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem(value: '', child: Text('None')),
                for (final b in CookieBrowser.values)
                  DropdownMenuItem(value: b.argument, child: Text(b.label)),
              ],
              onChanged: (value) => _pick(selected, value ?? ''),
            ),
            if (selected != null &&
                selected.isMacOnly &&
                !Platform.isMacOS) ...[
              // yt-dlp cannot read Safari's store off macOS at all, so saying
              // only "desktop" would promise something that cannot happen.
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${selected.label} cookies can only be read on macOS. '
                  'Picking another browser avoids a download that cannot work.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.error,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Profile folder'),
              subtitle: Text(
                // A greyed-out row with no explanation is the failure mode this
                // project keeps guarding against, so the reason is the subtitle
                // rather than an absence.
                selected == null
                    ? 'Choose a browser first'
                    : settings.cookieBrowserRootPath.isEmpty
                    ? 'Not chosen'
                    : '${profiles.length} '
                          '${profiles.length == 1 ? "profile" : "profiles"} found',
              ),
              trailing: const Icon(Icons.folder_open),
              onTap: selected == null ? null : onBrowse,
            ),
            if (selected != null) ...[
              const SizedBox(height: 4),
              DropdownButtonFormField<String>(
                initialValue: profiles.contains(settings.cookieBrowserProfile)
                    ? settings.cookieBrowserProfile
                    : '',
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Profile',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem(
                    value: '',
                    child: Text("The browser's own default"),
                  ),
                  for (final p in profiles)
                    DropdownMenuItem(value: p, child: Text(p)),
                ],
                onChanged: profiles.isEmpty
                    ? null
                    : (value) => onPatch(
                        settings.copyWith(cookieBrowserProfile: value ?? ''),
                      ),
              ),
              if (profiles.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    settings.cookieBrowserRootPath.isEmpty
                        ? 'Choose the profile folder to list what is in it. '
                              "Until then yt-dlp uses the browser's own "
                              'default, which is right for most people.'
                        : (ProfileProblem.notAProfileRoot.message ??
                              'That folder has no browser profiles in it.'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.error,
                    ),
                  ),
                ),
            ],
            if (profileProblem != null && profileProblem.message != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  // The stored name is still passed to yt-dlp, minus this
                  // profile, so saying so is what makes it honest rather than
                  // merely blocked.
                  'That profile is being ignored: ${profileProblem.message}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.error,
                  ),
                ),
              ),
            if (source == CookieSource.browser &&
                settings.cookiesPath.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Your imported cookies.txt is set aside while this is on. '
                  'yt-dlp is given one cookie source, never two — with both, a '
                  'site you switched off would still go out from the browser. '
                  'Turn this off to go back to the file.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (source == CookieSource.browser &&
                settings.cookieDisabledDomains.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${settings.cookieDisabledDomains.length} '
                  '${settings.cookieDisabledDomains.length == 1 ? "site" : "sites"} '
                  'you switched off are still stored, but nothing is filtering '
                  'them out of a browser\'s cookies — those switches have no '
                  'effect until you turn this off.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.error,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// Changing the browser keeps the imported jar; the source resolution in
  /// `cookie_browser.dart` decides which one is used, and the notes above say
  /// which. Clearing the browser goes back to the jar with nothing else to
  /// restore, because the jar was never touched.
  void _pick(CookieBrowser? previous, String argument) {
    if (argument == previous?.argument) return;
    onPatch(settings.copyWith(cookieBrowser: argument));
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

class _AppUpdateRow extends StatelessWidget {
  const _AppUpdateRow({
    required this.result,
    required this.checking,
    required this.error,
    required this.onRetry,
  });

  final AppUpdateResult? result;
  final bool checking;
  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (checking) {
      return const ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.system_update_alt_outlined),
        title: Text('App version'),
        subtitle: Text('Checking…'),
      );
    }
    if (error != null) {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.error_outline),
        title: const Text('App version'),
        subtitle: Text('Could not check for updates: $error'),
        trailing: IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Retry',
          onPressed: onRetry,
        ),
      );
    }
    if (result == null) {
      // First check pending or a host without a platform plugin. Render nothing
      // rather than a row of dots, which looks empty either way but means a
      // different thing.
      return const SizedBox.shrink();
    }
    return switch (result!.status) {
      AppUpdateStatus.updateAvailable => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.system_update_alt_outlined),
        title: const Text('Update available'),
        subtitle: Text(
          'Version ${result!.release!.version} is out — you have an older build.',
        ),
        trailing: TextButton(
          onPressed: () => launchUrl(Uri.parse(result!.release!.url)),
          child: const Text('Download'),
        ),
      ),
      AppUpdateStatus.upToDate => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.check_circle_outline),
        title: const Text('App version'),
        subtitle: const Text('Up to date'),
        trailing: IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Check again',
          onPressed: onRetry,
        ),
      ),
      AppUpdateStatus.unreachable => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.cloud_off_outlined),
        title: const Text('App version'),
        subtitle: const Text('Could not reach the update server'),
        trailing: IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Retry',
          onPressed: onRetry,
        ),
      ),
      AppUpdateStatus.unknownCurrent => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.help_outline),
        title: const Text('App version'),
        subtitle: const Text('Version unknown outside a release build'),
        trailing: IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Retry',
          onPressed: onRetry,
        ),
      ),
    };
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

/// YouTube player clients and the JavaScript runtime.
///
/// yt-dlp needs a PO token to fetch many YouTube formats, which increasingly
/// means a JS runtime. The `yt-dlp-ejs` package supplies it; this section
/// installs it on demand and reports what is actually installed, rather than
/// claiming a capability it cannot verify.
class _YoutubeSection extends ConsumerStatefulWidget {
  const _YoutubeSection({required this.settings, required this.onPatch});

  final AppSettings settings;
  final Future<void> Function(AppSettings) onPatch;

  @override
  ConsumerState<_YoutubeSection> createState() => _YoutubeSectionState();
}

class _YoutubeSectionState extends ConsumerState<_YoutubeSection> {
  EjsInfo? _ejs;
  bool _installing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  Future<void> _probe() async {
    final info = await ref.read(ejsInstallerProvider).status(refresh: true);
    if (mounted) setState(() => _ejs = info);
  }

  Future<void> _install() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _installing = true;
      _error = null;
    });
    try {
      final version = BinaryManager.ytEjsVersion;
      final installer = ref.read(ejsInstallerProvider);
      // Resolved from PyPI rather than hard-coded, so a stale pin cannot
      // become a permanently broken install.
      final url = await installer.resolveLatestWheel(version);
      final info = await installer.install(archiveUrl: url, version: version);
      if (!mounted) return;
      setState(() {
        _ejs = info;
        _installing = false;
      });
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('JavaScript runtime installed')),
        );
    } on EjsInstallException catch (e) {
      if (!mounted) return;
      setState(() {
        _installing = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _installing = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _uninstall() async {
    await ref.read(ejsInstallerProvider).uninstall();
    await _probe();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final yt = widget.settings.youtube;
    final ejs = _ejs;

    void patch(YoutubePrefs next) =>
        widget.onPatch(widget.settings.copyWith(youtube: next));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text('YouTube', style: theme.textTheme.labelMedium),
        ),
        const SizedBox(height: 4),
        Text(
          'YouTube hides formats behind a proof-of-origin token, which yt-dlp '
          'obtains with a small JavaScript component.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(
              ejs?.isUsable == true ? Icons.check_circle : Icons.info_outline,
              size: 16,
              color: ejs?.isUsable == true
                  ? scheme.primary
                  : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                ejs?.summary ?? 'Checking the JavaScript runtime…',
                style: theme.textTheme.bodySmall,
              ),
            ),
            if (!_installing)
              TextButton(
                onPressed: _install,
                child: Text(ejs?.isUsable == true ? 'Update' : 'Install'),
              ),
          ],
        ),
        if (_installing) const LinearProgressIndicator(),
        if (ejs?.isUsable == true)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _uninstall,
              child: const Text('Remove'),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ),
        const Divider(height: 28),
        Text('Extra player clients', style: theme.textTheme.labelSmall),
        const SizedBox(height: 4),
        Text(
          'Some formats are only offered to particular clients. Adding more can '
          'unlock them, at the cost of more requests to YouTube.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final client in YoutubeClient.values)
              if (client != YoutubeClient.web)
                FilterChip(
                  label: Text(client.label),
                  selected: yt.extraClients.contains(client),
                  onSelected: (v) => patch(
                    yt.copyWith(
                      extraClients: v
                          ? [...yt.extraClients, client]
                          : [
                              for (final c in yt.extraClients)
                                if (c != client) c,
                            ],
                    ),
                  ),
                ),
          ],
        ),
      ],
    );
  }
}
