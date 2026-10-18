import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/services/ytdlp/arg_tokenizer.dart';

void main() {
  group('tokenizeArgs', () {
    test('splits on runs of whitespace', () {
      expect(tokenizeArgs('--a --b'), ['--a', '--b']);
      expect(tokenizeArgs('  --a \t\n --b  '), ['--a', '--b']);
      expect(tokenizeArgs(''), isEmpty);
      expect(tokenizeArgs('   '), isEmpty);
    });

    test('single quotes are literal, backslashes included', () {
      expect(tokenizeArgs(r"--match-title 'a\b'"), ['--match-title', r'a\b']);
      // A path with spaces is the common reason to quote at all.
      expect(tokenizeArgs("'/tmp/my videos/f.mp4'"), ['/tmp/my videos/f.mp4']);
    });

    test('double quotes honour backslash escapes', () {
      expect(tokenizeArgs(r'"a\"b"'), ['a"b']);
      expect(tokenizeArgs(r'"a\\b"'), [r'a\b']);
    });

    test('a backslash outside quotes escapes the next character', () {
      expect(tokenizeArgs(r'a\ b'), ['a b']);
    });

    test('an explicitly empty quoted argument is preserved', () {
      expect(tokenizeArgs("--a '' --b"), ['--a', '', '--b']);
    });

    test('quotes may be glued to unquoted text', () {
      expect(tokenizeArgs(r"--path=/tmp/a'b'c"), [r"--path=/tmp/abc"]);
      expect(tokenizeArgs('"a""b"'), ['ab']);
    });

    test('an unterminated quote is an error, not a silently closed string', () {
      expect(
        () => tokenizeArgs("--a 'unterminated"),
        throwsA(isA<ArgSyntaxException>()),
      );
      expect(
        () => tokenizeArgs('--a "unterminated'),
        throwsA(isA<ArgSyntaxException>()),
      );
    });

    test('a trailing backslash is an error', () {
      expect(() => tokenizeArgs(r'a\'), throwsA(isA<ArgSyntaxException>()));
    });

    test('shell metacharacters stay inside their token and are never run', () {
      // There is no shell anywhere in the pipeline, so these are inert data.
      final tokens = tokenizeArgs('--x "a; rm -rf /" && echo pwned');
      expect(tokens, ['--x', 'a; rm -rf /', '&&', 'echo', 'pwned']);
    });
  });

  group('hasFlag', () {
    test('matches long, short and attached-value spellings', () {
      expect(hasFlag(['--output', 'x'], 'output', shortFlag: 'o'), isTrue);
      expect(hasFlag(['--output=x'], 'output', shortFlag: 'o'), isTrue);
      expect(hasFlag(['-o', 'x'], 'output', shortFlag: 'o'), isTrue);
      expect(hasFlag(['-ox'], 'output', shortFlag: 'o'), isTrue);
      expect(hasFlag(['--x', 'y'], 'output', shortFlag: 'o'), isFalse);
    });

    test('does not confuse a longer flag with a prefix', () {
      expect(hasFlag(['--output-template', 'x'], 'output'), isFalse);
    });
  });

  group('findManagedFlags', () {
    test('finds the flags the app sets itself', () {
      expect(findManagedFlags(['--output', '/tmp/x']), [ManagedFlag.output]);
      expect(findManagedFlags(['-f', 'b']), [ManagedFlag.format]);
      expect(findManagedFlags(['--no-playlist']), [ManagedFlag.playlist]);
      expect(findManagedFlags(['--yes-playlist']), [ManagedFlag.playlist]);
      expect(findManagedFlags(['--ffmpeg-location', '/x']), [
        ManagedFlag.ffmpegLocation,
      ]);
    });

    test('leaves ordinary flags alone', () {
      expect(
        findManagedFlags([
          '--concurrent-fragments',
          '4',
          '--limit-rate',
          '2M',
          '--embed-metadata',
        ]),
        isEmpty,
      );
    });
  });

  group('validateExtraArgs', () {
    test('an empty or benign field produces no issues', () {
      expect(validateExtraArgs(''), isEmpty);
      expect(validateExtraArgs('   '), isEmpty);
      expect(
        validateExtraArgs('--concurrent-fragments 4 --sponsorblock-remove'),
        isEmpty,
      );
    });

    test('a syntax error blocks and explains itself', () {
      final issues = validateExtraArgs("--a 'oops");
      expect(issues, hasLength(1));
      expect(issues.single.isBlocking, isTrue);
      expect(issues.single.message, contains('never closed'));
    });

    test('a managed duplicate warns and explains what wins', () {
      final issues = validateExtraArgs('--output /somewhere/else');
      expect(issues, hasLength(1));
      expect(
        issues.single.isBlocking,
        isFalse,
        reason: 'the download still works, the app value just wins',
      );
      expect(issues.single.message, contains('--output'));
      expect(issues.single.message, contains('ignored'));
    });

    test('--exec blocks, whatever spelling it uses', () {
      // The policy this pins: the extra-args field goes straight into the
      // download's argv, and yt-dlp would run whatever --exec names the
      // moment a download lands. That is beyond what a download-flags field
      // is for, so the field cannot be saved with it.
      final issues = validateExtraArgs('--exec "curl evil"');
      expect(issues.single.message, contains('runs another command'));
      expect(issues.single.isBlocking, isTrue);
      expect(validateExtraArgs('-e "curl evil"').single.isBlocking, isTrue);
    });

    test('--config-location only warns', () {
      // Loading flags from a file stays a warning — deciding to trust such a
      // file is a user policy, unlike the command execution of --exec.
      final issues = validateExtraArgs('--config-location /x/yt.conf');
      expect(issues.single.isBlocking, isFalse);
    });

    test('a second cookie source warns without claiming a false override', () {
      final issues = validateExtraArgs('--cookies /tmp/jar.txt');
      final issue = issues.singleWhere((i) => i.message.contains('cookie'));
      expect(
        issue.isBlocking,
        isFalse,
        reason: 'it only matters when the app also has a cookie source',
      );
      expect(
        issue.message,
        isNot(contains('is ignored')),
        reason:
            'the override claim is true only with a cookie source configured',
      );
    });

    test('--netrc is covered by the cookie-source warning', () {
      expect(
        validateExtraArgs('--netrc'),
        anyElement((ArgIssue i) => i.message.contains('netrc')),
      );
    });

    test(
      '-P/--paths is reported as a managed duplicate of where files land',
      () {
        for (final input in ['-P /somewhere/else', '--paths /somewhere/else']) {
          final issues = validateExtraArgs(input);
          expect(
            issues.where((i) => i.message.contains('--paths')),
            hasLength(1),
            reason:
                'the app always passes -o with an absolute path, so -P '
                'cannot move anything',
          );
        }
      },
    );

    test('reports every managed flag present', () {
      final issues = validateExtraArgs('-o /x -f best --yes-playlist');
      expect(issues, hasLength(3));
      expect(issues.every((i) => !i.isBlocking), isTrue);
    });
  });
}
