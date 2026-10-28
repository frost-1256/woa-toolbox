import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

class GitHubApiException implements Exception {
  GitHubApiException(this.statusCode, this.message);
  final int statusCode;
  final String message;
  @override
  String toString() => 'GitHub API エラー ($statusCode): $message';
}

class GitHubRun {
  const GitHubRun({
    required this.id,
    required this.runNumber,
    required this.headSha,
    required this.htmlUrl,
  });
  final int id;
  final int runNumber;
  final String headSha;
  final String htmlUrl;
}

class GitHubArtifact {
  const GitHubArtifact({
    required this.id,
    required this.name,
    required this.sizeBytes,
  });
  final int id;
  final String name;
  final int sizeBytes;
}

/// workflow runs 一覧の JSON から最新の成功 run を取り出す（テスト可能な純関数）。
GitHubRun? parseLatestSuccessfulRun(Map<String, Object?> json) {
  final runs = json['workflow_runs'];
  if (runs is! List || runs.isEmpty) return null;
  final run = runs.first as Map<String, Object?>;
  return GitHubRun(
    id: run['id'] as int,
    runNumber: run['run_number'] as int,
    headSha: (run['head_sha'] as String).substring(0, 7),
    htmlUrl: run['html_url'] as String,
  );
}

/// artifacts 一覧の JSON から名前で探す（テスト可能な純関数）。
GitHubArtifact? parseArtifactByName(
    Map<String, Object?> json, String name) {
  final artifacts = json['artifacts'];
  if (artifacts is! List) return null;
  for (final a in artifacts) {
    final artifact = a as Map<String, Object?>;
    if (artifact['name'] == name && artifact['expired'] != true) {
      return GitHubArtifact(
        id: artifact['id'] as int,
        name: name,
        sizeBytes: artifact['size_in_bytes'] as int,
      );
    }
  }
  return null;
}

/// zip バイト列から、名前が [fileName] で終わるファイルを取り出す
/// （テスト可能な純関数）。
Uint8List extractFileFromZip(Uint8List zipBytes, String fileName) {
  final archive = ZipDecoder().decodeBytes(zipBytes);
  for (final file in archive) {
    if (file.isFile && file.name.endsWith(fileName)) {
      return Uint8List.fromList(file.content as List<int>);
    }
  }
  throw StateError('zip の中に $fileName が見つかりません');
}

/// 成果物 zip からブートイメージ (.img) を取り出す。
/// Mu-Silicium の成果物の中身は boot.img ではなく Mu-spacewar.img のような
/// 名前なので、.img を探して Mu- 始まりを優先する。
Uint8List extractBootImageFromZip(Uint8List zipBytes) {
  final archive = ZipDecoder().decodeBytes(zipBytes);
  final images = archive.files
      .where((f) => f.isFile && f.name.endsWith('.img'))
      .toList();
  if (images.isEmpty) {
    throw StateError('zip の中に .img ファイルが見つかりません');
  }
  images.sort((a, b) {
    final aMu = a.name.split('/').last.startsWith('Mu-') ? 0 : 1;
    final bMu = b.name.split('/').last.startsWith('Mu-') ? 0 : 1;
    return aMu.compareTo(bMu);
  });
  return Uint8List.fromList(images.first.content as List<int>);
}

/// GitHub Actions の成果物を取得するクライアント。
/// 成果物のダウンロードは公開リポジトリでも認証が必須なため、
/// 呼び出し側がユーザーのトークン（Actions 読み取り権限）を渡す。
/// トークンはログに出さない。
class GitHubActionsClient {
  GitHubActionsClient({this.token, HttpClient Function()? httpClientFactory})
      : _httpClientFactory = httpClientFactory ?? HttpClient.new;

  final String? token;
  final HttpClient Function() _httpClientFactory;

  Future<Map<String, Object?>> _getJson(Uri uri) async {
    final client = _httpClientFactory();
    try {
      final request = await client.getUrl(uri);
      request.headers.set('Accept', 'application/vnd.github+json');
      request.headers.set('X-GitHub-Api-Version', '2022-11-28');
      if (token != null && token!.isNotEmpty) {
        request.headers.set('Authorization', 'Bearer $token');
      }
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        throw GitHubApiException(
            response.statusCode, _errorHint(response.statusCode, body));
      }
      return jsonDecode(body) as Map<String, Object?>;
    } finally {
      client.close();
    }
  }

  String _errorHint(int status, String body) {
    if (status == 401 || status == 403) {
      return '認証に失敗しました。トークンが未設定か、Actions の読み取り権限がありません。';
    }
    if (status == 404) {
      return 'リポジトリまたはワークフローが見つかりません。';
    }
    return body.length > 200 ? body.substring(0, 200) : body;
  }

  Future<GitHubRun?> latestSuccessfulRun(
    String owner,
    String repo,
    String workflowFileName,
  ) async {
    final uri = Uri.parse(
        'https://api.github.com/repos/$owner/$repo/actions/workflows/$workflowFileName/runs?status=success&per_page=1');
    return parseLatestSuccessfulRun(await _getJson(uri));
  }

  Future<GitHubArtifact?> artifactForRun(
    String owner,
    String repo,
    int runId,
    String artifactName,
  ) async {
    final uri = Uri.parse(
        'https://api.github.com/repos/$owner/$repo/actions/runs/$runId/artifacts');
    return parseArtifactByName(await _getJson(uri), artifactName);
  }

  /// 成果物 zip をダウンロードする（要トークン）。
  Future<Uint8List> downloadArtifactZip(
    String owner,
    String repo,
    int artifactId,
  ) async {
    if (token == null || token!.isEmpty) {
      throw GitHubApiException(
          401, '成果物のダウンロードには GitHub トークンが必要です');
    }
    final uri = Uri.parse(
        'https://api.github.com/repos/$owner/$repo/actions/artifacts/$artifactId/zip');
    final client = _httpClientFactory();
    try {
      final request = await client.getUrl(uri);
      request.headers.set('Authorization', 'Bearer $token');
      request.followRedirects = true;
      final response = await request.close();
      if (response.statusCode != 200) {
        final body = await response.transform(utf8.decoder).join();
        throw GitHubApiException(
            response.statusCode, _errorHint(response.statusCode, body));
      }
      final builder = BytesBuilder();
      await for (final chunk in response) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } finally {
      client.close();
    }
  }

  /// 最新の成功 run から成果物を取り出し、中のファイルまで一気に取得する。
  Future<({GitHubRun run, GitHubArtifact artifact, Uint8List fileBytes})>
      fetchLatestArtifactFile({
    required String owner,
    required String repo,
    required String workflowFileName,
    required String artifactName,
  }) async {
    final run = await latestSuccessfulRun(owner, repo, workflowFileName);
    if (run == null) {
      throw StateError('成功したワークフロー実行が見つかりません');
    }
    final artifact = await artifactForRun(owner, repo, run.id, artifactName);
    if (artifact == null) {
      throw StateError('成果物 $artifactName が見つかりません (run #${run.runNumber})');
    }
    final zip = await downloadArtifactZip(owner, repo, artifact.id);
    final bytes = extractBootImageFromZip(zip);
    return (run: run, artifact: artifact, fileBytes: bytes);
  }
}
