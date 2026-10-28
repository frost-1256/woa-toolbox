import 'dart:convert';

/// バックアップ1ファイル分の記録（設計書 §5.2）。
class BackupFileEntry {
  const BackupFileEntry({
    required this.fileName,
    required this.partitionName,
    required this.sizeBytes,
    required this.sha256,
  });

  final String fileName;
  final String partitionName;
  final int sizeBytes;
  final String sha256;

  Map<String, Object?> toJson() => {
        'fileName': fileName,
        'partitionName': partitionName,
        'sizeBytes': sizeBytes,
        'sha256': sha256,
      };

  factory BackupFileEntry.fromJson(Map<String, Object?> json) =>
      BackupFileEntry(
        fileName: json['fileName'] as String,
        partitionName: json['partitionName'] as String,
        sizeBytes: json['sizeBytes'] as int,
        sha256: json['sha256'] as String,
      );
}

/// バックアップの manifest。端末識別情報を必須とし、復元は
/// 取得した端末にだけ許可する（設計書 §5.2 / §5.3）。
class BackupManifest {
  const BackupManifest({
    required this.deviceSerial,
    required this.productDevice,
    required this.createdAt,
    required this.layoutFingerprint,
    required this.files,
  });

  final String deviceSerial;
  final String productDevice;
  final DateTime createdAt;

  /// 取得時点の GPT フィンガープリント（GptTable.fingerprint）。
  final String layoutFingerprint;
  final List<BackupFileEntry> files;

  Map<String, Object?> toJson() => {
        'version': 1,
        'deviceSerial': deviceSerial,
        'productDevice': productDevice,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'layoutFingerprint': layoutFingerprint,
        'files': files.map((f) => f.toJson()).toList(),
      };

  factory BackupManifest.fromJson(Map<String, Object?> json) {
    if (json['version'] != 1) {
      throw FormatException('未対応の manifest バージョンです: ${json['version']}');
    }
    return BackupManifest(
      deviceSerial: json['deviceSerial'] as String,
      productDevice: json['productDevice'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      layoutFingerprint: json['layoutFingerprint'] as String,
      files: (json['files'] as List)
          .map((f) => BackupFileEntry.fromJson(f as Map<String, Object?>))
          .toList(),
    );
  }

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  factory BackupManifest.decode(String text) =>
      BackupManifest.fromJson(jsonDecode(text) as Map<String, Object?>);

  /// このバックアップを [serial] の端末に復元してよいか。
  bool isForDevice(String serial) => deviceSerial == serial;
}

/// manifest と実ファイルの照合結果の問題点。
class ManifestProblem {
  const ManifestProblem(this.fileName, this.detail);
  final String fileName;
  final String detail;
  @override
  String toString() => '$fileName: $detail';
}

/// manifest と、ファイル名→(サイズ, sha256) の実測値を照合する。
List<ManifestProblem> verifyManifest(
  BackupManifest manifest,
  Map<String, ({int sizeBytes, String sha256})> actual,
) {
  final problems = <ManifestProblem>[];
  for (final entry in manifest.files) {
    final found = actual[entry.fileName];
    if (found == null) {
      problems.add(ManifestProblem(entry.fileName, 'ファイルがありません'));
      continue;
    }
    if (found.sizeBytes != entry.sizeBytes) {
      problems.add(ManifestProblem(entry.fileName,
          'サイズ不一致: manifest ${entry.sizeBytes} / 実測 ${found.sizeBytes}'));
    }
    if (found.sha256 != entry.sha256) {
      problems.add(ManifestProblem(entry.fileName, 'SHA-256 不一致'));
    }
  }
  return problems;
}
