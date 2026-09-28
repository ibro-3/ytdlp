import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/core/models/youtube_prefs.dart';
import 'package:ytdlp/core/models/download_options.dart';
import 'package:ytdlp/core/models/video_info.dart';
import 'package:ytdlp/services/ytdlp/ejs_installer.dart';
import 'package:ytdlp/services/ytdlp/ytdlp_service.dart';

const _video = Format(
  kind: FormatKind.video,
  label: '720p',
  selector: 'bv*[height<=720]+ba/b[height<=720]/b',
);

List<String> _args({
  YoutubePrefs youtube = const YoutubePrefs(),
  List<String> extraArgs = const [],
}) => buildDownloadArgs(
  url: 'https://youtu.be/abc',
  format: _video,
  options: const DownloadOptions(),
  outputDir: '/tmp/stg',
  template: '%(title)s [%(id)s].%(ext)s',
  extraArgs: extraArgs,
  youtube: youtube,
);

void main() {
  group('YoutubePrefs', () {
    test('defaults to the JS runtime on and web only', () {
      const p = YoutubePrefs();
      expect(p.useEjs, isTrue);
      expect(p.extraClients, isEmpty);
      expect(p.playerClientsTarget, 'web');
    });

    test('a web-only selection is not worth sending', () {
      // `web` is already yt-dlp's default, so the flag would be a no-op on
      // every download.
      expect(const YoutubePrefs().isClientSelectionMeaningful, isFalse);
    });

    test('extra clients are listed after web', () {
      const p = YoutubePrefs(
        extraClients: [YoutubeClient.ios, YoutubeClient.tv],
      );
      expect(p.isClientSelectionMeaningful, isTrue);
      expect(p.playerClientsTarget, 'web,ios,tv');
    });

    test('fromMap drops an unknown client rather than passing it on', () {
      // yt-dlp errors out on an unrecognised value, which would break every
      // download rather than one.
      final p = YoutubePrefs.fromMap({
        'extraClients': ['ios', 'not_a_client', 'web'],
      });
      expect(p.extraClients, [YoutubeClient.ios]);
    });

    test('fromMap never restores web as an extra', () {
      final p = YoutubePrefs.fromMap({
        'extraClients': ['web', 'web'],
      });
      expect(p.extraClients, isEmpty);
    });

    test('fromMap defaults when nothing is stored', () {
      expect(YoutubePrefs.fromMap(null), const YoutubePrefs());
      expect(YoutubePrefs.fromMap(const {}), const YoutubePrefs());
    });

    test('round-trips through a map', () {
      const p = YoutubePrefs(
        useEjs: false,
        extraClients: [YoutubeClient.android],
      );
      final back = YoutubePrefs.fromMap(p.toMap());
      expect(back, p);
    });

    test('copyWith sets and clears', () {
      const p = YoutubePrefs();
      expect(p.copyWith(useEjs: false).useEjs, isFalse);
      expect(p.copyWith(extraClients: const [YoutubeClient.ios]).extraClients, [
        YoutubeClient.ios,
      ]);
      expect(p.copyWith().useEjs, isTrue);
    });

    test('tv-like clients are flagged', () {
      expect(YoutubeClient.tv.isTvLike, isTrue);
      expect(YoutubeClient.tvSimulator.isTvLike, isTrue);
      expect(YoutubeClient.web.isTvLike, isFalse);
    });
  });

  group('command line', () {
    test('no client flag by default', () {
      // The common case must stay byte-identical to before this feature.
      final a = _args();
      expect(a, isNot(contains('--extractor-args')));
    });

    test('a web-only selection still sends nothing', () {
      expect(
        _args(youtube: const YoutubePrefs(extraClients: [])),
        isNot(contains('--extractor-args')),
      );
    });

    test('extra clients produce the extractor args', () {
      final a = _args(
        youtube: const YoutubePrefs(extraClients: [YoutubeClient.ios]),
      );
      expect(
        a,
        containsAllInOrder([
          '--extractor-args',
          'youtube:player_client=web,ios',
        ]),
      );
    });

    test('several clients are comma separated', () {
      final a = _args(
        youtube: const YoutubePrefs(
          extraClients: [YoutubeClient.ios, YoutubeClient.webEmbedded],
        ),
      );
      expect(a, contains('youtube:player_client=web,ios,web_embedded'));
    });

    test('the app value is sent after a raw one, so it wins', () {
      // yt-dlp lets the last occurrence win, so a raw --extractor-args in the
      // extra-args field must come first for the picker to take effect.
      final a = _args(
        youtube: const YoutubePrefs(extraClients: [YoutubeClient.ios]),
        extraArgs: const ['--extractor-args', 'youtube:player_client=android'],
      );
      expect(
        a.lastIndexOf('youtube:player_client=web,ios'),
        greaterThan(a.indexOf('youtube:player_client=android')),
        reason: 'the last occurrence is the one yt-dlp uses',
      );
    });

    test('the URL is still last', () {
      final a = _args(
        youtube: const YoutubePrefs(extraClients: [YoutubeClient.ios]),
      );
      expect(a.last, 'https://youtu.be/abc');
    });
  });

  group('EjsInstaller helpers', () {
    test('picks the pure-Python wheel from the PyPI payload', () {
      final url = EjsInstaller.resolveWheelUrl({
        'urls': [
          {
            'filename': 'yt_dlp_ejs-1.2.0-cp313-cp313-manylinux.whl',
            'url': 'a',
          },
          {'filename': 'yt_dlp_ejs-1.2.0-py3-none-any.whl', 'url': 'good'},
        ],
      });
      expect(
        url,
        'good',
        reason:
            'a platform wheel would not match the bundled '
            'interpreter',
      );
    });

    test('returns null when there is no pure-Python wheel', () {
      expect(
        EjsInstaller.resolveWheelUrl({
          'urls': [
            {'filename': 'x-cp313-cp313-win.whl', 'url': 'a'},
          ],
        }),
        isNull,
      );
      expect(EjsInstaller.resolveWheelUrl(const {}), isNull);
      expect(EjsInstaller.resolveWheelUrl({'urls': 'nope'}), isNull);
    });

    test('tolerates a malformed entry in the list', () {
      expect(
        EjsInstaller.resolveWheelUrl({
          'urls': [
            'garbage',
            {'no_filename': 1},
            {'filename': 'yt_dlp_ejs-1-py3-none-any.whl', 'url': 'ok'},
          ],
        }),
        'ok',
      );
    });

    test('the PyPI url is well formed', () {
      expect(
        EjsInstaller.pypiJsonUrl('1.2.0'),
        'https://pypi.org/pypi/yt_dlp_ejs/1.2.0/json',
      );
    });
  });

  group('EjsInfo', () {
    test('summarises each state for the settings screen', () {
      expect(
        const EjsInfo(status: EjsStatus.missing).summary,
        'JS runtime not installed',
      );
      expect(
        const EjsInfo(status: EjsStatus.installed, version: '1.2.0').summary,
        'JS runtime 1.2.0',
      );
      expect(
        const EjsInfo(status: EjsStatus.installed).summary,
        'JS runtime installed',
      );
      expect(
        const EjsInfo(status: EjsStatus.broken).summary,
        contains('not working'),
      );
      expect(
        const EjsInfo(status: EjsStatus.unknown).summary,
        contains('unknown'),
      );
    });

    test('only a verified install counts as usable', () {
      expect(const EjsInfo(status: EjsStatus.installed).isUsable, isTrue);
      expect(const EjsInfo(status: EjsStatus.broken).isUsable, isFalse);
      expect(const EjsInfo().isUsable, isFalse);
    });
  });
}
