import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/core/models/cookie_browser.dart';
import 'package:ytdlp/core/models/cookie_profiles.dart';

void main() {
  group('CookieBrowser.byArgument', () {
    test('recognises yt-dlp\'s own spelling', () {
      expect(CookieBrowser.byArgument('chrome'), CookieBrowser.chrome);
      expect(CookieBrowser.byArgument('firefox'), CookieBrowser.firefox);
    });

    test('ignores case and stray whitespace', () {
      // The value can come out of a hand-edited settings box, and rejecting
      // `Chrome` would silently fall back to the jar.
      expect(CookieBrowser.byArgument('  Chrome '), CookieBrowser.chrome);
    });

    test('rejects a name yt-dlp does not have', () {
      // Passing it on would fail every download on an argument yt-dlp rejects,
      // which is a far worse outcome than falling back to the jar.
      expect(CookieBrowser.byArgument('chrom'), isNull);
      expect(CookieBrowser.byArgument('safari:Default'), isNull);
      expect(CookieBrowser.byArgument(''), isNull);
    });
  });

  group('checkProfileName', () {
    test('an ordinary profile name is accepted', () {
      expect(checkProfileName('Default'), isNull);
      expect(checkProfileName('Profile 2'), isNull);
      expect(
        checkProfileName('   '),
        isNull,
        reason: 'empty means the default',
      );
      expect(checkProfileName('chrome+kwallet6'), isNull);
    });

    test('a path is refused', () {
      // yt-dlp reads a profile argument that starts with a path separator as an
      // absolute path, so a hand-edited settings box could otherwise aim the
      // cookie read at any directory on the device.
      expect(checkProfileName('/etc'), ProfileProblem.notAProfileName);
      expect(
        checkProfileName('/home/me/.config/chrome'),
        ProfileProblem.notAProfileName,
      );
      expect(checkProfileName(r'\Users\me'), ProfileProblem.notAProfileName);
      expect(checkProfileName('  /etc  '), ProfileProblem.notAProfileName);
    });

    test('every problem has something to show the user', () {
      expect(ProfileProblem.notAProfileRoot.message, isNotNull);
      expect(ProfileProblem.notAProfileName.message, isNotNull);
    });
  });

  group('cookieBrowserSpec', () {
    test('is the bare name with no profile', () {
      expect(cookieBrowserSpec(browser: CookieBrowser.firefox), 'firefox');
    });

    test('appends a profile with a colon', () {
      expect(
        cookieBrowserSpec(browser: CookieBrowser.chrome, profile: 'Profile 2'),
        'chrome:Profile 2',
      );
    });

    test('trims the profile rather than emitting a dangling colon', () {
      expect(
        cookieBrowserSpec(browser: CookieBrowser.chrome, profile: '  '),
        'chrome',
      );
    });

    test('passes a profile with punctuation through', () {
      // yt-dlp accepts characters like `:` and `+` in a profile name, so the
      // app should pass them through unchanged rather than silently dropping
      // the profile.
      expect(
        cookieBrowserSpec(
          browser: CookieBrowser.chrome,
          profile: r'C:\Users\me\Profile 2',
        ),
        r'chrome:C:\Users\me\Profile 2',
      );
      expect(
        cookieBrowserSpec(browser: CookieBrowser.chrome, profile: 'kwallet6'),
        'chrome:kwallet6',
      );
    });

    test('is null with no browser', () {
      expect(cookieBrowserSpec(browser: null), isNull);
    });
  });

  group('resolveCookieSource', () {
    test('nothing configured', () {
      expect(
        resolveCookieSource(cookiesPath: '', cookieBrowser: ''),
        CookieSource.none,
      );
    });

    test('a jar', () {
      expect(
        resolveCookieSource(cookiesPath: '/x/cookies.txt', cookieBrowser: ''),
        CookieSource.file,
      );
    });

    test('a browser', () {
      expect(
        resolveCookieSource(cookiesPath: '', cookieBrowser: 'firefox'),
        CookieSource.browser,
      );
    });

    test('a browser wins over a jar, because it is the newer intent', () {
      expect(
        resolveCookieSource(
          cookiesPath: '/x/cookies.txt',
          cookieBrowser: 'chrome',
        ),
        CookieSource.browser,
      );
    });

    test('an unrecognised browser is not a browser', () {
      // The jar is still there and still works; treating a typo as "no source"
      // would leave the user logged out with nothing telling them why.
      expect(
        resolveCookieSource(
          cookiesPath: '/x/cookies.txt',
          cookieBrowser: 'chrom',
        ),
        CookieSource.file,
      );
    });
  });

  group('cookieBrowserBlock', () {
    test('allows every desktop platform', () {
      for (final mac in [true, false]) {
        expect(
          cookieBrowserBlock(isWeb: false, isMobile: false, isMacOS: mac),
          isNull,
        );
      }
    });

    test('blocks mobile with a reason, not with absence', () {
      // The point of the exercise: a hidden control leaves a user unable to
      // tell "this app cannot" from "this app never heard of it".
      final why = cookieBrowserBlock(
        isWeb: false,
        isMobile: true,
        isMacOS: false,
      );
      expect(why, isNotNull);
      expect(why, contains('cookies.txt'));
    });

    test('blocks a browser build with a reason', () {
      expect(
        cookieBrowserBlock(isWeb: true, isMobile: false, isMacOS: false),
        isNotNull,
      );
    });

    test('the reason is never a bare "unavailable"', () {
      // A bare adjective gives the user nothing to do and nothing to report.
      final why = cookieBrowserBlock(
        isWeb: false,
        isMobile: true,
        isMacOS: false,
      );
      expect(why!.length, greaterThan(40));
      expect(why, isNot(contains('unavailable')));
    });
  });

  group('cookieArgs', () {
    test('empty when nothing is configured', () {
      expect(cookieArgs(), isEmpty);
      expect(cookieArgs(cookiesPath: '', cookieBrowser: ''), isEmpty);
    });

    test('a jar becomes --cookies', () {
      expect(cookieArgs(cookiesPath: '/x/cookies.txt'), [
        '--cookies',
        '/x/cookies.txt',
      ]);
    });

    test('a browser becomes --cookies-from-browser', () {
      expect(cookieArgs(cookieBrowser: 'firefox'), [
        '--cookies-from-browser',
        'firefox',
      ]);
    });

    test('a profile is included', () {
      expect(
        cookieArgs(cookieBrowser: 'chrome', cookieBrowserProfile: 'Profile 2'),
        ['--cookies-from-browser', 'chrome:Profile 2'],
      );
    });

    test('never emits both sources', () {
      // The guarantee the per-site manager rests on: a site switched off in the
      // jar must not be able to go out via a browser store.
      final args = cookieArgs(
        cookiesPath: '/x/cookies.txt',
        cookieBrowser: 'chrome',
      );
      expect(args, isNot(contains('--cookies')));
      expect(args, ['--cookies-from-browser', 'chrome']);
    });

    test('falls back to the jar when the browser name is a typo', () {
      // Passing `chrom` on would fail every download on an argument yt-dlp
      // does not have, with an error that says nothing about the setting.
      expect(
        cookieArgs(cookiesPath: '/x/cookies.txt', cookieBrowser: 'chrom'),
        ['--cookies', '/x/cookies.txt'],
      );
    });

    test('passes a profile with special characters through', () {
      final a = cookieArgs(
        cookieBrowser: 'chrome',
        cookieBrowserProfile: r'C:\Users\me\Profile 2',
      );
      expect(a, ['--cookies-from-browser', r'chrome:C:\Users\me\Profile 2']);
    });

    test('trims a jar path rather than passing whitespace', () {
      expect(cookieArgs(cookiesPath: '  /x/cookies.txt  '), [
        '--cookies',
        '/x/cookies.txt',
      ]);
    });
  });

  group('profileNamesIn', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('ytdlp_profiles_');
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    /// A Chromium layout: a bare `Cookies` file in each profile.
    void chromium(String name) {
      final dir = Directory('${root.path}/$name')..createSync();
      File('${dir.path}/Cookies').writeAsStringSync('x');
    }

    /// A Windows/macOS Chromium layout: the store lives in `Network/`.
    void chromiumNetwork(String name) {
      final dir = Directory('${root.path}/$name/Network')
        ..createSync(recursive: true);
      File('${dir.path}/Cookies').writeAsStringSync('x');
    }

    /// A Firefox layout.
    void firefox(String name) {
      final dir = Directory('${root.path}/$name')..createSync();
      File('${dir.path}/cookies.sqlite').writeAsStringSync('x');
    }

    test('finds a Chromium root', () async {
      // Linux keeps the store bare; Windows and macOS bury it in Network/.
      chromium('Default');
      chromiumNetwork('Profile 1');

      expect(await profileNamesIn(root.path), ['Default', 'Profile 1']);
    });

    test('finds a Firefox root', () async {
      firefox('4g3ab2.default-release');

      expect(await profileNamesIn(root.path), ['4g3ab2.default-release']);
    });

    test('lists the default profile first', () async {
      chromium('Profile 2');
      chromium('Default');

      expect((await profileNamesIn(root.path)).first, 'Default');
    });

    test('lists the Firefox default first too', () async {
      firefox('zzz.default');
      firefox('4g3a.default-release');

      expect((await profileNamesIn(root.path)).first, '4g3a.default-release');
    });

    test('ignores directories with no cookie store in them', () async {
      // A browser's profile root also holds Extensions, Local State, Crashpad
      // and more. Reporting those would make the picker unusable.
      Directory('${root.path}/Extensions/abc').createSync(recursive: true);
      Directory('${root.path}/System Profile').createSync();
      chromium('Default');

      expect(await profileNamesIn(root.path), ['Default']);
    });

    test('does not descend past one level', () async {
      // A recursive walk would report the whole browser installation, and a
      // profile nested inside another is not something yt-dlp accepts.
      chromium('Default');
      final nested = Directory('${root.path}/Profile 9')..createSync();
      Directory('${nested.path}/Vendor/Cookies').createSync(recursive: true);

      expect(await profileNamesIn(root.path), ['Default']);
    });

    test('ignores hidden folders', () async {
      chromium('Default');
      Directory('${root.path}/.cache').createSync();

      expect(await profileNamesIn(root.path), ['Default']);
    });

    test('a missing folder is an empty list, not an error', () async {
      // The user can have picked a folder on removable media that is now gone.
      // Throwing here would take the settings page down with it.
      expect(await profileNamesIn('${root.path}/gone'), isEmpty);
    });

    test('a file rather than a folder is an empty list', () async {
      final file = File('${root.path}/cookies.txt')
        ..writeAsStringSync('# Netscape HTTP Cookie File\n');
      expect(await profileNamesIn(file.path), isEmpty);
    });
  });
}
