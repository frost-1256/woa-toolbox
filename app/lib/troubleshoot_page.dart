import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:woa_toolbox_core/woa_toolbox_core.dart';

import 'app_state.dart';

/// トラブルシューティング画面（DESIGN.md §12）。
/// Gadget で見えている win / esp に対してオフライン診断を行い、
/// 検出された既知問題を選んで修復する。診断は読み取り専用で、
/// 書き込みは「修復」ボタンの明示操作＋確認ダイアログ経由のみ。
class TroubleshootPage extends StatefulWidget {
  const TroubleshootPage({super.key, required this.state});

  final AppState state;

  @override
  State<TroubleshootPage> createState() => _TroubleshootPageState();
}

class _TroubleshootPageState extends State<TroubleshootPage> {
  String? _winDir;
  String? _espDir;
  bool _busy = false;
  String? _error;
  TroubleshootReport? _report;
  final Set<String> _selected = {};
  final List<String> _progress = [];

  Troubleshooter _shooter() => Troubleshooter(
    runner: const ProcessCommandRunner(),
    winDir: _winDir!,
    espDir: _espDir!,
  );

  IconData _statusIcon(FindingStatus s) => switch (s) {
    FindingStatus.detected => Icons.error_outline,
    FindingStatus.ok => Icons.check_circle_outline,
    FindingStatus.notApplicable => Icons.remove_circle_outline,
    FindingStatus.unknown => Icons.help_outline,
  };

  Color? _statusColor(BuildContext context, FindingStatus s) => switch (s) {
    FindingStatus.detected => Theme.of(context).colorScheme.error,
    FindingStatus.ok => null,
    FindingStatus.notApplicable => Theme.of(context).colorScheme.outline,
    FindingStatus.unknown => Theme.of(context).colorScheme.tertiary,
  };

  String _statusLabel(FindingStatus s) => switch (s) {
    FindingStatus.detected => '該当',
    FindingStatus.ok => '正常',
    FindingStatus.notApplicable => '対象外',
    FindingStatus.unknown => '判定不能',
  };

  Future<void> _diagnose() async {
    setState(() {
      _busy = true;
      _error = null;
      _progress.clear();
    });
    try {
      final report = await _shooter().diagnose();
      if (!mounted) return;
      setState(() {
        _report = report;
        _selected
          ..clear()
          // OOBE 完了扱いだけは自動選択しない。アカウント未作成のまま
          // OOBE を飛ばす副作用があるため、利用者が明示的にチェック
          // した場合だけ修復対象にする（H1）。
          ..addAll(
            report.findings
                .where(
                  (f) =>
                      f.status == FindingStatus.detected &&
                      f.fixable &&
                      f.id != IssueId.oobeIncomplete,
                )
                .map((f) => f.id),
          );
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _fix() async {
    final ids = Set<String>.from(_selected);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('選択した問題を修復します'),
        content: Text(
          '${ids.length} 件の修復をオフラインで適用します。\n\n'
          '・SYSTEM ハイブは編集前に自動バックアップされます\n'
          '・各値は書き込み後に読み戻して検証されます\n'
          '・OOBE 完了扱い（ChildCompletion）は、アカウント未作成の'
          'ままログオン画面へ進む場合があります\n\n'
          '進めてもよいですか？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('修復する'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _busy = true;
      _error = null;
      _progress.clear();
    });
    try {
      final report = await _shooter().applyFixes(
        ids,
        onProgress: (m) {
          if (mounted) setState(() => _progress.add(m));
        },
      );
      if (!mounted) return;
      setState(() {
        _report = report;
        _selected.clear();
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _pickerRow({
    required String label,
    required String? value,
    required void Function(String) onPicked,
  }) {
    return Row(
      children: [
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () async {
                  final p = await FilePicker.platform.getDirectoryPath();
                  if (p != null) onPicked(p);
                },
          icon: const Icon(Icons.folder_open_outlined),
          label: Text(label),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(value ?? '未選択')),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = _winDir != null && _espDir != null;
    final report = _report;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          Text('トラブルシューティング', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text(
            '前提: Recovery の Mass Storage で esp / win を PC に'
            '見せた状態で、それぞれのドライブを選ぶ。Windows 上でのみ動作'
            '（reg.exe 依存）。管理者として実行すること。診断は読み取り'
            '専用で、状態は変わりません。',
          ),
          if (!Platform.isWindows) ...[
            const SizedBox(height: 8),
            const Text('※ このホストは Windows ではないため実行できません'),
          ],
          const SizedBox(height: 12),
          _pickerRow(
            label: 'win ボリューム',
            value: _winDir,
            onPicked: (p) => setState(() => _winDir = p),
          ),
          const SizedBox(height: 4),
          _pickerRow(
            label: 'esp ボリューム',
            value: _espDir,
            onPicked: (p) => setState(() => _espDir = p),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.icon(
                onPressed: (_busy || !ready || !Platform.isWindows)
                    ? null
                    : _diagnose,
                icon: const Icon(Icons.health_and_safety_outlined),
                label: const Text('診断する'),
              ),
              const SizedBox(width: 8),
              if (_busy) const CircularProgressIndicator(),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_error!),
              ),
            ),
          ],
          if (report != null) ...[
            const SizedBox(height: 16),
            Text('診断結果', style: theme.textTheme.titleMedium),
            for (final f in report.findings)
              CheckboxListTile(
                value: _selected.contains(f.id),
                onChanged: (f.status == FindingStatus.detected && f.fixable)
                    ? (v) => setState(() {
                        if (v == true) {
                          _selected.add(f.id);
                        } else {
                          _selected.remove(f.id);
                        }
                      })
                    : null,
                secondary: Icon(
                  _statusIcon(f.status),
                  color: _statusColor(context, f.status),
                ),
                title: Text('${f.title}（${_statusLabel(f.status)}）'),
                subtitle: Text(f.detail),
                controlAffinity: ListTileControlAffinity.leading,
              ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: (_busy || _selected.isEmpty) ? null : _fix,
              icon: const Icon(Icons.build_outlined),
              label: Text('選択した問題を修復（${_selected.length} 件）'),
            ),
            if (report.notes.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('診断メモ', style: theme.textTheme.titleMedium),
              for (final n in report.notes)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.notes_outlined),
                  title: Text(n),
                ),
            ],
          ],
          if (_progress.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('修復ログ', style: theme.textTheme.titleMedium),
            for (final p in _progress)
              ListTile(
                dense: true,
                leading: const Icon(Icons.check),
                title: Text(p),
              ),
          ],
        ],
      ),
    );
  }
}
