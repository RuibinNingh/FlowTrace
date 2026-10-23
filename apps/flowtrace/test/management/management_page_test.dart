import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:flowtrace/core/config/data_space.dart';
import 'package:flowtrace/core/config/server_address.dart';
import 'package:flowtrace/core/money/money.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/ledger/ledger_repository.dart';
import 'package:flowtrace/features/management/management_editor.dart';
import 'package:flowtrace/features/management/management_page.dart';
import 'package:flowtrace/features/management/management_templates.dart';

class _Rig {
  final database = AppDatabase(NativeDatabase.memory());
  late final local = LocalRepository(database);
  late final ledger = LedgerRepository(local);
  final space = DataSpace(
    server: ServerAddress.parse('https://management.example.test'),
    serverInstanceId: const Uuid().v4(),
    userId: const Uuid().v4(),
  );
  final epoch = const Uuid().v4();
  Future<void>? _closing;
  Future<void> close() => _closing ??= database.close();
  Future<void> initialize() => local.registerSpace(space);
  Future<String> book({String name = '隔离管理账本'}) async {
    final id = const Uuid().v4();
    await ledger.save(
      space,
      entityType: 'book',
      scopeId: space.userId,
      entityId: id,
      payload: {
        'name': name,
        'currency': 'CNY',
        'timezone': 'Asia/Shanghai',
        'month_start_day': 1,
        'template': 'blank',
        'icon': 'book',
        'cover_color': '#2279D7',
        'show_assets': false,
        'display_mode': 'month',
      },
    );
    return id;
  }

  Future<LedgerView> read() => ledger.read(
    space,
    query: const LedgerQuery(includeArchived: true, includeDeleted: true),
  );
  Future<void> role(String bookId, String role) async {
    // A confirmed server projection with explicit membership, not inferred roles.
    await (database.delete(
      database.pendingOperations,
    )..where((t) => t.entityId.equals(bookId))).go();
    await (database.update(
      database.localEntities,
    )..where((t) => t.entityId.equals(bookId))).write(
      LocalEntitiesCompanion(
        scopeId: Value(bookId),
        serverRevision: const Value('1'),
      ),
    );
    await database
        .into(database.syncStates)
        .insertOnConflictUpdate(
          SyncStatesCompanion.insert(
            spaceId: space.id,
            clientId: const Uuid().v4(),
            epoch: epoch,
          ),
        );
    await local.writeSetting(
      'sync.scope-details.${space.id}',
      jsonEncode({
        'version': 1,
        'epoch': epoch,
        'scopes': [
          {'scope_id': bookId, 'role': role},
        ],
      }),
    );
  }
}

late _Rig _rig;

Future<void> _show(
  WidgetTester tester,
  _Rig fixture, {
  String? bookId,
  ManagementSection section = ManagementSection.books,
  ValueNotifier<int>? changes,
  bool Function()? isCurrent,
  ValueChanged<String>? onSelected,
}) async {
  tester.view.physicalSize = const Size(1000, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData.dark(),
      home: ManagementPage(
        repository: fixture.ledger,
        space: fixture.space,
        initialBookId: bookId,
        initialSection: section,
        isCurrent: isCurrent ?? () => true,
        sessionChanges: changes,
        onBookSelected: onSelected,
      ),
    ),
  );
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  await tester.pumpAndSettle();
}

Finder _field(String label) => find.widgetWithText(TextFormField, label);
Finder _filled(String label) => find
    .ancestor(
      of: find.text(label),
      matching: find.byWidgetPredicate((widget) => widget is FilledButton),
    )
    .first;
