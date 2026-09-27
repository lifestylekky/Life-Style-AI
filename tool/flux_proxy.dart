import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

const _fluxApiBase = 'https://api.fluxapi.ai';
const _githubApiBase = 'https://api.github.com';
final _random = Random.secure();
final _generations = <String, _Generation>{};
String? _authenticationError;

Future<void> main() async {
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8787;
  final bindHost = (Platform.environment['FLUX_PROXY_HOST'] ?? '127.0.0.1')
      .trim();
  final apiKey = (Platform.environment['FLUXAPI_KEY'] ?? '').trim();
  if (apiKey.isEmpty) {
    stderr.writeln('Set FLUXAPI_KEY before starting the FLUX proxy.');
    exitCode = 64;
    return;
  }

  final github = _GitHubConfig.fromEnvironment();
  final server = await HttpServer.bind(bindHost, port);
  final client = http.Client();
  _authenticationError = await _checkAuthentication(client, apiKey);
  if (_authenticationError != null) {
    stderr.writeln('FLUX proxy authentication failed: $_authenticationError');
  }
  stdout.writeln('FLUX proxy listening on http://$bindHost:$port');
  if (github == null) {
    stdout.writeln(
      'Reference uploads are disabled. Set GITHUB_TOKEN and '
      'GITHUB_REPOSITORY=owner/repo to enable them.',
    );
  }

  await for (final request in server) {
    unawaited(_handle(request, client, apiKey, github));
  }
}

Future<void> _handle(
  HttpRequest request,
  http.Client client,
  String apiKey,
  _GitHubConfig? github,
) async {
  _cors(request.response);
  if (request.method == 'OPTIONS') {
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
    return;
  }

  try {
    switch ((request.method, request.uri.path)) {
      case ('GET', '/health'):
        await _json(request.response, HttpStatus.ok, {
          'status': _authenticationError == null ? 'ok' : 'misconfigured',
          'authenticated': _authenticationError == null,
          'provider': 'FluxAPI.ai',
          'referenceUploads': github != null,
          if (_authenticationError != null) 'error': _authenticationError,
        });
      case ('POST', '/v1/flux-pro-1.1'):
        await _submit(request, client, apiKey, github);
      case ('GET', '/v1/get_result'):
        await _poll(request, client, apiKey, github);
      case ('GET', '/v1/image'):
        await _image(request, client);
      default:
        await _json(request.response, HttpStatus.notFound, {
          'error': 'Not found',
        });
    }
  } catch (error) {
    try {
      await _json(request.response, HttpStatus.badGateway, {
        'error': 'FLUX proxy request failed: $error',
      });
    } catch (_) {
      // The response may already be closed after an upstream stream failure.
    }
  }
}

Future<String?> _checkAuthentication(http.Client client, String apiKey) async {
  try {
    final response = await client
        .get(
          Uri.parse(
            '$_fluxApiBase/api/v1/flux/kontext/record-info?taskId=auth-check',
          ),
          headers: _fluxHeaders(apiKey),
        )
        .timeout(const Duration(seconds: 15));
    final payload = _decodeObject(response.body);
    if (response.statusCode >= 200 &&
        response.statusCode < 300 &&
        payload['code'] != 401) {
      return null;
    }
    return 'FluxAPI.ai returned HTTP ${response.statusCode}: '
        '${payload['msg'] ?? response.body}';
  } catch (error) {
    return 'Could not validate FLUXAPI_KEY: $error';
  }
}

