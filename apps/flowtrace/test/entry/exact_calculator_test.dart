import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/core/money/money.dart';
import 'package:flowtrace/features/entry/exact_calculator.dart';

void main() {
  test('decimal expressions and JavaScript unsafe integers remain exact', () {
    final calculator = ExactCalculator(initial: '0.10+0.20-0.01');
    expect(calculator.evaluate().display(), '0.29');
    calculator.expression = '90071992547409.93+0.02';
    expect(calculator.evaluate().minor.toString(), '9007199254740995');
  });

  test('currency precision, incomplete input and overflow block a save', () {
    final calculator = ExactCalculator(initial: '1.001');
    expect(() => calculator.evaluate(), throwsA(isA<DomainError>()));
    calculator.expression = '1+';
    expect(calculator.preview, isNull);
    calculator.expression = '92233720368547758.07+0.01';
    expect(() => calculator.evaluate(), throwsA(isA<DomainError>()));
    calculator.expression = '1-2';
    expect(calculator.preview, '-1.00');
    expect(
      () => calculator.evaluate(positive: true),
      throwsA(isA<DomainError>()),
    );
  });

  test('keypad never silently truncates precision and allows correction', () {
    final calculator = ExactCalculator();
    for (final key in ['.', '1', '2', '3', '+', '-', '0', '.', '0', '2']) {
      calculator.input(key);
    }
    expect(calculator.expression, '0.12-0.02');
    expect(calculator.preview, '0.10');
    calculator.input('⌫');
    calculator.input('3');
    expect(calculator.preview, '0.09');
    calculator.input('C');
    expect(calculator.expression, isEmpty);
  });
}
