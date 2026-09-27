import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'cloud_config.dart';
import 'models.dart';

class SupabaseService implements ProductPersistence {
  SupabaseService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  @override
  Future<List<Product>> loadProducts() async {
    if (!CloudConfig.isConfigured) return [];
    final response = await _client
        .get(
          Uri.parse(CloudConfig.endpoint('/v1/products')),
          headers: CloudConfig.headers(),
        )
        .timeout(const Duration(seconds: 45));
    _ensureSuccess(response, 'Product load');
    final payload = _object(response.body);
    final records = payload['products'];
    if (records is! List) return [];
    return Future.wait(
      records.whereType<Map<String, dynamic>>().map(_productFromJson),
    );
  }

  @override
  Future<void> saveProduct(Product product) async {
    if (!CloudConfig.isConfigured) return;
    final uploadedByBytes = <int, String>{};

    Future<String?> ensureImage(
      Uint8List? bytes,
      String? currentUrl,
      String kind,
    ) async {
      if (currentUrl?.isNotEmpty == true) return currentUrl;
      if (bytes == null) return null;
      final identity = identityHashCode(bytes);
      final cached = uploadedByBytes[identity];
      if (cached != null) return cached;
      final url = await _uploadImage(product.id, kind, bytes);
      uploadedByBytes[identity] = url;
      return url;
    }

    product.productImageUrl = await ensureImage(
      product.productImage,
      product.productImageUrl,
      'product',
    );
    product.colorSetImageUrl = await ensureImage(
      product.colorSetImage,
      product.colorSetImageUrl,
      'colour-set',
    );
    product.posterImageUrl = await ensureImage(
      product.posterImage,
      product.posterImageUrl,
      'poster',
    );

    final messages = <Map<String, dynamic>>[];
    for (var position = 0; position < product.chat.length; position++) {
      final message = product.chat[position];
      while (message.imageUrls.length < message.imageBytesList.length) {
        message.imageUrls.add('');
      }
      for (var index = 0; index < message.imageBytesList.length; index++) {
        message.imageUrls[index] =
            await ensureImage(
              message.imageBytesList[index],
              message.imageUrls[index],
              message.modelLabel == null ? 'chat-reference' : 'generated',
            ) ??
            '';
      }
      messages.add(_messageToJson(message, position));
    }

    final response = await _client
        .put(
          Uri.parse(CloudConfig.endpoint('/v1/products/sync')),
          headers: CloudConfig.headers(json: true),
          body: jsonEncode({
            'product': _productToJson(product),
            'messages': messages,
          }),
        )
        .timeout(const Duration(seconds: 90));
    _ensureSuccess(response, 'Product sync');
  }

  @override
  Future<void> deleteProduct(String productId) async {
    if (!CloudConfig.isConfigured) return;
    final uri = Uri.parse(
      CloudConfig.endpoint('/v1/products'),
    ).replace(queryParameters: {'id': productId});
    final response = await _client
        .delete(uri, headers: CloudConfig.headers())
        .timeout(const Duration(seconds: 30));
    _ensureSuccess(response, 'Product delete');
  }

  Future<String> _uploadImage(
    String productId,
    String kind,
    Uint8List bytes,
  ) async {
    final response = await _client
        .post(
          Uri.parse(CloudConfig.endpoint('/v1/assets')),
          headers: CloudConfig.headers(json: true),
          body: jsonEncode({
            'product_id': productId,
            'kind': kind,
            'bytes': base64Encode(bytes),
          }),
        )
        .timeout(const Duration(seconds: 60));
    _ensureSuccess(response, 'Image upload');
    final url = _object(response.body)['url'];
    if (url is! String || url.isEmpty) {
      throw const FormatException('Image upload returned no URL.');
    }
    return url;
  }