Future<void> _submit(
  HttpRequest request,
  http.Client client,
  String apiKey,
  _GitHubConfig? github,
) async {
  final incoming = _decodeObject(await utf8.decoder.bind(request).join());
  final prompt = incoming['prompt'];
  if (prompt is! String || prompt.trim().isEmpty) {
    await _json(request.response, HttpStatus.badRequest, {
      'error': 'A non-empty prompt is required.',
    });
    return;
  }

  _GitHubUpload? reference;
  final encodedReference = incoming['image_prompt'];
  if (encodedReference is String && encodedReference.isNotEmpty) {
    if (github == null) {
      await _json(request.response, HttpStatus.serviceUnavailable, {
        'error':
            'Reference image uploads are not configured. Set '
            'GITHUB_TOKEN and GITHUB_REPOSITORY on the proxy.',
      });
      return;
    }
    reference = await _uploadReference(client, github, encodedReference);
  }

  try {
    final width = incoming['width'] as num?;
    final height = incoming['height'] as num?;
    final upstream = await client
        .post(
          Uri.parse('$_fluxApiBase/api/v1/flux/kontext/generate'),
          headers: _fluxHeaders(apiKey, json: true),
          body: jsonEncode({
            'prompt': prompt.trim(),
            'aspectRatio': _aspectRatio(width, height),
            'model': 'flux-kontext-pro',
            'outputFormat': 'jpeg',
            'promptUpsampling': incoming['prompt_upsampling'] == true,
            'safetyTolerance': incoming['safety_tolerance'] ?? 2,
            'enableTranslation': true,
            if (reference != null) 'inputImage': reference.downloadUrl,
          }),
        )
        .timeout(const Duration(seconds: 45));

    final payload = _decodeObject(upstream.body);
    final data = payload['data'];
    final taskId = data is Map<String, dynamic> ? data['taskId'] : null;
    if (upstream.statusCode < 200 ||
        upstream.statusCode >= 300 ||
        payload['code'] != 200 ||
        taskId is! String ||
        taskId.isEmpty) {
      if (reference != null) {
        await _deleteReference(client, github!, reference);
      }
      await _json(request.response, _upstreamStatus(upstream, payload), {
        'error': payload['msg'] ?? 'FluxAPI.ai did not create the task.',
      });
      return;
    }

    final token = _token();
    _generations[token] = _Generation(
      taskId: taskId,
      createdAt: DateTime.now(),
      reference: reference,
    );
    await _removeExpired(client, github);
    await _json(request.response, HttpStatus.ok, {
      'id': taskId,
      'polling_url': '${_origin(request)}/v1/get_result?token=$token',
    });
  } catch (_) {
    if (reference != null && github != null) {
      await _deleteReference(client, github, reference);
    }
    rethrow;
  }
}

Future<void> _poll(
  HttpRequest request,
  http.Client client,
  String apiKey,
  _GitHubConfig? github,
) async {
  final token = request.uri.queryParameters['token'];
  final generation = token == null ? null : _generations[token];
  if (generation == null) {
    await _json(request.response, HttpStatus.notFound, {
      'error': 'Unknown or expired generation token.',
    });
    return;
  }

  final uri = Uri.parse(
    '$_fluxApiBase/api/v1/flux/kontext/record-info',
  ).replace(queryParameters: {'taskId': generation.taskId});
  final upstream = await client
      .get(uri, headers: _fluxHeaders(apiKey))
      .timeout(const Duration(seconds: 30));
  final payload = _decodeObject(upstream.body);
  if (upstream.statusCode < 200 ||
      upstream.statusCode >= 300 ||
      payload['code'] != 200) {
    await _json(request.response, _upstreamStatus(upstream, payload), {
      'error': payload['msg'] ?? 'FluxAPI.ai polling failed.',
    });
    return;
  }

  final data = payload['data'];
  if (data is! Map<String, dynamic>) {
    throw const FormatException('FluxAPI.ai returned invalid task data.');
  }
  final flag = data['successFlag'];
  if (flag == 0) {
    await _json(request.response, HttpStatus.ok, {'status': 'Pending'});
    return;
  }

  await _cleanReference(client, github, generation);
  if (flag == 1) {
    final result = data['response'];
    final imageUrl = result is Map<String, dynamic>
        ? result['resultImageUrl']
        : null;
    if (imageUrl is! String || imageUrl.isEmpty) {
      throw const FormatException('FluxAPI.ai completed without an image URL.');
    }
    generation.imageUrl = Uri.parse(imageUrl);
    await _json(request.response, HttpStatus.ok, {
      'status': 'Ready',
      'result': {'sample': '${_origin(request)}/v1/image?token=$token'},
    });
    return;
  }

  await _json(request.response, HttpStatus.ok, {
    'status': 'Failed',
    'details': data['errorMessage'] ?? 'FluxAPI.ai generation failed.',
  });
}

