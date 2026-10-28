import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:woa_toolbox_core/woa_toolbox_core.dart';

import 'app_state.dart';

/// プランのプレビューと確認（設計書 §2: Plan → Preview → Confirm → Execute）。
/// 破壊的操作ではチェックボックスを入れるまで実行できない。
class PlanPreviewDialog extends StatefulWidget {
  const PlanPreviewDialog({super.key, required this.plan, required this.serial});

  final OperationPlan plan;
  final String serial;

  @override
  State<PlanPreviewDialog> createState() => _PlanPreviewDialogState();
}

class _PlanPreviewDialogState extends State<PlanPreviewDialog> {
  bool _checked = false;

  @override
  Widget build(BuildContext context) {
    final plan = widget.plan;
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(plan.title),
      content: SizedBox(
        width: 580,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (plan.destructive) ...[
                Card(
                  color: theme.colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text('この操作は端末へ書き込みます。\n'
                        '対象シリアル: ${widget.serial}\n'
                        'プランの有効期限: ${plan.expiresAt.toLocal()}'),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              for (final w in plan.warnings)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.warning_amber),
                  title: Text(w),
                ),
              if (plan.diff != null) ...[
                Text('GPT 差分（${plan.diff!.changes.length} 件）',
                    style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                if (plan.diff!.isEmpty) const Text('差分はありません'),
                for (final c in plan.diff!.changes)
                  ListTile(
                    dense: true,
                    leading: Icon(switch (c.kind) {
                      GptChangeKind.added => Icons.add_circle_outline,
                      GptChangeKind.removed => Icons.remove_circle_outline,
                      GptChangeKind.resized => Icons.swap_horiz,
                      GptChangeKind.moved => Icons.open_with,
                      GptChangeKind.typeChanged => Icons.label_outline,
                    }),
                    title: Text(c.name),
                    subtitle: Text(c.detail),
                  ),
                const SizedBox(height: 8),
              ],
              Text('実行ステップ', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              for (final (i, s) in plan.steps.indexed) ...[
                Text('${i + 1}. ${s.description}'),
                Padding(
                  padding: const EdgeInsets.only(left: 16, bottom: 6),
                  child: Text(
                    s.commandPreview,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(fontFamily: 'monospace'),
                  ),
                ),
              ],
              if (plan.destructive)
                CheckboxListTile(
                  value: _checked,
                  onChanged: (v) => setState(() => _checked = v ?? false),
                  title: const Text('対象端末と内容を確認しました'),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: (plan.destructive && !_checked)
              ? null
              : () => Navigator.pop(context, true),
          child: const Text('実行する'),
        ),
      ],
    );
  }
}

/// 旧バックアップ取り込みダイアログ。GPT ダンプ（任意）と
/// パーティションイメージファイル群を選ぶ。パーティション名は
/// ファイル名（拡張子なし）から決まる。
class LegacyImportDialog extends StatefulWidget {
  const LegacyImportDialog({super.key});

  @override
  State<LegacyImportDialog> createState() => _LegacyImportDialogState();
}

class _LegacyImportDialogState extends State<LegacyImportDialog> {
  String? _gptPath;
  final Map<String, String> _partitions = {};

  String _stem(String path) {
    final base = path.split(RegExp(r'[\\/]')).last;
    final dot = base.lastIndexOf('.');
    return dot > 0 ? base.substring(0, dot) : base;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('旧バックアップを取り込む'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('手作業で取得したバックアップを Toolbox 形式に変換します。'
                'バックアップ GPT はプライマリから合成されます。'),
            const SizedBox(height: 12),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: () async {
                    final r = await FilePicker.platform.pickFiles();
                    final p = r?.files.single.path;
                    if (p != null) setState(() => _gptPath = p);
                  },
                  icon: const Icon(Icons.description_outlined),
                  label: const Text('GPT ダンプを選ぶ'),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_gptPath == null
                      ? '未選択（任意）'
                      : _gptPath!.split(RegExp(r'[\\/]')).last),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: () async {
                    final r = await FilePicker.platform
                        .pickFiles(allowMultiple: true);
                    if (r != null) {
                      setState(() {
                        for (final f in r.files) {
                          if (f.path != null) {
                            _partitions[_stem(f.path!)] = f.path!;
                          }
                        }
                      });
                    }
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('パーティションを追加'),
                ),
              ],
            ),
            for (final e in _partitions.entries)
              ListTile(
                dense: true,
                title: Text(e.key),
                subtitle: Text(e.value),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () =>
                      setState(() => _partitions.remove(e.key)),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: (_gptPath == null && _partitions.isEmpty)
              ? null
              : () => Navigator.pop(
                    context,
                    (gptPath: _gptPath, partitions: _partitions),
                  ),
          child: const Text('取り込む'),
        ),
      ],
    );
  }
}

/// バックアップ / 復元ページ（Phase 2）。
class BackupsPage extends StatefulWidget {
  const BackupsPage({super.key, required this.state});

  final AppState state;

  @override
  State<BackupsPage> createState() => _BackupsPageState();
}

