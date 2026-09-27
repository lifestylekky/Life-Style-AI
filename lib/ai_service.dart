import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'cloud_config.dart';
import 'models.dart';
import 'supabase_service.dart';

class AiService {
  static const String _model = 'deepseek-flash';
  static Map<String, String> _promptProfiles = const {};

  static bool get isConfigured => CloudConfig.isConfigured;

  static Future<void> refreshPromptProfiles(SupabaseService service) async {
    try {
      final profiles = await service.loadPromptProfiles();
      if (profiles.isNotEmpty) _promptProfiles = profiles;
    } catch (_) {
      // Built-in fallbacks keep the app usable during a temporary config outage.
    }
  }

  static String _profile(String key, String fallback) =>
      _promptProfiles[key]?.trim().isNotEmpty == true
      ? _promptProfiles[key]!.trim()
      : fallback;

  static Future<String> chat({
    required String message,
    Product? product,
    List<Uint8List> images = const [],
    List<ChatMessage> history = const [],
  }) async {
    if (!isConfigured) {
      return 'DeepSeek API key is not configured for this build.';
    }

    final system = StringBuffer()
      ..writeln(
        _profile(
          'assistant_profile',
          'You are Life Style AI, a concise ecommerce product-studio assistant. Be practical, specific, and never invent product facts. Inspect only images explicitly attached to the current request.',
        ),
      );

    if (product != null) {
      system
        ..writeln('\nCurrent product context:')
        ..writeln('Name: ${product.name}')
        ..writeln(
          'Reference: ${product.referenceDescription.isEmpty ? '(none)' : product.referenceDescription}',
        )
        ..writeln(
          'Description: ${product.description.isEmpty ? '(none)' : product.description}',
        );
      if (product.memorySummary.isNotEmpty) {
        system.writeln('Product memory: ${product.memorySummary}');
      }
    }

    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': system.toString()},
      for (final item in history) _toApiMessage(item),
      {
        'role': 'user',
        'content': _buildUserContent(message: message, images: images),
      },
    ];

