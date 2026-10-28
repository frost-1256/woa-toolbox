import 'dart:typed_data';

import 'gpt.dart';

/// LBA 単位でブロックデバイスを読む抽象化。
/// 実機（adb exec-out dd）とテスト（メモリイメージ）で実装を差し替える。
abstract interface class LbaReader {
  /// 論理セクタサイズ（バイト）。実機検出した値。
  int get sectorSize;

  /// ディスク総 LBA 数。
  int get totalLbas;

  /// [startLba] から [count] セクタを読む。返るバイト数は正確に
  /// count × sectorSize でなければならない（転送完全性の検証は実装側）。
  Future<Uint8List> readLbas(int startLba, int count);
}

/// メモリ上のディスクイメージに対する LbaReader（テスト・ファイル検証用）。
class MemoryLbaReader implements LbaReader {
  MemoryLbaReader(this.image, {required this.sectorSize});

  final Uint8List image;

  @override
  final int sectorSize;

  @override
  int get totalLbas => image.length ~/ sectorSize;

  @override
  Future<Uint8List> readLbas(int startLba, int count) async {
    final start = startLba * sectorSize;
    final end = start + count * sectorSize;
    if (start < 0 || end > image.length) {
      throw RangeError('LBA 範囲外: $startLba +$count (total $totalLbas)');
    }
    return Uint8List.sublistView(image, start, end);
  }
}

/// LbaReader 経由で GPT を読む高レベル API（設計書 §4.1 の2段階読み）。
class GptReader {
  /// プライマリ GPT: まず先頭2セクタでヘッダーを読み、エントリ配列の
  /// 大きさが分かってから残りを読む。
  static Future<GptTable> readPrimary(LbaReader reader) async {
    final head = await reader.readLbas(0, 2);
    // ヘッダーは LBA1 = 先頭から1セクタ目にある。
    final probe = _ProbeHeader(head, reader.sectorSize, reader.sectorSize);
    final entrySectors = probe.entryArraySectors;
    final totalHeadSectors = probe.partitionEntryLba + entrySectors;
    final Uint8List full;
    if (totalHeadSectors <= 2) {
      full = head;
    } else {
      full = await reader.readLbas(0, totalHeadSectors);
    }
    return GptParser.parsePrimary(full, sectorSize: reader.sectorSize);
  }

  /// バックアップ GPT: 最終セクタのヘッダーを先に読み、エントリ配列の
  /// 位置を確定させてから配列ごと読む。
  static Future<GptTable> readBackup(LbaReader reader) async {
    final lastLba = reader.totalLbas - 1;
    final tail = await reader.readLbas(lastLba, 1);
    final probe = _ProbeHeader(tail, 0, reader.sectorSize);
    final entrySectors = probe.entryArraySectors;
    final start = probe.partitionEntryLba;
    if (start + entrySectors + 1 != reader.totalLbas) {
      throw GptFormatException(
          'バックアップ GPT の配置が想定と異なります (entries@$start +$entrySectors, total ${reader.totalLbas})');
    }
    final region = await reader.readLbas(start, entrySectors + 1);
    return GptParser.parseBackup(region,
        sectorSize: reader.sectorSize, totalLbas: reader.totalLbas);
  }

  /// プライマリとバックアップの両方を読み、整合まで確認した結果を返す。
  static Future<({GptTable primary, GptTable backup, bool consistent})>
      readBoth(LbaReader reader) async {
    final primary = await readPrimary(reader);
    final backup = await readBackup(reader);
    return (
      primary: primary,
      backup: backup,
      consistent: gptTablesMatch(primary, backup),
    );
  }
}

/// 完全な検証をせずにヘッダーの配置情報だけを読む内部用プローブ。
class _ProbeHeader {
  _ProbeHeader(Uint8List bytes, int offset, int sectorSize) {
    final d = ByteData.sublistView(bytes, offset, offset + 92);
    final sig = String.fromCharCodes(bytes.sublist(offset, offset + 8));
    if (sig != 'EFI PART') {
      throw GptFormatException('GPT シグネチャが見つかりません: "$sig"');
    }
    partitionEntryLba = d.getUint64(72, Endian.little);
    final num = d.getUint32(80, Endian.little);
    final size = d.getUint32(84, Endian.little);
    entryArraySectors = (num * size + sectorSize - 1) ~/ sectorSize;
  }

  late final int partitionEntryLba;
  late final int entryArraySectors;
}
