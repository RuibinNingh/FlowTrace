import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../core/config/data_space.dart';
import '../../core/money/currency_catalog.dart';
import '../../core/money/money.dart';
import '../../data/ledger/ledger_models.dart';
import '../../data/ledger/ledger_query.dart';
import '../../data/ledger/ledger_reporting.dart';
import '../../data/preferences/app_preferences.dart';
import '../../data/sync/sync_engine.dart';
import '../../domain/ledger/calendar_rules.dart';
import '../../domain/ledger/timezone_rules.dart';
import '../assets/assets_page.dart';
import '../drafts/drafts_page.dart';
import '../entry/entry_icons.dart';
import '../entry/entry_page.dart';
import '../transactions/bill_detail_page.dart';
import '../search/search_page.dart';
import '../management/management_page.dart';
import '../statistics/statistics_page.dart';
import 'home_report_summary.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    required this.app,
    required this.space,
    this.clock,
    super.key,
  });
  final AppController app;
  final DataSpace space;
  final DateTime Function()? clock;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final Stream<LedgerView> _stream;
  String? _bookId;
  DateTime _month = DateTime.now();
  String? _periodBook;
  bool _explicitDateSelection = false;
  bool _syncing = false;
  bool _desktopLayout = false;
  late final bool _quickEntryRequested;
  bool _quickEntryConsumed = false, _quickEntryQueued = false;
  bool _selectionReady = false, _selectionChanged = false;
  LedgerView? _quickEntryView;
  final _transactionsScroll = ScrollController();
  final _summaryScroll = ScrollController();
  AppPreferences get _preferences => widget.app.preferences.value;
  bool get _current =>
      widget.app.space?.id == widget.space.id && !widget.app.switchingSpace;

  @override
  void initState() {
    super.initState();
    _quickEntryRequested = _preferences.quickEntry;
    widget.app.protection.addListener(_protectionChanged);
    _stream = widget.app.ledger.watch(widget.space);
    _loadSelection();
  }

  @override
  void dispose() {
    widget.app.protection.removeListener(_protectionChanged);
    _transactionsScroll.dispose();
    _summaryScroll.dispose();
    super.dispose();
  }

  void _dismissNavigation() {
    if (!_desktopLayout) Navigator.pop(context);
  }

  Future<void> _search({String? day}) => Navigator.push<void>(
    context,
    MaterialPageRoute<void>(
      builder: (_) => SearchPage(
        app: widget.app,
        space: widget.space,
        initialBookId: _bookId,
        initialFilter: day == null
            ? null
            : BillFilter(
                bookIds: {_bookId!},
                fromDate: day,
                endDateExclusive: day == '9999-12-31'
                    ? null
                    : isoBusinessDate(
                        businessDate(day).add(const Duration(days: 1)),
                      ),
              ),
      ),
    ),
  );

  Future<void> _loadSelection() async {
    try {
      final selected = await widget.app.repository.readSetting(
        'ledger.selected-book.${widget.space.id}',
      );
      if (mounted && _current) {
        setState(() {
          if (!_selectionChanged) _bookId = selected;
          _selectionReady = true;
        });
      }
    } catch (_) {
      // A failed selection read must not navigate into a guessed book.
      _quickEntryConsumed = true;
    }
  }

  void _protectionChanged() {
    final view = _quickEntryView;
    if (mounted && view != null) _scheduleQuickEntry(view);
  }

  void _scheduleQuickEntry(LedgerView view) {
    if (!_quickEntryRequested ||
        _quickEntryConsumed ||
        _quickEntryQueued ||
        !_selectionReady ||
        !_current ||
        !mounted) {
      return;
    }
    final protection = widget.app.protection;
    if (!protection.ready ||
        protection.locked ||
        protection.busy ||
        widget.app.preparingUpdate ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final selected = _bookId;
    if (selected == null ||
        !view.canCreate('bill', selected) ||
        view.find('book', selected)?.effectiveArchived != false) {
      return;
    }
    _quickEntryQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _quickEntryQueued = false;
      if (!mounted ||
          !_current ||
          _quickEntryConsumed ||
          _bookId != selected ||
          widget.app.preparingUpdate ||
          !protection.ready ||
          protection.locked ||
          protection.busy ||
          ModalRoute.of(context)?.isCurrent != true ||
          _quickEntryView?.find('book', selected)?.effectiveArchived != false ||
          _quickEntryView?.canCreate('bill', selected) != true) {
        return;
      }
      _entry();
    });
  }

  Future<void> _select(String id) async {
    if (!_current) return;
    setState(() {
      _selectionChanged = true;
      _selectionReady = true;
      _bookId = id;
      _explicitDateSelection = false;
    });
    await widget.app.repository.writeSetting(
      'ledger.selected-book.${widget.space.id}',
      id,
    );
  }

  Future<void> _manage() async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ManagementPage(
          repository: widget.app.ledger,
          space: widget.space,
          initialBookId: _bookId,
          isCurrent: () => _current,
          sessionChanges: widget.app,
          onBookSelected: _select,
        ),
      ),
    );
  }

  Future<void> _report({int tab = 0}) async {
    if (_bookId == null || !_current) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => StatisticsPage(
          app: widget.app,
          space: widget.space,
          bookId: _bookId!,
          initialDate: isoBusinessDate(_month),
          initialTab: tab,
        ),
      ),
    );
  }

  Future<void> _sync() async {
    if (_syncing || !widget.app.canSync) return;
    setState(() => _syncing = true);
    try {
      final report = await widget.app.syncEngine.synchronize(
        SyncLease.capture(widget.app.identity!),
      );
      if (mounted && _current) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '已同步${report.applied}项，剩余${report.pending}项，冲突${report.conflicts}项。',
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted && _current) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('同步未完成，本机记录已保留。可在同步页面查看原因。')),
        );
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _entry({LedgerEntity? existing, LedgerDraft? draft}) async {
    final id = draft?.bookId ?? _bookId;
    if (id == null || !_current) return;
    _quickEntryConsumed = true;
    await Navigator.push(
      context,
      MaterialPageRoute<bool>(
        builder: (_) => EntryPage(
          app: widget.app,
          space: widget.space,
          bookId: id,
          existing: existing,
          draft: draft,
        ),
      ),
    );
  }

  Future<void> _drafts() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => AnimatedBuilder(
        animation: widget.app,
        builder: (context, _) {
          if (!_current) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Text('资料空间已切换。'),
            );
          }
          return SizedBox(
            height: MediaQuery.sizeOf(context).height * .7,
            child: StreamBuilder<List<LedgerDraft>>(
              stream: widget.app.ledger.watchDrafts(widget.space),
              builder: (context, snapshot) => Column(
                children: [
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text(
                      '记账草稿',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      children: [
                        if (snapshot.data?.isEmpty == true)
                          const ListTile(title: Text('暂无记账草稿')),
                        for (final draft in snapshot.data ?? <LedgerDraft>[])
                          ListTile(
                            title: Text(
                              draft.payload['note'] as String? ?? '未完成的记账',
                            ),
                            subtitle: Text(
                              '${draft.payload['business_date'] ?? ''} · ${_preferences.hideAmounts ? '金额已隐藏' : draft.ui['expression'] ?? ''}',
                            ),
                            onTap: () async {
                              Navigator.pop(sheetContext);
                              await _entry(draft: draft);
                            },
                            trailing: IconButton(
                              tooltip: '删除草稿',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () async {
                                final yes = await showDialog<bool>(
                                  context: context,
                                  builder: (c) => AlertDialog(
                                    title: const Text('删除完整记账草稿？'),
                                    content: const Text('已选择的图片原件仍保存在本机。'),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(c, false),
                                        child: const Text('取消'),
                                      ),
                                      TextButton(
                                        onPressed: () => Navigator.pop(c, true),
                                        child: const Text('删除'),
                                      ),
                                    ],
                                  ),
                                );
                                if (yes == true && _current) {
                                  await widget.app.ledger.deleteDraft(
                                    widget.space,
                                    draft.id,
                                  );
                                }
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _detail(LedgerEntity entity) => Navigator.push<void>(
    context,
    MaterialPageRoute<void>(
      builder: (_) => BillDetailPage(
        app: widget.app,
        space: widget.space,
        entityId: entity.id,
      ),
    ),
  );

  Widget _drawer(LedgerView view) => Drawer(
    child: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Text(
              '流迹 FlowTrace',
              style: TextStyle(fontSize: 23, fontWeight: FontWeight.w600),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: Text(widget.app.identity?.account?.username ?? '账号'),
            subtitle: Text(
              widget.app.identity?.online == true
                  ? '在线 · 独立资料空间'
                  : '离线 · 会话待验证',
            ),
            onTap: () {
              _dismissNavigation();
              Navigator.pushNamed(context, '/account');
            },
          ),
          const Divider(),
          for (final book in view.books)
            ListTile(
              leading: Icon(EntryIcons.of(book.payload['icon'])),
              selected: book.id == _bookId,
              title: Text(book.name),
              onTap: () {
                _dismissNavigation();
                _select(book.id);
              },
            ),
          ListTile(
            leading: const Icon(Icons.library_books_outlined),
            title: const Text('管理账本、分类与标签'),
            onTap: () {
              _dismissNavigation();
              _manage();
            },
          ),
          if (_preferences.assetsEnabled &&
              view.find('book', _bookId ?? '')?.payload['show_assets'] == true)
            ListTile(
              leading: const Icon(Icons.account_balance_wallet_outlined),
              title: const Text('资金账户'),
              onTap: () {
                _dismissNavigation();
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        AssetsPage(app: widget.app, space: widget.space),
                  ),
                );
              },
            ),
          ListTile(
            leading: const Icon(Icons.edit_note_outlined),
            title: const Text('记账草稿'),
            onTap: () {
              _dismissNavigation();
              _drafts();
            },
          ),
          if (_bookId != null) ...[
            for (final item in [
              (0, Icons.bar_chart, '统计'),
              (1, Icons.calendar_month_outlined, '收支日历'),
              (2, Icons.savings_outlined, '预算'),
            ])
              ListTile(
                leading: Icon(item.$2),
                title: Text(item.$3),
                onTap: () {
                  _dismissNavigation();
                  _report(tab: item.$1);
                },
              ),
          ],
          ListTile(
            leading: const Icon(Icons.notes_outlined),
            title: const Text('随手备注草稿'),
            onTap: () {
              _dismissNavigation();
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => DraftsPage(controller: widget.app),
                ),
              );
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.sync_outlined),
            title: Text('同步与恢复 · ${view.pendingCount}项待处理'),
            onTap: () {
              _dismissNavigation();
              Navigator.pushNamed(context, '/sync');
            },
          ),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('设置'),
            onTap: () {
              _dismissNavigation();
              Navigator.pushNamed(context, '/settings');
            },
          ),
        ],
      ),
    ),
  );

  Widget _body(LedgerView view) {
    final book = _bookId == null
        ? view.books.firstOrNull
        : view.find('book', _bookId!);
    if (book == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.auto_stories_outlined,
                size: 72,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 24),
              Text(
                view.books.isEmpty ? '从一本账本开始' : '请选择可访问的账本',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              const Text('先创建账本和分类，再记录第一笔收支。', textAlign: TextAlign.center),
              const SizedBox(height: 24),
              FilledButton.icon(
                key: const Key('home-create-book'),
                onPressed: _manage,
                icon: const Icon(Icons.add),
                label: const Text('创建或选择账本'),
              ),
            ],
          ),
        ),
      );
    }
    _bookId = book.id;
    _scheduleQuickEntry(view);
    final payload = book.payload;
    final mode = payload['display_mode'] as String? ?? 'month';
    final monthStart = payload['month_start_day'] as int? ?? 1;
    final (start, end) = periodBounds(isoBusinessDate(_month), monthStart);
    final bills =
        view.bills.where((b) {
          final p = b.payload;
          final day = p['business_date'] as String;
          return p['book_id'] == book.id &&
              (mode == 'all' ||
                  mode == 'year' && day.startsWith('${_month.year}-') ||
                  mode == 'month' &&
                      day.compareTo(start) >= 0 &&
                      day.compareTo(end) < 0);
        }).toList()..sort((a, b) {
          final d = (b.payload['business_date'] as String).compareTo(
            a.payload['business_date'] as String,
          );
          return d != 0 ? d : b.id.compareTo(a.id);
        });
    final currency = payload['currency'] as String;
    final allDays =
        bills.map((b) => b.payload['business_date'] as String).toList()..sort();
    final reportStart = mode == 'all'
        ? (allDays.firstOrNull ?? start)
        : mode == 'year'
        ? '${_month.year}-01-01'
        : start;
    final reportEnd = mode == 'all' && allDays.isNotEmpty
        ? (allDays.last == '9999-12-31'
              ? null
              : isoBusinessDate(
                  businessDate(allDays.last).add(const Duration(days: 1)),
                ))
        : mode == 'year'
        ? '${_month.year + 1}-01-01'
        : end;
    final reportQuery = reportEnd == null
        ? null
        : ReportQuery(
            bookId: book.id,
            reportCurrency: currency,
            reportScale: currencyScales[currency]!,
            startDate: reportStart,
            endDateExclusive: reportEnd,
          );
    final groups = <String, List<LedgerEntity>>{};
    for (final bill in bills) {
      groups
          .putIfAbsent(bill.payload['business_date'] as String, () => [])
          .add(bill);
    }
    final colorText = payload['cover_color'] as String? ?? '#2279D7';
    final cover = Color(int.parse('FF${colorText.substring(1)}', radix: 16));
    final summary = HomeReportSummary(
      key: ValueKey('${book.id}:$currency:$reportStart:$reportEnd'),
      app: widget.app,
      space: widget.space,
      query: reportQuery,
      bookName: book.name,
      mode: mode,
      cover: cover,
      onOpen: _report,
      onOpenTab: (tab) => _report(tab: tab),
    );
    final transactions = ListView(
      key: const Key('home-transactions-list'),
      controller: _transactionsScroll,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 110),
      children: [
        if (!_desktopLayout) ...[summary, const SizedBox(height: 12)],
        Card(
          child: ListTile(
            leading: Icon(
              _syncing ? Icons.hourglass_empty : Icons.cloud_outlined,
            ),
            title: Text(
              view.syncStatus == 'active'
                  ? '${view.pendingCount}项待同步 · ${bills.length}笔记录'
                  : '资料需要同步或恢复',
            ),
            subtitle: Text(
              widget.app.identity?.online == true
                  ? '下拉同步，记录优先保存在本机'
                  : '离线可继续记账，联网后同步',
            ),
            trailing: TextButton(
              onPressed: () => Navigator.pushNamed(context, '/sync'),
              child: const Text('查看'),
            ),
          ),
        ),
        const SizedBox(height: 18),
        if (bills.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 50),
            child: Column(
              children: [
                Icon(
                  Icons.receipt_long_outlined,
                  size: 54,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 16),
                const Text('这个时间范围还没有账单'),
                const SizedBox(height: 8),
                const Text(
                  '点击下方 +，记下第一笔。',
                  style: TextStyle(color: Colors.grey),
                ),
              ],
            ),
          ),
        for (final group in groups.entries) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                      children: [
                        Text(
                          group.key,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const Spacer(),
                        Text(
                          '${group.value.length}笔',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  for (final bill in group.value) _billRow(view, bill),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
    if (_desktopLayout &&
        (_preferences.showHomeSummary ||
            _preferences.showHomeBudget ||
            _preferences.showHomeTrend)) {
      final width = ((MediaQuery.sizeOf(context).width - 280) * .38).clamp(
        320.0,
        400.0,
      );
      return Row(
        key: const Key('home-desktop-panes'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: RefreshIndicator(onRefresh: _sync, child: transactions),
          ),
          SizedBox(
            width: width,
            child: Scrollbar(
              controller: _summaryScroll,
              child: SingleChildScrollView(
                controller: _summaryScroll,
                padding: const EdgeInsets.fromLTRB(0, 0, 16, 100),
                child: summary,
              ),
            ),
          ),
        ],
      );
    }
    return RefreshIndicator(onRefresh: _sync, child: transactions);
  }

  Widget _billRow(LedgerView view, LedgerEntity bill) {
    final p = bill.payload;
    final money = Money.fromJson(p['money']);
    final type = p['bill_type'];
    final category = p['category_id'] == null
        ? null
        : view.find('category', p['category_id'] as String);
    final title =
        category?.name ??
        switch (type) {
          'income' => '收入',
          'expense' => '未分类支出',
          'transfer' => '转账',
          'refund' => '退款',
          'reimbursement' => '报销',
          _ => '账务记录',
        };
    final note = p['note'] as String? ?? '';
    final parentId = category?.payload['parent_id'];
    final presentation = BillPresentation.create(
      preferences: _preferences,
      category: title,
      note: note,
      parentCategory: parentId is String
          ? view.find('category', parentId)?.name
          : null,
    );
    final stackedAmount =
        MediaQuery.sizeOf(context).width < 600 ||
        MediaQuery.textScalerOf(context).scale(14) > 20;
    final amount = Text(
      '${_preferences.hideAmounts
          ? ''
          : type == 'expense'
          ? '-'
          : type == 'income'
          ? '+'
          : ''}${_preferences.formatMoney(money)} ${money.currency}',
      style: TextStyle(
        color: type == 'expense'
            ? _preferences.expenseColor
            : type == 'income'
            ? _preferences.incomeColor
            : null,
        fontWeight: FontWeight.w500,
      ),
    );
    final status = bill.conflicted || bill.pending
        ? Text(
            bill.conflicted ? '有冲突' : '待同步',
            style: Theme.of(context).textTheme.labelSmall,
          )
        : null;
    return GestureDetector(
      onSecondaryTapDown: (details) => _billMenu(bill, details.globalPosition),
      child: ListTile(
        key: ValueKey('bill-${bill.id}'),
        contentPadding: EdgeInsets.zero,
        leading: !_preferences.showCategoryIcons
            ? null
            : Icon(
                type == 'transfer'
                    ? Icons.swap_horiz_rounded
                    : EntryIcons.of(category?.payload['icon']),
              ),
        title: Text(presentation.title),
        subtitle: stackedAmount
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (presentation.subtitle != null)
                    Text(presentation.subtitle!),
                  amount,
                  ?status,
                ],
              )
            : presentation.subtitle == null
            ? null
            : Text(
                presentation.subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
        trailing: stackedAmount
            ? null
            : Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [amount, ?status],
              ),
        onTap: () => _detail(bill),
      ),
    );
  }

  Future<void> _billMenu(LedgerEntity bill, Offset position) async {
    final box = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 1, 1),
        Offset.zero & box.size,
      ),
      items: const [
        PopupMenuItem(value: 'detail', child: Text('打开账单详情')),
        PopupMenuItem(value: 'day', child: Text('查看当天流水')),
      ],
    );
    if (!mounted || !_current) return;
    if (action == 'detail') await _detail(bill);
    if (action == 'day') {
      await _search(day: bill.payload['business_date'] as String);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.app,
    builder: (context, _) {
      if (!_current) {
        return const Scaffold(body: Center(child: Text('正在切换资料空间…')));
      }
      return StreamBuilder<LedgerView>(
        stream: _stream,
        builder: (context, snapshot) {
          final view = snapshot.data;
          _quickEntryView = view;
          final selectedBook = _bookId == null
              ? view?.books.firstOrNull
              : view?.find('book', _bookId!);
          if (selectedBook != null &&
              (!_explicitDateSelection || _periodBook != selectedBook.id)) {
            _month = businessDate(
              instantBusinessDate(
                (widget.clock?.call() ?? DateTime.now())
                    .toUtc()
                    .toIso8601String(),
                selectedBook.payload['timezone'] as String,
              ),
            );
            _periodBook = selectedBook.id;
          }
          _desktopLayout = MediaQuery.sizeOf(context).width >= 1100;
          return CallbackShortcuts(
            bindings: {
              const SingleActivator(
                LogicalKeyboardKey.keyN,
                control: true,
                alt: true,
              ): () {
                if (_current &&
                    _bookId != null &&
                    view?.canCreate('bill', _bookId!) == true) {
                  _entry();
                }
              },
              const SingleActivator(
                LogicalKeyboardKey.keyF,
                control: true,
                alt: true,
              ): () {
                if (_current) _search();
              },
              const SingleActivator(
                LogicalKeyboardKey.comma,
                control: true,
              ): () {
                if (_current) Navigator.pushNamed(context, '/settings');
              },
            },
            child: FocusTraversalGroup(
              child: Focus(
                autofocus: true,
                child: Scaffold(
                  appBar: AppBar(
                    title: TextButton(
                      onPressed: () async {
                        final selected = await showDatePicker(
                          context: context,
                          initialDate: _month,
                          firstDate: DateTime(1900),
                          lastDate: DateTime(2100, 12, 31),
                          initialDatePickerMode: DatePickerMode.year,
                        );
                        if (selected != null && mounted && _current) {
                          setState(() {
                            _month = selected;
                            _explicitDateSelection = true;
                          });
                        }
                      },
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              '${_month.year}-${_month.month.toString().padLeft(2, '0')}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const Icon(Icons.expand_more),
                        ],
                      ),
                    ),
                    actions: [
                      IconButton(
                        tooltip: '统计、日历与预算',
                        key: const Key('open-statistics'),
                        onPressed: _bookId == null ? null : _report,
                        icon: const Icon(Icons.bar_chart),
                      ),
                      IconButton(
                        tooltip: '搜索账单（Ctrl+Alt+F）',
                        key: const Key('open-bill-search'),
                        onPressed: _search,
                        icon: const Icon(Icons.search),
                      ),
                      IconButton(
                        tooltip: '记账草稿',
                        onPressed: _drafts,
                        icon: const Icon(Icons.edit_note_outlined),
                      ),
                      IconButton(
                        tooltip: '设置',
                        key: const Key('open-settings'),
                        onPressed: () =>
                            Navigator.pushNamed(context, '/settings'),
                        icon: const Icon(Icons.tune_rounded),
                      ),
                    ],
                  ),
                  drawer: view == null || _desktopLayout ? null : _drawer(view),
                  body: snapshot.hasError
                      ? const Center(child: Text('本地账本读取失败，请重试。'))
                      : view == null
                      ? const Center(child: CircularProgressIndicator())
                      : _desktopLayout
                      ? Row(
                          key: const Key('home-desktop-shell'),
                          children: [
                            SizedBox(width: 260, child: _drawer(view)),
                            const VerticalDivider(width: 1),
                            Expanded(child: _body(view)),
                          ],
                        )
                      : _body(view),
                  floatingActionButtonLocation:
                      FloatingActionButtonLocation.centerFloat,
                  floatingActionButton: view == null || _bookId == null
                      ? null
                      : FloatingActionButton.large(
                          key: const Key('new-entry'),
                          onPressed: view.canCreate('bill', _bookId!)
                              ? () => _entry()
                              : null,
                          tooltip: '记一笔（Ctrl+Alt+N）',
                          child: const Icon(Icons.add, size: 34),
                        ),
                ),
              ),
            ),
          );
        },
      );
    },
  );
}
