import '../theme/status_colors.dart';
import 'package:flutter/material.dart';

/// Semantic status colors, previously provided by StatusColors.success etc.
class StatusColors {
  StatusColors._();

  static const Color success = Color(0xFF0E8420);
  static const Color warning = Color(0xFFF99B11);
  static const Color danger = Color(0xFFC7162B);

  static const Color orange = warning;
  static const Color red = danger;
}
