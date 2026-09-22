import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  late final TextEditingController _androidUrlController;

  @override
  void initState() {
    super.initState();
    _androidUrlController = TextEditingController(
        text: ref.read(settingsControllerProvider).androidYtdlpUrl);
    _loadVersion();
  }

  @override
  void dispose() {
    _androidUrlController.dispose();
    super.dispose();
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

  Future<void> _updateEngine() async {
    setState(() {
      _updating = true;
      _engineMessage = null;
    });
    try {
      // Persist a possibly-edited Android URL first.
      final settings = ref.read(settingsControllerProvider);
      final url = _androidUrlController.text.trim();
      if (url != settings.androidYtdlpUrl) {
        await _patch(settings.copyWith(androidYtdlpUrl: url));
      }
      final v = await ref
          .read(binaryManagerProvider)
          .updateYtdlp(androidUrl: url.isEmpty ? null : url);
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
                              icon: Icon(Icons.settings_suggest_outlined)),
                          ButtonSegment(
                              value: ThemeMode.light,
                              label: Text('Light'),
                              icon: Icon(Icons.light_mode_outlined)),
                          ButtonSegment(
                              value: ThemeMode.dark,
                              label: Text('Dark'),
                              icon: Icon(Icons.dark_mode_outlined)),
                        ],
                        selected: {settings.themeMode},
                        onSelectionChanged: (s) =>
                            _patch(settings.copyWith(themeMode: s.first)),
                      ),
                      const SizedBox(height: 16),
                      Text('Theme color',
                          style: Theme.of(context).textTheme.labelMedium),
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
                              onTap: () => _patch(
                                  settings.copyWith(seedColor: value)),
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
                      Text('Default video quality',
                          style: Theme.of(context).textTheme.labelMedium),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final t in AppSettings.videoTierOptions)
                            ChoiceChip(
                              label: Text(
                                  t == null ? 'Best quality' : '${t}p'),
                              selected: settings.defaultVideoTier == t,
                              onSelected: (_) => _patch(settings.copyWith(
                                  defaultVideoTier: () => t)),
                            ),
                        ],
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Audio only by default'),
                        subtitle: const Text(
                            'Download M4A audio instead of video'),
                        value: settings.defaultAudioOnly,
                        onChanged: (v) => _patch(
                            settings.copyWith(defaultAudioOnly: v)),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Ask quality each time'),
                        subtitle: const Text(
                            'Show a quality picker before every download'),
                        value: settings.askQualityEachTime,
                        onChanged: (v) => _patch(
                            settings.copyWith(askQualityEachTime: v)),
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
                        subtitle: Text(_versionLoading
                            ? 'Checking…'
                            : _version == null
                                ? 'Not installed'
                                : 'v$_version'),
                        trailing: IconButton(
                          icon: const Icon(Icons.refresh),
                          tooltip: 'Check version',
                          onPressed:
                              _versionLoading ? null : _loadVersion,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _androidUrlController,
                        decoration: const InputDecoration(
                          labelText: 'Android yt-dlp build URL (optional)',
                          hintText: 'https://…/yt-dlp (bionic, per ABI)',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.url,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Android has no official build — updates need a bionic binary URL. Leave blank to keep the bundled copy.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _updating ? null : _updateEngine,
                        icon: _updating
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2))
                            : const Icon(Icons.system_update_outlined),
                        label: Text(
                            _updating ? 'Updating…' : 'Update yt-dlp'),
                      ),
                      if (_engineMessage != null) ...[
                        const SizedBox(height: 8),
                        SelectableText(_engineMessage!,
                            style: Theme.of(context).textTheme.bodySmall),
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
                            'Progress and completion alerts (Android 13+ asks for permission)'),
                        value: settings.notificationsEnabled,
                        onChanged: (v) async {
                          if (v) {
                            await ref
                                .read(notificationServiceProvider)
                                .requestPermission();
                          }
                          await _patch(settings.copyWith(
                              notificationsEnabled: v));
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
                                  detail:
                                      'You will see progress here during downloads.',
                                );
                            ScaffoldMessenger.of(context)
                              ..hideCurrentSnackBar()
                              ..showSnackBar(const SnackBar(
                                  content:
                                      Text('Test notification sent')));
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
                      width: 3)
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
