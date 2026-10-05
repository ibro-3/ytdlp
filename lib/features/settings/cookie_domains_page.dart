/// Per-site management of the imported cookie jar.
///
/// Lists every host in the jar with a switch, so a user who exported cookies
/// from a browser with a dozen sites logged in can keep sending only the one
/// yt-dlp actually needs.
///
/// The honesty requirement drives the layout. Switching a site off works by
/// omitting it from the file yt-dlp reads, and an omitted site is
/// indistinguishable from an expired one when a download fails. So this page
/// states the omission in three places: a running count in the header, a
/// standing explanation while anything is switched off, and a per-row count of
/// the cookies being withheld.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/cookie_browser.dart';
import '../../core/providers.dart';
import '../../services/cookies/cookie_domains.dart';

class CookieDomainsPage extends ConsumerStatefulWidget {
  const CookieDomainsPage({super.key});

  @override
  ConsumerState<CookieDomainsPage> createState() => _CookieDomainsPageState();
}

class _CookieDomainsPageState extends ConsumerState<CookieDomainsPage> {
  /// True while the initial load is running, which is the only time the list is
  /// genuinely empty and the spinner is the honest thing to show.
  bool _loading = true;

  /// True while a rewrite is in flight.
  ///
  /// Separate from [_loading] on purpose. A single flag would have to blank the
  /// list for the duration of every toggle — a spinner in place of the switches
  /// the user just pressed, for a write that takes milliseconds. This one only
  /// disables the controls, so a second tap cannot interleave two rewrites of
  /// the same file, which is the part that would actually corrupt it.
  bool _rewriting = false;

  List<CookieDomain> _domains = const [];
  String? _problem;

  @override
  void initState() {
    super.initState();
    // A Hive read is real I/O, which a widget test's fake-async zone will not
    // drive, so it has to be started before the first frame rather than in a
    // callback the test never reaches.
    _load();
  }

