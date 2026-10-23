import 'package:flutter/material.dart';

import '../../core/money/money.dart';

String reportAmount(String currency, int scale, Object? minor) =>
    Money(currency, scale, parseMinor(minor)).display();

/// Only the bounded drawing ratio becomes a double. Money remains BigInt.
double reportRatio(BigInt value, BigInt limit) {
  if (limit <= BigInt.zero || value <= BigInt.zero) return 0;
  final units = (value * BigInt.from(10000) ~/ limit);
  return (units > BigInt.from(10000) ? 10000 : units.toInt()) / 10000;
}

String reportPercent(BigInt value, BigInt total) {
  if (total == BigInt.zero) return '—';
  final units = roundHalfUp(value * BigInt.from(1000), total.abs());
  final sign = units.isNegative ? '-' : '';
  final n = units.abs();
  return '$sign${n ~/ BigInt.from(10)}.${n % BigInt.from(10)}%';
}

class ReportMetric extends StatelessWidget {
  const ReportMetric(this.label, this.value, {this.color, super.key});
  final String label, value;
  final Color? color;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 160,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 6),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(color: color),
          ),
        ],
      ),
    ),
  );
}

class ReportSection extends StatelessWidget {
  const ReportSection({
    required this.title,
    required this.child,
    this.action,
    super.key,
  });
  final String title;
  final Widget child;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              ?action,
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    ),
  );
}
