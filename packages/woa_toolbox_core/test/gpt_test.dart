import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:woa_toolbox_core/woa_toolbox_core.dart';

import 'gpt_image_builder.dart';

void main() {
  group('実機フィクスチャ (spacewar stock GPT)', () {
    final bytes = File('test/fixtures/gpt_sda_stock.bin').readAsBytesSync();

    test('プライマリ GPT が検証を通り、10 パーティションを読める', () {
      final table = GptParser.parsePrimary(bytes, sectorSize: 4096);
      expect(table.header.numberOfPartitionEntries, 32);
      expect(table.header.sizeOfPartitionEntry, 128);
      expect(table.header.alternateLba, 29644799);
      expect(table.partitions.length, 10);
      expect(
        table.partitions.map((p) => p.name),
        [
          'ssd',
          'persist',
          'misc',
          'keystore',
          'frp',
          'super',
          'vbmeta_system_a',
          'vbmeta_system_b',
          'metadata',
          'userdata',
        ],
      );
      final userdata = table.partitionByName('userdata')!;
      expect(userdata.firstLba, 1585704);
      expect(userdata.lastLba, 29644794);
      final persist = table.partitionByName('persist')!;
      expect(persist.sizeBytes(4096), 33554432);
    });

    test('stock レイアウトは android と判定される', () {
      final table = GptParser.parsePrimary(bytes, sectorSize: 4096);
      expect(classifyLayout(table), PartitionLayout.android);
    });

    test('フィンガープリントは SHA-256 形式', () {
      final table = GptParser.parsePrimary(bytes, sectorSize: 4096);
      expect(table.fingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));
    });
  });

  group('合成 GPT イメージ', () {
    test('4096B セクタ: プライマリとバックアップが一致する', () async {
      final image = buildGptImage(
        sectorSize: 4096,
        totalLbas: 4096,
        partitions: const [
          SyntheticPartition('super', 100, 999),
          SyntheticPartition('userdata', 1000, 3990),
        ],
      );
      final reader = MemoryLbaReader(image, sectorSize: 4096);
      final both = await GptReader.readBoth(reader);
      expect(both.consistent, isTrue);
      expect(both.primary.partitions.length, 2);
      expect(both.backup.isBackup, isTrue);
      expect(classifyLayout(both.primary), PartitionLayout.android);
    });

    test('esp と win があれば woa と判定される', () async {
      final image = buildGptImage(
        sectorSize: 4096,
        totalLbas: 4096,
        partitions: const [
          SyntheticPartition('super', 100, 999),
          SyntheticPartition('userdata', 1000, 3000),
          SyntheticPartition('esp', 3001, 3256),
          SyntheticPartition('win', 3257, 3990),
        ],
      );
      final reader = MemoryLbaReader(image, sectorSize: 4096);
      final table = await GptReader.readPrimary(reader);
      expect(classifyLayout(table), PartitionLayout.woa);
    });

    test('512B セクタでも解析できる', () async {
      final image = buildGptImage(
        sectorSize: 512,
        totalLbas: 32768,
        partitions: const [
          SyntheticPartition('userdata', 2048, 32000),
        ],
      );
      final reader = MemoryLbaReader(image, sectorSize: 512);
      final both = await GptReader.readBoth(reader);
      expect(both.consistent, isTrue);
      expect(both.primary.partitionByName('userdata')!.firstLba, 2048);
    });
  });

  group('異常系', () {
    final fixture = File('test/fixtures/gpt_sda_stock.bin').readAsBytesSync();

    test('エントリ配列を壊すと CRC 不一致で落ちる', () {
      final corrupted = Uint8List.fromList(fixture);
      corrupted[8192 + 100] ^= 0xFF;
      expect(
        () => GptParser.parsePrimary(corrupted, sectorSize: 4096),
        throwsA(isA<GptFormatException>()),
      );
    });

    test('ヘッダーを壊すとヘッダー CRC 不一致で落ちる', () {
      final corrupted = Uint8List.fromList(fixture);
      corrupted[4096 + 40] ^= 0xFF; // firstUsableLba
      expect(
        () => GptParser.parsePrimary(corrupted, sectorSize: 4096),
        throwsA(isA<GptFormatException>()),
      );
    });

    test('途中で切れたデータは落ちる', () {
      final truncated = Uint8List.sublistView(fixture, 0, 2000);
      expect(
        () => GptParser.parsePrimary(truncated, sectorSize: 4096),
        throwsA(isA<GptFormatException>()),
      );
    });

    test('セクタサイズを取り違えると落ちる', () {
      expect(
        () => GptParser.parsePrimary(fixture, sectorSize: 512),
        throwsA(isA<GptFormatException>()),
      );
    });

    test('バックアップ側の破損は readBoth で検出できる', () async {
      final image = buildGptImage(
        sectorSize: 4096,
        totalLbas: 4096,
        partitions: const [SyntheticPartition('userdata', 1000, 3990)],
      );
      final corrupted = Uint8List.fromList(image);
      // バックアップのエントリ領域（末尾側）を壊す。
      corrupted[corrupted.length - 4096 - 100] ^= 0xFF;
      final reader = MemoryLbaReader(corrupted, sectorSize: 4096);
      expect(
        () => GptReader.readBackup(reader),
        throwsA(isA<GptFormatException>()),
      );
    });
  });
}
