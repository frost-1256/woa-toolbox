import 'dart:io';

import 'package:crypto/crypto.dart';

import '../gpt/gpt_reader.dart';

/// 大きな LBA 範囲・ファイルをチャンク単位で処理する共有ヘルパー。
///
/// パーティション全量を 1 回の readLbas / readAsBytes でメモリに載せると、
/// 数十 GiB のパーティションで OOM する（実機テストで 32 GiB の win
/// 読み取りがアプリを落とした）。ここでは読み・書き・ハッシュをすべて
/// チャンク逐次処理にし、メモリ使用量をチャンクサイズ程度に抑える。

/// 既定のチャンクサイズ（バイト）。adb exec-out 1 回分の転送量と
/// 呼び出し回数のバランスで決めた値。
const int defaultStreamChunkBytes = 64 * 1024 * 1024;

/// [chunkBytes] からチャンクあたりのセクタ数を決める（最低 1）。
int _chunkSectors(LbaReader reader, int chunkBytes) {
  final sectors = chunkBytes ~/ reader.sectorSize;
  return sectors < 1 ? 1 : sectors;
}

void _checkRange(int startLba, int count) {
  if (startLba < 0) {
    throw ArgumentError.value(startLba, 'startLba', '負の LBA は不正です');
  }
  if (count < 0) {
    throw ArgumentError.value(count, 'count', '負のセクタ数は不正です');
  }
}

/// sha256.startChunkedConversion の受け口。close 時に Digest が 1 回だけ
/// 流れてくる（crypto の契約。複数回来たら契約違反として assert で気づく）。
class _DigestSink implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest data) {
    assert(digest == null, 'Digest は close 時に 1 回だけのはずです');
    digest = data;
  }

  @override
  void close() {}
}

/// LBA 範囲をチャンク単位で読みながらファイルへ逐次書き出し、
/// SHA-256 も逐次計算する。戻り値は書き出したバイト数と SHA-256。
///
/// 各チャンクのバイト数が期待値と違う場合は StateError
/// （転送完全性の検証。AdbLbaReader 側でも同じ検証をしている）。
/// 書き出しは `<file>.partial` に対して行い、全チャンク成功後に
/// 最終名へ rename する。途中で失敗した場合は .partial を消し、
/// 最終名のファイルは作らない（部分イメージの誤用防止）。
/// [count] が 0 の場合は空ファイルと空入力のハッシュで成功する。
Future<({int sizeBytes, String sha256})> writeLbaRangeToFile(
  LbaReader reader,
  int startLba,
  int count,
  File file, {
  int chunkBytes = defaultStreamChunkBytes,
  void Function(int doneBytes, int totalBytes)? onChunk,
}) async {
  _checkRange(startLba, count);
  final sectorSize = reader.sectorSize;
  final totalBytes = count * sectorSize;
  final step = _chunkSectors(reader, chunkBytes);
  final digestSink = _DigestSink();
  final byteSink = sha256.startChunkedConversion(digestSink);
  final partial = File('${file.path}.partial');
  final out = partial.openWrite();
  var doneSectors = 0;
  var doneBytes = 0;
  Object? primaryError;
  StackTrace? primaryStack;
  try {
    while (doneSectors < count) {
      final remaining = count - doneSectors;
      final n = remaining < step ? remaining : step;
      final chunk = await reader.readLbas(startLba + doneSectors, n);
      if (chunk.length != n * sectorSize) {
        throw StateError('チャンクの受信バイト数が一致しません: '
            '期待 ${n * sectorSize} / 実際 ${chunk.length} '
            '(LBA ${startLba + doneSectors} +$n)');
      }
      out.add(chunk);
      byteSink.add(chunk);
      // チャンクごとに flush して書き込み側のバックプレッシャにする
      // （add の完了を待たないと、遅いディスクで未書き込みチャンクが
      // キューに溜まり続けてメモリ上限が保証されなくなる）。
      await out.flush();
      doneSectors += n;
      doneBytes += chunk.length;
      onChunk?.call(doneBytes, totalBytes);
    }
  } catch (e, st) {
    primaryError = e;
    primaryStack = st;
  }
  // close 系の例外で元の例外をマスクしない（先に起きた方を優先）。
  try {
    await out.close();
  } catch (e, st) {
    primaryError ??= e;
    primaryStack ??= st;
  }
  try {
    byteSink.close();
  } catch (e, st) {
    primaryError ??= e;
    primaryStack ??= st;
  }
  if (primaryError != null) {
    // 失敗時は .partial を残さない（大きなゴミと誤用の防止）。
    try {
      if (await partial.exists()) await partial.delete();
    } catch (_) {
      // 掃除の失敗で元の例外を隠さない。
    }
    Error.throwWithStackTrace(primaryError, primaryStack!);
  }
  // 全チャンク成功後にだけ最終名へ載せる。
  if (await file.exists()) await file.delete();
  await partial.rename(file.path);
  final digest = digestSink.digest;
  if (digest == null) {
    throw StateError('SHA-256 の計算が完了しませんでした');
  }
  return (sizeBytes: doneBytes, sha256: digest.toString());
}

/// LBA 範囲をチャンク単位で読み、SHA-256 だけを逐次計算する
/// （書き込み後の読み戻し検証用）。[count] が 0 の場合は空入力の
/// ハッシュを返す。
Future<String> hashLbaRange(
  LbaReader reader,
  int startLba,
  int count, {
  int chunkBytes = defaultStreamChunkBytes,
  void Function(int doneBytes, int totalBytes)? onChunk,
}) async {
  _checkRange(startLba, count);
  final sectorSize = reader.sectorSize;
  final totalBytes = count * sectorSize;
  final step = _chunkSectors(reader, chunkBytes);
  final digestSink = _DigestSink();
  final byteSink = sha256.startChunkedConversion(digestSink);
  var doneSectors = 0;
  var doneBytes = 0;
  try {
    while (doneSectors < count) {
      final remaining = count - doneSectors;
      final n = remaining < step ? remaining : step;
      final chunk = await reader.readLbas(startLba + doneSectors, n);
      if (chunk.length != n * sectorSize) {
        throw StateError('チャンクの受信バイト数が一致しません: '
            '期待 ${n * sectorSize} / 実際 ${chunk.length} '
            '(LBA ${startLba + doneSectors} +$n)');
      }
      byteSink.add(chunk);
      doneSectors += n;
      doneBytes += chunk.length;
      onChunk?.call(doneBytes, totalBytes);
    }
  } finally {
    byteSink.close();
  }
  final digest = digestSink.digest;
  if (digest == null) {
    throw StateError('SHA-256 の計算が完了しませんでした');
  }
  return digest.toString();
}

/// ファイルをストリームで読み、長さと SHA-256 を逐次計算する
/// （復元前のバックアップファイル照合用）。[onChunk] には
/// 読み進んだバイト数とファイル全長を渡す。
Future<({int length, String sha256})> hashFileContents(
  File file, {
  void Function(int doneBytes, int totalBytes)? onChunk,
}) async {
  final totalBytes = await file.length();
  final digestSink = _DigestSink();
  final byteSink = sha256.startChunkedConversion(digestSink);
  var length = 0;
  try {
    await for (final chunk in file.openRead()) {
      byteSink.add(chunk);
      length += chunk.length;
      onChunk?.call(length, totalBytes);
    }
  } finally {
    byteSink.close();
  }
  final digest = digestSink.digest;
  if (digest == null) {
    throw StateError('SHA-256 の計算が完了しませんでした');
  }
  return (length: length, sha256: digest.toString());
}
