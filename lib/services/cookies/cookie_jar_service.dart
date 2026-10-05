/// Owns the two files behind per-site cookie management.
///
/// There are two, and the split is what makes switching a site off reversible:
///
/// - the **source** jar, byte-for-byte what the user imported, never rewritten;
/// - the **generated** jar, the source minus the sites switched off, which is
///   the only path yt-dlp is ever given.
///
/// Rewriting the import in place would be simpler and would destroy it: the
/// next switch would be applied to an already-filtered jar, and the sites the
/// user turned off could never come back without a fresh browser export.
///
/// Because omission is invisible from the outside — a withheld cookie looks
/// exactly like an expired one — [buildGenerated] refuses to write a jar with
/// nothing in it, so a mis-set switch fails loudly in the UI instead of quietly
/// breaking every download.
library;

import 'dart:io';

import 'cookie_domains.dart';
import 'cookie_jar.dart';

/// What happened when the jar was generated, in terms a caller can report.
class CookieJarWriteResult {
  const CookieJarWriteResult({
    required this.path,
    required this.kept,
    required this.withheld,
    this.sites = 0,
    this.reason,
  });

  /// The file written.
  final String path;

  /// Cookies in it.
  final int kept;

  /// Cookies left out, because their site is switched off.
  final int withheld;

  /// Distinct hosts left in it.
  ///
  /// Kept separate from [kept] because "3 cookies from 2 sites" and "3 sites"
  /// are different claims, and reporting the cookie count as a site count would
  /// be the kind of plausible-looking miscount a support report then has to
  /// unpick.
  final int sites;

  /// Why nothing was written, when nothing was.
  final String? reason;

  bool get wroteSomething => reason == null;
}

class CookieJarService {
  const CookieJarService({required this.supportDir});

  /// Where both files live. The paths are derived rather than stored so a
  /// moved support directory cannot leave settings pointing at a file that is
  /// no longer there.
  final String supportDir;

  String get sourcePath => '$supportDir/cookies-source.txt';

  String get generatedPath => '$supportDir/cookies.txt';

  /// Reads and parses the full import, or an empty result if there is none.
  ///
  /// Never throws: a missing or unreadable source is a state the UI can explain
  /// ("re-import your cookies"), not a crash.
  Future<CookieJarParseResult> readSource([String? sourcePath]) async {
    final path = sourcePath ?? this.sourcePath;
    try {
      final text = await File(path).readAsString();
      return CookieJar.parse(text);
    } catch (_) {
      return const CookieJarParseResult(entries: [], skipped: 0);
    }
  }

  /// Stores [text] as the new source and regenerates the jar yt-dlp reads.
  ///
  /// [disabled] is pruned against the jar's own hosts first, so a stale entry
  /// from a previous import cannot carry over and withhold a cookie from a site
  /// the user never chose to withhold.
  Future<CookieJarWriteResult> importSource(
    String text, {
    Set<String> disabled = const {},
  }) async {
    final parsed = CookieJar.parse(text);
    final domains = groupCookieDomains(parsed.entries);
    final kept = pruneDisabledDomains(disabled, domains);
    await _write(sourcePath, text);
    return buildGenerated(disabled: kept);
  }

  /// Rewrites the generated jar from the source, withholding [disabled].
  ///
  /// [disabled] is required rather than defaulted. A default of "nothing is
  /// disabled" here would be the worst possible wrong answer: the caller would
  /// hand back a jar holding credentials the user had just switched off, and
  /// nothing downstream would notice.
  Future<CookieJarWriteResult> buildGenerated({
    required Set<String> disabled,
  }) async {
    final parsed = await readSource();
    final kept = enabledCookieEntries(parsed.entries, disabled: disabled);
    final withheld = parsed.entries.length - kept.length;
    if (kept.isEmpty) {
      // Writing an empty jar is the one outcome that must not happen quietly:
      // yt-dlp would then be handed a valid file containing no cookies, and
      // every request would fail with a 403 the user cannot connect to a
      // switch they made.
      return CookieJarWriteResult(
        path: generatedPath,
        kept: 0,
        withheld: withheld,
        reason: withheld == 0
            ? 'The cookie file has no cookies in it.'
            : 'Every site is switched off, so there is nothing left to send.',
      );
    }
    await _write(generatedPath, CookieJar.write(kept));
    return CookieJarWriteResult(
      path: generatedPath,
      kept: kept.length,
      withheld: withheld,
      sites: groupCookieDomains(kept).length,
    );
  }

  /// Deletes both files. Called when the user removes cookies, so a withdrawn
  /// login is not left readable on disk for the next download to pick up.
  Future<void> remove() async {
    for (final path in [sourcePath, generatedPath]) {
      try {
        await File(path).delete();
      } catch (_) {
        // Already gone, or held by something else. Either way there is nothing
        // left to point yt-dlp at once the settings are cleared.
      }
    }
  }

  Future<void> _write(String path, String contents) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(contents, flush: true);
  }
}
