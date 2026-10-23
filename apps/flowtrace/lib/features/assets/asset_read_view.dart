import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/config/data_space.dart';
import '../../core/money/money.dart';
import '../../core/network/api_failure.dart';
import '../../data/assets/asset_read_repository.dart';
import '../../data/preferences/app_preferences.dart';
import '../../data/sync/sync_engine.dart';
import '../../domain/ledger/calendar_rules.dart';

String assetMoney(
  Money? value, [
  AppPreferences preferences = const AppPreferences(),
]) => preferences.hideAmounts
    ? '••••'
    : value == null
    ? '不可用'
    : '${value.currency} ${preferences.formatMoney(value)}';

String assetReadIssue(String code) => switch (code) {
  'asset.opening_date_required' => '缺少账户启用日期，历史余额与账期应还不可用。',
  'asset.entries_before_opening' ||
  'asset.entry_before_opening' ||
  'asset.before_opening' => '存在早于账户启用日期的分录，历史结果不可用。',
  'asset.credit_calendar_incomplete' => '请先配置出账日与还款日。',
  'asset.credit_period_incomplete' => '账户启用前的账期缺少完整证据，应还金额不可用。',
  'asset.balance_unavailable' => '账户余额与有效分录尚未核对一致。',
  'assets.rate_unavailable' ||
  'asset.rate_unavailable' ||
  'asset.valuation_rate_required' => '缺少指定日期的直接估值汇率。',
  'asset.limit_exceeded' => '读取范围超出限制，请缩短日期范围。',
  'assets.account_unconfirmed' => '账户尚未完成同步，暂不能读取服务器明细。',
  'assets.scope_unavailable' ||
  'permission_denied' ||
  'scope_revoked' ||
  'forbidden' => '当前无权读取这些资料。',
  'assets.read_only' ||
  'resync_required' ||
  'epoch_changed' ||
  'client_mismatch' => '资料需要先完成同步恢复核对。',
  'assets.evidence_changed' || 'assets.stale_response' => '读取期间资料版本已变化，请重新刷新。',
  'identity_changed' || 'session_invalid' || 'unauthorized' => '请联网登录当前账号后重试。',
  'not_found' => '服务器上尚无此账户，或当前无权读取。',
  'network_unavailable' || 'request_timeout' => '网络暂不可用，未把缺失资料当作零。',
  'assets.storage_unavailable' => '本地资料监听已中断，原结果已隐藏，请重新打开页面。',
  _ => '当前证据不足，结果暂不可用。',
};

AssetReadRepository assetReads(AppController app) => AssetReadRepository(
  app.repository,
  refreshPermissions: (lease) async {
    await app.syncEngine.refreshScopes(lease);
  },
);

/// Shared server/cached projection lifecycle. Every account or permission
/// change clears displayed data before loading a newly eligible cache cut.
class AssetReadView extends StatefulWidget {
  const AssetReadView({
    required this.app,
    required this.space,
    required this.repository,
    required this.query,
    required this.builder,
    this.leaseFactory,
    super.key,
  });
  final AppController app;
  final DataSpace space;
  final AssetReadRepository repository;
  final AssetReadQuery query;
  final Widget Function(BuildContext context, AssetReadSnapshot snapshot)
  builder;
  final SyncLease Function()? leaseFactory;
  @override
  State<AssetReadView> createState() => _AssetReadViewState();
}

class _AssetReadViewState extends State<AssetReadView> {
  StreamSubscription<int>? _subscription;
  AssetReadSnapshot? _snapshot;
  String? _stamp, _error;
  int _generation = 0, _evidenceGeneration = 0;
  int _watchGeneration = 0;
  bool _busy = false, _loading = true, _wasCurrent = false;
  bool _watchFailed = false;
  int? _sessionGeneration;
  bool get _current =>
      mounted &&
      widget.app.space?.id == widget.space.id &&
      !widget.app.switchingSpace;

