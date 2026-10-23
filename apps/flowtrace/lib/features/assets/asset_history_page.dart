import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/config/data_space.dart';
import '../../core/money/money.dart';
import '../../data/assets/asset_read_repository.dart';
import '../../data/preferences/app_preferences.dart';
import '../../data/preferences/preferences_scope.dart';
import '../../domain/ledger/calendar_rules.dart';
import 'asset_read_view.dart';

class AssetHistoryPage extends StatefulWidget {
  const AssetHistoryPage({
    required this.app,
    required this.space,
    this.scopeId,
    this.initialDate,
    super.key,
  });
  final AppController app;
  final DataSpace space;
  final String? scopeId;
  final DateTime? initialDate;
  @override
  State<AssetHistoryPage> createState() => _AssetHistoryPageState();
}

class _AssetHistoryPageState extends State<AssetHistoryPage> {
  String _money(Money? value) =>
      assetMoney(value, widget.app.preferences.value);
  late final _repository = assetReads(widget.app);
  late final _date = widget.initialDate ?? DateTime.now();
  late String _start = isoBusinessDate(DateTime.utc(_date.year, _date.month));
  late String _end = isoBusinessDate(DateTime.utc(_date.year, _date.month + 1));
  int _selected = 0;
  bool get _current =>
      widget.app.space?.id == widget.space.id && !widget.app.switchingSpace;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.app,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('资产趋势')),
      body: !_current
          ? const Center(child: Text('资料空间已变化，请返回。'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text('按当前有效账务重构每个业务日的余额；更正或删除旧账会重算曲线。未记录启用日或缺少估值时显示缺口。'),
                const SizedBox(height: 12),
                AssetDateRange(
                  start: _start,
                  endExclusive: _end,
                  onChanged: (start, end) {
                    if (_current) {
                      setState(() {
                        _start = start;
                        _end = end;
                        _selected = 0;
                      });
                    }
                  },
                ),
                const SizedBox(height: 12),
                AssetReadView(
                  app: widget.app,
                  space: widget.space,
                  repository: _repository,
                  query: AssetReadQuery.history(
                    scopeId: widget.scopeId ?? widget.space.userId,
                    startDate: _start,
                    endDateExclusive: _end,
                  ),
                  builder: (context, result) {
                    final history = result.data as AssetHistory;
                    final selected = history
                        .points[_selected.clamp(0, history.points.length - 1)];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '本位币 ${history.currency} · ${history.valuationPolicy == 'exact_date' ? '仅用当日直接报价' : '允许使用当日或之前最新直接报价'}',
                        ),
                        const SizedBox(height: 12),
                        AssetHistoryChart(
                          preferences: widget.app.preferences.value,
                          points: history.points,
                          selected: _selected,
                          onSelected: (index) =>
                              setState(() => _selected = index),
                        ),
                        const SizedBox(height: 8),
                        _point(selected, selected: true),
                        const Divider(),
                        for (final point in history.points) _point(point),
                      ],
                    );
                  },
                ),
              ],
            ),
    ),
  );
  Widget _point(AssetHistoryPoint point, {bool selected = false}) => Card(
    key: selected
        ? const Key('asset-history-selected')
        : Key('asset-history-${point.date}'),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            point.date,
            style: selected ? Theme.of(context).textTheme.titleMedium : null,
          ),
          if (point.totals case final totals?) ...[
            Text('净资产 ${_money(totals.net)}'),
            Wrap(
              spacing: 16,
              children: [
                Text('资产 ${_money(totals.assets)}'),
                Text('负债 ${_money(totals.liabilities)}'),
                Text('借入 ${_money(totals.borrowed)}'),
                Text('借出 ${_money(totals.lent)}'),
              ],
            ),
          ] else
            for (final issue in point.issues) Text(assetReadIssue(issue)),
        ],
      ),
    ),
  );
}

/// Only the drawing coordinate uses a bounded ratio. Every label is exact
/// Money, and missing evidence creates a gap rather than an interpolated zero.
class AssetHistoryChart extends StatelessWidget {
  const AssetHistoryChart({
    required this.points,
    required this.selected,
    required this.onSelected,
    this.preferences,
    super.key,
  });
  final List<AssetHistoryPoint> points;
  final int selected;
  final ValueChanged<int> onSelected;
  final AppPreferences? preferences;
  @override
  Widget build(BuildContext context) =>
      (preferences ?? AppPreferencesScope.of(context)).hideAmounts
      ? const Padding(
          key: Key('asset-history-chart-hidden'),
          padding: EdgeInsets.all(24),
          child: Text('金额已隐藏，资产数值曲线暂不展示。'),
        )
      : Semantics(
          label: '资产净值走势，点击日期查看精确金额，缺少资料的日期留空',
          child: LayoutBuilder(
            builder: (context, constraints) => GestureDetector(
              key: const Key('asset-history-chart'),
              onTapUp: (details) {
                if (points.isEmpty || constraints.maxWidth <= 0) return;
                onSelected(
                  ((details.localPosition.dx / constraints.maxWidth) *
                          (points.length - 1))
                      .round()
                      .clamp(0, points.length - 1),
                );
              },
              child: SizedBox(
                height: 180,
                width: double.infinity,
                child: CustomPaint(
                  painter: _HistoryPainter(
                    points,
                    selected,
                    Theme.of(context).colorScheme.primary,
                    Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
              ),
            ),
          ),
        );
}

class _HistoryPainter extends CustomPainter {
  _HistoryPainter(this.points, this.selected, this.color, this.grid);
  final List<AssetHistoryPoint> points;
  final int selected;
  final Color color, grid;
  @override
  void paint(Canvas canvas, Size size) {
    final values = points
        .map((point) => point.totals?.net.minor)
        .whereType<BigInt>()
        .toList();
    if (values.isEmpty) return;
    var low = values.reduce((a, b) => a < b ? a : b),
        high = values.reduce((a, b) => a > b ? a : b);
    if (low == high) {
      low -= BigInt.one;
      high += BigInt.one;
    }
    final span = high - low,
        path = Path(),
        pen = Paint()
          ..color = color
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke;
    for (var i = 0; i < 3; i++) {
      final y = 8 + (size.height - 16) * i / 2;
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        Paint()..color = grid,
      );
    }
    var connected = false;
    for (var i = 0; i < points.length; i++) {
      final value = points[i].totals?.net.minor;
      if (value == null) {
        connected = false;
        continue;
      }
      final ratio =
          ((value - low) * BigInt.from(1000000) ~/ span).toInt() / 1000000;
      final x = points.length == 1
              ? size.width / 2
              : size.width * i / (points.length - 1),
          y = 8 + (size.height - 16) * (1 - ratio);
      if (connected) {
        path.lineTo(x, y);
      } else {
        path.moveTo(x, y);
      }
      connected = true;
      canvas.drawCircle(
        Offset(x, y),
        i == selected ? 5 : 2,
        Paint()..color = color,
      );
    }
    canvas.drawPath(path, pen);
  }

  @override
  bool shouldRepaint(covariant _HistoryPainter oldDelegate) =>
      oldDelegate.points != points ||
      oldDelegate.selected != selected ||
      oldDelegate.color != color ||
      oldDelegate.grid != grid;
}
