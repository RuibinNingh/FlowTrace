import 'package:flutter/material.dart';

import '../../core/money/money.dart';

enum IncomeExpenseColors { expenseRed, incomeRed }

/// Device/browser presentation preferences. These never change ledger rules or
/// generate sync operations; book/account business settings remain separate.
@immutable
class AppPreferences {
  const AppPreferences({
    this.themeMode = ThemeMode.dark,
    this.incomeExpenseColors = IncomeExpenseColors.expenseRed,
    this.groupThousands = false,
    this.weekStartsMonday = true,
    this.showCategoryIcons = true,
    this.showFullCategory = false,
    this.preferNote = false,
    this.showHomeSummary = true,
    this.showHomeBudget = true,
    this.showHomeTrend = true,
    this.hideAmounts = false,
    this.assetsEnabled = true,
    this.multiCurrencyEnabled = true,
    this.reimbursementsEnabled = true,
    this.discountEnabled = true,
    this.billTimeEnabled = true,
    this.billImagesEnabled = true,
    this.billFlagsEnabled = true,
    this.tagsEnabled = true,
    this.quickEntry = false,
  });

  final ThemeMode themeMode;
  final IncomeExpenseColors incomeExpenseColors;
  final bool groupThousands, weekStartsMonday;
  final bool showCategoryIcons, showFullCategory, preferNote;
  final bool showHomeSummary, showHomeBudget, showHomeTrend, hideAmounts;
  final bool assetsEnabled, multiCurrencyEnabled, reimbursementsEnabled;
  final bool discountEnabled, billTimeEnabled, billImagesEnabled;
  final bool billFlagsEnabled, tagsEnabled, quickEntry;

  static const _booleanFields = {
    'group_thousands',
    'week_starts_monday',
    'show_category_icons',
    'show_full_category',
    'prefer_note',
    'show_home_summary',
    'show_home_budget',
    'show_home_trend',
    'hide_amounts',
    'assets_enabled',
    'multi_currency_enabled',
    'reimbursements_enabled',
    'discount_enabled',
    'bill_time_enabled',
    'bill_images_enabled',
    'bill_flags_enabled',
    'tags_enabled',
    'quick_entry',
  };

  factory AppPreferences.fromJson(Object? json) {
    if (json is! Map<String, Object?> ||
        json['version'] != 1 ||
        json.keys.any(
          (key) => !{
            'version',
            'theme_mode',
            'income_expense_colors',
            ..._booleanFields,
          }.contains(key),
        )) {
      throw const FormatException('无法读取此版本的本机设置。');
    }
    for (final key in _booleanFields) {
      if (json.containsKey(key) && json[key] is! bool) {
        throw const FormatException('本机设置格式不正确。');
      }
    }
    final theme = json['theme_mode'];
    final colors = json['income_expense_colors'];
    if (theme is! String ||
        !ThemeMode.values.any((item) => item.name == theme) ||
        colors is! String ||
        !IncomeExpenseColors.values.any((item) => item.name == colors)) {
      throw const FormatException('本机外观设置格式不正确。');
    }
    const defaults = AppPreferences();
    return AppPreferences(
      themeMode: ThemeMode.values.byName(theme),
      incomeExpenseColors: IncomeExpenseColors.values.byName(colors),
      groupThousands:
          json['group_thousands'] as bool? ?? defaults.groupThousands,
      weekStartsMonday:
          json['week_starts_monday'] as bool? ?? defaults.weekStartsMonday,
      showCategoryIcons:
          json['show_category_icons'] as bool? ?? defaults.showCategoryIcons,
      showFullCategory:
          json['show_full_category'] as bool? ?? defaults.showFullCategory,
      preferNote: json['prefer_note'] as bool? ?? defaults.preferNote,
      showHomeSummary:
          json['show_home_summary'] as bool? ?? defaults.showHomeSummary,
      showHomeBudget:
          json['show_home_budget'] as bool? ?? defaults.showHomeBudget,
      showHomeTrend: json['show_home_trend'] as bool? ?? defaults.showHomeTrend,
      hideAmounts: json['hide_amounts'] as bool? ?? defaults.hideAmounts,
      assetsEnabled: json['assets_enabled'] as bool? ?? defaults.assetsEnabled,
      multiCurrencyEnabled:
          json['multi_currency_enabled'] as bool? ??
          defaults.multiCurrencyEnabled,
      reimbursementsEnabled:
          json['reimbursements_enabled'] as bool? ??
          defaults.reimbursementsEnabled,
      discountEnabled:
          json['discount_enabled'] as bool? ?? defaults.discountEnabled,
      billTimeEnabled:
          json['bill_time_enabled'] as bool? ?? defaults.billTimeEnabled,
      billImagesEnabled:
          json['bill_images_enabled'] as bool? ?? defaults.billImagesEnabled,
      billFlagsEnabled:
          json['bill_flags_enabled'] as bool? ?? defaults.billFlagsEnabled,
      tagsEnabled: json['tags_enabled'] as bool? ?? defaults.tagsEnabled,
      quickEntry: json['quick_entry'] as bool? ?? defaults.quickEntry,
    );
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'theme_mode': themeMode.name,
    'income_expense_colors': incomeExpenseColors.name,
    'group_thousands': groupThousands,
    'week_starts_monday': weekStartsMonday,
    'show_category_icons': showCategoryIcons,
    'show_full_category': showFullCategory,
    'prefer_note': preferNote,
    'show_home_summary': showHomeSummary,
    'show_home_budget': showHomeBudget,
    'show_home_trend': showHomeTrend,
    'hide_amounts': hideAmounts,
    'assets_enabled': assetsEnabled,
    'multi_currency_enabled': multiCurrencyEnabled,
    'reimbursements_enabled': reimbursementsEnabled,
    'discount_enabled': discountEnabled,
    'bill_time_enabled': billTimeEnabled,
    'bill_images_enabled': billImagesEnabled,
    'bill_flags_enabled': billFlagsEnabled,
    'tags_enabled': tagsEnabled,
    'quick_entry': quickEntry,
  };

