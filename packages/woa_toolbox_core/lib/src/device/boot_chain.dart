import 'adb_client.dart';
import 'command_runner.dart';
import 'device_probe.dart';
import 'fastboot_client.dart';

/// Recovery → ブートローダー → fastboot boot の連続操作。
///
/// ユーザーの標準ブート手順（Recovery で `adb reboot bootloader` してから
/// `fastboot boot <image>`）を 1 操作にまとめたもの。再起動の前にイメージを
/// 検証し、対象シリアルが fastboot モードで再検出されるまで待ってから
/// boot する。フラッシュは行わない（一時ブートのみ）。
class RecoveryBootChain {
  RecoveryBootChain(
    this._runner, {
    this.adbExecutable = 'adb',
    this.fastbootExecutable = 'fastboot',
    this.pollInterval = const Duration(seconds: 2),
    this.timeout = const Duration(seconds: 90),
  });

  final CommandRunner _runner;
  final String adbExecutable;
  final String fastbootExecutable;
  final Duration pollInterval;
  final Duration timeout;

  /// [serial] の端末（Recovery モードで接続済みの前提）を再起動し、
  /// [imagePath] を fastboot boot する。進捗は [onProgress] に流す。
  Future<void> bootFromRecovery({
    required String serial,
    required String imagePath,
    void Function(String line)? onProgress,
  }) async {
    // 再起動してからイメージ不正に気づく事故を防ぐため、先に検証する。
    final problem = await BootImage.validateFile(imagePath);
    if (problem != null) {
      throw ArgumentError('ブートイメージが不正です: $problem');
    }

    onProgress?.call('Recovery からブートローダーへ再起動します');
    await AdbClient(_runner, adbExecutable: adbExecutable)
        .reboot(serial, target: 'bootloader');

    onProgress?.call('fastboot モードで検出されるのを待っています…');
    final probe = DeviceProbe(
      _runner,
      adbExecutable: adbExecutable,
      fastbootExecutable: fastbootExecutable,
    );
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final devices = await probe.probe();
      final found = devices.any(
          (d) => d.serial == serial && d.mode == DeviceMode.fastboot);
      if (found) break;
      if (DateTime.now().isAfter(deadline)) {
        throw StateError(
            'タイムアウト: $serial が fastboot モードで検出されませんでした');
      }
      await Future<void>.delayed(pollInterval);
    }

    onProgress?.call('fastboot boot を実行します');
    await FastbootClient(_runner, fastbootExecutable: fastbootExecutable)
        .boot(serial, imagePath, onOutput: onProgress);
    onProgress?.call('ブートイメージを送信しました。端末側で UEFI が起動します。');
  }
}
