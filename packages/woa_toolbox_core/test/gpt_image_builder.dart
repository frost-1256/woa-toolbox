import 'dart:typed_data';

import 'package:woa_toolbox_core/woa_toolbox_core.dart';

/// テスト用に、検証可能な GPT ディスクイメージ（プライマリ＋バックアップ）を
/// メモリ上に構築する。
class SyntheticPartition {
  const SyntheticPartition(this.name, this.firstLba, this.lastLba);
  final String name;
  final int firstLba;
  final int lastLba;
}

Uint8List buildGptImage({
  required int sectorSize,
  required int totalLbas,
  required List<SyntheticPartition> partitions,
  int numberOfEntries = 32,
  int entrySize = 128,
}) {
  final image = Uint8List(totalLbas * sectorSize);
  final entryArrayBytes = numberOfEntries * entrySize;
  final entryArraySectors = (entryArrayBytes + sectorSize - 1) ~/ sectorSize;
  final firstUsable = 2 + entryArraySectors;
  final lastUsable = totalLbas - 2 - entryArraySectors;

  // プロテクティブ MBR（タイプ 0xEE）。
  image[450] = 0xEE;
  final mbr = ByteData.sublistView(image, 0, sectorSize);
  mbr.setUint32(454, 1, Endian.little);
  mbr.setUint32(458, totalLbas - 1, Endian.little);
  image[510] = 0x55;
  image[511] = 0xAA;

  Uint8List buildEntries() {
    final entries = Uint8List(entryArrayBytes);
    for (var i = 0; i < partitions.length; i++) {
      final p = partitions[i];
      final off = i * entrySize;
      // タイプ GUID（非ゼロのパターン）とユニーク GUID。
      for (var k = 0; k < 16; k++) {
        entries[off + k] = 0xA0 + k;
        entries[off + 16 + k] = (i + 1) * 16 + k;
      }
      final d = ByteData.sublistView(entries, off, off + entrySize);
      d.setUint64(32, p.firstLba, Endian.little);
      d.setUint64(40, p.lastLba, Endian.little);
      final nameUnits = p.name.codeUnits;
      for (var k = 0; k < nameUnits.length && k < 36; k++) {
        entries[off + 56 + k * 2] = nameUnits[k] & 0xFF;
        entries[off + 56 + k * 2 + 1] = (nameUnits[k] >> 8) & 0xFF;
      }
    }
    return entries;
  }

  final entries = buildEntries();
  final entriesCrc = Crc32.compute(entries);

  void writeHeader(int headerLba, int myLba, int alternateLba, int entriesLba) {
    final off = headerLba * sectorSize;
    image.setRange(off, off + 8, 'EFI PART'.codeUnits);
    final d = ByteData.sublistView(image, off, off + sectorSize);
    d.setUint32(8, 0x00010000, Endian.little); // revision 1.0
    d.setUint32(12, 92, Endian.little); // header size
    d.setUint64(24, myLba, Endian.little);
    d.setUint64(32, alternateLba, Endian.little);
    d.setUint64(40, firstUsable, Endian.little);
    d.setUint64(48, lastUsable, Endian.little);
    for (var k = 0; k < 16; k++) {
      image[off + 56 + k] = 0xD0 + k; // disk GUID
    }
    d.setUint64(72, entriesLba, Endian.little);
    d.setUint32(80, numberOfEntries, Endian.little);
    d.setUint32(84, entrySize, Endian.little);
    d.setUint32(88, entriesCrc, Endian.little);
    final headerBytes = Uint8List.sublistView(image, off, off + 92);
    final crc = Crc32.compute(headerBytes);
    d.setUint32(16, crc, Endian.little);
  }

  // プライマリ。
  image.setRange(2 * sectorSize, 2 * sectorSize + entryArrayBytes, entries);
  writeHeader(1, 1, totalLbas - 1, 2);
  // バックアップ。
  final backupEntriesLba = totalLbas - 1 - entryArraySectors;
  image.setRange(backupEntriesLba * sectorSize,
      backupEntriesLba * sectorSize + entryArrayBytes, entries);
  writeHeader(totalLbas - 1, totalLbas - 1, 1, backupEntriesLba);
  return image;
}
