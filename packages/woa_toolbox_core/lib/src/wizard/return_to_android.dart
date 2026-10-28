import 'dart:io';

import '../device/adb_client.dart';
import '../device/device_probe.dart';
import '../gpt/gpt.dart';
import '../layout/layout_classifier.dart';

enum ReturnStep {
  precondition,
  restoreGpt,
  rebootRecovery,
  awaitSideload,
  sideload,
  done,
}

/// 「Android（LineageOS）に戻す」ウィザードの状態機械（設計書 §5.4）。
///
/// 各ステップは 前提検証 → 実行 → 成功確認 を 1 単位とし、満たさない
/// 場合は先へ進まず例外で停止する。GPT 復元そのものは注入された
/// [restoreGpt]（RestoreExecutor を使う処理）が担う。
/// sideload モードへの移行は端末側のメニュー操作が必要なため、
/// awaitSideload ステップでユーザー操作を待つ。
class ReturnToAndroidWizard {
  ReturnToAndroidWizard({
    required this.adb,
    required this.probe,
    required this.restoreGpt,
    this.pollInterval = const Duration(seconds: 2),
    this.recoveryTimeout = const Duration(minutes: 3),
    this.sideloadTimeout = const Duration(minutes: 5),
  });

  final AdbClient adb;
  final Future<List<ToolboxDevice>> Function() probe;

  /// GPT 復元処理（進捗コールバック付き）。
  final Future<void> Function(void Function(String line) onProgress)
      restoreGpt;

  final Duration pollInterval;
  final Duration recoveryTimeout;
  final Duration sideloadTimeout;

  Future<DeviceMode?> _waitMode(
    String serial,
    bool Function(DeviceMode mode) ok,
    Duration timeout,
  ) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final devices = await probe();
      for (final d in devices) {
        if (d.serial == serial && ok(d.mode)) return d.mode;
      }
      await Future<void>.delayed(pollInterval);
    }
    return null;
  }

  Future<void> run({
    required String serial,
    required GptTable currentPrimary,
    required GptTable restorePrimary,
    required String lineageZipPath,
    required void Function(ReturnStep step, String message) onStep,
  }) async {
    // 1. 前提検証。
    onStep(ReturnStep.precondition, '前提を検証しています');
    if (!await File(lineageZipPath).exists()) {
      throw ArgumentError('LineageOS の zip が見つかりません: $lineageZipPath');
    }
    final devices = await probe();
    ToolboxDevice? device;
    for (final d in devices) {
      if (d.serial == serial) device = d;
    }
    if (device == null) {
      throw StateError('端末 $serial が見つかりません');
    }
    if (device.mode != DeviceMode.recovery) {
      throw StateError(
          '端末が Recovery モードではありません（現在: ${device.mode.name}）');
    }
    if (classifyLayout(currentPrimary) != PartitionLayout.woa) {
      throw StateError('現在の GPT が WoA レイアウトではありません。GPT 復元は不要です');
    }
    if (classifyLayout(restorePrimary) == PartitionLayout.woa) {
      throw StateError(
          '復元先 GPT が WoA レイアウトです。Android 用のバックアップを選んでください');
    }

    // 2. GPT 復元（自動バックアップ付きの注入処理）。
    onStep(ReturnStep.restoreGpt, 'GPT を Android レイアウトへ復元しています');
    await restoreGpt((line) => onStep(ReturnStep.restoreGpt, line));

    // 3. Recovery を再起動して戻ってくるのを確認する。
    onStep(ReturnStep.rebootRecovery, 'Recovery を再起動しています');
    await adb.reboot(serial, target: 'recovery');
    final back = await _waitMode(
      serial,
      (m) => m == DeviceMode.recovery || m == DeviceMode.sideload,
      recoveryTimeout,
    );
    if (back == null) {
      throw StateError('Recovery に戻ってきませんでした');
    }

    // 4. sideload モード待ち（端末側のメニュー操作が必要）。
    if (back != DeviceMode.sideload) {
      onStep(
        ReturnStep.awaitSideload,
        '端末の Recovery メニューで「Apply update」→「Apply from ADB」を選んでください',
      );
      final mode = await _waitMode(
        serial,
        (m) => m == DeviceMode.sideload,
        sideloadTimeout,
      );
      if (mode == null) {
        throw StateError('sideload モードになりませんでした（タイムアウト）');
      }
    }

    // 5. sideload。
    onStep(ReturnStep.sideload, 'LineageOS を sideload しています（数分かかります）');
    await adb.sideload(serial, lineageZipPath);

    // 6. 完了。
    onStep(
      ReturnStep.done,
      '完了しました。端末を再起動して LineageOS の起動を確認してください',
    );
  }
}
