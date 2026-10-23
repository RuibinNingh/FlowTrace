import '../../core/money/money.dart';

/// The entry keypad supports addition and subtraction in currency precision.
/// Each operand and the result stay exact on native and JavaScript runtimes.
final class ExactCalculator {
  ExactCalculator({this.currency = 'CNY', this.scale = 2, String initial = ''})
    : expression = initial;

  final String currency;
  final int scale;
  String expression;

  void input(String key) {
    if (key == '⌫') {
      if (expression.isNotEmpty) {
        expression = expression.substring(0, expression.length - 1);
      }
      return;
    }
    if (key == 'C') {
      expression = '';
      return;
    }
    if (!RegExp(r'^[0-9.+-]$').hasMatch(key)) return;
    if (expression.length >= 128) return;
    if (key == '+' || key == '-') {
      if (expression.isEmpty) return;
      if (expression.endsWith('+') || expression.endsWith('-')) {
        expression = '${expression.substring(0, expression.length - 1)}$key';
      } else if (!expression.endsWith('.')) {
        expression += key;
      }
      return;
    }
    final start = expression.lastIndexOf(RegExp(r'[+-]')) + 1;
    final operand = expression.substring(start);
    if (key == '.') {
      if (operand.contains('.') || scale == 0) return;
      expression += operand.isEmpty ? '0.' : '.';
      return;
    }
    if (operand.contains('.') && operand.split('.').last.length >= scale) {
      return;
    }
    if (operand == '0') {
      expression = '${expression.substring(0, start)}$key';
    } else {
      expression += key;
    }
  }

  Money evaluate({bool positive = false}) {
    if (expression.isEmpty ||
        expression.length > 128 ||
        !RegExp(
          r'^\d+(?:\.\d+)?(?:[+-]\d+(?:\.\d+)?)*$',
        ).hasMatch(expression)) {
      throw const DomainError('calculator.incomplete');
    }
    var value = BigInt.zero;
    var sign = BigInt.one;
    for (final match in RegExp(r'\d+(?:\.\d+)?|[+-]').allMatches(expression)) {
      final token = match.group(0)!;
      if (token == '+' || token == '-') {
        sign = token == '+' ? BigInt.one : -BigInt.one;
      } else {
        value = checkedMinor(
          value + sign * parseDisplay(token, currency, scale).minor,
        );
      }
    }
    if (positive && value <= BigInt.zero) {
      throw const DomainError('money.must_be_positive');
    }
    return Money(currency, scale, value);
  }

  String? get preview {
    try {
      return evaluate().display();
    } on DomainError {
      return null;
    }
  }
}
