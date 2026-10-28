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
          const Divider(),
          _WindowsInstallSection(state: state),
        ],
      ),
    );
  }
}

/// Windows インストールウィザードのフォーム＋進捗。
class _WindowsInstallSection extends StatefulWidget {
  const _WindowsInstallSection({required this.state});

  final AppState state;

  @override
  State<_WindowsInstallSection> createState() =>
      _WindowsInstallSectionState();
}

class _WindowsInstallSectionState extends State<_WindowsInstallSection> {
  String? _winDir;
  String? _espDir;
  String? _wimPath;
  String? _packDir;
  String? _unattendPath;
  final _indexController = TextEditingController(text: '1');

  static const _stepLabels = {
    WinInstallStep.precondition: '前提検証',
    WinInstallStep.verifyWim: 'WIM 検証',
    WinInstallStep.applyImage: 'イメージ展開',
    WinInstallStep.buildBcd: 'BCD 構築',
    WinInstallStep.injectDrivers: 'ドライバー注入',
    WinInstallStep.placeUnattend: 'unattend 配置',
    WinInstallStep.verify: '検証',
    WinInstallStep.done: '完了',
  };

  @override
  void dispose() {
    _indexController.dispose();
    super.dispose();
  }

  Future<String?> _pickDir() => FilePicker.platform.getDirectoryPath();
  Future<String?> _pickFile(List<String> exts) async {
    final r = await FilePicker.platform
        .pickFiles(type: FileType.custom, allowedExtensions: exts);
    return r?.files.single.path;
  }

  Widget _pickerRow({
    required String label,
    required String? value,
    required VoidCallback onPick,
    VoidCallback? onClear,
  }) {
    return Row(
      children: [
        OutlinedButton.icon(
          onPressed: widget.state.busy ? null : onPick,
          icon: const Icon(Icons.folder_open_outlined),
          label: Text(label),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(value ?? '未選択')),
        if (value != null && onClear != null)
          IconButton(icon: const Icon(Icons.close), onPressed: onClear),
      ],
    );
  }

  Future<void> _start() async {
    final state = widget.state;
    final index = int.tryParse(_indexController.text) ?? 1;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Windows をインストールします'),
        content: Text(
          'win: $_winDir\n'
          'esp: $_espDir\n'
          'WIM: $_wimPath（インデックス $index）\n\n'
          '・win ボリュームへ新規展開します（既存 Windows がある場合は中止されます）\n'
          '・esp の既存 BCD は退避してから新規構築します\n'
          '・ドライバー注入時は qci2c の Start=4 を自動で再適用します\n\n'
          'アプリを管理者として実行している必要があります。進めますか？',
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
      await state.runWindowsInstall(
        winDir: _winDir!,
        espDir: _espDir!,
        wimPath: _wimPath!,
        imageIndex: index,
        driverPackDir: _packDir,
        unattendPath: _unattendPath,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final theme = Theme.of(context);
    final ready = _winDir != null && _espDir != null && _wimPath != null;
    final currentStep = state.winWizardStep;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Windows インストール', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text('前提: Recovery の Mass Storage で esp / win を PC に'
            '見せた状態で、それぞれのドライブを選ぶ。Windows 上でのみ動作'
            '（DISM 依存）。管理者として実行すること。'),
        const SizedBox(height: 8),
        _pickerRow(
          label: 'win ボリューム',
          value: _winDir,
          onPick: () async {
            final p = await _pickDir();
            if (p != null) setState(() => _winDir = p);
          },
        ),
        const SizedBox(height: 4),
        _pickerRow(
          label: 'esp ボリューム',
          value: _espDir,
          onPick: () async {
            final p = await _pickDir();
            if (p != null) setState(() => _espDir = p);
          },
        ),
        const SizedBox(height: 4),
        _pickerRow(
          label: 'install.wim',
          value: _wimPath,
          onPick: () async {
            final p = await _pickFile(['wim', 'esd']);
            if (p != null) setState(() => _wimPath = p);
          },
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            const Text('イメージ インデックス: '),
            SizedBox(
              width: 64,
              child: TextField(
                controller: _indexController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(isDense: true),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        _pickerRow(
          label: 'ドライバーパック（任意）',
          value: _packDir,
          onPick: () async {
            final p = await _pickDir();
            if (p != null) setState(() => _packDir = p);
          },
          onClear: () => setState(() => _packDir = null),
        ),
        const SizedBox(height: 4),
        _pickerRow(
          label: 'unattend.xml（任意）',
          value: _unattendPath,
          onPick: () async {
            final p = await _pickFile(['xml']);
            if (p != null) setState(() => _unattendPath = p);
          },
          onClear: () => setState(() => _unattendPath = null),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: (state.busy || !ready) ? null : _start,
          icon: const Icon(Icons.install_desktop_outlined),
          label: const Text('Windows インストールを開始'),
        ),
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
                  ? Text(state.winWizardMessage)
                  : null,
            ),
        ],
      ],
    );
  }
}