  AppPreferences copyWith({
    ThemeMode? themeMode,
    IncomeExpenseColors? incomeExpenseColors,
    bool? groupThousands,
    bool? weekStartsMonday,
    bool? showCategoryIcons,
    bool? showFullCategory,
    bool? preferNote,
    bool? showHomeSummary,
    bool? showHomeBudget,
    bool? showHomeTrend,
    bool? hideAmounts,
    bool? assetsEnabled,
    bool? multiCurrencyEnabled,
    bool? reimbursementsEnabled,
    bool? discountEnabled,
    bool? billTimeEnabled,
    bool? billImagesEnabled,
    bool? billFlagsEnabled,
    bool? tagsEnabled,
    bool? quickEntry,
  }) => AppPreferences(
    themeMode: themeMode ?? this.themeMode,
    incomeExpenseColors: incomeExpenseColors ?? this.incomeExpenseColors,
    groupThousands: groupThousands ?? this.groupThousands,
    weekStartsMonday: weekStartsMonday ?? this.weekStartsMonday,
    showCategoryIcons: showCategoryIcons ?? this.showCategoryIcons,
    showFullCategory: showFullCategory ?? this.showFullCategory,
    preferNote: preferNote ?? this.preferNote,
    showHomeSummary: showHomeSummary ?? this.showHomeSummary,
    showHomeBudget: showHomeBudget ?? this.showHomeBudget,
    showHomeTrend: showHomeTrend ?? this.showHomeTrend,
    hideAmounts: hideAmounts ?? this.hideAmounts,
    assetsEnabled: assetsEnabled ?? this.assetsEnabled,
    multiCurrencyEnabled: multiCurrencyEnabled ?? this.multiCurrencyEnabled,
    reimbursementsEnabled: reimbursementsEnabled ?? this.reimbursementsEnabled,
    discountEnabled: discountEnabled ?? this.discountEnabled,
    billTimeEnabled: billTimeEnabled ?? this.billTimeEnabled,
    billImagesEnabled: billImagesEnabled ?? this.billImagesEnabled,
    billFlagsEnabled: billFlagsEnabled ?? this.billFlagsEnabled,
    tagsEnabled: tagsEnabled ?? this.tagsEnabled,
    quickEntry: quickEntry ?? this.quickEntry,
  );

  Color get incomeColor => incomeExpenseColors == IncomeExpenseColors.expenseRed
      ? const Color(0xFF20A678)
      : const Color(0xFFF05B63);
  Color get expenseColor =>
      incomeExpenseColors == IncomeExpenseColors.expenseRed
      ? const Color(0xFFF05B63)
      : const Color(0xFF20A678);

  /// A presentation-only grouping pass over the exact decimal string. It never
  /// parses an amount to double and is not accepted back as a ledger payload.
  String formatMoney(Money money, {bool reveal = false}) {
    if (hideAmounts && !reveal) return '••••';
    final value = money.display();
    if (!groupThousands) return value;
    final sign = value.startsWith('-') ? '-' : '';
    final parts = value.replaceFirst('-', '').split('.');
    final digits = parts.first;
    final grouped = StringBuffer(sign);
    for (var index = 0; index < digits.length; index++) {
      if (index > 0 && (digits.length - index) % 3 == 0) grouped.write(',');
      grouped.write(digits[index]);
    }
    if (parts.length == 2) grouped.write('.${parts[1]}');
    return grouped.toString();
  }
}

/// Shared by the preview and real bill rows. No private metadata is inferred.
class BillPresentation {
  const BillPresentation({required this.title, this.subtitle});
  final String title;
  final String? subtitle;

  factory BillPresentation.create({
    required AppPreferences preferences,
    required String category,
    String? parentCategory,
    String note = '',
  }) {
    final full =
        preferences.showFullCategory &&
            parentCategory != null &&
            parentCategory.isNotEmpty &&
            parentCategory != category
        ? '$parentCategory / $category'
        : category;
    final useNote = preferences.preferNote && note.trim().isNotEmpty;
    return BillPresentation(
      title: useNote ? note : full,
      subtitle: useNote
          ? full
          : note.isEmpty
          ? null
          : note,
    );
  }
}
