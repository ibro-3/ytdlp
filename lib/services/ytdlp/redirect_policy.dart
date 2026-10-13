/// Hosts the official yt-dlp release assets are served from.
///
/// GitHub answers a `releases/latest/download/...` request with a 302 to the
/// versioned release URL on `github.com`, which in turn 302s to
/// `release-assets.githubusercontent.com`. Anything else is not a hop the app
/// should follow: a checksum index and a binary are fetched separately, and a
/// redirect of either could hand whoever controlled it both the file and the
/// digest published for it.
const Set<String> githubReleaseHosts = {
  'github.com',
  'objects.githubusercontent.com',
  'release-assets.githubusercontent.com',
};

/// The policy used for the app-managed yt-dlp release downloads.
const RedirectPolicy githubReleaseRedirects = RedirectPolicy(
  allowedHosts: githubReleaseHosts,
);

/// Why a redirect was refused.
class RedirectException implements Exception {
  const RedirectException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// How many redirects a download may be walked through before giving up.
const int defaultMaxRedirects = 5;

/// The HTTPS-only, host-pinned redirect rule for a set of trusted origins.
///
/// Redirects are followed explicitly by the caller (setting
/// `HttpRequest.followRedirects = false`) so every hop can be checked against
/// [allowedHosts]. `HttpClient` follows redirects on its own otherwise, and the
/// scheme is pinned as well as the host: a redirect to `http://github.com/…`
/// names an allowed host while dropping to cleartext, and a checksum protects
/// the bytes, not the request that fetched them.
class RedirectPolicy {
  const RedirectPolicy({
    required this.allowedHosts,
    this.maxRedirects = defaultMaxRedirects,
  });

  /// Bare hostnames (no scheme, no port) a redirect may point at.
  final Set<String> allowedHosts;

  /// Redirect hops to follow before refusing the download.
  final int maxRedirects;

  /// Resolves a `Location` header against [current], refusing to leave an
  /// HTTPS URL on [allowedHosts].
  ///
  /// Pure, so the decision that carries the whole host-pinning guarantee is
  /// testable without a network.
  Uri resolve(Uri current, String location) {
    Uri next;
    try {
      // Resolved against the *current* URL, because a relative `Location` is
      // legal and the CDN uses one.
      next = current.resolve(location);
    } catch (_) {
      throw RedirectException(
        'The server sent a redirect this app could not follow ("$location").',
      );
    }
    if (next.scheme != 'https' || !allowedHosts.contains(next.host)) {
      throw RedirectException(
        'The download was redirected to ${next.host}, which this app does not '
        'fetch from, so it was stopped.',
      );
    }
    return next;
  }
}

/// True for the HTTP status codes that carry a `Location` header.
bool isRedirectStatus(int statusCode) =>
    statusCode == 301 ||
    statusCode == 302 ||
    statusCode == 303 ||
    statusCode == 307 ||
    statusCode == 308;
