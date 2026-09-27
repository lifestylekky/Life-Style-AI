import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'cloud_config.dart';

enum ProductImageSize {
  square('Square', 1024, 1024, '1:1'),
  portrait('Portrait', 768, 1024, '3:4'),
  landscape('Landscape', 1024, 768, '4:3');

  const ProductImageSize(this.label, this.width, this.height, this.ratio);

  final String label;
  final int width;
  final int height;
  final String ratio;
}

class GeneratedProductImage {
  const GeneratedProductImage({
    required this.bytes,
    required this.sourceUrl,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final String sourceUrl;
  final int width;
  final int height;
}

class FluxService {
  static const _terminalFailures = {
    'Error',
    'Failed',
    'Request Moderated',
    'Content Moderated',
  };

  static Future<GeneratedProductImage> generateProductImage({
    required String prompt,
    required ProductImageSize size,
    Uint8List? referenceImage,
    void Function(int progress)? onProgress,
    http.Client? client,
  }) async {
    final ownedClient = client == null ? http.Client() : null;
    final httpClient = client ?? ownedClient!;
    try {
      onProgress?.call(2);
      final body = <String, dynamic>{
        'prompt': prompt,
        'width': size.width,
        'height': size.height,
        'prompt_upsampling': false,
        'safety_tolerance': 2,
        'output_format': 'jpeg',
        if (referenceImage != null)
          'image_prompt': base64Encode(referenceImage),
      };

      final endpoint = CloudConfig.endpoint('/v1/flux-pro-1.1');
      final submission = await httpClient
          .post(
            Uri.parse(endpoint),
            headers: CloudConfig.headers(json: true),
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 45));

      if (submission.statusCode < 200 || submission.statusCode >= 300) {
        throw StateError(
          _apiError('FLUX', submission.statusCode, submission.body),
        );
      }

      final submitted = _jsonObject(submission.body, 'FLUX submission');
      final pollingUrl = submitted['polling_url'];
      if (pollingUrl is! String || pollingUrl.isEmpty) {
        throw const FormatException('FLUX did not return a polling URL.');
      }

      onProgress?.call(8);
      final deadline = DateTime.now().add(const Duration(minutes: 3));
      var attempt = 0;
      while (DateTime.now().isBefore(deadline)) {
        final poll = await httpClient
            .get(Uri.parse(pollingUrl), headers: CloudConfig.headers())
            .timeout(const Duration(seconds: 30));

        if (poll.statusCode < 200 || poll.statusCode >= 300) {
          throw StateError(
            _apiError('FLUX polling', poll.statusCode, poll.body),
          );
        }

        final payload = _jsonObject(poll.body, 'FLUX polling');
        final status = payload['status']?.toString() ?? 'Pending';
        if (status == 'Ready') {
          final result = payload['result'];
          final imageUrl = result is Map<String, dynamic>
              ? result['sample']
              : null;
          if (imageUrl is! String || imageUrl.isEmpty) {
            throw const FormatException('FLUX completed without an image URL.');
          }

          onProgress?.call(96);
          final imageResponse = await httpClient
              .get(Uri.parse(imageUrl), headers: CloudConfig.headers())
              .timeout(const Duration(seconds: 60));
          if (imageResponse.statusCode < 200 ||
              imageResponse.statusCode >= 300) {
            throw StateError(
              'FLUX image download failed (${imageResponse.statusCode}).',
            );
          }
          onProgress?.call(100);
          return GeneratedProductImage(
            bytes: imageResponse.bodyBytes,
            sourceUrl: imageUrl,
            width: size.width,
            height: size.height,
          );
        }

        if (_terminalFailures.contains(status)) {
          final detail = payload['details'] ?? payload['error'] ?? status;
          throw StateError('FLUX generation failed: $detail');
        }

        attempt++;
        onProgress?.call((8 + attempt * 4).clamp(8, 92));
        await Future<void>.delayed(const Duration(milliseconds: 650));
      }

      throw TimeoutException('FLUX image generation took too long.');
    } finally {
      ownedClient?.close();
    }
  }

  static Map<String, dynamic> _jsonObject(String body, String source) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('$source returned an invalid response.');
    }
    return decoded;
  }

  static String _apiError(String source, int status, String body) {
    if (status == 401 || status == 403) {
      return '$source authentication failed ($status). The FluxAPI.ai key '
          'configured on the proxy was rejected. Set a valid FLUXAPI_KEY and '
          'restart the proxy.';
    }
    try {
      final payload = _jsonObject(body, source);
      final detail =
          payload['detail'] ?? payload['error'] ?? payload['message'];
      if (detail != null) return '$source error $status: $detail';
    } catch (_) {
      // Fall back to a compact status-only error for non-JSON responses.
    }
    return '$source error $status.';
  }
}
