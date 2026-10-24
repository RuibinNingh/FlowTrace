import '../../core/network/api_failure.dart';
import '../../data/data_tools/data_tools_models.dart';

/// Fixed reasons only. Source cells, response bodies and exception text never
/// become diagnostic labels.
String importErrorReason(String code) => switch (code) {
  'mapping_required' || 'import_mapping_required' => '请选择对应的账户、分类、标签或原图后重新预览',
  'source_modified' || 'import_source_modified' => '原来源记录已有后续修改',
  'import_attachment_transfer_conflict' => '原图状态或使用范围已变化',
  'invalid_exact_amount' || 'invalid_amount' => '金额精度或范围不正确',
  'too_many_rows' ||
  'qianji_export_requires_staging' => '此文件需要完整导入，请使用“钱迹原始导出 / 超过50条完整导入”',
  'unsupported_qianji_columns' => '未识别钱迹表头，请选择钱迹原始导出文件或公开导入模板',
  'invalid_columns' => '列数与表头不一致，请核对原文件中的列',
  'workbook_dimensions_invalid' => 'Excel实际行列超出该入口限制，请使用完整导入',
  'one_template_sheet_required' => '钱迹文件需要包含一个账单工作表',
  'workbook_formula_not_allowed' => '文件包含公式，请使用钱迹直接导出的原始数值文件',
  'invalid_xlsx' => 'Excel文件无法读取，请确认文件完整且不是加密文件',
  'invalid_csv' => 'CSV编码或列格式不正确，请使用UTF-8原始导出',
  'empty_import' => '文件中没有可以导入的账单记录',
  'unsupported_qianji_type' => '该钱迹账单类型暂不支持，请按错误码核对',
  'qianji_export_duplicate_id' ||
  'qianji_duplicate_id' => '原文件存在重复账单ID，无法唯一识别账单',
  'qianji_export_invalid_id' ||
  'qianji_invalid_id' ||
  'qianji_id_invalid' => '原文件账单ID缺失或格式不正确，请保留钱迹原始文本ID',
  'qianji_refund_source_missing' ||
  'qianji_export_refund_source_missing' ||
  'qianji_reference_missing' => '退款关联的原支出不在当前文件中，请导出包含原支出与退款的完整账本',
  'qianji_refund_source_invalid' ||
  'qianji_export_refund_source_invalid' ||
  'qianji_source_type_invalid' => '退款关联目标不是可退款的原支出',
  'qianji_refund_source_ambiguous' ||
  'qianji_reference_invalid' => '账单关联格式不正确，退款需要唯一的原支出ID',
  'qianji_refund_cross_book' ||
  'qianji_export_cross_book_reference' ||
  'qianji_source_book_mismatch' => '退款与原支出属于不同账本，当前关联不能导入',
  'qianji_refund_cycle' ||
  'qianji_export_reference_cycle' ||
  'qianji_reference_cycle' => '账单关联出现循环，请核对原文件',
  'qianji_refund_currency_mismatch' ||
  'qianji_export_currency_mismatch' ||
  'qianji_currency_mismatch' ||
  'qianji_source_currency_mismatch' => '原支出、退款或目标账本的币种不一致，请核对币种映射',
  'qianji_currency_unsupported' ||
  'qianji_export_unsupported_currency' => '原文件币种无法按目标账本精度解析',
  'qianji_refund_amount_invalid' ||
  'qianji_refund_exceeds_source' => '退款金额或累计退款超过原支出可退金额',
  'qianji_reimbursement_details_required' => '已报销账单缺少实际回款明细，请补充原始明细后导入',
  'receipt_source_not_found' || 'source_bill_not_found' => '关联的原支出不存在或当前无权读取',
  'invalid_attachment_manifest' => '原图校验清单不完整或不正确',
  _ => '文件未通过校验，请按下面的错误码定位原因',
};

String importErrorDescription(DataImportError error) {
  final field = error.field;
  final safeField =
      field != null &&
          RegExp(r'^[A-Za-z0-9_./\u4e00-\u9fff -]{1,100}$').hasMatch(field)
      ? ' · 字段：$field'
      : '';
  return '${error.row == null ? '文件' : '第${error.row}行'}$safeField：'
      '${importErrorReason(error.code)}（错误码：${error.code}）';
}

String importFailureDescription(ApiFailure error) {
  if (error.status == null && error.requestId == null) return error.message;
  final code = RegExp(r'^[A-Za-z0-9_.-]{1,100}$').hasMatch(error.code)
      ? error.code
      : 'request_failed';
  final request = ApiFailure.sanitizedRequestId(error.requestId);
  return '${error.message}\n错误码：$code'
      '${request == null ? '' : '\n请求ID：$request'}';
}