    return _sendMessages(messages: messages, temperature: 0.7);
  }

  static Future<String> productImagePrompt({
    required String message,
    Product? product,
    List<Uint8List> images = const [],
    List<ChatMessage> history = const [],
  }) async {
    if (!isConfigured) {
      throw StateError('DeepSeek API key is not configured for this build.');
    }

    final system = StringBuffer()
      ..writeln(
        _profile(
          'product_image',
          'Create one production-ready English FLUX prompt for a premium ecommerce product image. Preserve the selected reference exactly and return only the final prompt.',
        ),
      );

    if (product != null) {
      system
        ..writeln('\nProduct record:')
        ..writeln('Name: ${product.name}')
        ..writeln(
          'Reference notes: ${product.referenceDescription.isEmpty ? '(none)' : product.referenceDescription}',
        )
        ..writeln(
          'Description: ${product.description.isEmpty ? '(none)' : product.description}',
        );
      if (product.memorySummary.isNotEmpty) {
        system.writeln('Product memory: ${product.memorySummary}');
      }
    }

    final recentTextHistory = history
        .where((item) => item.text != 'Styling')
        .take(6)
        .map(
          (item) => <String, dynamic>{
            'role': item.isUser ? 'user' : 'assistant',
            'content': item.text,
          },
        );
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': system.toString()},
      ...recentTextHistory,
      {
        'role': 'user',
        'content': _buildUserContent(
          message:
              'Create the final ecommerce image-generation prompt for this request: $message',
          images: images,
        ),
      },
    ];

    final prompt = await _sendMessages(
      messages: messages,
      temperature: 0.35,
      throwOnError: true,
    );
    return _cleanPrompt(prompt);
  }

  static Future<String> detectColorSet({
    required String message,
    Product? product,
    List<Uint8List> images = const [],
    List<ChatMessage> history = const [],
  }) async {
    final productImages = images.isNotEmpty
        ? images
        : <Uint8List>[
            if (product?.productImage != null) product!.productImage!,
          ];
    if (productImages.isEmpty) {
      throw StateError('Attach a product image before detecting colours.');
    }
    final result = await _sendMessages(
      messages: [
        {
          'role': 'system',
          'content': _profile(
            'color_detection',
            'Inspect the supplied product reference and return valid JSON with summary and colors fields. Each color needs name, hex, and generation_instruction. Do not use markdown fences.',
          ),
        },
        {
          'role': 'user',
          'content': _buildUserContent(
            message:
                'Product: ${product?.name ?? 'Uncatalogued product'}\n'
                '${product?.memorySummary.isNotEmpty == true ? 'Product memory: ${product!.memorySummary}\n' : ''}'
                '${message.isEmpty ? 'Detect the complete product colour set.' : message}',
            images: productImages,
          ),
        },
      ],
      temperature: 0.2,
      throwOnError: true,
    );
    return result.trim();
  }

  static Future<String> posterPrompt({
    required String message,
    Product? product,
    List<Uint8List> images = const [],
    List<ChatMessage> history = const [],
  }) async {
    if (images.isEmpty) {
      throw StateError('A poster needs at least one reference image.');
    }
    final prompt = await _sendMessages(
      messages: [
        {
          'role': 'system',
          'content': _profile(
            'poster',
            'Create one master English FLUX prompt for a finished ecommerce poster using only the supplied references. Preserve product identity and return only the prompt.',
          ),
        },
        {
          'role': 'user',
          'content': _buildUserContent(
            message:
                'Product: ${product?.name ?? 'Uncatalogued product'}\n'
                'Reference notes: ${product?.referenceDescription ?? '(none)'}\n'
                '${product?.memorySummary.isNotEmpty == true ? 'Product memory: ${product!.memorySummary}\n' : ''}'
                'Poster request: $message',
            images: images,
          ),
        },
      ],
      temperature: 0.3,
      throwOnError: true,
    );
    return _cleanPrompt(prompt);
  }

  static Future<String> identifyProductName(Uint8List image) async {
    final result = await _sendMessages(
      messages: [
        {
          'role': 'system',
          'content': _profile(
            'product_name',
            'Identify the actual ecommerce product. Return only a natural 2-5 word product name using material or construction and category. Never use colour as the main name.',
          ),
        },
        {
          'role': 'user',
          'content': _buildUserContent(
            message: 'Return the product name only.',
            images: [image],
          ),
        },
      ],
      temperature: 0.1,
      throwOnError: true,
    );
    return _cleanSingleLine(result);
  }

  static Future<String> productDescription({
    required Product product,
    required ProductDescriptionTemplate template,
  }) async {
    final templateKey = switch (template) {
      ProductDescriptionTemplate.catalogue => 'description_catalogue',
      ProductDescriptionTemplate.whatsapp => 'description_whatsapp',
      ProductDescriptionTemplate.social => 'description_social',
    };
    final fallback = switch (template) {
      ProductDescriptionTemplate.catalogue =>
        'Write an accurate catalogue listing with exact product name, material, sizes, colours, price, use, and care. Never invent facts.',
      ProductDescriptionTemplate.whatsapp =>
        '''Return a WhatsApp listing with 🛍 *PRODUCT NAME*, 📦 _CATEGORY_, each 📏 size and 💰 LKR price tier, location 12 Main Street Kattankudy 03, contacts 0767051440 / 0768509808, WhatsApp group https://chat.whatsapp.com/D6oa6LZ5zeB4mApF25EPrb, island-wide delivery, Life Style, and Specialist in UnderGarments. Use keycap emoji digits for every price.''',
      ProductDescriptionTemplate.social =>
        'Write an accurate concise social caption with exact product name, sizes, prices, material, colours, and 3-5 hashtags.',
    };
    return _sendMessages(
      messages: [
        {'role': 'system', 'content': _profile(templateKey, fallback)},
        {
          'role': 'user',
          'content': _buildUserContent(
            message:
                'Product name: ${product.name}\n'
                'Detected colour set: ${product.detectedColorSet.isEmpty ? '(none)' : product.detectedColorSet}\n'
                'Product memory: ${product.memorySummary.isEmpty ? '(none)' : product.memorySummary}\n'
                'Reference notes: ${product.referenceDescription}',
            images: [if (product.productImage != null) product.productImage!],
          ),
        },
      ],
      temperature: 0.35,
      throwOnError: true,
    );
  }

  static Future<bool> referenceMatches({
    required Uint8List savedProduct,
    required Uint8List newReference,
  }) async {
    final result = await _sendMessages(
      messages: [
        {
          'role': 'system',
          'content': _profile(
            'reference_match',
            'Compare image 1 and image 2. Return only SAME if they show the same underlying product or a colour variant; otherwise return only DIFFERENT.',
          ),
        },
        {
          'role': 'user',
          'content': _buildUserContent(
            message:
                'Image 1 is the saved product. Image 2 is the new reference.',
            images: [savedProduct, newReference],
          ),
        },
      ],
      temperature: 0,
      throwOnError: true,
    );
    return _cleanSingleLine(result).toUpperCase().startsWith('SAME');
  }

  static Future<String> colorVariantPrompt({
    required Product product,
    required ProductColorVariant color,
    required Uint8List reference,
  }) async {
    final result = await _sendMessages(
      messages: [
        {
          'role': 'system',
          'content': _profile(
            'color_variant',
            'Create one FLUX editing prompt that changes only the selected product colour while preserving every other product and scene detail. Return only the prompt.',
          ),
        },
        {
          'role': 'user',
          'content': _buildUserContent(
            message:
                'Product: ${product.name}\nRequested colour: ${color.name} (${color.hex})\nColour instruction: ${color.generationInstruction}\n${product.memorySummary.isEmpty ? '' : 'Product memory: ${product.memorySummary}'}',
            images: [reference],
          ),
        },
      ],
      temperature: 0.2,
      throwOnError: true,
    );
    return _cleanPrompt(result);
  }

  static Future<String> summarizeProductMemory({
    required Product product,
    required List<ChatMessage> messages,
  }) async {
    final exchange = messages
        .where((message) => message.kind == ChatMessageKind.text)
        .map(
          (message) =>
              '${message.isUser ? 'User' : 'Assistant'}: ${message.text}',
        )
        .join('\n');
    final result = await _sendMessages(
      messages: [
        {
          'role': 'system',
          'content': _profile(
            'memory_summary',
            'Update the product memory using the previous memory and newest exchange. Return no more than 100 words and prioritize recent confirmed facts.',
          ),
        },
        {
          'role': 'user',
          'content':
              'Product: ${product.name}\nPrevious memory: ${product.memorySummary.isEmpty ? '(none)' : product.memorySummary}\nNewest exchange:\n$exchange',
        },
      ],
      temperature: 0.15,
      throwOnError: true,
    );
    final words = result.trim().split(RegExp(r'\s+'));
    return words.length <= 100 ? result.trim() : words.take(100).join(' ');
  }

  static Future<String> _sendMessages({
    required List<Map<String, dynamic>> messages,
    required double temperature,
    bool throwOnError = false,
  }) async {
    try {
      final res = await http
          .post(
            Uri.parse(CloudConfig.endpoint('/v1/deepseek')),
            headers: CloudConfig.headers(json: true),
            body: jsonEncode({
              'model': _model,
              'temperature': temperature,
              'messages': messages,
            }),
          )
          .timeout(const Duration(seconds: 90));

      if (res.statusCode < 200 || res.statusCode >= 300) {
        final error = _readableApiError(res.statusCode, res.body);
        if (throwOnError) throw StateError(error);
        return error;
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final choices = data['choices'] as List<dynamic>?;
      final first = choices?.isNotEmpty == true
          ? choices!.first as Map<String, dynamic>
          : null;
      final msg = first?['message'] as Map<String, dynamic>?;
      final content = msg?['content'];
      if (content is String && content.trim().isNotEmpty) {
        return content.trim();
      }
      const error = 'DeepSeek returned an empty reply. Try again.';
      if (throwOnError) throw StateError(error);
      return '($error)';
    } on TimeoutException {
      const error =
          'DeepSeek took too long to respond. Check your connection and try again.';
      if (throwOnError) throw TimeoutException(error);
      return error;
    } on http.ClientException {
      const error =
          'Could not connect to DeepSeek. Check your internet connection and try again.';
      if (throwOnError) throw StateError(error);
      return error;
    } on FormatException {
      const error = 'DeepSeek returned an invalid response. Please try again.';
      if (throwOnError) throw const FormatException(error);
      return error;
    } catch (error) {
      if (throwOnError) rethrow;
      return 'DeepSeek request failed. Please try again. ($error)';
    }
  }

  static String _cleanPrompt(String value) {
    var prompt = value.trim();
    if (prompt.startsWith('```') && prompt.endsWith('```')) {
      prompt = prompt.replaceFirst(RegExp(r'^```(?:text)?\s*'), '');
      prompt = prompt.replaceFirst(RegExp(r'\s*```$'), '').trim();
    }
    if (prompt.length >= 2 &&
        ((prompt.startsWith('"') && prompt.endsWith('"')) ||
            (prompt.startsWith("'") && prompt.endsWith("'")))) {
      prompt = prompt.substring(1, prompt.length - 1).trim();
    }
    return prompt;
  }

  static String _cleanSingleLine(String value) {
    final cleaned = _cleanPrompt(value)
        .split(RegExp(r'[\r\n]+'))
        .first
        .replaceAll(RegExp(r'^[#*\-\s]+|[#*\-\s]+$'), '')
        .trim();
    if (cleaned.isEmpty || cleaned.length > 80) {
      throw const FormatException('DeepSeek returned an invalid product name.');
    }
    return cleaned;
  }

  static Map<String, dynamic> _toApiMessage(ChatMessage message) {
    return {
      'role': message.isUser ? 'user' : 'assistant',
      'content': message.isUser ? message.prompt ?? message.text : message.text,
    };
  }

  static String _readableApiError(int statusCode, String body) {
    try {
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final error = decoded['error'];
      if (error is Map<String, dynamic> && error['message'] is String) {
        return 'DeepSeek error $statusCode: ${error['message']}';
      }
    } catch (_) {
      // Fall back to the status code when the server response is not JSON.
    }
    return 'DeepSeek error $statusCode. Please check the API key and try again.';
  }

  static Object _buildUserContent({
    required String message,
    required List<Uint8List> images,
  }) {
    if (images.isEmpty) return message;

    final content = <Map<String, dynamic>>[
      {'type': 'text', 'text': message},
    ];

    for (final image in images) {
      final mimeType = _detectImageMimeType(image);
      content.add({
        'type': 'image_url',
        'image_url': {
          'url': 'data:$mimeType;base64,${base64Encode(image)}',
          'detail': 'auto',
        },
      });
    }

    return content;
  }

  static String _detectImageMimeType(Uint8List bytes) {
    if (bytes.length >= 4 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return 'image/png';
    }
    if (bytes.length >= 6 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38) {
      return 'image/gif';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'image/webp';
    }
    return 'image/jpeg';
  }
}