  @override
  void initState() {
    super.initState();
    _wasCurrent = _current;
    _sessionGeneration = widget.app.identity?.sessionGeneration;
    widget.app.addListener(_sessionChanged);
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant AssetReadView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query.id != widget.query.id ||
        oldWidget.space.id != widget.space.id ||
        oldWidget.repository != widget.repository) {
      _generation++;
      _stamp = null;
      _snapshot = null;
      _error = null;
      _busy = false;
      _loading = true;
      unawaited(_subscription?.cancel());
      _subscribe();
      unawaited(_checkEvidence());
    }
    if (oldWidget.app != widget.app) {
      oldWidget.app.removeListener(_sessionChanged);
      widget.app.addListener(_sessionChanged);
    }
  }

  void _subscribe() {
    _watchFailed = false;
    final watch = ++_watchGeneration;
    _subscription = widget.repository.changes.listen(
      (_) {
        if (watch == _watchGeneration) {
          unawaited(_checkEvidence());
        }
      },
      onError: (Object _, StackTrace _) => _watchLost(watch),
      onDone: () => _watchLost(watch),
    );
  }

  void _watchLost(int watch) {
    if (!mounted || watch != _watchGeneration) return;
    _generation++;
    _evidenceGeneration++;
    _watchGeneration++;
    _watchFailed = true;
    unawaited(_subscription?.cancel());
    setState(() {
      _snapshot = null;
      _stamp = null;
      _busy = false;
      _loading = false;
      _error = 'assets.storage_unavailable';
    });
  }

  void _sessionChanged() {
    final current = _current,
        generation = widget.app.identity?.sessionGeneration;
    if (_wasCurrent == current && _sessionGeneration == generation) return;
    _wasCurrent = current;
    _sessionGeneration = generation;
    _generation++;
    setState(() {
      _snapshot = null;
      _error = _watchFailed ? 'assets.storage_unavailable' : null;
      _busy = false;
      _loading = current && !_watchFailed;
      _stamp = null;
    });
    if (current) unawaited(_checkEvidence());
  }

  Future<void> _checkEvidence() async {
    final run = ++_evidenceGeneration;
    if (!_current || _watchFailed) return;
    String? stamp;
    String? error;
    try {
      stamp = await widget.repository.evidenceStamp(widget.space, widget.query);
    } on DomainError catch (e) {
      error = e.code;
    } catch (_) {
      error = 'assets.invalid_data';
    }
    if (!_current || run != _evidenceGeneration) return;
    if (stamp != null && stamp == _stamp) return;
    _stamp = stamp;
    if (_busy) {
      setState(() {
        _snapshot = null;
        _error = error;
        _loading = false;
      });
      return;
    }
    final generation = ++_generation;
    setState(() {
      _snapshot = null;
      _error = error;
      _loading = error == null;
      _busy = false;
    });
    if (error != null) return;
    try {
      final cached = await widget.repository.cached(widget.space, widget.query);
      if (!_current || generation != _generation) return;
      setState(() {
        _snapshot = cached;
        _loading = false;
      });
    } on DomainError catch (e) {
      if (_current && generation == _generation) {
        setState(() {
          _error = e.code;
          _loading = false;
        });
      }
    } catch (_) {
      if (_current && generation == _generation) {
        setState(() {
          _error = 'assets.invalid_data';
          _loading = false;
        });
      }
    }
  }

  Future<void> _refresh() async {
    if (_busy || !_current || _watchFailed) return;
    final generation = ++_generation;
    setState(() {
      _snapshot = null;
      _error = null;
      _busy = true;
      _loading = false;
    });
    try {
      final factory = widget.leaseFactory;
      final identity = widget.app.identity;
      if (factory == null && identity == null) {
        throw const DomainError('session_invalid');
      }
      final captured = factory != null
          ? factory()
          : SyncLease.capture(identity!);
      final lease = SyncLease(
        space: captured.space,
        clientId: captured.clientId,
        epoch: captured.epoch,
        supportsGroupPull: captured.supportsGroupPull,
        request: captured.request,
        isCurrent: () => _current && captured.isCurrent(),
      );
      if (lease.space.id != widget.space.id) {
        throw const DomainError('identity_changed');
      }
      final result = await widget.repository.fetch(lease, widget.query);
      if (!_current || generation != _generation) return;
      if (result.evidence !=
          await widget.repository.evidenceStamp(widget.space, widget.query)) {
        throw const DomainError('assets.evidence_changed');
      }
      if (!_current || generation != _generation) return;
      _stamp = result.evidence;
      setState(() => _snapshot = result);
    } on DomainError catch (e) {
      if (_current && generation == _generation) {
        setState(() => _error = e.code);
      }
    } on ApiFailure catch (e) {
      if (_current && generation == _generation) {
        setState(() => _error = e.code);
      }
    } catch (_) {
      if (_current && generation == _generation) {
        setState(() => _error = 'assets.invalid_data');
      }
    } finally {
      if (_current && generation == _generation) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _generation++;
    _evidenceGeneration++;
    _watchGeneration++;
    widget.app.removeListener(_sessionChanged);
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.app,
    builder: (context, _) => !_current
        ? const Padding(
            padding: EdgeInsets.all(16),
            child: Text('资料空间已变化，请返回。'),
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('本页读取服务器已同步记录。本机待同步变更不计入；离线仅展示版本与权限均可核对的已确认缓存。'),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  key: const Key('asset-read-refresh'),
                  onPressed: _busy || _watchFailed ? null : _refresh,
                  icon: const Icon(Icons.refresh),
                  label: Text(_busy ? '正在核对…' : '刷新服务器资料'),
                ),
              ),
              if (_busy || _loading) const LinearProgressIndicator(),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    assetReadIssue(_error!),
                    key: const Key('asset-read-error'),
                  ),
                ),
              if (!_busy && !_loading && _error == null && _snapshot == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    '暂无符合当前版本的已确认资料，请联网刷新。',
                    key: Key('asset-read-unavailable'),
                  ),
                ),
              if (_snapshot case final value?) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    '${value.fromCache ? '已确认缓存' : '服务器已确认'} · 账务版本 ${value.data.envelope.scopeRevision} · 配置版本 ${value.data.envelope.configRevision}\n确认时间 ${value.confirmedAt.toLocal().toIso8601String().substring(0, 19)}',
                    key: const Key('asset-read-proof'),
                  ),
                ),
                widget.builder(context, value),
              ],
            ],
          ),
  );
}