Future<void> _image(HttpRequest request, http.Client client) async {
  final token = request.uri.queryParameters['token'];
  final generation = token == null ? null : _generations[token];
  final imageUrl = generation?.imageUrl;
  if (generation == null || imageUrl == null) {
    await _json(request.response, HttpStatus.notFound, {
      'error': 'The generated image is not ready or has expired.',
    });
    return;
  }

  final upstream = await client
      .get(imageUrl)
      .timeout(const Duration(seconds: 60));
  request.response.statusCode = upstream.statusCode;
  request.response.headers.contentType = ContentType.parse(
    upstream.headers['content-type'] ?? 'image/jpeg',
  );
  request.response.add(upstream.bodyBytes);
  await request.response.close();
  if (upstream.statusCode >= 200 && upstream.statusCode < 300) {
    _generations.remove(token);
  }
}

Future<_GitHubUpload> _uploadReference(
  http.Client client,
  _GitHubConfig config,
  String encoded,
) async {
  final bytes = base64Decode(encoded.split(',').last);
  if (bytes.length > 10 * 1024 * 1024) {
    throw const FormatException('Reference images must be 10 MB or smaller.');
  }
  final extension = _imageExtension(bytes);
  final path =
      '${config.pathPrefix}/${DateTime.now().millisecondsSinceEpoch}-'
      '${_token().substring(0, 10)}.$extension';
  final uri = Uri.parse(
    '$_githubApiBase/repos/${config.repository}/contents/$path',
  );
  final response = await client
      .put(
        uri,
        headers: _githubHeaders(config.token),
        body: jsonEncode({
          'message': 'Add temporary FLUX reference image',
          'content': base64Encode(bytes),
          'branch': config.branch,
        }),
      )
      .timeout(const Duration(seconds: 45));
  final payload = _decodeObject(response.body);
  final content = payload['content'];
  final downloadUrl = content is Map<String, dynamic>
      ? content['download_url']
      : null;
  final sha = content is Map<String, dynamic> ? content['sha'] : null;
  if (response.statusCode < 200 ||
      response.statusCode >= 300 ||
      downloadUrl is! String ||
      sha is! String) {
    throw StateError(
      'GitHub reference upload failed (${response.statusCode}): '
      '${payload['message'] ?? 'invalid response'}',
    );
  }
  return _GitHubUpload(path: path, sha: sha, downloadUrl: downloadUrl);
}

Future<void> _deleteReference(
  http.Client client,
  _GitHubConfig config,
  _GitHubUpload upload,
) async {
  final uri = Uri.parse(
    '$_githubApiBase/repos/${config.repository}/contents/${upload.path}',
  );
  try {
    await client
        .delete(
          uri,
          headers: _githubHeaders(config.token),
          body: jsonEncode({
            'message': 'Remove temporary FLUX reference image',
            'sha': upload.sha,
            'branch': config.branch,
          }),
        )
        .timeout(const Duration(seconds: 30));
  } catch (error) {
    stderr.writeln('Could not clean up ${upload.path}: $error');
  }
}

Future<void> _cleanReference(
  http.Client client,
  _GitHubConfig? github,
  _Generation generation,
) async {
  final reference = generation.reference;
  if (reference == null || github == null) return;
  generation.reference = null;
  await _deleteReference(client, github, reference);
}

Future<void> _removeExpired(http.Client client, _GitHubConfig? github) async {
  final cutoff = DateTime.now().subtract(const Duration(minutes: 15));
  final expired = _generations.entries
      .where((entry) => entry.value.createdAt.isBefore(cutoff))
      .toList();
  for (final entry in expired) {
    await _cleanReference(client, github, entry.value);
    _generations.remove(entry.key);
  }
}

Map<String, String> _fluxHeaders(String apiKey, {bool json = false}) => {
  'accept': 'application/json',
  'Authorization': 'Bearer $apiKey',
  if (json) 'Content-Type': 'application/json',
};

Map<String, String> _githubHeaders(String token) => {
  'accept': 'application/vnd.github+json',
  'Authorization': 'Bearer $token',
  'X-GitHub-Api-Version': '2022-11-28',
  'Content-Type': 'application/json',
};

Map<String, dynamic> _decodeObject(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Upstream returned an invalid JSON response.');
  }
  return decoded;
}

