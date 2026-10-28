import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:woa_toolbox_core/woa_toolbox_core.dart';

/// fastboot devices が stderr に出る実機挙動を再現するフェイク。
class _StderrFastbootRunner implements CommandRunner {
  @override
  Future<CommandResult> run(String executable, List<String> arguments) async {
    if (executable == 'adb') {
      return CommandResult(
        exitCode: 0,
        stdoutBytes: Uint8List.fromList(utf8.encode('List of devices attached\n')),
        stderrText: '',
      );
    }
    return CommandResult(
      exitCode: 0,
      stdoutBytes: Uint8List(0),
      stderrText: 'abcd1234\tfastboot\n',
    );
  }
}

void main() {
  group('adb devices パース', () {
    test('状態と product を読める', () {
      const output = '''
List of devices attached
abcd1234	device product:spacewar model:A063 device:spacewar
emulator-5554	recovery
xyz987	unauthorized
''';
      final devices = parseAdbDevices(output);
      expect(devices.length, 3);
      expect(devices[0].serial, 'abcd1234');
      expect(devices[0].state, AdbDeviceState.device);
      expect(devices[0].product, 'spacewar');
      expect(devices[1].state, AdbDeviceState.recovery);
      expect(devices[2].state, AdbDeviceState.unauthorized);
    });
  });

  group('fastboot devices パース', () {
    test('fastboot 行だけ拾う', () {
      const output = 'abcd1234\tfastboot\nnotadevice\n';
      expect(parseFastbootDevices(output), ['abcd1234']);
    });

    test('実機は stderr に出すため、probe は stderr も見る', () async {
      final devices = await DeviceProbe(_StderrFastbootRunner()).probe();
      expect(devices.length, 1);
      expect(devices.single.serial, 'abcd1234');
      expect(devices.single.mode, DeviceMode.fastboot);
    });
  });

  group('ブロック情報の単位換算 (§4.1)', () {
    test('spacewar 実測値: 4096B セクタで総 LBA を算出できる', () {
      // 総容量 29644800 LBA × 4096B = 121,425,100,800 バイト
      // 512B 単位では 237,158,400。
      final info = blockInfoFromSysfs(logicalSectorSize: 4096, size512: 237158400);
      expect(info.totalBytes, 121425100800);
      expect(info.totalLbas, 29644800);
    });

    test('割り切れない組み合わせは矛盾として弾く', () {
      expect(
        () => blockInfoFromSysfs(logicalSectorSize: 4096, size512: 1001),
        throwsA(isA<FormatException>()),
      );
    });

    test('512B セクタではそのまま一致する', () {
      final info = blockInfoFromSysfs(logicalSectorSize: 512, size512: 32768);
      expect(info.totalLbas, 32768);
    });
  });

  group('バックアップ manifest', () {
    BackupManifest sample() => BackupManifest(
          deviceSerial: 'abcd1234',
          productDevice: 'spacewar',
          createdAt: DateTime.utc(2026, 10, 28, 12, 0),
          layoutFingerprint: 'a' * 64,
          files: const [
            BackupFileEntry(
              fileName: 'persist.bin',
              partitionName: 'persist',
              sizeBytes: 33554432,
              sha256: 'deadbeef',
            ),
          ],
        );

    test('JSON ラウンドトリップ', () {
      final decoded = BackupManifest.decode(sample().encode());
      expect(decoded.deviceSerial, 'abcd1234');
      expect(decoded.files.single.partitionName, 'persist');
      expect(decoded.isForDevice('abcd1234'), isTrue);
      expect(decoded.isForDevice('other999'), isFalse);
    });

    test('照合で欠落・サイズ・ハッシュの不一致を検出する', () {
      final manifest = sample();
      expect(verifyManifest(manifest, const {}).length, 1);
      expect(
        verifyManifest(manifest, const {
          'persist.bin': (sizeBytes: 1, sha256: 'deadbeef'),
        }).length,
        1,
      );
      expect(
        verifyManifest(manifest, const {
          'persist.bin': (sizeBytes: 33554432, sha256: 'cafe'),
        }).length,
        1,
      );
      expect(
        verifyManifest(manifest, const {
          'persist.bin': (sizeBytes: 33554432, sha256: 'deadbeef'),
        }),
        isEmpty,
      );
    });
  });
}
