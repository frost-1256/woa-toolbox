import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../crc32.dart';

/// GPT の解析に失敗した理由を表す例外。
class GptFormatException implements Exception {
  GptFormatException(this.message);
  final String message;
  @override
  String toString() => 'GptFormatException: $message';
}

/// GPT の GUID（先頭3フィールドがリトルエンディアン）を文字列化する。
String formatGuid(Uint8List bytes, int offset) {
  final d = ByteData.sublistView(bytes, offset, offset + 16);
  String h(int v, int w) => v.toRadixString(16).padLeft(w, '0');
  final p1 = h(d.getUint32(0, Endian.little), 8);
  final p2 = h(d.getUint16(4, Endian.little), 4);
  final p3 = h(d.getUint16(6, Endian.little), 4);
  final rest = StringBuffer();
  for (var i = 8; i < 16; i++) {
    if (i == 10) rest.write('-');
    rest.write(h(bytes[offset + i], 2));
  }
  return '$p1-$p2-$p3-$rest';
}

bool _isZeroGuid(Uint8List bytes, int offset) {
  for (var i = 0; i < 16; i++) {
    if (bytes[offset + i] != 0) return false;
  }
  return true;
}

class GptHeader {
  const GptHeader({
    required this.revision,
    required this.headerSize,
    required this.myLba,
    required this.alternateLba,
    required this.firstUsableLba,
    required this.lastUsableLba,
    required this.diskGuid,
    required this.partitionEntryLba,
    required this.numberOfPartitionEntries,
    required this.sizeOfPartitionEntry,
    required this.partitionEntryArrayCrc32,
  });

  final int revision;
  final int headerSize;
  final int myLba;
  final int alternateLba;
  final int firstUsableLba;
  final int lastUsableLba;
  final String diskGuid;
  final int partitionEntryLba;
  final int numberOfPartitionEntries;
  final int sizeOfPartitionEntry;
  final int partitionEntryArrayCrc32;

  /// エントリ配列が占めるバイト数。
  int get entryArrayBytes => numberOfPartitionEntries * sizeOfPartitionEntry;

  /// エントリ配列が占めるセクタ数（切り上げ）。
  int entryArraySectors(int sectorSize) =>
      (entryArrayBytes + sectorSize - 1) ~/ sectorSize;
}

class GptPartition {
  const GptPartition({
    required this.index,
    required this.typeGuid,
    required this.uniqueGuid,
    required this.firstLba,
    required this.lastLba,
    required this.attributes,
    required this.name,
  });

  final int index;
  final String typeGuid;
  final String uniqueGuid;
  final int firstLba;
  final int lastLba;
  final int attributes;
  final String name;

  int get sizeLbas => lastLba - firstLba + 1;
  int sizeBytes(int sectorSize) => sizeLbas * sectorSize;
}

/// 検証済み GPT テーブル（プライマリまたはバックアップ）。
class GptTable {
  const GptTable({
    required this.header,
    required this.partitions,
    required this.sectorSize,
    required this.isBackup,
  });

  final GptHeader header;
  final List<GptPartition> partitions;
  final int sectorSize;
  final bool isBackup;

  GptPartition? partitionByName(String name) {
    for (final p in partitions) {
      if (p.name == name) return p;
    }
    return null;
  }

  bool hasPartition(String name) => partitionByName(name) != null;

  /// レイアウトのフィンガープリント（プラン束縛・バックアップ検証用）。
  /// ディスク GUID と全パーティションの (名前, 開始, 終了) から SHA-256 を作る。
  String get fingerprint {
    final b = StringBuffer()
      ..write(header.diskGuid)
      ..write('|');
    for (final p in partitions) {
      b.write('${p.name}:${p.firstLba}-${p.lastLba};');
    }
    return sha256.convert(utf8.encode(b.toString())).toString();
  }
}

