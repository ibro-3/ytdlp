/// The per-site view of a cookie jar.
///
/// yt-dlp takes a whole `--cookies` file and nothing finer-grained: there is no
/// flag for "send these cookies but not those". So "switch this site off" has
/// to be implemented by writing a *narrower* jar than the one the user
/// imported, and pointing yt-dlp at that.
///
/// That makes omission the dangerous part. A site quietly missing from the file
/// is indistinguishable, from the download log, from a site whose cookies have
/// expired — the request fails for a reason the user was never told about. So
/// this file is also where the rules that make omission legible live: which
/// hosts count as one site, what is dropped, and what the UI is required to say.
///
/// Two deliberate decisions, both about not lying to the user:
///
/// - **A host is grouped exactly as written**, minus the leading dot browsers
///   use to mean "and subdomains". `.example.com` and `example.com` are one
///   site because a switch has to govern both; `www.example.com` is a *separate*
///   site, listed separately, and switching `example.com` off does not quietly
///   disable it. Collapsing to a registrable domain would be friendlier in the
///   common case, but a wrong guess there silently changes which credentials
///   are sent to which host — a bad trade for tidier list output.
/// - **Expiry is reported as the soonest one**, not the latest. The soonest is
///   when the site's authentication starts to degrade, which is the date the
///   user can act on.
library;

import 'cookie_model.dart';

/// The host as the user would recognise it: no leading dot, lowercased, no
/// surrounding whitespace.
///
/// The key a switch is stored and matched against. Case-insensitive because a
/// host is, and dot-trimmed because a leading dot is a browser's way of spelling
/// the same host — grouping those apart would show the user two rows for one
/// site, each governing only part of it.
String cookieHostKey(String domain) {
  var host = domain.trim().toLowerCase();
  while (host.startsWith('.')) {
    host = host.substring(1);
  }
  return host;
}

/// One site in a jar, with the state the per-site manager needs.
class CookieDomain {
  CookieDomain({
    required this.domain,
    required List<CookieJarEntry> entries,
    this.enabled = true,
  }) : entries = List.unmodifiable(entries);

  /// The host, as produced by [cookieHostKey].
  final String domain;

  /// Every cookie the jar holds for this host, in file order.
  final List<CookieJarEntry> entries;

  /// Whether yt-dlp is allowed to see this site's cookies.
  final bool enabled;

  /// Copies of the domain with the switch set the other way.
  CookieDomain withEnabled(bool value) =>
      CookieDomain(domain: domain, entries: entries, enabled: value);

  int get cookieCount => entries.length;

  /// Whether every cookie here is marked HttpOnly.
  ///
  /// Worth surfacing because a jar of only HttpOnly cookies is a *browser*
  /// export rather than something the user wrote, and that changes how they
  /// should think about editing it.
  bool get httpOnly => entries.isNotEmpty && entries.every((e) => e.httpOnly);

  /// Whether this site's cookies are only sent over HTTPS.
  bool get secureOnly => entries.isNotEmpty && entries.every((e) => e.secure);

  /// The soonest expiry among this site's cookies, or null when they are all
  /// session cookies.
  ///
  /// Null means "until the browser closes", not "unknown", and the UI says so
  /// rather than showing a blank.
  DateTime? get expiresAt {
    final dates = <DateTime>[
      for (final e in entries)
        if (e.expiry != null) e.expiry!,
    ];
    if (dates.isEmpty) return null;
    dates.sort();
    return dates.first;
  }

  /// Whether every cookie here is already past its expiry at [at].
  ///
  /// True for a site whose cookies are all dead — which yt-dlp will still send
  /// unless filtered out, and which is a common reason a login "stopped
  /// working" with no visible cause.
  bool isStaleAt(DateTime at) =>
      entries.isNotEmpty && entries.every((e) => e.isExpiredAt(at));

  /// Whether any cookie here is still good at [at].
  bool isLiveAt(DateTime at) => entries.any((e) => !e.isExpiredAt(at));

  /// One line describing the site's lifetime, in the user's terms.
  ///
  /// Takes `now` rather than reading the clock so the wording is testable.
  String lifetimeLabel(DateTime now) {
    if (isStaleAt(now)) return 'Expired — needs re-exporting from the browser';
    final expiry = expiresAt;
    if (expiry == null) return 'Session only — gone when the browser closes';
    final days = expiry.difference(now).inDays;
    if (days <= 0) return 'Expires today';
    if (days == 1) return 'Expires tomorrow';
    if (days < 30) return 'Expires in $days days';
    final months = (days / 30).round();
    return months <= 1
        ? 'Expires in about a month'
        : 'Expires in $months months';
  }

  @override
  String toString() =>
      'CookieDomain($domain, cookies: $cookieCount, enabled: $enabled)';
}

/// Groups a parsed jar into one [CookieDomain] per host.
///
/// [disabled] names the hosts the user has switched off, as keys from
/// [cookieHostKey]. Hosts absent from it are enabled, so a stored list left over
/// from an older jar cannot disable a site the user never chose to disable.
///
/// Ordered by cookie count, then by name: the sites that matter most to a
/// download are the ones carrying a login, and a jar is long enough that an
/// alphabetical list buries them.
List<CookieDomain> groupCookieDomains(
  List<CookieJarEntry> entries, {
  Set<String> disabled = const {},
}) {
  final byHost = <String, List<CookieJarEntry>>{};
  for (final entry in entries) {
    final key = cookieHostKey(entry.domain);
    if (key.isEmpty) continue;
    byHost.putIfAbsent(key, () => []).add(entry);
  }
  final domains = byHost.entries
      .map(
        (e) => CookieDomain(
          domain: e.key,
          entries: e.value,
          enabled: !disabled.contains(e.key),
        ),
      )
      .toList();
  domains.sort((a, b) {
    final byCount = b.cookieCount.compareTo(a.cookieCount);
    return byCount != 0 ? byCount : a.domain.compareTo(b.domain);
  });
  return domains;
}

/// The cookies yt-dlp should be given: everything except the switched-off sites.
///
/// Matching is on the exact host, because the switch in the UI is per host. A
/// domain that would group to an empty key is dropped rather than kept: it
/// cannot be shown, so it cannot be controlled, and an un-controllable cookie
/// in the file is exactly the silent omission this exists to avoid.
List<CookieJarEntry> enabledCookieEntries(
  List<CookieJarEntry> entries, {
  Set<String> disabled = const {},
}) => [
  for (final entry in entries)
    if (!disabled.contains(cookieHostKey(entry.domain))) entry,
];

/// [disabled] reduced to the hosts that are actually in [domains].
///
/// Called when a new jar is imported: it keeps the user's choices for the sites
/// that are still there and drops the ones that are gone, so the stored list
/// cannot grow forever or resurrect a decision about a site no longer present.
Set<String> pruneDisabledDomains(
  Set<String> disabled,
  List<CookieDomain> domains,
) {
  final present = {for (final d in domains) d.domain};
  return {
    for (final d in disabled)
      if (present.contains(d)) d,
  };
}
