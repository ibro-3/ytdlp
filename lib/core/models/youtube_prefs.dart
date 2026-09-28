/// YouTube client selection and JS-runtime support.
///
/// yt-dlp needs a PO token, which increasingly means a JavaScript runtime, to
/// fetch many YouTube formats. The official answer is the `yt-dlp-ejs` package
/// loaded from yt-dlp's plugin directory — the same mechanism Seal and
/// youtubedl-android use.
///
/// This model covers the two knobs the user can actually turn: which player
/// clients yt-dlp should try, and whether the EJS components should be
/// installed. Everything else (download, verification, wiring) lives in
/// `EjsInstaller`.
library;

/// A YouTube player client yt-dlp can be asked to use.
enum YoutubeClient {
  /// The default web client. Always present.
  web('web', 'Web (default)'),

  /// Some formats are only exposed to the TV-embedded player.
  tv('tv', 'TV embedded'),

  /// The iOS client, which historically returns formats the web client hides.
  ios('ios', 'iOS'),

  /// The Android client.
  android('android', 'Android'),

  /// The web-embedded player, used for formats the plain web client restricts.
  webEmbedded('web_embedded', 'Web embedded'),

  /// The TV-simulator client, which is not rate-limited like the others.
  tvSimulator('tv_simulator', 'TV simulator');

  const YoutubeClient(this.id, this.label);

  /// The value yt-dlp expects in `player_client=`.
  final String id;

  final String label;

  /// Whether this client needs a TV/embedded style signature. Kept so the UI can
  /// flag the ones most likely to be rate-limited.
  bool get isTvLike => this == tv || this == tvSimulator || this == webEmbedded;
}

/// The YouTube-specific settings.
class YoutubePrefs {
  const YoutubePrefs({this.useEjs = true, this.extraClients = const []});

  /// Whether the JS runtime components should be installed and used.
  final bool useEjs;

  /// Clients to try *in addition* to `web`.
  ///
  /// `web` is always included because yt-dlp falls back to it anyway, and
  /// leaving it selectable is how a user would break things.
  final List<YoutubeClient> extraClients;

  /// The value for `--extractor-args youtube:player_client=`.
  String get playerClientsTarget =>
      [YoutubeClient.web.id, for (final c in extraClients) c.id].join(',');

  /// Whether the client list is worth sending at all: `web` alone is already
  /// yt-dlp's default, so the flag would be a no-op.
  bool get isClientSelectionMeaningful => extraClients.isNotEmpty;

  Map<String, dynamic> toMap() => {
    'useEjs': useEjs,
    'extraClients': [for (final c in extraClients) c.id],
  };

  factory YoutubePrefs.fromMap(Map<String, dynamic>? m) {
    if (m == null) return const YoutubePrefs();
    // Unknown client ids are dropped rather than passed through: yt-dlp errors
    // out on an unrecognised value, which would break every download.
    final ids = (m['extraClients'] as List?)?.whereType<String>() ?? const [];
    return YoutubePrefs(
      useEjs: m['useEjs'] as bool? ?? true,
      extraClients: [
        for (final id in ids)
          for (final c in YoutubeClient.values)
            if (c.id == id && c != YoutubeClient.web) c,
      ],
    );
  }

  YoutubePrefs copyWith({bool? useEjs, List<YoutubeClient>? extraClients}) =>
      YoutubePrefs(
        useEjs: useEjs ?? this.useEjs,
        extraClients: extraClients ?? this.extraClients,
      );

  @override
  bool operator ==(Object other) =>
      other is YoutubePrefs &&
      other.useEjs == useEjs &&
      other.extraClients.length == extraClients.length &&
      other.extraClients.every(extraClients.contains);

  @override
  int get hashCode => Object.hash(useEjs, Object.hashAll(extraClients));
}
