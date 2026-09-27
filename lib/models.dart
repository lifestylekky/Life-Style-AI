import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

enum ChatMessageKind { text, responding, styling, crafting }

enum ProductDescriptionTemplate {
  catalogue('Catalogue', 'Structured product listing'),
  whatsapp('WhatsApp', 'Compact customer-ready message'),
  social('Social', 'Caption with selling highlights');

  const ProductDescriptionTemplate(this.label, this.subtitle);

  final String label;
  final String subtitle;
}

class ProductColorVariant {
  ProductColorVariant({
    String? id,
    required this.name,
    this.hex = '#808080',
    this.generationInstruction = '',
    this.imageBytes,
    this.imageUrl,
    this.selected = false,
  }) : id = id ?? _recordId();

  final String id;
  String name;
  String hex;
  String generationInstruction;
  Uint8List? imageBytes;
  String? imageUrl;
  bool selected;
  bool isGenerating = false;
  int progress = 0;
  String? error;
}

class ChatMessage {
  ChatMessage({
    String? id,
    required this.text,
    required this.isUser,
    Uint8List? imageBytes,
    List<Uint8List>? imageBytesList,
    List<String>? imageUrls,
    this.prompt,
    this.generationPrompt,
    this.imageWidth,
    this.imageHeight,
    this.modelLabel,
    this.isImageGenerationRequest = false,
    this.actionName = 'chat',
    this.kind = ChatMessageKind.text,
    this.progress = 0,
    DateTime? timestamp,
  }) : id = id ?? _recordId(),
       imageBytesList = List.unmodifiable([?imageBytes, ...?imageBytesList]),
       imageUrls = List<String>.from(imageUrls ?? const []),
       timestamp = timestamp ?? DateTime.now();

  final String id;
  final String text;
  final bool isUser;
  final List<Uint8List> imageBytesList;
  final List<String> imageUrls;
  final String? prompt;
  final String? generationPrompt;
  final int? imageWidth;
  final int? imageHeight;
  final String? modelLabel;
  final bool isImageGenerationRequest;
  final String actionName;
  final DateTime timestamp;
  ChatMessageKind kind;
  int progress;
  bool hasAnimated = false;

  Uint8List? get imageBytes =>
      imageBytesList.isEmpty ? null : imageBytesList.first;
}

class Product {
  Product({
    required this.id,
    required this.name,
    DateTime? createdAt,
    this.productImageUrl,
    this.colorSetImageUrl,
    this.posterImageUrl,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  final DateTime createdAt;

  String name;
  Uint8List? productImage;
  Uint8List? colorSetImage;
  Uint8List? posterImage;
  String? productImageUrl;
  String? colorSetImageUrl;
  String? posterImageUrl;
  String description = '';
  String referenceDescription = '';
  String detectedColorSet = '';
  bool productNameDetected = false;
  String memorySummary = '';
  String? memoryLastMessageId;
  final List<ProductColorVariant> colorVariants = [];
  final List<ChatMessage> chat = [];

  String get generatedDescription {
    if (description.trim().isNotEmpty) return description.trim();
    return '''${name.toUpperCase()}

Premium boutique-ready textile product for Life Style collection.

• Product: $name
• Presentation: clean liquid catalogue style
• Images: original product reference${colorSetImage != null ? ', colour set reference' : ''}${posterImage != null ? ', poster design' : ''}
• Best use: catalogue, WhatsApp sharing, in-store product reference

Available details like fabric, size, colour and price can be added in the Reference Description section.''';
  }
}

abstract class ProductPersistence {
  Future<List<Product>> loadProducts();
  Future<void> saveProduct(Product product);
  Future<void> deleteProduct(String productId);
}

class ProductStore extends ChangeNotifier {
  ProductStore._();
  static final ProductStore instance = ProductStore._();

  final List<Product> products = [];
  final Map<String, Timer> _saveTimers = {};
  final Map<String, Future<void>> _saveQueues = {};
  ProductPersistence? _persistence;
  bool isLoading = false;
  String? syncError;

  void configure(ProductPersistence persistence) {
    _persistence = persistence;
  }

  Future<void> load() async {
    final persistence = _persistence;
    if (persistence == null || isLoading) return;
    isLoading = true;
    syncError = null;
    notifyListeners();
    try {
      final loaded = await persistence.loadProducts();
      products
        ..clear()
        ..addAll(loaded);
    } catch (error) {
      syncError = '$error';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Product? byId(String id) {
    for (final p in products) {
      if (p.id == id) return p;
    }
    return null;
  }

  Product createProduct({String? name, Uint8List? imageBytes}) {
    final count = products.length;
    final p = Product(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      name: (name == null || name.trim().isEmpty)
          ? 'Product ${count + 1}'
          : name.trim(),
    );
    p.productImage = imageBytes;
    products.insert(0, p);
    notifyListeners();
    _scheduleSave(p, immediate: true);
    return p;
  }

  void addChat(Product p, ChatMessage m) {
    p.chat.add(m);
    notifyListeners();
    _scheduleSave(p);
  }

  void deleteProduct(Product p) {
    products.removeWhere((item) => item.id == p.id);
    notifyListeners();
    _saveTimers.remove(p.id)?.cancel();
    final persistence = _persistence;
    if (persistence != null) {
      unawaited(
        persistence.deleteProduct(p.id).catchError((Object error) {
          syncError = '$error';
          notifyListeners();
        }),
      );
    }
  }

  void touch(Product p) {
    notifyListeners();
    _scheduleSave(p);
  }

  Future<void> flush(Product product) async {
    _saveTimers.remove(product.id)?.cancel();
    await _enqueueSave(product);
  }

  void _scheduleSave(Product product, {bool immediate = false}) {
    if (_persistence == null) return;
    _saveTimers.remove(product.id)?.cancel();
    _saveTimers[product.id] = Timer(
      immediate ? Duration.zero : const Duration(milliseconds: 650),
      () {
        _saveTimers.remove(product.id);
        unawaited(_enqueueSave(product));
      },
    );
  }

  Future<void> _enqueueSave(Product product) {
    final previous = _saveQueues[product.id] ?? Future<void>.value();
    final next = previous.catchError((_) {}).then((_) async {
      if (!products.any((item) => item.id == product.id)) return;
      try {
        await _persistence?.saveProduct(product);
        syncError = null;
      } catch (error) {
        syncError = '$error';
        notifyListeners();
      }
    });
    _saveQueues[product.id] = next;
    return next;
  }
}

final Random _idRandom = Random.secure();

String _recordId() =>
    '${DateTime.now().microsecondsSinceEpoch}-${_idRandom.nextInt(1 << 32).toRadixString(16)}';
