import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/services/updates/app_update_service.dart';

void main() {
  group('AppUpdater.compare', () {
    test('a newer upstream version offers an update', () {
      expect(
        AppUpdater.compare('v1.1.0', '1.0.0'),
        AppUpdateStatus.updateAvailable,
      );
      expect(
        AppUpdater.compare('v2.0.0', '1.9.9'),
        AppUpdateStatus.updateAvailable,
      );
    });

    test('the same version is up to date', () {
      expect(AppUpdater.compare('v1.0.0', '1.0.0'), AppUpdateStatus.upToDate);
      // Without the leading v, the same.
      expect(AppUpdater.compare('1.0.0', '1.0.0'), AppUpdateStatus.upToDate);
      // A higher upstream patch than the app also counts as current — no update
      // when upstream is behind.
      expect(AppUpdater.compare('v0.9.9', '1.0.0'), AppUpdateStatus.upToDate);
    });

    test('a build suffix is not worth an update prompt', () {
      // The suffix tracks the ABI, not a user-visible release, so a rebuild of
      // the same release must not prompt.
      expect(
        AppUpdater.compare('v1.0.0+2', '1.0.0+1'),
        AppUpdateStatus.upToDate,
      );
    });

    test('a prerelease upstream never outranks a stable app', () {
      // The v1.0.0-rc.1 tag was cut before 1.0.0. A stable build already on
      // 1.0.0 must not be offered the rc as an "update".
      expect(
        AppUpdater.compare('v1.0.0-rc.1', '1.0.0'),
        AppUpdateStatus.upToDate,
      );
      // Nor may it when the rc is for a newer minor.
      expect(
        AppUpdater.compare('v1.1.0-rc.1', '1.0.0'),
        AppUpdateStatus.updateAvailable,
      );
    });

    test('a prerelease app can graduate to the release', () {
      expect(
        AppUpdater.compare('v1.0.0', '1.0.0-rc.1'),
        AppUpdateStatus.updateAvailable,
      );
      expect(
        AppUpdater.compare('v1.0.0-rc.2', '1.0.0-rc.1'),
        AppUpdateStatus.updateAvailable,
      );
      expect(
        AppUpdater.compare('v1.0.0-rc.1', '1.0.0-rc.2'),
        AppUpdateStatus.upToDate,
      );
    });

    test('an rc build on the same rc is up to date', () {
      expect(
        AppUpdater.compare('v1.0.0-rc.1+1', '1.0.0-rc.1'),
        AppUpdateStatus.upToDate,
      );
    });

    test('it handles a missing upstream tag honestly', () {
      expect(AppUpdater.compare(null, '1.0.0'), AppUpdateStatus.unreachable);
    });

    test('an unreadable current version says it cannot tell', () {
      expect(
        AppUpdater.compare('v1.0.0', 'unknown (debug build)'),
        AppUpdateStatus.unknownCurrent,
      );
    });

    test('an unparsable upstream tag is unreachable, not "current"', () {
      expect(
        AppUpdater.compare('nightly-SNAPSHOT', '1.0.0'),
        AppUpdateStatus.unreachable,
      );
    });
  });

  group('SemanticVersion', () {
    test('orders numeric parts and ignores a leading v', () {
      final a = SemanticVersion(1, 2, 3);
      final b = SemanticVersion(1, 10, 0);
      final c = SemanticVersion(2, 0, 0);
      expect(a.compareTo(b), isNegative);
      expect(c.compareTo(a), isPositive);
      expect(a, SemanticVersion(1, 2, 3));
    });

    test('isNewerThan follows compareTo', () {
      expect(
        SemanticVersion(1, 1, 0).isNewerThan(SemanticVersion(1, 0, 0)),
        isTrue,
      );
      expect(
        SemanticVersion(1, 0, 0).isNewerThan(SemanticVersion(1, 1, 0)),
        isFalse,
      );
    });

    test('the semver.org prerelease ordering holds end to end', () {
      // The spec's own chain (§11): each entry is lower than the next.
      const chain = [
        '1.0.0-alpha',
        '1.0.0-alpha.1',
        '1.0.0-alpha.beta',
        '1.0.0-beta',
        '1.0.0-beta.2',
        '1.0.0-beta.11',
        '1.0.0-rc.1',
        '1.0.0',
      ];
      final parsed = chain.map(SemanticVersion.tryParse).toList();
      for (final v in parsed) {
        expect(v, isNotNull, reason: '$chain did not parse');
      }
      for (var i = 0; i < parsed.length - 1; i++) {
        expect(
          parsed[i + 1]!.isNewerThan(parsed[i]!),
          isTrue,
          reason: '${parsed[i + 1]} should be newer than ${parsed[i]}',
        );
        expect(parsed[i]!.compareTo(parsed[i + 1]!), isNegative);
      }
    });

    test('a prerelease parses with its identifiers and is a prerelease', () {
      final v = SemanticVersion.tryParse('v1.0.0-rc.1+42');
      expect(v, SemanticVersion(1, 0, 0, ['rc', '1']));
      expect(v!.isPrerelease, isTrue);
      expect(v.toString(), '1.0.0-rc.1');
    });

    test('nonsense identifiers are rejected rather than reordered', () {
      expect(SemanticVersion.tryParse('1.0.0-'), isNull);
      expect(SemanticVersion.tryParse('1.0.0-rc..1'), isNull);
      expect(SemanticVersion.tryParse('1.0.0-rc_1'), isNull);
      expect(SemanticVersion.tryParse('1.0.0-01'), isNull);
      expect(SemanticVersion.tryParse('-1.0.0'), isNull);
    });
  });

  group('AppUpdater (with a faked HTTP)', () {
    String releases(List<Map<String, Object?>> entries) => jsonEncode(entries);

    test(
      'an endpoint that returns junk reports unreachable, never throws',
      () async {
        final updater = AppUpdater(
          http: (_, _) async => 'not json at all',
          currentVersion: () async => '1.0.0',
        );
        final result = await updater.check();
        expect(result.status, AppUpdateStatus.unreachable);
      },
    );

    test('a non-list endpoint response reports unreachable', () async {
      final updater = AppUpdater(
        http: (_, _) async => '{"tag_name": "v9.9.9"}',
        currentVersion: () async => '1.0.0',
      );
      final result = await updater.check();
      expect(result.status, AppUpdateStatus.unreachable);
    });

    test('a null HTTP response reports unreachable', () async {
      final updater = AppUpdater(
        http: (_, _) async => null,
        currentVersion: () async => '1.0.0',
      );
      final result = await updater.check();
      expect(result.status, AppUpdateStatus.unreachable);
    });

    test(
      'a newer upstream tag is reported as an update with the release',
      () async {
        final updater = AppUpdater(
          http: (_, _) async => releases([
            {'tag_name': 'v9.9.9', 'draft': false, 'prerelease': false},
          ]),
          currentVersion: () async => '1.0.0',
        );
        final result = await updater.check();
        expect(result.status, AppUpdateStatus.updateAvailable);
        expect(result.release?.tag, 'v9.9.9');
        expect(result.release?.prerelease, isFalse);
      },
    );

    test('a stable build is not nudged onto a prerelease', () async {
      // The repo has a 1.0.0 stable and a 1.1.0-rc.1. The stable build rides
      // the stable channel and stays "up to date"; it must not be offered
      // the rc.
      final updater = AppUpdater(
        http: (_, _) async => releases([
          {'tag_name': 'v1.1.0-rc.1', 'draft': false, 'prerelease': true},
          {'tag_name': 'v1.0.0', 'draft': false, 'prerelease': false},
        ]),
        currentVersion: () async => '1.0.0',
      );
      final result = await updater.check();
      expect(result.status, AppUpdateStatus.upToDate);
      expect(result.release?.tag, 'v1.0.0');
    });

    test(
      'a stable build with no stable release sees the prerelease anyway',
      () async {
        // The repo's only release is the rc. Saying "up to date" would strand
        // every 0.1 install two generations back; the fallback says what
        // exists, marked as a pre-release.
        final updater = AppUpdater(
          http: (_, _) async => releases([
            {'tag_name': 'v1.0.0-rc.1', 'draft': false, 'prerelease': true},
          ]),
          currentVersion: () async => '0.1.0',
        );
        final result = await updater.check();
        expect(result.status, AppUpdateStatus.updateAvailable);
        expect(result.release?.tag, 'v1.0.0-rc.1');
        expect(result.release?.prerelease, isTrue);
      },
    );

    test('a prerelease build rides the prerelease channel', () async {
      final updater = AppUpdater(
        http: (_, _) async => releases([
          {'tag_name': 'v1.0.0', 'draft': false, 'prerelease': false},
          {'tag_name': 'v1.0.0-rc.1', 'draft': false, 'prerelease': true},
        ]),
        currentVersion: () async => '1.0.0-rc.1',
      );
      final result = await updater.check();
      expect(result.status, AppUpdateStatus.updateAvailable);
      expect(result.release?.tag, 'v1.0.0');
    });

    test('a prerelease build is current against its own rc', () async {
      final updater = AppUpdater(
        http: (_, _) async => releases([
          {'tag_name': 'v1.0.0-rc.1', 'draft': false, 'prerelease': true},
        ]),
        currentVersion: () async => '1.0.0-rc.1+1',
      );
      final result = await updater.check();
      expect(result.status, AppUpdateStatus.upToDate);
    });

    test('drafts and unparsable tags are skipped, not trusted', () async {
      final updater = AppUpdater(
        http: (_, _) async => releases([
          {'tag_name': 'v9.9.9', 'draft': true, 'prerelease': false},
          {'tag_name': 'banana', 'draft': false, 'prerelease': false},
          {'tag_name': 'v1.0.0', 'draft': false, 'prerelease': false},
        ]),
        currentVersion: () async => '1.0.0',
      );
      final result = await updater.check();
      expect(result.status, AppUpdateStatus.upToDate);
      expect(result.release?.tag, 'v1.0.0');
    });
  });

  // Not part of the default run: this reaches the real GitHub API, so it fails
  // on a plane, behind a proxy that blocks api.github.com, or during a GitHub
  // outage — none of which say anything about the code under test. It is here
  // because the service's real behaviour against a real endpoint is worth
  // checking deliberately.
  //
  // Run it with:
  //   flutter test test/services/app_update_service_test.dart --tags network
  group('a real check', () {
    test('the live endpoint answers honestly', () async {
      // Whatever it finds — available, current, unreachable — it must land on
      // an honest state and never throw.
      final result = await AppUpdater(currentVersion: () async => '1.0.0')
          .check();
      expect(result.status, isIn(AppUpdateStatus.values));
    }, tags: const ['network']);
  });
}
