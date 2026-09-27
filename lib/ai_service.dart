import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'cloud_config.dart';
import 'models.dart';

class AiService {
  static const String _model = 'deepseek-flash';

  static bool get isConfigured => CloudConfig.isConfigured;

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
        'You are Life Style AI, a concise textile/product studio assistant.',
      )
      ..writeln(
        'Help with boutique products, descriptions, catalogues, size charts, colours, and product presentation.',
      )
      ..writeln('Reply in the user\'s casual Tanglish style when appropriate.')
      ..writeln(
        'Be practical and specific. When images are attached, inspect them and use visible details in your reply.',
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
        )
        ..writeln('Has product image: ${product.productImage != null}')
        ..writeln('Has colour set image: ${product.colorSetImage != null}')
        ..writeln('Has poster image: ${product.posterImage != null}');
    }

    final referenceImages = product == null
        ? const <Uint8List>[]
        : <Uint8List>[
            if (product.productImage != null) product.productImage!,
            if (product.colorSetImage != null) product.colorSetImage!,
            if (product.posterImage != null) product.posterImage!,
          ];
    final requestImages = [...referenceImages, ...images];

    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': system.toString()},
      for (final item in history) _toApiMessage(item),
      {
        'role': 'user',
        'content': _buildUserContent(message: message, images: requestImages),
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
        'You are an expert ecommerce product photographer and FLUX prompt writer.',
      )
      ..writeln(
        'Create one production-ready prompt for a premium ecommerce product image.',
      )
      ..writeln(
        'Preserve the reference product identity, construction, material, colours, patterns, proportions, and visible branding exactly.',
      )
      ..writeln(
        'Specify composition, camera angle, lighting, background, product placement, realistic material detail, clean shadows, and commercial retouching.',
      )
      ..writeln(
        'Do not invent extra products, text, logos, watermarks, hands, or props unless the user explicitly asks for them.',
      )
      ..writeln(
        'Return only the final FLUX prompt as plain text. Do not add a title, explanation, markdown, quotes, or alternatives.',
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
    }

    final referenceImages = product == null
        ? const <Uint8List>[]
        : <Uint8List>[
            if (product.productImage != null) product.productImage!,
            if (product.colorSetImage != null) product.colorSetImage!,
          ];
    final requestImages = [...referenceImages, ...images];
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
          images: requestImages,
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
    final productImages = <Uint8List>[
      if (product?.productImage != null) product!.productImage!,
      if (product?.colorSetImage != null) product!.colorSetImage!,
      ...images,
    ];
    if (productImages.isEmpty) {
      throw StateError('Attach a product image before detecting colours.');
    }
    final result = await _sendMessages(
      messages: [
        {
          'role': 'system',
          'content': '''You are a textile ecommerce colour specialist.
Inspect the supplied product images and return a concise colour-set report using exactly this template:
PRIMARY: <commercial colour name>
SECONDARY: <comma-separated colours or None>
ACCENTS: <comma-separated colours or None>
UNDERTONE: <warm, cool, or neutral>
LISTING COLOURS: <customer-friendly comma-separated names>
Do not identify the product or add commentary. Do not use markdown.''',
        },
        {
          'role': 'user',
          'content': _buildUserContent(
            message: message.isEmpty
                ? 'Detect the complete product colour set.'
                : message,
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
          'content':
              '''You are a senior ecommerce art director and FLUX prompt writer.
Study every supplied reference. Create one master prompt for a finished ecommerce poster that unifies the strongest generated product view with the original product references.
Preserve product identity, construction, material, colours, patterns, proportions, and visible branding. Specify hierarchy, product placement, background, lighting, camera treatment, negative space, and premium commercial retouching.
Do not request invented logos, unreadable copy, extra products, hands, or people unless explicitly requested.
Return only the final English FLUX prompt as plain text.''',
        },
        {
          'role': 'user',
          'content': _buildUserContent(
            message:
                'Product: ${product?.name ?? 'Uncatalogued product'}\n'
                'Reference notes: ${product?.referenceDescription ?? '(none)'}\n'
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
          'content':
              '''Identify the actual ecommerce product category from the image.
Return only a natural 2-5 word product name combining the visible material or construction with the real category, for example Cotton Nightwear, Ribbed Knit Top, Printed Rayon Kurti, or Linen Blend Shirt.
Never use a colour as the main product name. Do not mention background, model, gender, brand, style adjectives, punctuation, or explanations.''',
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
    final images = <Uint8List>[
      if (product.productImage != null) product.productImage!,
      if (product.colorSetImage != null) product.colorSetImage!,
      if (product.posterImage != null) product.posterImage!,
    ];
    final templateRules = switch (template) {
      ProductDescriptionTemplate.catalogue =>
        '''Use exactly this layout:
<PRODUCT NAME>
<one polished 2-sentence catalogue paragraph>

Material: <value or Not specified>
Available sizes: <value or Not specified>
Colours: <value or Not specified>
Price: <value or Contact for price>
Ideal for: <short use cases>
Care: <only when supported, otherwise Not specified>''',
      ProductDescriptionTemplate.whatsapp =>
        '''Use exactly this layout:
<PRODUCT NAME>
<one friendly sales sentence>

Material: <value or Not specified>
Sizes: <value or Not specified>
Colours: <value or Not specified>
Price: <value or Contact for price>

Message us to order.''',
      ProductDescriptionTemplate.social =>
        '''Use exactly this layout:
<PRODUCT NAME>
<two short engaging caption sentences>

Material: <value or Not specified>
Sizes: <value or Not specified>
Colours: <value or Not specified>
Price: <value or Contact for price>

<3-5 relevant hashtags>''',
    };
    return _sendMessages(
      messages: [
        {
          'role': 'system',
          'content': '''You write accurate ecommerce product descriptions.
Extract loosely typed price, size, material, and product details from the reference notes. Use the supplied product name and category consistently. Inspect images for visible product facts, but never invent factual specifications. Preserve currency exactly as entered. Return only the completed template with no markdown fences or explanation.

$templateRules''',
        },
        {
          'role': 'user',
          'content': _buildUserContent(
            message:
                'Product name: ${product.name}\n'
                'Detected colour set: ${product.detectedColorSet.isEmpty ? '(none)' : product.detectedColorSet}\n'
                'Reference notes: ${product.referenceDescription}',
            images: images,
          ),
        },
      ],
      temperature: 0.35,
      throwOnError: true,
    );
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
      'content': message.isUser
          ? _buildUserContent(
              message: message.prompt ?? message.text,
              images: message.imageBytesList,
            )
          : message.text,
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