Future<void> _tap(WidgetTester tester, String label) async {
  final candidates = find.text(label);
  final visible = candidates.hitTestable();
  final target = visible.evaluate().isEmpty ? candidates.last : visible.last;
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _menu(WidgetTester tester, String tooltip, String action) async {
  final target = find.byTooltip(tooltip);
  for (var attempt = 0; attempt < 20 && target.evaluate().isEmpty; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pumpAndSettle();
  }
  expect(target, findsOneWidget, reason: 'Visible menu: $tooltip');
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
  await _tap(tester, action);
}

void _testWidget(String description, Future<void> Function(WidgetTester) body) {
  testWidgets(description, (tester) async {
    try {
      await body(tester);
    } finally {
      // Drift delays the last watch cancellation with a zero-duration timer.
      // Dispose and drain it inside fakeAsync, before Flutter verifies timers.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      await tester.runAsync(_rig.close);
    }
  });
}

void main() {
  setUp(() async {
    _rig = _Rig();
    await _rig.initialize();
  });
  tearDown(() => _rig.close());

  test(
    'all observed template kinds expand to valid isolated configuration only',
    () async {
      for (final template in BookTemplates.values) {
        final id = const Uuid().v4();
        await _rig.ledger.saveBatch(
          _rig.space,
          template.writes(
            userScope: _rig.space.userId,
            bookId: id,
            book: const {
              'name': '合成模板',
              'currency': 'CNY',
              'timezone': 'Asia/Shanghai',
              'month_start_day': 31,
              'icon': 'book',
              'cover_color': '#2279D7',
              'show_assets': false,
              'display_mode': 'month',
            },
          ),
        );
        final view = await _rig.read();
        final items = view.categories.where((e) => e.scopeId == id).toList();
        expect(items.length, template.categories.length);
        final ids = items.map((e) => e.id).toSet();
        for (final child in items.where(
          (e) => e.payload['parent_id'] != null,
        )) {
          expect(ids, contains(child.payload['parent_id']));
          expect(
            view
                .find('category', child.payload['parent_id'] as String)!
                .payload['parent_id'],
            isNull,
          );
        }
        expect(view.accounts, isEmpty);
        expect(view.bills, isEmpty);
      }
    },
  );

  _testWidget(
    'copying settings remaps category and group IDs without copying private accounts',
    (tester) async {
      final book = await _rig.book();
      final parent = const Uuid().v4(),
          child = const Uuid().v4(),
          group = const Uuid().v4(),
          tag = const Uuid().v4();
      await _rig.ledger.saveBatch(_rig.space, [
        LedgerWrite(
          entityType: 'category',
          scopeId: book,
          entityId: parent,
          payload: const {
            'name': '合成父分类',
            'kind': 'expense',
            'parent_id': null,
            'icon': 'food',
            'sort_order': 0,
            'archived': false,
          },
        ),
        LedgerWrite(
          entityType: 'tag',
          scopeId: book,
          entityId: group,
          payload: const {
            'name': '合成分组',
            'color': '#2279D7',
            'kind': 'group',
            'group_id': null,
            'sort_order': 0,
            'archived': false,
          },
        ),
        LedgerWrite(
          entityType: 'category',
          scopeId: book,
          entityId: child,
          payload: {
            'name': '合成子分类',
            'kind': 'expense',
            'parent_id': parent,
            'icon': 'food',
            'sort_order': 0,
            'archived': false,
          },
        ),
        LedgerWrite(
          entityType: 'tag',
          scopeId: book,
          entityId: tag,
          payload: {
            'name': '合成标签',
            'color': '#2279D7',
            'kind': 'tag',
            'group_id': group,
            'sort_order': 0,
            'archived': false,
          },
        ),
        LedgerWrite(
          entityType: 'account',
          scopeId: _rig.space.userId,
          payload: const {
            'name': '合成私人现金',
            'kind': 'cash',
            'opening': {
              'currency': 'CNY',
              'currency_scale': 2,
              'amount_minor': '10000',
            },
            'include_in_net_assets': true,
            'hidden': false,
          },
        ),
      ]);
      await _show(tester, _rig, bookId: book);
      await _menu(tester, '账本操作 隔离管理账本', '仅复制设置');
      await tester.enterText(_field('新账本名称'), '复制的合成账本');
      await _tap(tester, '复制');
      final view = await _rig.read();
      final copied = view.books.singleWhere((e) => e.id != book);
      expect(copied.name, '复制的合成账本');
      final copiedCategories = view.categories
          .where((e) => e.scopeId == copied.id)
          .toList();
      final copiedTags = view.tags
          .where((e) => e.scopeId == copied.id)
          .toList();
      expect(copiedCategories.length, 2);
      expect(copiedTags.length, 2);
      expect(
        copiedCategories.map((e) => e.id).toSet().intersection({parent, child}),
        isEmpty,
      );
      expect(
        copiedCategories
            .singleWhere((e) => e.payload['parent_id'] != null)
            .payload['parent_id'],
        copiedCategories.singleWhere((e) => e.payload['parent_id'] == null).id,
      );
      expect(
        copiedTags
            .singleWhere((e) => e.payload['kind'] == 'tag')
            .payload['group_id'],
        copiedTags.singleWhere((e) => e.payload['kind'] == 'group').id,
      );
      expect(view.accounts.length, 1);
      expect(view.accounts.single.payload['opening'], {
        'currency': 'CNY',
        'currency_scale': 2,
        'amount_minor': '10000',
      });
      expect(view.bills, isEmpty);
    },
  );

  _testWidget(
    'template creation is a real local configuration transaction and selection',
    (tester) async {
      final selected = <String>[];
      await _show(tester, _rig, onSelected: selected.add);
      await _tap(tester, '新建账本');
      await tester.enterText(_field('账本名称'), '日常合成账本');
      await _tap(tester, '空白账本');
      await _tap(tester, '日常生活');
      await _tap(tester, '保存');
      final view = await _rig.read();
      await tester.pumpAndSettle();
      final book = view.books.single;
      expect(book.name, '日常合成账本');
      expect(book.payload['template'], 'daily');
      expect(book.payload['display_mode'], 'month');
      expect(
        view.categories.length,
        BookTemplates.find('daily')!.categories.length,
      );
      expect(view.accounts, isEmpty);
      expect(view.bills, isEmpty);
      expect(selected, [book.id]);
      final pending = await _rig.local.pending(_rig.space);
      expect(pending.length, view.categories.length + 1);
      expect(
        pending
            .skip(1)
            .every((op) => jsonDecode(op.operationJson)['depends_on'] != null),
        isTrue,
      );
    },
  );

  _testWidget(
    'categories support bulk names, icon search, level promotion, ordering and archive recovery',
    (tester) async {
      final book = await _rig.book();
      await _show(
        tester,
        _rig,
        bookId: book,
        section: ManagementSection.categories,
      );
      await _tap(tester, '添加分类');
      await tester.enterText(_field('分类名称'), '合成餐饮');
      await _tap(tester, '选择图标');
      await tester.enterText(find.widgetWithText(TextField, '搜索图标'), '餐饮');
      await tester.pumpAndSettle();
      await _tap(tester, '餐饮');
      await _tap(tester, '保存');
      var view = await _rig.read();
      await tester.pumpAndSettle();
      final parent = view.categories.single;
      expect(parent.payload['icon'], 'food');
      await _menu(tester, '分类操作 合成餐饮', '添加二级分类');
      await tester.enterText(_field('分类名称'), '合成早餐');
      await _tap(tester, '保存');
      view = await _rig.read();
      await tester.pumpAndSettle();
      final child = view.categories.singleWhere((e) => e.name == '合成早餐');
      expect(child.payload['parent_id'], parent.id);
      await _tap(tester, '合成早餐');
      await _tap(tester, '合成餐饮');
      await _tap(tester, '一级分类');
      await _tap(tester, '保存');
      expect(
        (await _rig.read()).find('category', child.id)!.payload['parent_id'],
        isNull,
      );
      await tester.pumpAndSettle();
      await _tap(tester, '添加分类');
      await tester.tap(find.widgetWithText(SwitchListTile, '批量添加'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('分类名称'), '批量甲\n批量乙');
      await _tap(tester, '保存');
      await _rig.read();
      await tester.pumpAndSettle();
      await _menu(tester, '分类操作 批量乙', '上移');
      view = await _rig.read();
      await tester.pumpAndSettle();
      expect(
        view.categories
                .singleWhere((e) => e.name == '批量乙')
                .payload['sort_order']
            as int,
        lessThan(
          view.categories
                  .singleWhere((e) => e.name == '批量甲')
                  .payload['sort_order']
              as int,
        ),
      );
      await _menu(tester, '分类操作 合成餐饮', '归档');
      expect(
        (await _rig.read()).find('category', parent.id)!.effectiveArchived,
        isTrue,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('management-category-archive')),
          matching: find.text('已归档'),
        ),
      );
      await tester.pumpAndSettle();
      await _menu(tester, '分类操作 合成餐饮', '恢复');
      expect(
        (await _rig.read()).find('category', parent.id)!.effectiveArchived,
        isFalse,
      );
    },
  );

  _testWidget(
    'tag groups retain child flags on archive, move membership and protect referenced groups',
    (tester) async {
      final book = await _rig.book();
      await _show(tester, _rig, bookId: book, section: ManagementSection.tags);
      await _tap(tester, '添加分组');
      await tester.enterText(_field('分组名称'), '合成旅行组');
      await _tap(tester, '保存');
      await _rig.read();
      await tester.pumpAndSettle();
      await _menu(tester, '标签操作 合成旅行组', '在此分组添加标签');
      await tester.enterText(_field('标签名称'), '合成交通');
      await tester.enterText(_field('颜色'), '#ff6600');
      await _tap(tester, '保存');
      var view = await _rig.read();
      await tester.pumpAndSettle();
      final group = view.tags.singleWhere((e) => e.payload['kind'] == 'group');
      final tag = view.tags.singleWhere((e) => e.payload['kind'] == 'tag');
      expect(tag.payload['group_id'], group.id);
      expect(tag.payload['color'], '#ff6600');
      await _menu(tester, '标签操作 合成旅行组', '归档');
      view = await _rig.read();
      await tester.pumpAndSettle();
      expect(view.find('tag', tag.id)!.effectiveArchived, isTrue);
      expect(view.find('tag', tag.id)!.payload['archived'], isFalse);
      await _tap(tester, '已归档');
      await _menu(tester, '标签操作 合成旅行组', '恢复');
      expect(
        (await _rig.read()).find('tag', tag.id)!.effectiveArchived,
        isFalse,
      );
      await tester.pumpAndSettle();
      await _tap(tester, '启用');
      await _tap(tester, '合成交通');
      await _tap(tester, '合成旅行组');
      await _tap(tester, '未分组');
      await _tap(tester, '保存');
      expect(
        (await _rig.read()).find('tag', tag.id)!.payload['group_id'],
        isNull,
      );
      await tester.pumpAndSettle();
      await _menu(tester, '标签操作 合成旅行组', '删除');
      await _tap(tester, '删除');
      expect((await _rig.read()).find('tag', group.id)!.deleted, isTrue);
      expect((await _rig.read()).find('tag', tag.id)!.deleted, isFalse);
    },
  );

  _testWidget(
    'empty-book editor may add definitions but viewer cannot and book settings stay owner-only',
    (tester) async {
      final book = await _rig.book();
      await _rig.role(book, 'editor');
      await _show(
        tester,
        _rig,
        bookId: book,
        section: ManagementSection.categories,
      );
      expect(tester.widget<FilledButton>(_filled('添加分类')).onPressed, isNotNull);
      await _tap(tester, '账本');
      await tester.tap(find.byTooltip('账本操作 隔离管理账本'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PopupMenuItem<String>>(
              find.widgetWithText(PopupMenuItem<String>, '编辑账本与显示设置'),
            )
            .enabled,
        isFalse,
      );
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      await _tap(tester, '分类');
      await _rig.role(book, 'viewer');
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(_filled('添加分类')).onPressed, isNull);
      expect((await _rig.read()).categories, isEmpty);
      expect(await _rig.local.pending(_rig.space), isEmpty);
    },
  );

  _testWidget(
    'account change hides an open editor immediately and cannot save private input',
    (tester) async {
      final book = await _rig.book();
      var current = true;
      final changes = ValueNotifier(0);
      addTearDown(changes.dispose);
      await _show(
        tester,
        _rig,
        bookId: book,
        section: ManagementSection.categories,
        changes: changes,
        isCurrent: () => current,
      );
      await _tap(tester, '添加分类');
      await tester.enterText(_field('分类名称'), '尚未保存的私有名称');
      final before = (await _rig.local.pending(_rig.space)).length;
      current = false;
      changes.value++;
      await tester.pumpAndSettle();
      expect(find.text('尚未保存的私有名称'), findsNothing);
      expect(find.text('资料已切换'), findsOneWidget);
      expect(find.text('保存'), findsNothing);
      expect((await _rig.local.pending(_rig.space)).length, before);
      current = true;
      changes.value++;
      await tester.pumpAndSettle();
      expect(find.text('尚未保存的私有名称'), findsNothing);
      expect(find.text('保存'), findsNothing);
      expect((await _rig.local.pending(_rig.space)).length, before);
    },
  );

  _testWidget(
    'save failure keeps form input and a later explicit retry can succeed',
    (tester) async {
      var fail = true;
      var saved = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ManagementEditor(
                      type: 'category',
                      title: '隔离编辑',
                      initial: const {
                        'name': '',
                        'kind': 'expense',
                        'parent_id': null,
                        'icon': 'food',
                        'sort_order': 0,
                        'archived': false,
                      },
                      isCurrent: () => true,
                      onSave: (edit) async {
                        if (fail) {
                          throw const DomainError('category.invalid_parent');
                        }
                        saved++;
                      },
                    ),
                  ),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      await _tap(tester, '打开');
      await tester.enterText(_field('分类名称'), '错误后保留');
      await _tap(tester, '保存');
      expect(find.text('错误后保留'), findsOneWidget);
      expect(find.textContaining('请选择同账本'), findsOneWidget);
      expect(saved, 0);
      fail = false;
      await _tap(tester, '保存');
      expect(saved, 1);
      expect(find.text('打开'), findsOneWidget);
    },
  );
}