  Future<Product> _productFromJson(Map<String, dynamic> json) async {
    final product =
        Product(
            id: json['id']?.toString() ?? '',
            name: json['name']?.toString() ?? 'Product',
            createdAt: DateTime.tryParse(
              json['created_at']?.toString() ?? '',
            )?.toLocal(),
            productImageUrl: json['product_image_url'] as String?,
            colorSetImageUrl: json['color_set_image_url'] as String?,
            posterImageUrl: json['poster_image_url'] as String?,
          )
          ..description = json['description']?.toString() ?? ''
          ..referenceDescription =
              json['reference_description']?.toString() ?? ''
          ..detectedColorSet = json['detected_color_set']?.toString() ?? ''
          ..productNameDetected = json['product_name_detected'] == true;

    final images = await Future.wait([
      _downloadImage(product.productImageUrl),
      _downloadImage(product.colorSetImageUrl),
      _downloadImage(product.posterImageUrl),
    ]);
    product
      ..productImage = images[0]
      ..colorSetImage = images[1]
      ..posterImage = images[2];

    final messages = json['messages'];
    if (messages is List) {
      for (final record in messages.whereType<Map<String, dynamic>>()) {
        product.chat.add(await _messageFromJson(record));
      }
    }
    return product;
  }

  Future<ChatMessage> _messageFromJson(Map<String, dynamic> json) async {
    final urls = (json['image_urls'] as List? ?? const [])
        .whereType<String>()
        .toList();
    final downloaded = await Future.wait(urls.map(_downloadImage));
    return ChatMessage(
      id: json['id']?.toString(),
      text: json['text']?.toString() ?? '',
      isUser: json['is_user'] == true,
      imageBytesList: downloaded.whereType<Uint8List>().toList(),
      imageUrls: urls,
      prompt: json['prompt'] as String?,
      generationPrompt: json['generation_prompt'] as String?,
      imageWidth: json['image_width'] as int?,
      imageHeight: json['image_height'] as int?,
      modelLabel: json['model_label'] as String?,
      isImageGenerationRequest: json['is_image_generation_request'] == true,
      actionName: json['action_name']?.toString() ?? 'chat',
      kind: ChatMessageKind.values.firstWhere(
        (item) => item.name == json['kind'],
        orElse: () => ChatMessageKind.text,
      ),
      progress: json['progress'] as int? ?? 0,
      timestamp: DateTime.tryParse(
        json['created_at']?.toString() ?? '',
      )?.toLocal(),
    );
  }

  Future<Uint8List?> _downloadImage(String? url) async {
    if (url == null || url.isEmpty) return null;
    try {
      final response = await _client
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 45));
      return response.statusCode >= 200 && response.statusCode < 300
          ? response.bodyBytes
          : null;
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic> _productToJson(Product product) => {
    'id': product.id,
    'name': product.name,
    'description': product.description,
    'reference_description': product.referenceDescription,
    'detected_color_set': product.detectedColorSet,
    'product_name_detected': product.productNameDetected,
    'product_image_url': product.productImageUrl,
    'color_set_image_url': product.colorSetImageUrl,
    'poster_image_url': product.posterImageUrl,
  };

  static Map<String, dynamic> _messageToJson(
    ChatMessage message,
    int position,
  ) => {
    'id': message.id,
    'position': position,
    'text': message.text,
    'is_user': message.isUser,
    'image_urls': message.imageUrls.where((url) => url.isNotEmpty).toList(),
    'prompt': message.prompt,
    'generation_prompt': message.generationPrompt,
    'image_width': message.imageWidth,
    'image_height': message.imageHeight,
    'model_label': message.modelLabel,
    'is_image_generation_request': message.isImageGenerationRequest,
    'action_name': message.actionName,
    'kind': message.kind.name,
    'progress': message.progress,
  };

  static Map<String, dynamic> _object(String body) {
    final value = jsonDecode(body);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Cloud service returned invalid JSON.');
    }
    return value;
  }

  static void _ensureSuccess(http.Response response, String operation) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    var detail = response.body;
    try {
      detail = _object(response.body)['error']?.toString() ?? detail;
    } catch (_) {}
    throw StateError('$operation failed (${response.statusCode}): $detail');
  }
}