/// プライマリとバックアップが同じレイアウトを指しているか。
bool gptTablesMatch(GptTable a, GptTable b) {
  if (a.header.diskGuid != b.header.diskGuid) return false;
  if (a.partitions.length != b.partitions.length) return false;
  for (var i = 0; i < a.partitions.length; i++) {
    final x = a.partitions[i];
    final y = b.partitions[i];
    if (x.typeGuid != y.typeGuid ||
        x.uniqueGuid != y.uniqueGuid ||
        x.firstLba != y.firstLba ||
        x.lastLba != y.lastLba ||
        x.name != y.name) {
      return false;
    }
  }
  return true;
}

/// GPT パーサー。セクタサイズは呼び出し側が実機検出した値を与える
/// （設計書 §4.1：固定値にしない）。
class GptParser {
  static const _signature = 'EFI PART';

  /// プライマリ GPT を解析する。
  /// [bytes] はディスク先頭から、エントリ配列の終わりまでを含むこと。
  static GptTable parsePrimary(Uint8List bytes, {required int sectorSize}) {
    _requireLength(bytes, sectorSize * 2, 'プライマリ GPT ヘッダー');
    final header = _parseHeader(bytes, sectorSize, sectorSize);
    if (header.myLba != 1) {
      throw GptFormatException(
          'プライマリヘッダーの現在 LBA が 1 ではありません: ${header.myLba}');
    }
    final entriesOffset = header.partitionEntryLba * sectorSize;
    final partitions =
        _parseEntries(bytes, entriesOffset, header, sectorSize);
    return GptTable(
      header: header,
      partitions: partitions,
      sectorSize: sectorSize,
      isBackup: false,
    );
  }

  /// バックアップ GPT を解析する。
  /// [bytes] は「エントリ配列の先頭からディスク末尾まで」を含むこと。
  /// [totalLbas] はディスク総 LBA 数（容量バイト数 / セクタサイズ）。
  static GptTable parseBackup(
    Uint8List bytes, {
    required int sectorSize,
    required int totalLbas,
  }) {
    _requireLength(bytes, sectorSize, 'バックアップ GPT ヘッダー');
    final headerOffsetInBuffer = bytes.length - sectorSize;
    final header = _parseHeader(bytes, headerOffsetInBuffer, sectorSize);
    if (header.myLba != totalLbas - 1) {
      throw GptFormatException(
          'バックアップヘッダーの現在 LBA (${header.myLba}) が最終 LBA (${totalLbas - 1}) と一致しません');
    }
    final arraySectors = header.entryArraySectors(sectorSize);
    final expectedStartLba = totalLbas - 1 - arraySectors;
    if (header.partitionEntryLba != expectedStartLba) {
      throw GptFormatException(
          'バックアップのエントリ開始 LBA (${header.partitionEntryLba}) が想定 ($expectedStartLba) と一致しません');
    }
    final partitions = _parseEntries(bytes, 0, header, sectorSize);
    return GptTable(
      header: header,
      partitions: partitions,
      sectorSize: sectorSize,
      isBackup: true,
    );
  }

  static void _requireLength(Uint8List bytes, int needed, String what) {
    if (bytes.length < needed) {
      throw GptFormatException('$whatを読むには $needed バイト必要ですが ${bytes.length} バイトしかありません');
    }
  }

