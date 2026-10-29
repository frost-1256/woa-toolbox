import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:woa_toolbox_core/woa_toolbox_core.dart';

import 'gpt_image_builder.dart';

const _sector = 512;

/// readLbas の呼び出しを記録する LbaReader。
class RecordingReader implements LbaReader {
  RecordingReader(this.image, {int sectorSize = _sector}) : _ss = sectorSize;

  final Uint8List image;
  final int _ss;
  final List<({int start, int count})> calls = [];

  @override
  int get sectorSize => _ss;

  @override
  int get totalLbas => image.length ~/ _ss;

  @override
  Future<Uint8List> readLbas(int startLba, int count) async {
    calls.add((start: startLba, count: count));
    final start = startLba * _ss;
    return Uint8List.sublistView(image, start, start + count * _ss);
  }
}

/// [failOnCall] 回目の読みで、例外を投げずに短いバイト列を返す
/// （転送欠損を装う）LbaReader。ヘルパー側の長さ照合を検証する。
class ShortReadReader extends RecordingReader {
  ShortReadReader(super.image, {required this.failOnCall});

  final int failOnCall;

  @override
  Future<Uint8List> readLbas(int startLba, int count) async {
    final full = await super.readLbas(startLba, count);
    if (calls.length == failOnCall) {
      return Uint8List.sublistView(full, 0, full.length - _sector);
    }
    return full;
  }
}

Uint8List _patternImage(int sectors) {
  final image = Uint8List(sectors * _sector);
  for (var i = 0; i < image.length; i++) {
    image[i] = (i * 31 + 7) & 0xFF;
  }
  return image;
}

