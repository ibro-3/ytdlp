import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ytdlp/core/models/command_template.dart';
import 'package:ytdlp/core/models/settings_model.dart';
import 'package:ytdlp/services/settings/backup_service.dart';
import 'package:ytdlp/services/settings/template_store.dart';

void main() {
  late Directory tempRoot;
  late Box<dynamic> box;
  late TemplateStore templates;
  late BackupService backup;

  setUp(() async {
    tempRoot = Directory.systemTemp.createTempSync('ytdlp-backup-');
    Hive.init(tempRoot.path);
    box = await Hive.openBox<dynamic>('backup');
    templates = TemplateStore(box);
    backup = BackupService(box: box, templates: templates);
  });

  tearDown(() async {
    await box.close();
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('export', () {
    test('captures the stored settings', () async {
      await box.put(
        BackupService.settingsKey,
        const AppSettings(extraArgs: '--embed-metadata').toMap(),
      );
      expect(backup.export().settings.extraArgs, '--embed-metadata');
    });

    test('falls back to defaults with nothing stored', () {
      // Compared as maps: AppSettings is a plain model with no value equality.
      expect(backup.export().settings.toMap(), const AppSettings().toMap());
    });

    test('includes saved templates', () async {
      await templates.save(
        const CommandTemplate(name: 'Split', args: '--concurrent-fragments 4'),
      );
      final snapshot = backup.export();
      expect(snapshot.templates, hasLength(1));
      expect(snapshot.templates.single.name, 'Split');
    });
  });

  group('round trip', () {
    test('settings and templates survive export then restore', () async {
      await box.put(
        BackupService.settingsKey,
        const AppSettings(
          extraArgs: '--embed-metadata',
          outputTemplate: '%(uploader)s/%(title)s.%(ext)s',
          maxQueueSize: 120,
        ).toMap(),
      );
      await templates.save(
        const CommandTemplate(name: 'Split', args: '--concurrent-fragments 4'),
      );
      final original = backup.export();

      // Wipe, then restore.
      await box.delete(BackupService.settingsKey);
      await templates.clear();
      expect(backup.export().settings.extraArgs, isEmpty);

      expect(await backup.restore(original), isTrue);
      final after = backup.export();
      expect(after.settings.extraArgs, '--embed-metadata');
      expect(after.settings.outputTemplate, '%(uploader)s/%(title)s.%(ext)s');
      expect(after.settings.maxQueueSize, 120);
      expect(after.templates.single.name, 'Split');
    });

    test('a restore replaces templates rather than merging', () async {
      await templates.save(const CommandTemplate(name: 'Keep', args: '--a'));
      final snapshot = backup.export();
      // A template that exists now but not in the backup must not come back.
      await templates.save(const CommandTemplate(name: 'Extra', args: '--b'));

      await backup.restore(snapshot);
      expect(templates.templates.map((t) => t.name), [
        'Keep',
      ], reason: 'a restore is a snapshot, not a merge');
    });
  });

  group('decode', () {
    test('reads a backup this build wrote', () {
      final encoded = SettingsBackup(
        version: SettingsBackup.currentVersion,
        settings: const AppSettings(extraArgs: '--a'),
        templates: const [CommandTemplate(name: 'T', args: '--b')],
      ).encode();
      final parsed = SettingsBackup.decode(encoded);
      expect(parsed, isNotNull);
      expect(parsed!.settings.extraArgs, '--a');
      expect(parsed.templates.single.args, '--b');
    });

    test('rejects malformed JSON', () {
      expect(SettingsBackup.decode('not json at all'), isNull);
      expect(SettingsBackup.decode(''), isNull);
    });

    test('rejects JSON that is not a backup', () {
      expect(SettingsBackup.decode('[1, 2, 3]'), isNull);
      expect(SettingsBackup.decode('{"hello": "world"}'), isNull);
      expect(SettingsBackup.decode('{"app": "not an object"}'), isNull);
    });

    test('refuses a backup from a newer build', () {
      // A partial restore would be worse than none.
      final future = '{"version": 99, "app": {}}';
      expect(SettingsBackup.decode(future), isNull);
    });

    test('reads an older backup best-effort', () {
      // A missing field already has a default, so an old document still loads.
      final older = '{"version": 0, "app": {"extraArgs": "--old"}}';
      final parsed = SettingsBackup.decode(older);
      expect(parsed, isNotNull);
      expect(parsed!.settings.extraArgs, '--old');
      expect(parsed.templates, isEmpty);
    });

    test('tolerates a template list of the wrong type', () {
      final odd = '{"version": 1, "app": {}, "templates": "nope"}';
      final parsed = SettingsBackup.decode(odd);
      expect(parsed, isNotNull);
      expect(parsed!.templates, isEmpty);
    });
  });

  group('restoreFrom', () {
    test('rejects a non-backup and writes nothing', () async {
      await box.put(
        BackupService.settingsKey,
        const AppSettings(extraArgs: '--keep').toMap(),
      );
      expect(await backup.restoreFrom('garbage'), isFalse);
      expect(
        backup.export().settings.extraArgs,
        '--keep',
        reason: 'a failed restore must leave the box alone',
      );
    });

    test('applies a valid document', () async {
      final encoded = SettingsBackup(
        version: SettingsBackup.currentVersion,
        settings: const AppSettings(extraArgs: '--restored'),
        templates: const [],
      ).encode();
      expect(await backup.restoreFrom(encoded), isTrue);
      expect(backup.export().settings.extraArgs, '--restored');
    });
  });
}
