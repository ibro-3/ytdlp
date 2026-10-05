/// One cookie in a Netscape `cookies.txt` jar.
///
/// The on-disk format is seven tab-separated fields per line, and the
/// fields mean more than "a key and a value": the domain flag decides
/// whether the cookie is sent to subdomains, `secure` decides whether
/// it is only sent over HTTPS, and the expiry decides whether it
/// survives a restart. Modelling them as first-class fields is what
/// lets the app reason about a jar — count it, filter it, explain it —
/// instead of treating it as an opaque blob it merely forwards to
/// yt-dlp.
///
/// Values are never logged or included in a diagnostics report: a
/// cookie is a credential. The model exposes the *metadata* a support
/// report needs (domain, path, expiry) and deliberately nothing of the
/// value itself.
class CookieJarEntry {
  const CookieJarEntry({
    required this.domain,
    required this.path,
    required this.name,
    required this.value,
    this.includeSubdomains = false,
    this.secure = false,
    this.httpOnly = false,
    this.expiry,
  });

  /// The host the cookie belongs to, e.g. `.example.com`. A leading
  /// dot (the common form) means "this host and its subdomains" when
  /// [includeSubdomains] is true.
  final String domain;

  /// The URL path the cookie is restricted to, `/` for a whole host.
  final String path;

  final String name;

  /// The secret. Never logged, never reported, never compared in a
  /// test assertion.
  final String value;

  /// The Netscape `flag` column: whether [domain] also covers its
  /// subdomains.
  final bool includeSubdomains;

  /// Whether the cookie is only sent over HTTPS.
  final bool secure;

  /// Whether the cookie carries the `HttpOnly` attribute. Netscape
  /// files record this as a `#HttpOnly_` prefix on the line rather
  /// than a column.
  final bool httpOnly;

  /// When the cookie stops being sent. Null is a *session* cookie,
  /// which the browser discards on close — so null is a real state,
  /// not "unknown".
  final DateTime? expiry;

  /// Whether the cookie is still being sent at [at].
  ///
  /// A cookie with no expiry never expires; one whose expiry has
  /// passed is dead weight yt-dlp will still send unless it is
  /// filtered out, which is exactly the kind of stale state that
  /// makes a login look broken.
  bool isExpiredAt(DateTime at) => expiry != null && !at.isBefore(expiry!);

  CookieJarEntry copyWith({
    String? domain,
    String? path,
    String? name,
    String? value,
    bool? includeSubdomains,
    bool? secure,
    bool? httpOnly,
    DateTime? Function()? expiry,
  }) {
    return CookieJarEntry(
      domain: domain ?? this.domain,
      path: path ?? this.path,
      name: name ?? this.name,
      value: value ?? this.value,
      includeSubdomains: includeSubdomains ?? this.includeSubdomains,
      secure: secure ?? this.secure,
      httpOnly: httpOnly ?? this.httpOnly,
      expiry: expiry != null ? expiry() : this.expiry,
    );
  }

  /// Metadata only, by design: two cookies can share every field
  /// except the value, and no diagnostic or log should ever print
  /// [value].
  @override
  bool operator ==(Object other) =>
      other is CookieJarEntry &&
      other.domain == domain &&
      other.path == path &&
      other.name == name &&
      other.includeSubdomains == includeSubdomains &&
      other.secure == secure &&
      other.httpOnly == httpOnly &&
      other.expiry == expiry;

  @override
  int get hashCode => Object.hash(
    domain,
    path,
    name,
    includeSubdomains,
    secure,
    httpOnly,
    expiry,
  );

  @override
  String toString() =>
      'CookieJarEntry($domain, path=$path, name=$name, '
      'subdomains=$includeSubdomains, secure=$secure, '
      'httpOnly=$httpOnly, expiry=$expiry)';
}
