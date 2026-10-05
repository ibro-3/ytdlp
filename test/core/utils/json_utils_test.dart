import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/core/utils/json_utils.dart';

void main() {
  group('jsonList', () {
    test('returns the typed elements of a list', () {
      expect(
        jsonList<Map<String, dynamic>>([
          {'a': 1},
        ]),
        [
          {'a': 1},
        ],
      );
    });

    test('degrades to an empty list for anything that is not a list', () {
      expect(jsonList(null), isEmpty);
      expect(jsonList('[]'), isEmpty);
      expect(jsonList(42), isEmpty);
      expect(jsonList({'a': 1}), isEmpty);
    });

    test('drops elements of the wrong type rather than failing the whole', () {
      // yt-dlp emits a `formats` list; one entry that is a string must not
      // throw away the other (valid) entries the download needs.
      expect(
        jsonList<Map<String, dynamic>>([
          {'format_id': 'best'},
          'not a format',
          42,
        ]),
        [
          {'format_id': 'best'},
        ],
      );
    });
  });

  group('jsonMap', () {
    test('returns the map when given one', () {
      expect(jsonMap({'a': 1}), {'a': 1});
    });

    test('degrades to an empty map for anything else', () {
      expect(jsonMap(null), isEmpty);
      expect(jsonMap('x'), isEmpty);
      expect(jsonMap([1]), isEmpty);
    });
  });

  group('jsonNum', () {
    test('passes a number through', () {
      expect(jsonNum(3.5), 3.5);
      expect(jsonNum(7), 7);
    });

    test('rejects a non-number, including a string that looks like one', () {
      // The payload is user-controlled; a field documented as integer can hold
      // a string, and treating it as a number would parse the format list wrong.
      expect(jsonNum('3.5'), isNull);
      expect(jsonNum(null), isNull);
    });
  });

  group('jsonString', () {
    test('passes a non-empty string through', () {
      expect(jsonString('best'), 'best');
    });

    test('rejects empty strings and non-strings', () {
      expect(jsonString(''), isNull);
      expect(jsonString(null), isNull);
      expect(jsonString(1), isNull);
    });
  });
}
