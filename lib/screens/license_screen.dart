import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../models/license_state.dart';
import '../routes/app_routes.dart';
import '../services/license_service.dart';
import '../theme/app_colors.dart';

/// Full-screen gate shown when the trial/license is missing or expired.
class LicenseScreen extends GetView<LicenseService> {
  const LicenseScreen({super.key});

  static const String supportEmail = 'rpfinser24@gmail.com';

  @override
  Widget build(BuildContext context) {
    final keyController = TextEditingController();
    return Scaffold(
      backgroundColor: context.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Obx(() {
                    if (controller.status.value == LicenseStatus.active) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        Get.offAllNamed(AppRoutes.home);
                      });
                    }
                    return const SizedBox.shrink();
                  }),
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      gradient: AppColors.accentGradient,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: const Icon(Icons.bolt_rounded, size: 40, color: Colors.white),
                  ),
                  const SizedBox(height: 20),
                  Text('RankRocket AI',
                      style: TextStyle(
                          fontSize: 24, fontWeight: FontWeight.w700, color: context.text)),
                  const SizedBox(height: 6),
                  Obx(() {
                    final st = controller.status.value;
                    if (st == LicenseStatus.offline) {
                      return Text(
                        'Cannot verify your license. Check your internet connection and try again.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14, color: context.textM),
                      );
                    }
                    return Text(
                      'Your trial or license has expired.',
                      style: TextStyle(fontSize: 14, color: context.textM),
                    );
                  }),
                  const SizedBox(height: 28),
                  Text('Your device code',
                      style: TextStyle(fontSize: 12, color: context.textD)),
                  const SizedBox(height: 8),
                  Obx(() {
                    final code = controller.info.value?.deviceCode ?? '';
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      decoration: BoxDecoration(
                        color: context.bgPanel,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(code,
                              style: const TextStyle(
                                  fontSize: 22, letterSpacing: 2, fontWeight: FontWeight.w700,
                                  fontFamily: 'monospace')),
                          if (code.isNotEmpty)
                            IconButton(
                              icon: const Icon(Icons.copy_rounded, size: 18),
                              onPressed: () => Clipboard.setData(ClipboardData(text: code)),
                            ),
                        ],
                      ),
                    );
                  }),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: context.bgPanel,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: context.border),
                    ),
                    child: Column(
                      children: [
                        const Icon(Icons.mail_outline_rounded, color: AppColors.accent),
                        const SizedBox(height: 8),
                        Text('Email $supportEmail with your device code to get a license key.',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 13, color: context.textM)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: keyController,
                    textCapitalization: TextCapitalization.characters,
                    style: const TextStyle(fontFamily: 'monospace', letterSpacing: 1),
                    decoration: InputDecoration(
                      labelText: 'License key',
                      hintText: 'RR-XXXX-XXXX-XXXX',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Obx(() {
                    final err = controller.activateError.value;
                    if (err.isEmpty) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(err,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 12, color: AppColors.red)),
                    );
                  }),
                  Obx(() => SizedBox(
                        width: double.infinity,
                        height: 46,
                        child: ElevatedButton(
                          onPressed: controller.activating.value
                              ? null
                              : () => controller.activate(keyController.text.trim()),
                          child: controller.activating.value
                              ? const SizedBox(
                                  width: 20, height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2))
                              : const Text('Activate'),
                        ),
                      )),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
