import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../crc32.dart';
import '../gpt/gpt.dart';
import 'manifest.dart';

/// GUID 文字列（8-4-4-4-12）を GPT のバイト表現に書き戻す。
/// [GptParser] の formatGuid の逆変換（先頭 3 フィールドは LE）。
void writeGuid(Uint8List bytes, int offset, String guid) {
  final parts = guid.split('-');
  if (parts.length != 5) {
    throw ArgumentError('GUID の形式が不正です: $guid');
  }
  final d = ByteData.sublistView(bytes, offset, offset + 16);
  d.setUint32(0, int.parse(parts[0], radix: 16), Endian.little);
  d.setUint16(4, int.parse(parts[1], radix: 16), Endian.little);
  d.setUint16(6, int.parse(parts[2], radix: 16), Endian.little);
  final tail = parts[3] + parts[4];
  for (var i = 0; i < 8; i++) {
    bytes[offset + 8 + i] = int.parse(tail.substring(i * 2, i * 2 + 2), radix: 16);
  }
}

/// プライマリ GPT からバックアップ GPT 領域を合成する。
/// エントリ配列はプライマリのものをそのまま使い（GPT 仕様上同一）、
/// ヘッダーは myLba / alternateLba / partitionEntryLba を差し替えて
/// CRC を再計算する。
Uint8List buildBackupRegion(
  GptTable primary,
  Uint8List entriesArray, {
  required int totalLbas,
  required int sectorSize,
}) {
  final header = primary.header;
  final entrySectors =
      (header.entryArrayBytes + sectorSize - 1) ~/ sectorSize;
  final region = Uint8List((entrySectors + 1) * sectorSize);
  region.setRange(0, header.entryArrayBytes, entriesArray);

  final hOff = entrySectors * sectorSize;
  region.setRange(hOff, hOff + 8, ascii.encode('EFI PART'));
  final d = ByteData.sublistView(region, hOff, hOff + sectorSize);
  d.setUint32(8, header.revision, Endian.little);
  d.setUint32(12, header.headerSize, Endian.little);
  d.setUint64(24, totalLbas - 1, Endian.little);
  d.setUint64(32, 1, Endian.little);
  d.setUint64(40, header.firstUsableLba, Endian.little);
  d.setUint64(48, header.lastUsableLba, Endian.little);
  writeGuid(region, hOff + 56, header.diskGuid);
  d.setUint64(72, totalLbas - 1 - entrySectors, Endian.little);
  d.setUint32(80, header.numberOfPartitionEntries, Endian.little);
  d.setUint32(84, header.sizeOfPartitionEntry, Endian.little);
  d.setUint32(
      88, Crc32.compute(entriesArray, 0, header.entryArrayBytes), Endian.little);
  // CRC フィールド（16）はゼロのままヘッダー CRC を計算する。
  final headerBytes =
      Uint8List.sublistView(region, hOff, hOff + header.headerSize);
  d.setUint32(16, Crc32.compute(headerBytes), Endian.little);
  return region;
}

/// 手作業時代のバックアップ（GPT 単一ダンプ＋生パーティションイメージ群）を
/// Toolbox 形式（フォルダ＋manifest.json）に取り込む。
class LegacyImport {
  /// [gptDump] はプライマリ GPT 領域の生ダンプ（例: 初期構築時の
  /// gpt_sda.bin）。バックアップ領域は合成する。
  /// [partitionFiles] は パーティション名 → ファイル。
  /// sda の GPT にあるパーティションはサイズ一致を検証する。
  static Future<BackupManifest> importSet({
    Uint8List? gptDump,
    Map<String, File> partitionFiles = const {},
    required Directory outDir,
    required String deviceSerial,
    required String productDevice,
    required int sectorSize,
    required int totalLbas,
    GptTable? sdaPrimary,
    DateTime? createdAt,
  }) async {
    await outDir.create(recursive: true);
    final entries = <BackupFileEntry>[];
    String? fingerprint;

    Future<void> saveEntry(String name, String fileName, Uint8List bytes) async {
      final file =
          File('${outDir.path}${Platform.pathSeparator}$fileName');
      await file.writeAsBytes(bytes);
      entries.add(BackupFileEntry(
        fileName: fileName,
        partitionName: name,
        sizeBytes: bytes.length,
        sha256: sha256.convert(bytes).toString(),
      ));
    }

    if (gptDump != null) {
      final primary = GptParser.parsePrimary(gptDump, sectorSize: sectorSize);
      fingerprint = primary.fingerprint;
      final header = primary.header;
      final entrySectors =
          (header.entryArrayBytes + sectorSize - 1) ~/ sectorSize;
      final regionBytes = (header.partitionEntryLba + entrySectors) * sectorSize;
      if (gptDump.length < regionBytes) {
        throw ArgumentError(
            'GPT ダンプがプライマリ領域（$regionBytes バイト）より短いです: ${gptDump.length}');
      }
      final primaryRegion = Uint8List.sublistView(gptDump, 0, regionBytes);
      final entriesArray = Uint8List.sublistView(
        gptDump,
        header.partitionEntryLba * sectorSize,
        header.partitionEntryLba * sectorSize + header.entryArrayBytes,
      );
      await saveEntry('gpt-primary', 'gpt_primary.bin', primaryRegion);
      await saveEntry(
        'gpt-backup',
        'gpt_backup.bin',
        buildBackupRegion(primary, entriesArray,
            totalLbas: totalLbas, sectorSize: sectorSize),
      );
    }

    for (final e in partitionFiles.entries) {
      final bytes = await e.value.readAsBytes();
      final p = sdaPrimary?.partitionByName(e.key);
      if (p != null && bytes.length != p.sizeLbas * sectorSize) {
        throw ArgumentError('${e.key} のサイズが GPT と一致しません: '
            'ファイル ${bytes.length} / GPT ${p.sizeLbas * sectorSize}');
      }
      await saveEntry(e.key, '${e.key}.bin', bytes);
    }

    final manifest = BackupManifest(
      deviceSerial: deviceSerial,
      productDevice: productDevice,
      createdAt: createdAt ?? DateTime.now(),
      layoutFingerprint: fingerprint ?? sdaPrimary?.fingerprint ?? '',
      files: entries,
    );
    await File('${outDir.path}${Platform.pathSeparator}manifest.json')
        .writeAsString(
            const JsonEncoder.withIndent('  ').convert(manifest.toJson()));
    return manifest;
  }
}
