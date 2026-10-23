import 'package:uuid/uuid.dart';

import '../../data/ledger/ledger_models.dart';

final class TemplateCategory {
  const TemplateCategory(
    this.key,
    this.name,
    this.kind,
    this.icon, {
    this.parent,
  });
  final String key;
  final String name;
  final String kind;
  final String icon;
  final String? parent;
}

final class BookTemplate {
  const BookTemplate(this.id, this.name, this.description, this.categories);
  final String id;
  final String name;
  final String description;
  final List<TemplateCategory> categories;

  /// A local atomic configuration transaction; no accounts, bills or balances.
  List<LedgerWrite> writes({
    required String userScope,
    required String bookId,
    required Map<String, Object?> book,
  }) {
    const uuid = Uuid();
    final ids = {for (final category in categories) category.key: uuid.v4()};
    final ordered = [
      ...categories.where((e) => e.parent == null),
      ...categories.where((e) => e.parent != null),
    ];
    final orders = <String, int>{};
    return [
      LedgerWrite(
        entityType: 'book',
        scopeId: userScope,
        entityId: bookId,
        payload: {...book, 'template': id},
      ),
      for (final category in ordered)
        LedgerWrite(
          entityType: 'category',
          scopeId: bookId,
          entityId: ids[category.key],
          payload: {
            'name': category.name,
            'kind': category.kind,
            'parent_id': category.parent == null ? null : ids[category.parent],
            'icon': category.icon,
            'archived': false,
            'sort_order': orders.update(
              '${category.kind}:${category.parent}',
              (v) => v + 1,
              ifAbsent: () => 0,
            ),
          },
        ),
    ];
  }
}

/// Template kinds match the observed catalogue. Category contents are explicit
/// FlowTrace defaults, not claimed to be copied from unobserved source data.
abstract final class BookTemplates {
  static const income = [
    TemplateCategory('salary', '工资', 'income', 'salary'),
    TemplateCategory('bonus', '奖金', 'income', 'bonus'),
    TemplateCategory('other_income', '其他收入', 'income', 'other'),
  ];
  static const values = [
    BookTemplate('blank', '空白账本', '自行添加分类，不预置流水或资产。', []),
    BookTemplate('daily', '日常生活', '记录每天的收支。', [
      TemplateCategory('food', '餐饮', 'expense', 'food'),
      TemplateCategory('shopping', '购物', 'expense', 'shopping'),
      TemplateCategory('home', '住房', 'expense', 'home'),
      TemplateCategory('transport', '交通', 'expense', 'transport'),
      TemplateCategory('health', '医疗', 'expense', 'health'),
      TemplateCategory('education', '学习', 'expense', 'education'),
      TemplateCategory('entertainment', '娱乐', 'expense', 'entertainment'),
      ...income,
      TemplateCategory('breakfast', '早餐', 'expense', 'food', parent: 'food'),
      TemplateCategory('lunch', '午餐', 'expense', 'food', parent: 'food'),
      TemplateCategory('dinner', '晚餐', 'expense', 'food', parent: 'food'),
    ]),
    BookTemplate('travel', '旅行账本', '按行程整理旅途开销。', [
      TemplateCategory('transport', '交通', 'expense', 'transport'),
      TemplateCategory('stay', '住宿', 'expense', 'home'),
      TemplateCategory('food', '餐饮', 'expense', 'food'),
      TemplateCategory('tickets', '门票', 'expense', 'entertainment'),
      TemplateCategory('shopping', '购物', 'expense', 'shopping'),
      TemplateCategory('refund', '退款收入', 'income', 'other'),
    ]),
    BookTemplate('renovation', '装修账本', '整理材料、施工和家居费用。', [
      TemplateCategory('material', '装修材料', 'expense', 'home'),
      TemplateCategory('labor', '施工费用', 'expense', 'service'),
      TemplateCategory('furniture', '家具家电', 'expense', 'shopping'),
      TemplateCategory('design', '设计费用', 'expense', 'education'),
      TemplateCategory('refund', '退款收入', 'income', 'other'),
    ]),
    BookTemplate('wedding', '结婚账本', '整理婚礼筹备和礼金。', [
      TemplateCategory('banquet', '婚宴', 'expense', 'food'),
      TemplateCategory('clothing', '服饰', 'expense', 'shopping'),
      TemplateCategory('photo', '摄影', 'expense', 'digital'),
      TemplateCategory('ceremony', '婚庆', 'expense', 'gift'),
      TemplateCategory('gift_income', '礼金收入', 'income', 'gift'),
    ]),
    BookTemplate('gifts', '人情账本', '往来礼金与赠礼单独记录。', [
      TemplateCategory('gifts', '送礼', 'expense', 'gift'),
      TemplateCategory('banquet', '宴请', 'expense', 'food'),
      TemplateCategory('gift_income', '收礼', 'income', 'gift'),
    ]),
    BookTemplate('business_trip', '出差账本', '记录出差支出；报销需后续明确关联。', [
      TemplateCategory('transport', '差旅交通', 'expense', 'transport'),
      TemplateCategory('stay', '住宿', 'expense', 'home'),
      TemplateCategory('food', '餐饮', 'expense', 'food'),
      TemplateCategory('office', '办公费用', 'expense', 'service'),
      TemplateCategory('income', '其他收入', 'income', 'other'),
    ]),
    BookTemplate('company', '公司账本', '整理业务收入和经营费用。', [
      TemplateCategory('office', '办公费用', 'expense', 'service'),
      TemplateCategory('salary_cost', '员工薪酬', 'expense', 'salary'),
      TemplateCategory('rent', '场地租金', 'expense', 'home'),
      TemplateCategory('business_income', '营业收入', 'income', 'investment'),
      TemplateCategory('other_income', '其他收入', 'income', 'other'),
    ]),
    BookTemplate('shop', '店铺生意', '进货、运营与销售收支。', [
      TemplateCategory('stock', '进货', 'expense', 'shopping'),
      TemplateCategory('rent', '店铺租金', 'expense', 'home'),
      TemplateCategory('utilities', '水电运营', 'expense', 'utilities'),
      TemplateCategory('sales', '销售收入', 'income', 'investment'),
      TemplateCategory('other_income', '其他收入', 'income', 'other'),
    ]),
    BookTemplate('car', '汽车账本', '保养、出行和车辆费用。', [
      TemplateCategory('fuel', '加油充电', 'expense', 'utilities'),
      TemplateCategory('maintenance', '维修保养', 'expense', 'service'),
      TemplateCategory('parking', '停车通行', 'expense', 'transport'),
      TemplateCategory('insurance', '保险', 'expense', 'health'),
      TemplateCategory('other_income', '其他收入', 'income', 'other'),
    ]),
  ];

  static BookTemplate? find(String id) =>
      values.where((e) => e.id == id).firstOrNull;
}
