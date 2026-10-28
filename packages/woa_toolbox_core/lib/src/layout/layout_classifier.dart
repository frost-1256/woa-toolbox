import '../gpt/gpt.dart';

/// パーティション構成から推定したレイアウト種別（ダッシュボードのバッジ）。
enum PartitionLayout {
  /// esp / win を持つ WoA 構成。
  woa,

  /// userdata のみを持つ Android（stock / LineageOS）構成。
  android,

  /// どちらとも判定できない。
  unknown,
}

PartitionLayout classifyLayout(GptTable table) {
  final hasEsp = table.hasPartition('esp');
  final hasWin = table.hasPartition('win');
  final hasUserdata = table.hasPartition('userdata');
  if (hasEsp && hasWin) return PartitionLayout.woa;
  if (hasUserdata && !hasEsp && !hasWin) return PartitionLayout.android;
  return PartitionLayout.unknown;
}
