import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:woa_toolbox_core/woa_toolbox_core.dart';

import 'app_state.dart';

/// ウィザードページ。「Android（LineageOS）に戻す」と
/// Windows インストール（次フェーズ）の入口。
class WizardsPage extends StatefulWidget {
  const WizardsPage({super.key, required this.state});

  final AppState state;

  @override
  State<WizardsPage> createState() => _WizardsPageState();
}

class _WizardsPageState extends State<WizardsPage> {
  String? _lineageZipPath;

  static const _stepLabels = {
    ReturnStep.precondition: '前提検証',
    ReturnStep.restoreGpt: 'GPT 復元',
    ReturnStep.rebootRecovery: 'Recovery 再起動',
    ReturnStep.awaitSideload: 'sideload 待ち（端末操作）',
    ReturnStep.sideload: 'LineageOS を sideload',
    ReturnStep.done: '完了',
  };

  Future<void> _startReturnWizard() async {
    final state = widget.state;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Android（LineageOS）に戻します'),
        content: const Text(
          'GPT を Android レイアウトに戻し（esp / win は消えます）、'
          'LineageOS を sideload します。\n\n'
          '・Windows 側のデータは失われます\n'
          '・userdata は LineageOS の初回起動で初期化される前提です\n'
          '・書き込み前に現在の GPT は自動バックアップされます\n\n'
          '進めてもよいですか？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('開始する'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await state.runReturnToAndroid(_lineageZipPath!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final theme = Theme.of(context);
    final ready = state.canUseBackupOps &&
        state.loadedManifest != null &&
        _lineageZipPath != null;
    final currentStep = state.wizardStep;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          Text('ウィザード', style: theme.textTheme.titleLarge),
          const SizedBox(height: 16),
          Text('Android（LineageOS）に戻す',
              style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text('前提: Recovery で端末を選択し GPT を読み取り、'
              'バックアップ画面で Android 用バックアップ（manifest）を'
              '読み込んでおくこと。旧バックアップの取り込みでも可。'),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: state.busy
                    ? null
                    : () async {
                        final r = await FilePicker.platform.pickFiles(
                          type: FileType.custom,
                          allowedExtensions: ['zip'],
                        );
                        final p = r?.files.single.path;
                        if (p != null) setState(() => _lineageZipPath = p);
                      },
                icon: const Icon(Icons.folder_zip_outlined),
                label: const Text('LineageOS の zip を選ぶ'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_lineageZipPath ?? '未選択',
                    style: theme.textTheme.bodySmall),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (state.loadedManifest == null)
            const Text('※ バックアップが読み込まれていません（バックアップ画面へ）'),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: (state.busy || !ready) ? null : _startReturnWizard,
            icon: const Icon(Icons.settings_backup_restore),
            label: const Text('Android に戻すを開始'),
          ),
          if (state.error != null) ...[
            const SizedBox(height: 8),
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(state.error!),
              ),
            ),
          ],
          if (currentStep != null) ...[
            const SizedBox(height: 16),
            for (final entry in _stepLabels.entries)
              ListTile(
                dense: true,
                leading: Icon(
                  currentStep.index > entry.key.index
                      ? Icons.check_circle
                      : currentStep == entry.key
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                ),
                title: Text(entry.value),
                subtitle: currentStep == entry.key
                    ? Text(state.wizardMessage)
                    : null,
              ),
          ],
          const SizedBox(height: 24),
          Text('Windows インストール', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text('Windows インストールウィザードは次フェーズで実装します'
                  '（DISM 展開 → BCD 構築 → ドライバー注入の状態機械）。'),
            ),
          ),
        ],
      ),
    );
  }
}
