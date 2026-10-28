import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:woa_toolbox_core/woa_toolbox_core.dart';

/// UEFI イメージライブラリの1件。
class UefiImageEntry {
  const UefiImageEntry({
    required this.name,
    required this.path,
    required this.sizeBytes,
    required this.modified,
    required this.fingerprintShort,
    this.sourceLabel,
    this.memo = '',
  });
  final String name;
  final String path;
  final int sizeBytes;
  final DateTime modified;

  /// SHA-256 の先頭12桁（ビルドの同一性確認用）。
  final String fingerprintShort;

  /// 取得元の表示（例: "Actions Run #51 (3fe450a)"）。ローカル取り込みは null。
  final String? sourceLabel;

  /// ユーザーのメモ（例: 「v3.2 本番」）。
  final String memo;
}

/// アプリ全体の状態（Phase 1: 読み取り専用）。
/// 状態管理は ChangeNotifier で軽量に始める（設計書 §9 の未決定事項への暫定回答）。
class AppState extends ChangeNotifier {
  AppState() : logger = ToolLogger(sink: LogSink.memory);

  final ToolLogger logger;
  final CommandRunner _runner = const ProcessCommandRunner();

  List<ToolboxDevice> devices = [];
  ToolboxDevice? selected;
  GptTable? primaryTable;
  bool? gptConsistent;
  PartitionLayout? layout;
  MassStorageState? massStorage;
  bool busy = false;
  String? error;

  bool get canReadGpt {
    final mode = selected?.mode;
    return mode == DeviceMode.recovery || mode == DeviceMode.android;
  }

  Future<void> refreshDevices() async {
    await _guard(() async {
      logger.info('端末を検出しています…');
      devices = await DeviceProbe(_runner).probe();
      logger.info('${devices.length} 台の端末が見つかりました');
      if (selected != null &&
          !devices.any((d) => d.serial == selected!.serial)) {
        selected = null;
        primaryTable = null;
        gptConsistent = null;
        layout = null;
      }
    });
  }

  void select(ToolboxDevice device) {
    selected = device;
    primaryTable = null;
    gptConsistent = null;
    layout = null;
    massStorage = null;
    error = null;
    notifyListeners();
    if (device.mode == DeviceMode.recovery) {
      refreshMassStorageState();
    }
  }

  bool get canUseMassStorage => selected?.mode == DeviceMode.recovery;

  Future<void> refreshMassStorageState() async {
    final device = selected;
    if (device == null || !canUseMassStorage) return;
    try {
      massStorage =
          await GadgetService(_runner).massStorageState(device.serial);
      notifyListeners();
    } catch (_) {
      // 状態が読めない場合は unknown のままにする（致命的でない）。
    }
  }

  Future<void> enableMassStorage() async {
    final device = selected;
    if (device == null || !canUseMassStorage) return;
    await _guard(() async {
      logger.info('${device.serial} で Mass Storage を有効化します');
      await GadgetService(_runner).enableMassStorage(
        device.serial,
        onStep: (step) => logger.command(['adb', 'shell', step]),
      );
      massStorage = MassStorageState.on;
      logger.info(
          'Mass Storage を有効化しました。PC 側にディスクが見えるはずです。'
          '戻すときは端末を再起動して Recovery に入り直してください。');
    });
  }

  Future<void> readGpt() async {
    final device = selected;
    if (device == null || !canReadGpt) return;
    await _guard(() async {
      logger.info('${device.serial} の GPT を読み取ります');
      final adb = AdbClient(_runner);
      final info = await adb.blockInfo(device.serial);
      logger.info(
          'セクタサイズ ${info.logicalSectorSize}B / 総 LBA ${info.totalLbas}');
      final reader = AdbLbaReader(adb, device.serial, info);
      final both = await GptReader.readBoth(reader);
      primaryTable = both.primary;
      gptConsistent = both.consistent;
      layout = classifyLayout(both.primary);
      logger.info(
          'GPT 読み取り完了: ${both.primary.partitions.length} パーティション、'
          'プライマリ/バックアップ整合 = ${both.consistent}');
      if (!both.consistent) {
        logger.warn('プライマリとバックアップの GPT が一致しません');
      }
    });
  }

  // ---- UEFI イメージライブラリ / fastboot boot / Actions 取得 ----

  List<UefiImageEntry> uefiImages = [];
  String? selectedUefiImagePath;
  String githubToken = '';

