import 'gpt.dart';

enum GptChangeKind { added, removed, resized, moved, typeChanged }

/// GPT レイアウト間の 1 件の差分（復元プレビュー表示用）。
class GptChange {
  const GptChange({
    required this.kind,
    required this.name,
    required this.detail,
    this.before,
    this.after,
  });

  final GptChangeKind kind;
  final String name;
  final String detail;
  final GptPartition? before;
  final GptPartition? after;
}

/// 2 つの GPT レイアウトの差分。
class GptDiff {
  const GptDiff(this.changes);

  final List<GptChange> changes;

  bool get isEmpty => changes.isEmpty;
}

String _sizeText(GptPartition p, int sectorSize) {
  final mib = p.sizeLbas * sectorSize / (1024 * 1024);
  return '${p.firstLba}–${p.lastLba} (${mib.toStringAsFixed(1)} MiB)';
}

/// [before] → [after] の差分をパーティション名をキーに作る。
/// 復元計画のプレビュー（設計書 §4.2: 書き込み直前に GPT 全体の diff を
/// 必ず表示する）で使う。
GptDiff diffGpt(GptTable before, GptTable after) {
  final changes = <GptChange>[];
  final sectorSize = before.sectorSize;
  final beforeByName = {for (final p in before.partitions) p.name: p};
  final afterByName = {for (final p in after.partitions) p.name: p};

  for (final p in after.partitions) {
    final old = beforeByName[p.name];
    if (old == null) {
      changes.add(GptChange(
        kind: GptChangeKind.added,
        name: p.name,
        detail: '追加: ${_sizeText(p, sectorSize)}',
        after: p,
      ));
      continue;
    }
    if (old.typeGuid != p.typeGuid) {
      changes.add(GptChange(
        kind: GptChangeKind.typeChanged,
        name: p.name,
        detail: 'タイプ GUID 変更: ${old.typeGuid} → ${p.typeGuid}',
        before: old,
        after: p,
      ));
    }
    if (old.sizeLbas != p.sizeLbas) {
      changes.add(GptChange(
        kind: GptChangeKind.resized,
        name: p.name,
        detail: 'サイズ変更: ${_sizeText(old, sectorSize)} → ${_sizeText(p, sectorSize)}',
        before: old,
        after: p,
      ));
    } else if (old.firstLba != p.firstLba) {
      changes.add(GptChange(
        kind: GptChangeKind.moved,
        name: p.name,
        detail: '移動: ${_sizeText(old, sectorSize)} → ${_sizeText(p, sectorSize)}',
        before: old,
        after: p,
      ));
    }
  }
  for (final p in before.partitions) {
    if (!afterByName.containsKey(p.name)) {
      changes.add(GptChange(
        kind: GptChangeKind.removed,
        name: p.name,
        detail: '削除: ${_sizeText(p, sectorSize)}',
        before: p,
      ));
    }
  }
  return GptDiff(changes);
}