String _aspectRatio(num? width, num? height) {
  if (width == null || height == null || height == 0) return '1:1';
  final ratio = width / height;
  if (ratio > 1.15) return '4:3';
  if (ratio < 0.86) return '3:4';
  return '1:1';
}

String _imageExtension(List<int> bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47) {
    return 'png';
  }
  if (bytes.length >= 12 &&
      ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
      ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
    return 'webp';
  }
  return 'jpg';
}

int _upstreamStatus(http.Response response, Map<String, dynamic> payload) {
  if (response.statusCode < 200 || response.statusCode >= 300) {
    return response.statusCode;
  }
  return payload['code'] == 401
      ? HttpStatus.unauthorized
      : HttpStatus.badGateway;
}

Future<void> _json(
  HttpResponse response,
  int status,
  Map<String, dynamic> body,
) async {
  response.statusCode = status;
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode(body));
  await response.close();
}

void _cors(HttpResponse response) {
  response.headers
    ..set('Access-Control-Allow-Origin', '*')
    ..set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
    ..set('Access-Control-Allow-Headers', 'Content-Type');
}

String _origin(HttpRequest request) {
  return buildProxyOrigin(
    requestedScheme: request.requestedUri.scheme,
    requestedAuthority: request.requestedUri.authority,
    hostHeader: request.headers.value(HttpHeaders.hostHeader),
    forwardedHost: request.headers.value('x-forwarded-host'),
    forwardedPort: request.headers.value('x-forwarded-port'),
    forwardedProto: request.headers.value('x-forwarded-proto'),
    configuredOrigin: Platform.environment['PUBLIC_BASE_URL'],
  );
}

String buildProxyOrigin({
  required String requestedScheme,
  required String requestedAuthority,
  String? hostHeader,
  String? forwardedHost,
  String? forwardedPort,
  String? forwardedProto,
  String? configuredOrigin,
}) {
  final explicitOrigin = (configuredOrigin ?? '').trim().replaceAll(
    RegExp(r'/+$'),
    '',
  );
  if (explicitOrigin.isNotEmpty) return explicitOrigin;

  final proxyHost = forwardedHost?.split(',').first.trim();
  var host = proxyHost?.isNotEmpty == true
      ? proxyHost!
      : hostHeader ?? requestedAuthority;
  final proxyPort = forwardedPort?.split(',').first.trim();
  if (proxyPort?.isNotEmpty == true && !Uri.parse('http://$host').hasPort) {
    host = '$host:$proxyPort';
  }
  final protocol = forwardedProto?.split(',').first.trim() ?? requestedScheme;
  return '$protocol://$host';
}

String _token() => base64Url
    .encode(List<int>.generate(24, (_) => _random.nextInt(256)))
    .replaceAll('=', '');

class _Generation {
  _Generation({
    required this.taskId,
    required this.createdAt,
    required this.reference,
  });

  final String taskId;
  final DateTime createdAt;
  _GitHubUpload? reference;
  Uri? imageUrl;
}

class _GitHubUpload {
  const _GitHubUpload({
    required this.path,
    required this.sha,
    required this.downloadUrl,
  });

  final String path;
  final String sha;
  final String downloadUrl;
}

class _GitHubConfig {
  const _GitHubConfig({
    required this.token,
    required this.repository,
    required this.branch,
    required this.pathPrefix,
  });

  static _GitHubConfig? fromEnvironment() {
    final token = (Platform.environment['GITHUB_TOKEN'] ?? '').trim();
    final repository = (Platform.environment['GITHUB_REPOSITORY'] ?? '').trim();
    if (token.isEmpty && repository.isEmpty) return null;
    if (token.isEmpty || !repository.contains('/')) {
      throw const FormatException(
        'Set both GITHUB_TOKEN and GITHUB_REPOSITORY=owner/repo.',
      );
    }
    return _GitHubConfig(
      token: token,
      repository: repository,
      branch: (Platform.environment['GITHUB_BRANCH'] ?? 'main').trim(),
      pathPrefix:
          (Platform.environment['GITHUB_UPLOAD_PATH'] ?? 'flux-references')
              .trim()
              .replaceAll(RegExp(r'^/+|/+$'), ''),
    );
  }

  final String token;
  final String repository;
  final String branch;
  final String pathPrefix;
}