class _BackupsPageState extends State<BackupsPage> {
  static const _candidates = ['persist', 'metadata', 'frp', 'esp', 'win'];
  final Set<String> _selected = {'persist', 'metadata', 'frp'};

  Future<void> _confirmAndRun(
    OperationPlan Function() build,
    Future<void> Function(OperationPlan) run,
  ) async {
    final state = widget.state;
    final OperationPlan plan;
    try {
      plan = build();
    } catch (e) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('計画を作成できません'),
          content: Text('$e'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('閉じる'),
            ),
          ],
        ),
      );
      return;
    }
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) =>
          PlanPreviewDialog(plan: plan, serial: state.selected?.serial ?? ''),
    );
    if (ok == true) await run(plan);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final theme = Theme.of(context);
    final available = _candidates
        .where((n) => state.primaryTable?.hasPartition(n) ?? false)
        .toList();
    final effectiveSelected =
        _selected.where(available.contains).toList();
    final manifest = state.loadedManifest;
    final hasGptFiles = manifest != null &&
        manifest.files.any((f) => f.partitionName == 'gpt-primary') &&
        manifest.files.any((f) => f.partitionName == 'gpt-backup');

    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          Text('バックアップ / 復元', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          if (!state.canUseBackupOps)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Text('Recovery モードで端末を選び、GPT を読み取ると使えます。'
                    '実行はすべて Plan → プレビュー → 確認の順で行われます。'),
              ),
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
          const SizedBox(height: 16),
          Text('バックアップ', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.icon(
                onPressed: (state.busy || !state.canUseBackupOps)
                    ? null
                    : () => _confirmAndRun(
                          state.buildBackupGptPlan,
                          state.executeBackupPlan,
                        ),
                icon: const Icon(Icons.save_outlined),
                label: const Text('GPT をバックアップ'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: (state.busy ||
                        !state.canUseBackupOps ||
                        effectiveSelected.isEmpty)
                    ? null
                    : () => _confirmAndRun(
                          () => state
                              .buildBackupPartitionsPlan(effectiveSelected),
                          state.executeBackupPlan,
                        ),
                icon: const Icon(Icons.save_alt),
                label: const Text('選択中をバックアップ'),
              ),
            ],
          ),
          for (final name in available)
            CheckboxListTile(
              dense: true,
              value: _selected.contains(name),
              onChanged: (v) => setState(() {
                if (v ?? false) {
                  _selected.add(name);
                } else {
                  _selected.remove(name);
                }
              }),
              title: Text(name),
              subtitle: Text(
                  'LBA ${state.primaryTable!.partitionByName(name)!.firstLba}–'
                  '${state.primaryTable!.partitionByName(name)!.lastLba}'),
            ),
          const SizedBox(height: 24),
          Text('復元', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: state.busy
                    ? null
                    : () async {
                        final result = await FilePicker.platform.pickFiles(
                          type: FileType.custom,
                          allowedExtensions: ['json'],
                        );
                        final path = result?.files.single.path;
                        if (path != null) {
                          await state.loadBackupManifest(path);
                        }
                      },
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('manifest.json を選ぶ'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: (state.busy || !state.canUseBackupOps)
                    ? null
                    : () async {
                        final result =
                            await showDialog<({String? gptPath, Map<String, String> partitions})>(
                          context: context,
                          builder: (context) => const LegacyImportDialog(),
                        );
                        if (result != null) {
                          await state.importLegacyBackup(
                            gptDumpPath: result.gptPath,
                            partitionPaths: result.partitions,
                          );
                        }
                      },
                icon: const Icon(Icons.input),
                label: const Text('旧バックアップを取り込む'),
              ),
              const SizedBox(width: 12),
              if (manifest != null)
                Expanded(
                  child: Text(
                    'シリアル ${manifest.deviceSerial} / ${manifest.productDevice} / '
                    '${manifest.createdAt.toLocal()} / ${manifest.files.length} ファイル\n'
                    '${state.loadedBackupDirPath}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ],
          ),
          if (manifest != null) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: (state.busy || !state.canUseBackupOps || !hasGptFiles)
                  ? null
                  : () => _confirmAndRun(
                        state.buildRestoreGptPlan,
                        state.executeRestoreGptPlan,
                      ),
              icon: const Icon(Icons.restore),
              label: const Text('GPT を復元'),
            ),
            const SizedBox(height: 8),
            for (final entry in manifest.files.where((f) =>
                f.partitionName != 'gpt-primary' &&
                f.partitionName != 'gpt-backup'))
              ListTile(
                dense: true,
                title: Text(entry.partitionName),
                subtitle: Text('${entry.fileName} / ${entry.sizeBytes} バイト / '
                    'sha256 ${entry.sha256.substring(0, 12)}…'),
                trailing: OutlinedButton(
                  onPressed: (state.busy || !state.canUseBackupOps)
                      ? null
                      : () => _confirmAndRun(
                            () => state.buildRestorePartitionPlan(entry),
                            (plan) =>
                                state.executeRestorePartitionPlan(plan, entry),
                          ),
                  child: const Text('書き戻す'),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
