import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/core/money/money.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/preferences/app_preferences.dart';
import 'package:flowtrace/data/preferences/preferences_controller.dart';

void main() {
  test(
    'exact display grouping covers int64 and currency precision without changing money',
    () {
      const settings = AppPreferences(groupThousands: true);
      for (final (minor, scale, expected) in [
        ('9007199254740993', 2, '90,071,992,547,409.93'),
        ('-9223372036854775808', 0, '-9,223,372,036,854,775,808'),
        ('1250', 3, '1.250'),
        ('0', 2, '0.00'),
      ]) {
        final money = Money('CNY', scale, BigInt.parse(minor));
        expect(settings.formatMoney(money), expected);
        expect(money.minor.toString(), minor);
      }
      final amount = Money('CNY', 2, BigInt.from(1250));
      expect(settings.copyWith(hideAmounts: true).formatMoney(amount), '••••');
      expect(
        settings.copyWith(hideAmounts: true).formatMoney(amount, reveal: true),
        '12.50',
      );
    },
  );

  test('preview and bill use identical category/note choices', () {
    var preferences = const AppPreferences();
    BillPresentation present() => BillPresentation.create(
      preferences: preferences,
      category: '晚餐',
      parentCategory: '餐饮',
      note: '和朋友一起吃饭',
    );
    expect(present().title, '晚餐');
    expect(present().subtitle, '和朋友一起吃饭');
    preferences = preferences.copyWith(showFullCategory: true);
    expect(present().title, '餐饮 / 晚餐');
    preferences = preferences.copyWith(preferNote: true);
    expect(present().title, '和朋友一起吃饭');
    expect(present().subtitle, '餐饮 / 晚餐');
  });

  test(
    'all device preferences round trip with explicit version and reject unknown values',
    () {
      final preference = const AppPreferences().copyWith(
        themeMode: ThemeMode.system,
        groupThousands: true,
        showCategoryIcons: false,
        showFullCategory: true,
        preferNote: true,
        assetsEnabled: false,
        quickEntry: true,
      );
      expect(
        AppPreferences.fromJson(
          jsonDecode(jsonEncode(preference.toJson())),
        ).toJson(),
        preference.toJson(),
      );
      expect(
        () => AppPreferences.fromJson({...preference.toJson(), 'version': 2}),
        throwsFormatException,
      );
      expect(
        () => AppPreferences.fromJson({
          ...preference.toJson(),
          'group_thousands': 'true',
        }),
        throwsFormatException,
      );
      expect(
        () =>
            AppPreferences.fromJson({...preference.toJson(), 'unknown': false}),
        throwsFormatException,
      );
    },
  );

  group('durable preferences', () {
    late AppDatabase database;
    late LocalRepository repository;
    late PreferencesController controller;
    setUp(() {
      database = AppDatabase(NativeDatabase.memory());
      repository = LocalRepository(database);
      controller = PreferencesController(repository);
    });
    tearDown(() async {
      controller.dispose();
      await database.close();
    });

    test(
      'legacy theme is retained then new configuration reopens exactly',
      () async {
        await repository.writeSetting('theme_mode', 'light');
        await controller.initialize();
        expect(controller.value.themeMode, ThemeMode.light);
        await controller.update(
          controller.value.copyWith(preferNote: true, hideAmounts: true),
        );
        final reopened = PreferencesController(repository);
        await reopened.initialize();
        expect(reopened.value.toJson(), controller.value.toJson());
        expect(await repository.readSetting('theme_mode'), 'light');
        expect(
          await database.select(database.pendingOperations).get(),
          isEmpty,
        );
        reopened.dispose();
      },
    );

    test(
      'failed legacy/new atomic write preserves both previous settings and visible state',
      () async {
        await controller.initialize();
        await controller.update(controller.value);
        final original = await repository.readSetting(
          PreferencesController.settingKey,
        );
        await database.customStatement('''
        CREATE TRIGGER reject_theme BEFORE INSERT ON app_settings
        WHEN NEW.key = 'theme_mode' AND NEW.value = 'light'
        BEGIN SELECT RAISE(ABORT, 'injected local settings failure'); END
      ''');
        await expectLater(
          controller.update(
            controller.value.copyWith(themeMode: ThemeMode.light),
          ),
          throwsA(anything),
        );
        expect(controller.value.themeMode, ThemeMode.dark);
        expect(await repository.readSetting('theme_mode'), 'dark');
        expect(
          await repository.readSetting(PreferencesController.settingKey),
          original,
        );
        expect(controller.error, contains('未能保存'));
      },
    );

    test(
      'unreadable future settings are retained and recovery explicitly keeps original',
      () async {
        const raw = '{"version":42,"future":"preserve-me"}';
        await repository.writeSetting(PreferencesController.settingKey, raw);
        await controller.initialize();
        expect(controller.needsRecovery, isTrue);
        expect(
          await repository.readSetting(PreferencesController.settingKey),
          raw,
        );
        await expectLater(
          controller.update(controller.value.copyWith(hideAmounts: true)),
          throwsStateError,
        );
        await controller.restoreDefaults();
        expect(
          await repository.readSetting(PreferencesController.recoveryKey),
          raw,
        );
        expect(controller.needsRecovery, isFalse);
        expect(
          AppPreferences.fromJson(
            jsonDecode(
              (await repository.readSetting(PreferencesController.settingKey))!,
            ),
          ).toJson(),
          const AppPreferences().toJson(),
        );
      },
    );

    test(
      'two independent controllers reject stale full JSON and preserve both choices after explicit retry',
      () async {
        final other = PreferencesController(LocalRepository(database));
        addTearDown(other.dispose);
        await controller.initialize();
        await other.initialize();
        await controller.update(
          controller.value.copyWith(themeMode: ThemeMode.light),
        );
        await expectLater(
          other.update(other.value.copyWith(groupThousands: true)),
          throwsA(isA<PreferencesChanged>()),
        );
        expect(controller.value.themeMode, ThemeMode.light);
        expect(other.value.themeMode, ThemeMode.light);
        expect(other.value.groupThousands, isFalse);
        expect(other.error, contains('其他页面'));
        await other.update(other.value.copyWith(groupThousands: true));
        await expectLater(
          controller.update(
            controller.value.copyWith(themeMode: ThemeMode.system),
          ),
          throwsA(isA<PreferencesChanged>()),
        );
        expect(controller.value.groupThousands, isTrue);
        expect(controller.value.themeMode, ThemeMode.light);
        await controller.update(
          controller.value.copyWith(themeMode: ThemeMode.system),
        );
        final reopened = PreferencesController(repository);
        addTearDown(reopened.dispose);
        await reopened.initialize();
        expect(reopened.value.themeMode, ThemeMode.system);
        expect(reopened.value.groupThousands, isTrue);
        expect(await repository.readSetting('theme_mode'), 'system');
      },
    );

    test(
      'a stale recovery cannot overwrite another controller repaired configuration or original backup',
      () async {
        const raw = '{"version":42,"future":"original-to-retain"}';
        await repository.writeSetting(PreferencesController.settingKey, raw);
        final other = PreferencesController(LocalRepository(database));
        addTearDown(other.dispose);
        await controller.initialize();
        await other.initialize();
        await controller.restoreDefaults();
        await controller.update(
          controller.value.copyWith(
            themeMode: ThemeMode.light,
            preferNote: true,
          ),
        );
        final repaired = await repository.readSetting(
          PreferencesController.settingKey,
        );
        await expectLater(
          other.restoreDefaults(),
          throwsA(isA<PreferencesChanged>()),
        );
        expect(other.needsRecovery, isFalse);
        expect(other.value.themeMode, ThemeMode.light);
        expect(other.value.preferNote, isTrue);
        expect(
          await repository.readSetting(PreferencesController.settingKey),
          repaired,
        );
        expect(
          await repository.readSetting(PreferencesController.recoveryKey),
          raw,
        );
      },
    );

    test(
      'a legacy-only writer is also detected before new preferences replace its theme',
      () async {
        await controller.initialize();
        await repository.writeSetting('theme_mode', 'light');
        await expectLater(
          controller.update(controller.value.copyWith(groupThousands: true)),
          throwsA(isA<PreferencesChanged>()),
        );
        expect(
          await repository.readSetting(PreferencesController.settingKey),
          isNull,
        );
        expect(await repository.readSetting('theme_mode'), 'light');
        expect(controller.value.themeMode, ThemeMode.light);
        await controller.update(
          controller.value.copyWith(groupThousands: true),
        );
        expect(controller.value.groupThousands, isTrue);
        expect(await repository.readSetting('theme_mode'), 'light');
      },
    );
  });
}