void main() {
  group('streaming helpers', () {
    test('writeLbaRangeToFile は複数チャンクで内容と SHA が単発と一致する', () async {
      final image = _patternImage(40);
      final reader = RecordingReader(image);
      final dir = await Directory.systemTemp.createTemp('woa_stream_test');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}out.bin');

      final result = await writeLbaRangeToFile(
        reader,
        2,
        25,
        file,
        chunkBytes: 4 * _sector,
      );

      // 25 セクタ / 4 セクタ = 7 回（最終チャンクは 1 セクタ）。
      expect(reader.calls.length, 7);
      expect(reader.calls.last.count, 1);
      final expected =
          Uint8List.sublistView(image, 2 * _sector, 27 * _sector);
      final written = await file.readAsBytes();
      expect(written, expected);
      expect(result.sizeBytes, expected.length);
      expect(result.sha256, sha256.convert(expected).toString());
    });

    test('hashLbaRange は単発ハッシュと一致する', () async {
      final image = _patternImage(30);
      final reader = RecordingReader(image);
      final sha = await hashLbaRange(reader, 5, 17, chunkBytes: 3 * _sector);
      final expected =
          Uint8List.sublistView(image, 5 * _sector, 22 * _sector);
      expect(sha, sha256.convert(expected).toString());
      // 17 / 3 = 6 回。
      expect(reader.calls.length, 6);
    });

    test('hashFileContents は長さと SHA を返す', () async {
      final dir = await Directory.systemTemp.createTemp('woa_stream_test');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}f.bin');
      final bytes = _patternImage(9);
      await file.writeAsBytes(bytes);
      final result = await hashFileContents(file);
      expect(result.length, bytes.length);
      expect(result.sha256, sha256.convert(bytes).toString());
    });

    test('短いチャンクは StateError になる', () async {
      final image = _patternImage(20);
      final reader = ShortReadReader(image, failOnCall: 2);
      final dir = await Directory.systemTemp.createTemp('woa_stream_test');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}out.bin');
      await expectLater(
        writeLbaRangeToFile(reader, 0, 12, file, chunkBytes: 4 * _sector),
        throwsStateError,
      );
    });

    test('割り切れるチャンク境界でも成功する', () async {
      final image = _patternImage(30);
      final reader = RecordingReader(image);
      final dir = await Directory.systemTemp.createTemp('woa_stream_test');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}out.bin');
      final result = await writeLbaRangeToFile(
        reader,
        0,
        20,
        file,
        chunkBytes: 5 * _sector,
      );
      expect(reader.calls.length, 4);
      final expected = Uint8List.sublistView(image, 0, 20 * _sector);
      expect(await file.readAsBytes(), expected);
      expect(result.sha256, sha256.convert(expected).toString());
    });

    test('count = 0 は空ファイルと空ハッシュで成功する', () async {
      final image = _patternImage(4);
      final reader = RecordingReader(image);
      final dir = await Directory.systemTemp.createTemp('woa_stream_test');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}out.bin');
      final result = await writeLbaRangeToFile(reader, 0, 0, file);
      expect(reader.calls, isEmpty);
      expect(result.sizeBytes, 0);
      expect(result.sha256, sha256.convert(const <int>[]).toString());
      expect(await file.length(), 0);
    });

    test('負の count / startLba は ArgumentError になる', () async {
      final image = _patternImage(4);
      final reader = RecordingReader(image);
      final dir = await Directory.systemTemp.createTemp('woa_stream_test');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}out.bin');
      await expectLater(
        writeLbaRangeToFile(reader, 0, -1, file),
        throwsArgumentError,
      );
      await expectLater(
        writeLbaRangeToFile(reader, -1, 1, file),
        throwsArgumentError,
      );
      await expectLater(hashLbaRange(reader, 0, -5), throwsArgumentError);
    });

    test('chunkBytes がセクタ未満なら 1 セクタ刻みになる', () async {
      final image = _patternImage(8);
      final reader = RecordingReader(image);
      final dir = await Directory.systemTemp.createTemp('woa_stream_test');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}out.bin');
      await writeLbaRangeToFile(reader, 0, 5, file, chunkBytes: 1);
      expect(reader.calls.length, 5);
      expect(reader.calls.every((c) => c.count == 1), isTrue);
    });

    test('失敗時は最終名も .partial も残らない', () async {
      final image = _patternImage(20);
      final reader = ShortReadReader(image, failOnCall: 2);
      final dir = await Directory.systemTemp.createTemp('woa_stream_test');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}out.bin');
      await expectLater(
        writeLbaRangeToFile(reader, 0, 12, file, chunkBytes: 4 * _sector),
        throwsStateError,
      );
      expect(await file.exists(), isFalse);
      expect(await File('${file.path}.partial').exists(), isFalse);
    });

    test('hashLbaRange の短い読みも StateError になる', () async {
      final image = _patternImage(20);
      final reader = ShortReadReader(image, failOnCall: 3);
      await expectLater(
        hashLbaRange(reader, 0, 10, chunkBytes: 2 * _sector),
        throwsStateError,
      );
    });

    test('hashFileContents は複数ストリームチャンクをまたいでも一致する', () async {
      final dir = await Directory.systemTemp.createTemp('woa_stream_test');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}big.bin');
      // File.openRead の 1 チャンク（64 KiB）を超えるサイズで検証する。
      final bytes = Uint8List(1024 * 1024 + 12345);
      for (var i = 0; i < bytes.length; i++) {
        bytes[i] = (i * 17 + 3) & 0xFF;
      }
      await file.writeAsBytes(bytes);
      var chunkCalls = 0;
      final result = await hashFileContents(
        file,
        onChunk: (done, total) {
          chunkCalls++;
          expect(total, bytes.length);
        },
      );
      expect(chunkCalls, greaterThan(1));
      expect(result.length, bytes.length);
      expect(result.sha256, sha256.convert(bytes).toString());
    });

    test('4096 バイトセクタでもストリーミングできる', () async {
      const ss = 4096;
      final image = Uint8List(12 * ss);
      for (var i = 0; i < image.length; i++) {
        image[i] = (i * 13 + 5) & 0xFF;
      }
      final reader = RecordingReader(image, sectorSize: ss);
      final dir = await Directory.systemTemp.createTemp('woa_stream_test');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}out.bin');
      final result = await writeLbaRangeToFile(
        reader,
        1,
        10,
        file,
        chunkBytes: 3 * ss,
      );
      expect(reader.calls.length, 4);
      final expected = Uint8List.sublistView(image, ss, 11 * ss);
      expect(await file.readAsBytes(), expected);
      expect(result.sha256, sha256.convert(expected).toString());
    });
  });

  group('BackupExecutor ストリーミング', () {
    const planner = OperationPlanner();

    test('小さい chunkBytes でもバックアップが一致する', () async {
      final image = buildGptImage(
        sectorSize: _sector,
        totalLbas: 2048,
        partitions: const [
          SyntheticPartition('persist', 100, 199),
          SyntheticPartition('super', 200, 999),
          SyntheticPartition('userdata', 1000, 1990),
        ],
      );
      image.fillRange(100 * _sector, 200 * _sector, 0x5A);
      final reader = RecordingReader(image);
      final both = await GptReader.readBoth(
          MemoryLbaReader(image, sectorSize: _sector));
      final plan = planner.planBackupPartitions(
          serial: 'S1', primary: both.primary, names: ['persist']);
      final dir = await Directory.systemTemp.createTemp('woa_stream_test');
      addTearDown(() => dir.delete(recursive: true));

      final manifest = await const BackupExecutor().execute(
        plan,
        reader: reader,
        outDir: dir,
        serial: 'S1',
        productDevice: 'spacewar',
        currentFingerprint: both.primary.fingerprint,
        chunkBytes: 8 * _sector,
      );

      // persist は 100 セクタ → 8 セクタ刻みで 13 回読む。
      final persistCalls =
          reader.calls.where((c) => c.start >= 100 && c.start < 200).toList();
      expect(persistCalls.length, 13);
      final bytes = await File(
              '${dir.path}${Platform.pathSeparator}persist.bin')
          .readAsBytes();
      expect(bytes.length, 100 * _sector);
      expect(manifest.files.single.sha256, sha256.convert(bytes).toString());
    });

    test('GPT バックアップは 1 セクタ刻みでも内容が一致する', () async {
      final image = buildGptImage(
        sectorSize: _sector,
        totalLbas: 2048,
        partitions: const [
          SyntheticPartition('persist', 100, 199),
          SyntheticPartition('super', 200, 999),
          SyntheticPartition('userdata', 1000, 1990),
        ],
      );
      final reader = RecordingReader(image);
      final both = await GptReader.readBoth(
          MemoryLbaReader(image, sectorSize: _sector));
      final plan = planner.planBackupGpt(
        serial: 'S1',
        primary: both.primary,
        backup: both.backup,
        totalLbas: 2048,
      );
      final dir = await Directory.systemTemp.createTemp('woa_stream_test');
      addTearDown(() => dir.delete(recursive: true));

      final manifest = await const BackupExecutor().execute(
        plan,
        reader: reader,
        outDir: dir,
        serial: 'S1',
        productDevice: 'spacewar',
        currentFingerprint: both.primary.fingerprint,
        chunkBytes: _sector,
      );

      final pStart = plan.data['primaryStart'] as int;
      final pCount = plan.data['primaryCount'] as int;
      final primaryBytes = await File(
              '${dir.path}${Platform.pathSeparator}gpt_primary.bin')
          .readAsBytes();
      expect(
        primaryBytes,
        Uint8List.sublistView(
            image, pStart * _sector, (pStart + pCount) * _sector),
      );
      final entry = manifest.files
          .firstWhere((f) => f.fileName == 'gpt_primary.bin');
      expect(entry.sha256, sha256.convert(primaryBytes).toString());
    });

    test('途中チャンクの欠損では manifest を作らない', () async {
      final image = buildGptImage(
        sectorSize: _sector,
        totalLbas: 2048,
        partitions: const [
          SyntheticPartition('persist', 100, 199),
          SyntheticPartition('super', 200, 999),
          SyntheticPartition('userdata', 1000, 1990),
        ],
      );
      final reader = ShortReadReader(image, failOnCall: 3);
      final both = await GptReader.readBoth(
          MemoryLbaReader(image, sectorSize: _sector));
      final plan = planner.planBackupPartitions(
          serial: 'S1', primary: both.primary, names: ['persist']);
      final dir = await Directory.systemTemp.createTemp('woa_stream_test');
      addTearDown(() => dir.delete(recursive: true));

      await expectLater(
        const BackupExecutor().execute(
          plan,
          reader: reader,
          outDir: dir,
          serial: 'S1',
          productDevice: 'spacewar',
          currentFingerprint: both.primary.fingerprint,
          chunkBytes: 8 * _sector,
        ),
        throwsStateError,
      );
      expect(
        await File('${dir.path}${Platform.pathSeparator}manifest.json')
            .exists(),
        isFalse,
      );
    });
  });
}
