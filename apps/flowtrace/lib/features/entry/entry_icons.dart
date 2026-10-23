import 'package:flutter/material.dart';

/// Persist semantic keys, never Flutter code points or a font implementation.
abstract final class EntryIcons {
  static const values = <String, IconData>{
    'book': Icons.book_outlined,
    'food': Icons.restaurant_rounded,
    'restaurant': Icons.restaurant_rounded,
    'snack': Icons.icecream_outlined,
    'shopping': Icons.shopping_bag_outlined,
    'home': Icons.home_outlined,
    'transport': Icons.directions_bus_outlined,
    'travel': Icons.flight_outlined,
    'health': Icons.medical_services_outlined,
    'education': Icons.school_outlined,
    'study': Icons.menu_book_outlined,
    'salary': Icons.account_balance_wallet_outlined,
    'bonus': Icons.redeem_outlined,
    'gift': Icons.card_giftcard_outlined,
    'entertainment': Icons.sports_esports_outlined,
    'sport': Icons.directions_run_rounded,
    'digital': Icons.photo_camera_outlined,
    'utilities': Icons.bolt_outlined,
    'service': Icons.devices_other_outlined,
    'investment': Icons.trending_up_rounded,
    'cash': Icons.payments_outlined,
    'bank': Icons.account_balance_outlined,
    'credit_card': Icons.credit_card_outlined,
    'other': Icons.grid_view_rounded,
  };

  static IconData of(Object? key) => values[key] ?? Icons.category_outlined;
}
