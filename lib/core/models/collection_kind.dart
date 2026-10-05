/// What a link points at: a curated playlist, or a whole channel.
///
/// yt-dlp resolves both to the same `--flat-playlist` payload — a title and a
/// list of entries — so the payload on its own cannot tell them apart. The
/// *link* can, and the difference is not cosmetic:
///
/// - a curated playlist has an end, so the listing is complete once it arrives;
/// - a channel does not. Channels of any size exist, and the JSON for a large
///   one does not fit the metadata byte budget, so a channel is listed a page
///   at a time and the app has to say when it has only seen part of it.
///
/// Getting this wrong is not silent either way. Call a channel a playlist and
/// a 5,000-video list arrives truncated and reads as complete; call a curated
/// playlist a channel and it gets paged for no reason. So the classification is
/// deliberately conservative and returns null when it cannot tell.
enum CollectionKind {
  playlist('Playlist'),
  channel('Channel');

  const CollectionKind(this.label);

  /// What the collection is called in the UI. Deliberately not a plural: it
  /// labels the collection itself ("Channel"), not its contents.
  final String label;

  /// Both kinds contain videos, so this is deliberately not part of the enum.
  static const contentsNoun = 'video';

  /// Plural of [contentsNoun], for the count chips.
  static String contentsLabel(int count) =>
      '$count $contentsNoun${count == 1 ? '' : 's'}';
}

/// Classifies [url] by its path shape, or returns null when it is neither a
/// playlist nor a channel link.
///
/// Only YouTube's URL layouts are recognised. Every other extractor's
/// collections — a Vimeo album, a SoundCloud set, a bare `.m3u8` — return null
/// rather than a guess, because they are curated playlists by construction and
/// paging them would be wrong.
///
/// Returns null for a single video, including `watch?v=…&list=…`: the
/// download path resolves that to the video alone (see `buildDownloadArgs`,
/// which pins `--no-playlist`), so the playlist half of the URL is not a
/// collection the user asked to browse.
CollectionKind? collectionKindForUrl(String? url) {
  if (url == null) return null;
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return null;

  // `youtu.be` only ever shortens a single video, and a non-YouTube host has
  // no channel/playlist layout worth guessing at.
  if (!_isYouTubeHost(uri.host)) return null;

  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return null;

  // A trailing tab name (`/videos`, `/streams`, `/shorts`, `/featured`,
  // `/playlists`) is the same collection, so only the first segment is read.
  switch (segments.first) {
    case 'playlist':
      return CollectionKind.playlist;
    case 'channel' || 'c' || 'user':
      // `/channel`, `/c` and `/user` are all channel layouts; the name
      // follows. A bare `/channel` with no name is not a real channel link,
      // but it is unambiguously not a playlist either.
      return CollectionKind.channel;
  }

  // A handle is the first segment itself: `youtube.com/@somechannel/videos`.
  if (segments.first.startsWith('@')) return CollectionKind.channel;

  return null;
}

bool _isYouTubeHost(String host) {
  final h = host.toLowerCase();
  return h == 'youtube.com' ||
      h.endsWith('.youtube.com') ||
      h == 'youtube-nocookie.com' ||
      h.endsWith('.youtube-nocookie.com');
}

/// Resolves which kind of collection a completed fetch represents.
///
/// [requestedUrl] wins over the payload, because the payload for a channel
/// upload tab is frequently reported as a `youtube.com/playlist?list=UU…`
/// URL — yt-dlp really does enumerate a channel as an uploads playlist. The
/// user's link is the better evidence of what they meant to open.
///
/// [payload] is only consulted when the requested link said nothing, which
/// happens when the user pasted something the classifier does not recognise and
/// the extractor redirected it to the collection it resolved to.
///
/// Falls back to [CollectionKind.playlist] when neither says anything: every
/// flat playlist is a curated playlist unless something positively identifies
/// a channel, and paging a 40-video playlist because of a bad guess would be a
/// worse failure than the reverse.
CollectionKind resolveCollectionKind({
  required String requestedUrl,
  Map<String, dynamic>? payload,
}) {
  final fromRequest = collectionKindForUrl(requestedUrl);
  if (fromRequest != null) return fromRequest;

  final resolved = payload?['webpage_url'] ?? payload?['original_url'];
  final fromPayload = collectionKindForUrl(
    resolved is String ? resolved : null,
  );
  return fromPayload ?? CollectionKind.playlist;
}