  static GptHeader _parseHeader(
      Uint8List bytes, int offset, int sectorSize) {
    _requireLength(bytes, offset + 92, 'GPT ヘッダー');
    final sig = ascii.decode(bytes.sublist(offset, offset + 8));
    if (sig != _signature) {
      throw GptFormatException('GPT シグネチャが不正です: "$sig"');
    }
    final d = ByteData.sublistView(bytes, offset, offset + 92);
    final headerSize = d.getUint32(12, Endian.little);
    if (headerSize < 92 || headerSize > sectorSize) {
      throw GptFormatException('ヘッダーサイズが不正です: $headerSize');
    }
    final storedCrc = d.getUint32(16, Endian.little);
    // CRC フィールドを 0 にしてヘッダー CRC を検証する。
    final headerBytes = Uint8List.fromList(bytes.sublist(offset, offset + headerSize));
    headerBytes[16] = 0;
    headerBytes[17] = 0;
    headerBytes[18] = 0;
    headerBytes[19] = 0;
    final computedCrc = Crc32.compute(headerBytes);
    if (computedCrc != storedCrc) {
      throw GptFormatException(
          'ヘッダー CRC 不一致: 記録 ${storedCrc.toRadixString(16)} / 計算 ${computedCrc.toRadixString(16)}');
    }
    final header = GptHeader(
      revision: d.getUint32(8, Endian.little),
      headerSize: headerSize,
      myLba: d.getUint64(24, Endian.little),
      alternateLba: d.getUint64(32, Endian.little),
      firstUsableLba: d.getUint64(40, Endian.little),
      lastUsableLba: d.getUint64(48, Endian.little),
      diskGuid: formatGuid(bytes, offset + 56),
      partitionEntryLba: d.getUint64(72, Endian.little),
      numberOfPartitionEntries: d.getUint32(80, Endian.little),
      sizeOfPartitionEntry: d.getUint32(84, Endian.little),
      partitionEntryArrayCrc32: d.getUint32(88, Endian.little),
    );
    if (header.sizeOfPartitionEntry < 128 ||
        header.sizeOfPartitionEntry % 8 != 0) {
      throw GptFormatException(
          'パーティションエントリサイズが不正です: ${header.sizeOfPartitionEntry}');
    }
    if (header.numberOfPartitionEntries == 0 ||
        header.numberOfPartitionEntries > 1024) {
      throw GptFormatException(
          'パーティションエントリ数が想定外です: ${header.numberOfPartitionEntries}');
    }
    return header;
  }

  static List<GptPartition> _parseEntries(
    Uint8List bytes,
    int entriesOffset,
    GptHeader header,
    int sectorSize,
  ) {
    final arrayBytes = header.entryArrayBytes;
    _requireLength(bytes, entriesOffset + arrayBytes, 'パーティションエントリ配列');
    final computedCrc =
        Crc32.compute(bytes, entriesOffset, entriesOffset + arrayBytes);
    if (computedCrc != header.partitionEntryArrayCrc32) {
      throw GptFormatException(
          'エントリ配列 CRC 不一致: 記録 ${header.partitionEntryArrayCrc32.toRadixString(16)} / 計算 ${computedCrc.toRadixString(16)}');
    }
    final partitions = <GptPartition>[];
    for (var i = 0; i < header.numberOfPartitionEntries; i++) {
      final off = entriesOffset + i * header.sizeOfPartitionEntry;
      if (_isZeroGuid(bytes, off)) continue;
      final d = ByteData.sublistView(bytes, off, off + header.sizeOfPartitionEntry);
      final firstLba = d.getUint64(32, Endian.little);
      final lastLba = d.getUint64(40, Endian.little);
      if (lastLba < firstLba) {
        throw GptFormatException('エントリ $i の LBA 範囲が逆転しています');
      }
      if (firstLba < header.firstUsableLba || lastLba > header.lastUsableLba) {
        throw GptFormatException(
            'エントリ $i の範囲 ($firstLba-$lastLba) が使用可能 LBA 範囲 (${header.firstUsableLba}-${header.lastUsableLba}) の外です');
      }
      final nameBytes = bytes.sublist(off + 56, off + 56 + 72);
      final name = _decodeUtf16Name(nameBytes);
      partitions.add(GptPartition(
        index: i,
        typeGuid: formatGuid(bytes, off),
        uniqueGuid: formatGuid(bytes, off + 16),
        firstLba: firstLba,
        lastLba: lastLba,
        attributes: d.getUint64(48, Endian.little),
        name: name,
      ));
    }
    return partitions;
  }

  static String _decodeUtf16Name(Uint8List bytes) {
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      final u = bytes[i] | (bytes[i + 1] << 8);
      if (u == 0) break;
      units.add(u);
    }
    return String.fromCharCodes(units);
  }
}
