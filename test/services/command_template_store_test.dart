import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ytdlp/core/models/command_template.dart';
import 'package:ytdlp/services/settings/template_store.dart';

void main() {
  late Directory tempRoot;
  late Box<dynamic> box;
  late TemplateStore store;

  setUp(() async {
    tempRoot = Directory.systemTemp.createTempSync('ytdlp-templates-');
    Hive.init(tempRoot.path);
    box = await Hive.openBox<dynamic>('templates-test');
    store = TemplateStore(box);
  });

  tearDown(() async {
    await box.close();
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('save and read', () {
    test('round-trips a template', () async {
      expect(
        await store.save(
          const CommandTemplate(
            name: 'Sponsorblock',
            args: '--sponsorblock-remove default',
          ),
        ),
        isTrue,
      );

      final found = store.byName('Sponsorblock');
      expect(found, isNotNull);
      expect(found!.args, '--sponsorblock-remove default');
      expect(store.templates, hasLength(1));
    });

    test('a second template with the same name replaces the first', () async {
      await store.save(
        const CommandTemplate(name: 'Audio', args: '--extract-audio'),
      );
      await store.save(
        const CommandTemplate(
          name: 'Audio',
          args: '--extract-audio --embed-metadata',
        ),
      );

      expect(store.templates, hasLength(1));
      expect(store.byName('Audio')!.args, '--extract-audio --embed-metadata');
    });

    test('names differing only in case or spacing collide', () async {
      await store.save(const CommandTemplate(name: 'My Set', args: '--a'));
      await store.save(const CommandTemplate(name: 'my  set', args: '--b'));

      expect(store.templates, hasLength(1));
      expect(store.byName('MY SET')!.args, '--b');
    });

    test('a blank name is refused', () async {
      expect(
        await store.save(const CommandTemplate(name: '   ', args: '--a')),
        isFalse,
      );
      expect(store.templates, isEmpty);
    });

    test('the store is capped', () async {
      for (var i = 0; i < TemplateStore.maxTemplates; i++) {
        expect(
          await store.save(CommandTemplate(name: 'T$i', args: '--a')),
          isTrue,
        );
      }
      expect(
        await store.save(
          const CommandTemplate(name: 'One too many', args: '--a'),
        ),
        isFalse,
        reason: 'a full store refuses rather than growing without bound',
      );
      // Updating an existing one is still allowed at the cap.
      expect(
        await store.save(const CommandTemplate(name: 'T0', args: '--b')),
        isTrue,
      );
    });
  });

  group('ordering', () {
    test(
      'templates are listed alphabetically regardless of insert order',
      () async {
        await store.save(const CommandTemplate(name: 'zebra', args: '--z'));
        await store.save(const CommandTemplate(name: 'Alpha', args: '--a'));
        await store.save(const CommandTemplate(name: 'middle', args: '--m'));

        expect(store.templates.map((t) => t.name), [
          'Alpha',
          'middle',
          'zebra',
        ]);
      },
    );
  });

  group('remove and clear', () {
    test('removes one template', () async {
      await store.save(const CommandTemplate(name: 'A', args: '--a'));
      await store.save(const CommandTemplate(name: 'B', args: '--b'));

      expect(await store.remove('A'), isTrue);
      expect(store.templates.map((t) => t.name), ['B']);
    });

    test('removing a missing template reports false', () async {
      expect(await store.remove('nope'), isFalse);
    });

    test('clear removes every template but keeps other keys', () async {
      await box.put('unrelated', 'keep me');
      await store.save(const CommandTemplate(name: 'A', args: '--a'));
      await store.save(const CommandTemplate(name: 'B', args: '--b'));

      await store.clear();
      expect(store.templates, isEmpty);
      expect(box.get('unrelated'), 'keep me');
    });

    test('clear on an empty store is a no-op', () async {
      await store.clear();
      expect(store.templates, isEmpty);
    });
  });

  group('robustness', () {
    test('a corrupt record is skipped, not fatal', () async {
      await store.save(const CommandTemplate(name: 'Good', args: '--a'));
      // Written as a plain string, so it cannot be read as a template map.
      await box.put('tpl:bad', 'not a map');
      await box.put('tpl:alsonotamap', 42);

      expect(store.templates.map((t) => t.name), ['Good']);
    });

    test('byName returns null for a corrupt record', () async {
      await box.put('tpl:bad', 'not a map');
      expect(store.byName('bad'), isNull);
    });

    test('notifies listeners on save and remove', () async {
      var notifications = 0;
      store.addListener(() => notifications++);

      await store.save(const CommandTemplate(name: 'A', args: '--a'));
      expect(notifications, 1);

      await store.remove('A');
      expect(notifications, 2);

      // A no-op removal must not notify.
      await store.remove('A');
      expect(notifications, 2);
    });
  });

  group('CommandTemplate', () {
    test('round-trips through a map', () {
      const t = CommandTemplate(name: 'A', args: '--a --b');
      final back = CommandTemplate.fromMap(t.toMap());
      expect(back, t);
    });

    test('tolerates a map with missing fields', () {
      final t = CommandTemplate.fromMap(const {});
      expect(t.name, isEmpty);
      expect(t.args, isEmpty);
      expect(t.isNamed, isFalse);
    });

    test('equality is by name and args', () {
      expect(
        const CommandTemplate(name: 'A', args: '--a'),
        const CommandTemplate(name: 'A', args: '--a'),
      );
      expect(
        const CommandTemplate(name: 'A', args: '--a'),
        isNot(const CommandTemplate(name: 'A', args: '--b')),
      );
    });
  });
}
