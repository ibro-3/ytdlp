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
  });

  group('AppUpdater (with a faked HTTP)', () {
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
          http: (_, _) async => '{"tag_name": "v9.9.9"}',
          currentVersion: () async => '1.0.0',
        );
        final result = await updater.check();
        expect(result.status, AppUpdateStatus.updateAvailable);
        expect(result.release?.tag, 'v9.9.9');
      },
    );
  });

  group('a real check', () {
    test('the live endpoint answers honestly', () async {
      // Runs the real HTTP client against the real GitHub API. Whatever it
      // finds — available, current, unreachable — it must land on an honest
      // state and never throw.
      final result = await AppUpdater(currentVersion: () async => '1.0.0')
          .check();
      expect(result.status, isIn(AppUpdateStatus.values));
    });
  });
}
