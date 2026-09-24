import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/services/ytdlp/json_payload.dart';

void main() {
  group('decodeYtdlpPayload', () {
    test('decodes clean JSON', () {
      final out = decodeYtdlpPayload('{"_type": "video", "id": "abc"}');
      expect(out, {'_type': 'video', 'id': 'abc'});
    });

    test('rescues JSON that follows a short non-JSON preamble', () {
      const raw =
          'Runtime Python 3.14.1 [stable]\n'
          '{"_type": "video", "id": "abc"}';
      final out = decodeYtdlpPayload(raw);
      expect(out, {'_type': 'video', 'id': 'abc'});
    });

    test('returns null only when the payload is unreadable', () {
      expect(decodeYtdlpPayload(''), isNull);
      expect(decodeYtdlpPayload('garbage'), isNull);
      expect(decodeYtdlpPayload('{"broken": '), isNull);
    });

    test('does not rescue a long preamble', () {
      final out = decodeYtdlpPayload('${'noise ' * 3000}{"_type": "video"}');
      expect(out, isNull);
    });
  });

  group('jsonFailureMessage', () {
    test('explains an empty response', () {
      final msg = jsonFailureMessage('');
      expect(msg, contains('no data'));
    });

    test('shows what the response actually began with', () {
      final msg = jsonFailureMessage('Preamble line\n{"id":');
      expect(msg, contains('It began with: Preamble line {"id":'));
    });

    test('keeps the preview bounded', () {
      final msg = jsonFailureMessage('x' * 5000);
      expect(msg.length, lessThan(300));
    });
  });
}
