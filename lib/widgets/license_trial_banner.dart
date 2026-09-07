import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../models/license_state.dart';
import '../services/license_service.dart';
import '../theme/app_colors.dart';

/// Slim banner shown while the 30-day trial is active.
class LicenseTrialBanner extends GetView<LicenseService> {
  const LicenseTrialBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (controller.status.value != LicenseStatus.trial) {
        return const SizedBox.shrink();
      }
      final days = controller.info.value?.daysLeft ?? 0;
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        color: AppColors.orange.withValues(alpha: 0.12),
        child: Text(
          'Trial: $days day${days == 1 ? '' : 's'} left — email rpfinserv24@gmail.com for a license key',
          style: const TextStyle(fontSize: 12, color: AppColors.orange),
          textAlign: TextAlign.center,
        ),
      );
    });
  }
}
