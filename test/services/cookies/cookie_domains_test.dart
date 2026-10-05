import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/services/cookies/cookie_domains.dart';
import 'package:ytdlp/services/cookies/cookie_jar.dart';
import 'package:ytdlp/services/cookies/cookie_model.dart';

CookieJarEntry _cookie(
  String domain, {
  String name = 'sid',
  DateTime? expiry,
  bool secure = false,
  bool httpOnly = false,
}) => CookieJarEntry(
  domain: domain,
  path: '/',
  name: name,
  value: 'secret',
  secure: secure,
  httpOnly: httpOnly,
  expiry: expiry,
);

final _now = DateTime.utc(2026, 6, 1);

void main() {
  group('cookieHostKey', () {
    test('drops the leading dot browsers use for subdomains', () {
      // A switch that treated these as two sites would show the user two rows
      // for one site, each silently governing only part of it.
      expect(cookieHostKey('.example.com'), 'example.com');
      expect(cookieHostKey('example.com'), 'example.com');
    });

    test('drops repeated dots rather than leaving a broken host', () {
      expect(cookieHostKey('..example.com'), 'example.com');
    });

    test('is case- and whitespace-insensitive', () {
      // A host is case-insensitive by definition, so `Example.COM` and
      // `example.com` must not become two switchable rows.
      expect(cookieHostKey('  .Example.COM '), 'example.com');
    });

    test('reduces a whitespace-only domain to empty', () {
      expect(cookieHostKey('   '), isEmpty);
    });
  });

  group('CookieDomain', () {
    test('reports the soonest expiry, not the latest', () {
      // The soonest is when authentication starts to degrade, which is the
      // date the user can act on. The latest would keep promising a working
      // login after the first cookie had already died.
      final domain = CookieDomain(
        domain: 'example.com',
        entries: [
          _cookie('example.com', expiry: DateTime.utc(2026, 12, 1)),
          _cookie('example.com', expiry: DateTime.utc(2026, 6, 2)),
          _cookie('example.com', expiry: DateTime.utc(2026, 9, 1)),
        ],
      );
      expect(domain.expiresAt, DateTime.utc(2026, 6, 2));
    });

    test('a jar of only session cookies has no expiry', () {
      final domain = CookieDomain(
        domain: 'example.com',
        entries: [_cookie('example.com')],
      );
      expect(domain.expiresAt, isNull);
    });

    test('is stale only when every cookie has expired', () {
      final oneLive = CookieDomain(
        domain: 'example.com',
        entries: [
          _cookie('example.com', expiry: DateTime.utc(2026, 5, 1)),
          _cookie('example.com', expiry: DateTime.utc(2027, 5, 1)),
        ],
      );
      expect(oneLive.isStaleAt(_now), isFalse);
      expect(oneLive.isLiveAt(_now), isTrue);

      final allDead = CookieDomain(
        domain: 'example.com',
        entries: [
          _cookie('example.com', expiry: DateTime.utc(2026, 5, 1)),
          _cookie('example.com', expiry: DateTime.utc(2026, 4, 1)),
        ],
      );
      expect(allDead.isStaleAt(_now), isTrue);
      expect(allDead.isLiveAt(_now), isFalse);
    });

    test('a session cookie is never stale', () {
      final domain = CookieDomain(
        domain: 'example.com',
        entries: [
          _cookie('example.com', expiry: DateTime.utc(2000, 1, 1)),
          _cookie('example.com'),
        ],
      );
      expect(domain.isStaleAt(_now), isFalse);
    });

    test('withEnabled copies without touching the entries', () {
      final domain = CookieDomain(
        domain: 'example.com',
        entries: [_cookie('example.com')],
      );
      final off = domain.withEnabled(false);
      expect(off.enabled, isFalse);
      expect(off.cookieCount, 1);
      expect(domain.enabled, isTrue, reason: 'the original must not mutate');
    });

    group('lifetimeLabel', () {
      String labelFor(List<CookieJarEntry> entries) => CookieDomain(
        domain: 'example.com',
        entries: entries,
      ).lifetimeLabel(_now);

      test('says session cookies go when the browser closes', () {
        // Not "unknown" — a blank or a guess would be a different claim.
        expect(labelFor([_cookie('example.com')]), contains('browser closes'));
      });

      test('flags an expired jar instead of dating it', () {
        expect(
          labelFor([_cookie('example.com', expiry: DateTime.utc(2026, 1, 1))]),
          contains('Expired'),
        );
      });

      test('counts days, then rounds to months', () {
        expect(
          labelFor([_cookie('example.com', expiry: DateTime.utc(2026, 6, 11))]),
          'Expires in 10 days',
        );
        expect(
          labelFor([_cookie('example.com', expiry: DateTime.utc(2026, 7, 1))]),
          'Expires in about a month',
        );
        expect(
          labelFor([_cookie('example.com', expiry: DateTime.utc(2027, 1, 1))]),
          'Expires in 7 months',
        );
      });

      test('calls out the last day rather than saying "0 days"', () {
        // Late on the expiry date, not the instant itself: a cookie whose
        // expiry has arrived is dead, so "expires today" has to mean "later
        // today" rather than "at this very moment".
        expect(
          labelFor([
            _cookie('example.com', expiry: _now.add(const Duration(hours: 6))),
          ]),
          'Expires today',
        );
        expect(
          labelFor([
            _cookie(
              'example.com',
              expiry: _now.add(const Duration(days: 1, hours: 2)),
            ),
          ]),
          'Expires tomorrow',
        );
      });

      test('treats the exact expiry instant as already expired', () {
        expect(
          labelFor([_cookie('example.com', expiry: _now)]),
          contains('Expired'),
        );
      });
    });
  });

  group('groupCookieDomains', () {
    test('merges the dotted and bare spellings of one host', () {
      final domains = groupCookieDomains([
        _cookie('.example.com', name: 'a'),
        _cookie('example.com', name: 'b'),
      ]);
      expect(domains, hasLength(1));
      expect(domains.single.domain, 'example.com');
      expect(domains.single.cookieCount, 2);
    });

    test('keeps a subdomain as its own site', () {
      // The alternative — collapsing to a registrable domain — would mean a
      // switch reading "on" while actually withholding www's cookies, or the
      // reverse. Either is a lie about what is being sent.
      final domains = groupCookieDomains([
        _cookie('.example.com', name: 'a'),
        _cookie('www.example.com', name: 'b'),
      ]);
      expect(
        domains.map((d) => d.domain),
        containsAll(['example.com', 'www.example.com']),
      );
    });

    test('orders the sites carrying the most cookies first', () {
      // A jar is long enough that alphabetical order buries the site with the
      // actual login in it.
      final domains = groupCookieDomains([
        _cookie('a.test', name: '1'),
        _cookie('b.test', name: '2'),
        for (var i = 0; i < 5; i++) _cookie('c.test', name: 'c$i'),
        _cookie('d.test', name: '4'),
        _cookie('e.test', name: '5'),
      ]);
      expect(domains.first.domain, 'c.test');
      expect(domains.first.cookieCount, 5);
    });

    test('breaks a count tie by name so the list does not shuffle', () {
      final domains = groupCookieDomains([
        _cookie('zebra.test', name: '1'),
        _cookie('alpha.test', name: '2'),
      ]);
      expect(domains.map((d) => d.domain), ['alpha.test', 'zebra.test']);
    });

    test('applies the stored switch state', () {
      final domains = groupCookieDomains(
        [_cookie('a.test', name: '1'), _cookie('b.test', name: '2')],
        disabled: {'a.test'},
      );
      expect(domains.firstWhere((d) => d.domain == 'a.test').enabled, isFalse);
      expect(domains.firstWhere((d) => d.domain == 'b.test').enabled, isTrue);
    });

    test('drops a cookie with no host at all', () {
      // It could not be shown, so it could not be controlled, and an
      // un-controllable cookie in the file is exactly the silent omission the
      // per-site manager exists to prevent.
      final domains = groupCookieDomains([_cookie('  ', name: 'orphan')]);
      expect(domains, isEmpty);
    });

    test('an empty jar yields no sites rather than one empty site', () {
      expect(groupCookieDomains(const []), isEmpty);
    });
  });

  group('enabledCookieEntries', () {
    final jar = [
      _cookie('.example.com', name: 'a'),
      _cookie('example.com', name: 'b'),
      _cookie('other.test', name: 'c'),
    ];

    test('withholds every cookie of a switched-off host', () {
      // Both spellings, or the switch would only half-apply and the site would
      // keep working — or keep failing — for reasons the user cannot see.
      final kept = enabledCookieEntries(jar, disabled: {'example.com'});
      expect(kept.map((e) => e.name), ['c']);
    });

    test('withholds nothing when no host is off', () {
      expect(enabledCookieEntries(jar), hasLength(3));
    });

    test('leaves an unrelated host alone', () {
      final kept = enabledCookieEntries(jar, disabled: {'nowhere.test'});
      expect(kept, hasLength(3));
    });

    test('withholds nothing but the named host', () {
      final kept = enabledCookieEntries(jar, disabled: {'other.test'});
      expect(kept.map((e) => e.name), ['a', 'b']);
    });

    test('round-trips through write and parse unchanged', () {
      // The generated jar is what yt-dlp reads, so anything lost in the
      // round-trip is a credential that silently stopped being sent.
      final kept = enabledCookieEntries(jar, disabled: {'other.test'});
      final text = CookieJar.write(kept);
      final back = CookieJar.parse(text);
      expect(back.entries.map((e) => e.name), ['a', 'b']);
      // The domain is written back exactly as it was read. Re-spelling it
      // would change which hosts the cookie is sent to — the leading dot is
      // what makes it cover subdomains.
      expect(back.entries.map((e) => e.domain), [
        '.example.com',
        'example.com',
      ]);
      expect(back.entries.every((e) => e.value == 'secret'), isTrue);
      expect(back.skipped, 0);
    });
  });

  group('pruneDisabledDomains', () {
    test('keeps a choice the user made about a site still in the jar', () {
      final domains = groupCookieDomains([
        _cookie('a.test'),
        _cookie('b.test'),
      ]);
      expect(pruneDisabledDomains({'a.test', 'gone.test'}, domains), {
        'a.test',
      });
    });

    test('empties the set when the new jar shares nothing', () {
      final domains = groupCookieDomains([_cookie('new.test')]);
      expect(pruneDisabledDomains({'old.test'}, domains), isEmpty);
    });
  });
}