  Future<Directory> _appDataDir() async {
    final String base;
    if (Platform.isWindows) {
      base = Platform.environment['APPDATA'] ??
          (await Directory.systemTemp.createTemp()).path;
    } else {
      final home = Platform.environment['HOME'] ?? '/tmp';
      base = '$home/.local/share';
    }
    final dir = Directory('$base${Platform.pathSeparator}woa-toolbox');
    await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> _uefiImagesDir() async {
    final dir = Directory(
        '${(await _appDataDir()).path}${Platform.pathSeparator}uefi-images');
    await dir.create(recursive: true);
    return dir;
  }

  Future<File> _settingsFile() async =>
      File('${(await _appDataDir()).path}${Platform.pathSeparator}settings.json');

  Map<String, Object?> _settings = {};
  ThemeMode themeMode = ThemeMode.system;

  Future<void> _saveSettings() async {
    final settings = await _settingsFile();
    await settings.writeAsString(jsonEncode(_settings));
  }

  Future<void> loadUefiLibrary() async {
    try {
      final settings = await _settingsFile();
      if (await settings.exists()) {
        _settings =
            jsonDecode(await settings.readAsString()) as Map<String, Object?>;
        githubToken = (_settings['githubToken'] as String?) ?? '';
        themeMode = switch (_settings['themeMode'] as String?) {
          'dark' => ThemeMode.dark,
          'light' => ThemeMode.light,
          _ => ThemeMode.system,
        };
      }
    } catch (_) {
      // 設定が壊れていても起動は続ける。
    }
    await _refreshUefiImages();
    notifyListeners();
  }

  Future<void> setGithubToken(String token) async {
    githubToken = token.trim();
    _settings['githubToken'] = githubToken;
    await _saveSettings();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    _settings['themeMode'] = mode.name;
    notifyListeners();
    await _saveSettings();
  }

  /// ライブラリのメタデータ（メモ・取得元）: uefi-images/library.json
  Map<String, Map<String, Object?>> _libraryMeta = {};
  bool _libraryMetaLoaded = false;

  Future<File> _libraryMetaFile() async => File(
      '${(await _uefiImagesDir()).path}${Platform.pathSeparator}library.json');

  Future<void> _loadLibraryMeta() async {
    try {
      final file = await _libraryMetaFile();
      if (await file.exists()) {
        final json =
            jsonDecode(await file.readAsString()) as Map<String, Object?>;
        _libraryMeta = {
          for (final e in json.entries)
            e.key: (e.value as Map).cast<String, Object?>(),
        };
      }
    } catch (_) {
      _libraryMeta = {};
    }
    _libraryMetaLoaded = true;
  }

  Future<void> _saveLibraryMeta() async {
    final file = await _libraryMetaFile();
    await file.writeAsString(jsonEncode(_libraryMeta));
  }

  Future<void> _refreshUefiImages() async {
    if (!_libraryMetaLoaded) await _loadLibraryMeta();
    final dir = await _uefiImagesDir();
    final entries = <UefiImageEntry>[];
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.img')) {
        final stat = await entity.stat();
        final name = entity.uri.pathSegments.last;
        final bytes = await entity.readAsBytes();
        final meta = _libraryMeta[name] ?? const {};
        entries.add(UefiImageEntry(
          name: name,
          path: entity.path,
          sizeBytes: stat.size,
          modified: stat.modified,
          fingerprintShort:
              BootImage.fingerprintHex(bytes).substring(0, 12),
          sourceLabel: meta['sourceLabel'] as String?,
          memo: (meta['memo'] as String?) ?? '',
        ));
      }
    }
    entries.sort((a, b) => b.modified.compareTo(a.modified));
    uefiImages = entries;
    if (selectedUefiImagePath != null &&
        !entries.any((e) => e.path == selectedUefiImagePath)) {
      selectedUefiImagePath = null;
    }
  }

  /// イメージにメモを付ける（「v3.2 本番」など）。
  Future<void> setUefiMemo(String path, String memo) async {
    final name = path.split(RegExp(r'[\\/]')).last;
    final meta = _libraryMeta[name] ??= {};
    meta['memo'] = memo;
    await _saveLibraryMeta();
    await _refreshUefiImages();
    notifyListeners();
  }

  void selectUefiImage(String path) {
    selectedUefiImagePath = path;
    notifyListeners();
  }

  /// ローカルファイルを取り込む（形式検証を通ったものだけ）。
  Future<void> addUefiImage(String sourcePath) async {
    await _guard(() async {
      final problem = await BootImage.validateFile(sourcePath);
      if (problem != null) {
        throw StateError('UEFI イメージとして使えません: $problem');
      }
      final dir = await _uefiImagesDir();
      final name = sourcePath.split(RegExp(r'[\\/]')).last;
      var target = File('${dir.path}${Platform.pathSeparator}$name');
      if (await target.exists()) {
        final stem = name.replaceAll(RegExp(r'\.img$'), '');
        target = File(
            '${dir.path}${Platform.pathSeparator}$stem-${DateTime.now().millisecondsSinceEpoch}.img');
      }
      await File(sourcePath).copy(target.path);
      logger.info('UEFI イメージを取り込みました: ${target.uri.pathSegments.last}');
      await _refreshUefiImages();
      selectedUefiImagePath = target.path;
    });
  }

  /// Mu-Silicium の Actions から最新の成功 run の UEFI を取得する。
  Future<void> downloadLatestUefi() async {
    await _guard(() async {
      logger.info('GitHub Actions の最新 UEFI を取得します…');
      final client = GitHubActionsClient(token: githubToken);
      final result = await client.fetchLatestArtifactFile(
        owner: 'frost-1256',
        repo: 'Mu-Silicium',
        workflowFileName: 'spacewar.yml',
        artifactName: 'uefi-spacewar',
      );
      final problem = BootImage.validateBytes(result.fileBytes);
      if (problem != null) {
        throw StateError('取得したイメージが不正です: $problem');
      }
      final dir = await _uefiImagesDir();
      final name = 'Mu-spacewar-run${result.run.runNumber}.img';
      final target = File('${dir.path}${Platform.pathSeparator}$name');
      await target.writeAsBytes(result.fileBytes);
      final meta = _libraryMeta[name] ??= {};
      meta['sourceLabel'] =
          'Actions Run #${result.run.runNumber} (${result.run.headSha})';
      await _saveLibraryMeta();
      logger.info(
          'Run #${result.run.runNumber} (${result.run.headSha}) の UEFI を保存しました: $name');
      await _refreshUefiImages();
      selectedUefiImagePath = target.path;
    });
  }

  // ---- 再起動系 ----

  bool get _selectedIsAdb =>
      selected != null &&
      selected!.mode != DeviceMode.fastboot &&
      selected!.mode != DeviceMode.unauthorized &&
      selected!.mode != DeviceMode.offline &&
      selected!.mode != DeviceMode.unknown;

  Future<void> _afterReboot() async {
    selected = null;
    primaryTable = null;
    layout = null;
    massStorage = null;
    notifyListeners();
    await Future<void>.delayed(const Duration(seconds: 6));
    await refreshDevices();
  }

  /// ブートローダー (fastboot) へ再起動する。
  Future<void> rebootToBootloader() async {
    final device = selected;
    if (device == null) return;
    await _guard(() async {
      logger.info('${device.serial} をブートローダーへ再起動します');
      if (device.mode == DeviceMode.fastboot) {
        await FastbootClient(_runner).rebootBootloader(device.serial);
      } else if (_selectedIsAdb) {
        await AdbClient(_runner).reboot(device.serial, target: 'bootloader');
      } else {
        throw StateError('このモードでは実行できません');
      }
      logger.info('再起動しました。fastboot モードで検出されるはずです');
    });
    await _afterReboot();
  }

  /// Recovery へ再起動する（Recovery モード自身では出さない）。
  Future<void> rebootToRecovery() async {
    final device = selected;
    if (device == null || device.mode == DeviceMode.recovery) return;
    await _guard(() async {
      logger.info('${device.serial} を Recovery へ再起動します');
      if (device.mode == DeviceMode.fastboot) {
        await FastbootClient(_runner).rebootRecovery(device.serial);
      } else if (_selectedIsAdb) {
        await AdbClient(_runner).reboot(device.serial, target: 'recovery');
      } else {
        throw StateError('このモードでは実行できません');
      }
    });
    await _afterReboot();
  }

  bool get canBootUefi =>
      selected?.mode == DeviceMode.fastboot && selectedUefiImagePath != null;

  /// 選択中の fastboot 端末で、選択中のイメージを一時ブートする。
  Future<void> bootSelectedUefi() async {
    final device = selected;
    final imagePath = selectedUefiImagePath;
    if (device == null || imagePath == null || !canBootUefi) return;
    await _guard(() async {
      logger.info(
          '${device.serial} で UEFI を一時ブートします: ${imagePath.split(RegExp(r'[\\/]')).last}');
      await FastbootClient(_runner).boot(
        device.serial,
        imagePath,
        onOutput: (line) => logger.info('fastboot: $line'),
      );
      logger.info('ブートイメージを送信しました。端末側で UEFI が起動します。');
    });
  }

  Future<void> _guard(Future<void> Function() body) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      await body();
    } catch (e) {
      error = e.toString();
      logger.error(e.toString());
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}