  Future<void> _load() async {
    final settings = ref.read(settingsControllerProvider);
    if (settings.cookiesPath.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final service = await ref.read(cookieJarServiceProvider.future);
    final parsed = await service.readSource(settings.cookieSourcePath);
    if (!mounted) return;
    setState(() {
      _domains = groupCookieDomains(
        parsed.entries,
        disabled: settings.cookieDisabledDomains.toSet(),
      );
      _loading = false;
      _problem = parsed.entries.isEmpty
          ? "That cookie file couldn't be read. Import it again."
          : null;
    });
  }

  Future<void> _toggle(CookieDomain domain, bool enabled) async {
    if (_rewriting) return; // A second tap must not race the first rewrite.
    setState(() => _rewriting = true);
    final service = await ref.read(cookieJarServiceProvider.future);
    final settings = ref.read(settingsControllerProvider);
    final disabled = settings.cookieDisabledDomains.toSet();
    if (enabled) {
      disabled.remove(domain.domain);
    } else {
      disabled.add(domain.domain);
    }

    // Write the file *before* persisting the choice. If the write fails — the
    // disk is full, the directory vanished — the settings must not claim a site
    // is off when its cookies are still being sent.
    final result = await service.buildGenerated(disabled: disabled);
    if (!result.wroteSomething) {
      if (!mounted) return;
      setState(() {
        _problem = result.reason;
        _rewriting = false;
      });
      _say(result.reason ?? 'Nothing was changed');
      return;
    }
    await ref
        .read(settingsControllerProvider.notifier)
        .patch(
          settings.copyWith(cookieDisabledDomains: disabled.toList()..sort()),
        );
    if (!mounted) return;
    setState(() {
      _domains = [
        for (final d in _domains)
          d.domain == domain.domain ? d.withEnabled(enabled) : d,
      ];
      _problem = null;
      _rewriting = false;
    });
    _say(
      enabled
          ? '${domain.domain} is on again'
          : '${domain.domain} is off — its ${domain.cookieCount} '
                '${domain.cookieCount == 1 ? "cookie is" : "cookies are"} not sent',
    );
  }

  Future<void> _enableAll() async {
    if (_rewriting) return;
    setState(() => _rewriting = true);
    final service = await ref.read(cookieJarServiceProvider.future);
    final settings = ref.read(settingsControllerProvider);
    final result = await service.buildGenerated(disabled: const {});
    if (!result.wroteSomething) {
      if (!mounted) return;
      setState(() {
        _problem = result.reason;
        _rewriting = false;
      });
      _say(result.reason ?? 'Nothing was changed');
      return;
    }
    await ref
        .read(settingsControllerProvider.notifier)
        .patch(settings.copyWith(cookieDisabledDomains: const []));
    if (!mounted) return;
    setState(() {
      _domains = [for (final d in _domains) d.withEnabled(true)];
      _problem = null;
      _rewriting = false;
    });
    _say('Every site is on');
  }

  void _say(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final off = _domains.where((d) => !d.enabled).toList();
    final withheld = off.fold<int>(0, (n, d) => n + d.cookieCount);
    final now = DateTime.now();
    final browser = CookieBrowser.byArgument(
      ref.watch(settingsControllerProvider).cookieBrowser,
    );
    final browserInUse = browser?.label;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cookie sites'),
        actions: [
          if (off.isNotEmpty)
            TextButton(
              onPressed: _rewriting ? null : _enableAll,
              child: const Text('Turn all on'),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                Text(
                  'yt-dlp reads one cookie file. Switching a site off leaves '
                  'its cookies out of that file, so they are not sent to it.',
                  style: theme.textTheme.bodyMedium,
                ),
                if (browserInUse != null) ...[
                  const SizedBox(height: 12),
                  _Banner(
                    icon: Icons.warning_amber_rounded,
                    // Without this, every switch on this page would look like it
                    // governs what is sent while the browser's own copy of the
                    // same site went out regardless.
                    text:
                        'Not being sent right now: your $browserInUse cookies '
                        'are the source instead of this file, and the app '
                        'cannot filter a browser\'s store. These switches take '
                        'effect again when you turn that off in Settings.',
                    tone: _BannerTone.warning,
                  ),
                ],
                if (_problem != null) ...[
                  const SizedBox(height: 12),
                  _Banner(
                    icon: Icons.warning_amber_rounded,
                    text: _problem!,
                    tone: _BannerTone.warning,
                  ),
                ],
                if (off.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _Banner(
                    icon: Icons.visibility_off_outlined,
                    // Stated as a count rather than left for the user to work
                    // out: knowing a site is off does not tell them how much of
                    // their login is still working.
                    text:
                        '$withheld ${withheld == 1 ? "cookie is" : "cookies are"} '
                        'not being sent, from ${off.length} '
                        '${off.length == 1 ? "site" : "sites"}.',
                    tone: _BannerTone.info,
                  ),
                ],
                const SizedBox(height: 16),
                for (final domain in _domains)
                  _DomainTile(
                    domain: domain,
                    now: now,
                    onChanged: _rewriting ? null : (v) => _toggle(domain, v),
                  ),
                if (_domains.isEmpty && _problem == null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Center(
                      child: Text(
                        'No cookies are loaded.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _DomainTile extends StatelessWidget {
  const _DomainTile({
    required this.domain,
    required this.now,
    required this.onChanged,
  });

  final CookieDomain domain;
  final DateTime now;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stale = domain.isStaleAt(now);
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      value: domain.enabled,
      onChanged: onChanged,
      title: Text(
        domain.domain,
        style: theme.textTheme.titleMedium?.copyWith(
          // A disabled site is struck through rather than only dimmed: dimming
          // is easy to miss on a long list, and this row's whole point is that
          // its cookies are not going anywhere.
          decoration: domain.enabled ? null : TextDecoration.lineThrough,
        ),
      ),
      subtitle: Text(
        '${domain.cookieCount} '
        '${domain.cookieCount == 1 ? "cookie" : "cookies"} · '
        '${domain.lifetimeLabel(now)}',
        style: stale
            ? theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              )
            : null,
      ),
      secondary: stale
          ? Icon(Icons.warning_amber_rounded, color: theme.colorScheme.error)
          : const Icon(Icons.language_outlined),
    );
  }
}

enum _BannerTone { info, warning }

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text, required this.tone});

  final IconData icon;
  final String text;
  final _BannerTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colours = theme.colorScheme;
    final background = tone == _BannerTone.warning
        ? colours.errorContainer
        : colours.surfaceContainerHighest;
    final foreground = tone == _BannerTone.warning
        ? colours.onErrorContainer
        : colours.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: foreground),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
            ),
          ),
        ],
      ),
    );
  }
}