class AssetDateRange extends StatelessWidget {
  const AssetDateRange({
    required this.start,
    required this.endExclusive,
    required this.onChanged,
    super.key,
  });
  final String start, endExclusive;
  final void Function(String start, String endExclusive) onChanged;
  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    key: const Key('asset-read-date-range'),
    icon: const Icon(Icons.date_range_outlined),
    label: Text(
      '$start 至 ${isoBusinessDate(businessDate(endExclusive).subtract(const Duration(days: 1)))}',
    ),
    onPressed: () async {
      final picked = await showDateRangePicker(
        context: context,
        firstDate: DateTime(1),
        lastDate: DateTime(9999, 12, 30),
        initialDateRange: DateTimeRange(
          start: businessDate(start),
          end: businessDate(endExclusive).subtract(const Duration(days: 1)),
        ),
        helpText: '选择日期范围（最多366天）',
        saveText: '确认',
      );
      if (picked == null || !context.mounted) return;
      final first = DateTime.utc(
            picked.start.year,
            picked.start.month,
            picked.start.day,
          ),
          stop = DateTime.utc(
            picked.end.year,
            picked.end.month,
            picked.end.day,
          ).add(const Duration(days: 1));
      if (stop.difference(first).inDays > 366) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('每次最多读取366天，请缩短范围。')));
        return;
      }
      onChanged(isoBusinessDate(first), isoBusinessDate(stop));
    },
  );
}
