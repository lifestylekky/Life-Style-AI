import 'dart:async';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import 'ai_service.dart';
import 'flux_service.dart';
import 'image_tools.dart';
import 'inventory_page.dart';
import 'liquid_ui.dart';
import 'models.dart';
import 'message_ui.dart';
import 'product_page.dart';

typedef ChatRequest =
    Future<String> Function({
      required String message,
      Product? product,
      List<Uint8List> images,
      List<ChatMessage> history,
    });

typedef ProductImageRequest =
    Future<GeneratedProductImage> Function({
      required String prompt,
      required ProductImageSize size,
      Uint8List? referenceImage,
      void Function(int progress)? onProgress,
    });

typedef PosterReferenceBuilder =
    Future<Uint8List> Function(List<Uint8List> images);

Future<Uint8List> _buildPosterReferenceBoard(List<Uint8List> images) =>
    compute(buildReferenceBoard, images);

enum ChatActionMode { chat, productImage, detectColors, poster }

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    this.product,
    this.chatRequest = AiService.chat,
    this.imagePromptRequest = AiService.productImagePrompt,
    this.colorSetRequest = AiService.detectColorSet,
    this.posterPromptRequest = AiService.posterPrompt,
    this.productImageRequest = FluxService.generateProductImage,
    this.productNameRequest = AiService.identifyProductName,
    this.posterReferenceBuilder = _buildPosterReferenceBoard,
  });

  final Product? product;
  final ChatRequest chatRequest;
  final ChatRequest imagePromptRequest;
  final ChatRequest colorSetRequest;
  final ChatRequest posterPromptRequest;
  final ProductImageRequest productImageRequest;
  final Future<String> Function(Uint8List image) productNameRequest;
  final PosterReferenceBuilder posterReferenceBuilder;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with TickerProviderStateMixin {
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 950),
  )..forward();
  late final AnimationController _flow = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 10),
  )..repeat();

  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<ChatMessage> _messages = [];
  final List<Uint8List> _attachedImages = [];
  ChatActionMode _actionMode = ChatActionMode.chat;
  ProductImageSize _imageSize = ProductImageSize.square;
  bool _sending = false;
  bool _detectingProductName = false;

  static const List<Map<String, String>> _suggestions = [
    {
      'icon': '🛍',
      'title': 'Create product description',
      'subtitle': 'Write boutique-ready listing copy',
    },
    {
      'icon': '🖼',
      'title': 'Generate catalogue image',
      'subtitle': 'Prepare poster/product view flow',
    },
    {
      'icon': '📐',
      'title': 'Design a size chart',
      'subtitle': 'Add sizing notes and references',
    },
    {
      'icon': '🎨',
      'title': 'Build a colour collection',
      'subtitle': 'Organise all colour references',
    },
  ];

  bool get _canSend =>
      !_sending &&
      (_input.text.trim().isNotEmpty || _attachedImages.isNotEmpty);

  @override
  void initState() {
    super.initState();
    _messages.addAll(widget.product?.chat ?? const []);
    _input.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  @override
  void dispose() {
    _entrance.dispose();
    _flow.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Animation<double> _in(double start, double end) => CurvedAnimation(
    parent: _entrance,
    curve: Interval(start, end, curve: Curves.easeOutExpo),
  );

  Widget _stagger(Animation<double> anim, Widget child) {
    return FadeTransition(
      opacity: anim,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, .06),
          end: Offset.zero,
        ).animate(anim),
        child: child,
      ),
    );
  }

  void _openInventory() => Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => const InventoryPage()));

  void _openQuickAction(String action) {
    final p = ProductStore.instance.createProduct(name: action);
    p.referenceDescription = 'Started from home shortcut: $action';
    ProductStore.instance.touch(p);
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => ProductPage(productId: p.id)));
  }

  Future<void> _pickImages({bool createProducts = false}) async {
    try {
      final files = await ImagePicker().pickMultiImage(
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 82,
      );
      if (files.isEmpty) return;
      Uint8List? firstChatImage;
      for (final f in files) {
        final bytes = await f.readAsBytes();
        if (createProducts) {
          ProductStore.instance.createProduct(imageBytes: bytes);
        } else {
          _attachedImages.add(bytes);
          firstChatImage ??= bytes;
        }
      }
      if (!mounted) return;
      setState(() {});
      if (createProducts) _openInventory();
      if (!createProducts && firstChatImage != null) {
        unawaited(_identifyProductFromFirstImage(firstChatImage));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not open gallery: $e')));
      }
    }
  }

  Future<void> _send() async {
    if (!_canSend) return;
    final text = _input.text.trim();
    final images = List<Uint8List>.from(_attachedImages);
    if (images.isNotEmpty) {
      unawaited(_identifyProductFromFirstImage(images.first));
    }
    final imageCount = images.length;
    final history = _conversationHistory();
    final action = _actionMode;
    final isImageRequest =
        action == ChatActionMode.productImage ||
        action == ChatActionMode.poster;
    final imageSize = _imageSize;
    final requestText = text.isNotEmpty
        ? text
        : switch (action) {
            ChatActionMode.productImage =>
              'Create a polished ecommerce product image from the attached reference.',
            ChatActionMode.poster =>
              'Create a premium ecommerce poster from all available product references.',
            ChatActionMode.detectColors =>
              'Detect the complete colour set in the attached product.',
            ChatActionMode.chat =>
              'I attached $imageCount image(s). Help me plan the product content.',
          };
    final pendingMessage = ChatMessage(
      text: isImageRequest
          ? 'Styling'
          : action == ChatActionMode.detectColors
          ? 'Detecting colours'
          : 'Thinking',
      isUser: false,
      kind: isImageRequest
          ? ChatMessageKind.styling
          : ChatMessageKind.responding,
      imageWidth: isImageRequest ? imageSize.width : null,
      imageHeight: isImageRequest ? imageSize.height : null,
      modelLabel: isImageRequest ? 'FLUX Kontext Pro' : null,
    );
    setState(() {
      _sending = true;
      _record(
        ChatMessage(
          text: text.isEmpty
              ? isImageRequest
                    ? 'Generate a product image'
                    : '$imageCount image attached'
              : text,
          isUser: true,
          imageBytesList: images,
          prompt: requestText,
          isImageGenerationRequest: isImageRequest,
          actionName: action.name,
          imageWidth: isImageRequest ? imageSize.width : null,
          imageHeight: isImageRequest ? imageSize.height : null,
        ),
      );
      _record(pendingMessage);
      _input.clear();
      _attachedImages.clear();
    });
    _scrollToBottom();
    // Let Flutter paint the user message and its image group before encoding
    // image bytes for the network request.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    switch (action) {
      case ChatActionMode.productImage:
        await _completeImageRequest(
          requestText,
          images,
          history,
          pendingMessage,
          imageSize,
        );
      case ChatActionMode.poster:
        await _completePosterRequest(
          requestText,
          images,
          history,
          pendingMessage,
          imageSize,
        );
      case ChatActionMode.detectColors:
        await _completeColorSetRequest(
          requestText,
          images,
          history,
          pendingMessage,
        );
      case ChatActionMode.chat:
        await _completeRequest(requestText, images, history, pendingMessage);
    }
  }

  Future<void> _identifyProductFromFirstImage(Uint8List image) async {
    final product = widget.product;
    if (product == null ||
        product.productNameDetected ||
        _detectingProductName) {
      return;
    }
    _detectingProductName = true;
    try {
      final name = await widget.productNameRequest(image);
      if (name.trim().isEmpty) return;
      product
        ..name = name.trim()
        ..productNameDetected = true
        ..productImage ??= image;
      if (identical(product.productImage, image)) {
        product.productImageUrl = null;
      }
      ProductStore.instance.touch(product);
      if (mounted) setState(() {});
    } catch (_) {
      // Product naming is intentionally silent and must not block chat.
    } finally {
      _detectingProductName = false;
    }
  }

  List<ChatMessage> _conversationHistory() {
    return _messages
        .where((message) => message.kind == ChatMessageKind.text)
        .toList();
  }

  void _record(ChatMessage message) {
    _messages.add(message);
    if (widget.product != null) {
      ProductStore.instance.addChat(widget.product!, message);
    }
  }

  Future<void> _completeRequest(
    String text,
    List<Uint8List> images,
    List<ChatMessage> history,
    ChatMessage pendingMessage,
  ) async {
    String reply;
    try {
      reply = await widget.chatRequest(
        message: text,
        product: widget.product,
        images: images,
        history: history,
      );
    } catch (error) {
      reply = 'The AI request failed. Please try again. ($error)';
    }
    final replyMessage = ChatMessage(text: reply, isUser: false, prompt: text);

    _finishPending(pendingMessage, replyMessage);
  }

  Future<void> _completeImageRequest(
    String text,
    List<Uint8List> images,
    List<ChatMessage> history,
    ChatMessage pendingMessage,
    ProductImageSize size,
  ) async {
    try {
      final generationPrompt = await widget.imagePromptRequest(
        message: text,
        product: widget.product,
        images: images,
        history: history,
      );
      if (generationPrompt.trim().isEmpty) {
        throw StateError('The image prompt was empty.');
      }

      _updatePending(
        pendingMessage,
        kind: ChatMessageKind.crafting,
        progress: 1,
      );
      final productReference = images.isNotEmpty
          ? images.first
          : widget.product?.productImage;
      final generated = await widget.productImageRequest(
        prompt: generationPrompt,
        size: size,
        referenceImage: productReference,
        onProgress: (progress) => _updatePending(
          pendingMessage,
          kind: ChatMessageKind.crafting,
          progress: progress,
        ),
      );
      final replyMessage = ChatMessage(
        text: 'Generated product image',
        isUser: false,
        imageBytesList: [generated.bytes],
        prompt: text,
        generationPrompt: generationPrompt,
        imageWidth: generated.width,
        imageHeight: generated.height,
        modelLabel: 'FLUX Kontext Pro',
        actionName: ChatActionMode.productImage.name,
      );
      if (widget.product != null) {
        widget.product!
          ..posterImage = generated.bytes
          ..posterImageUrl = null;
      }
      _finishPending(pendingMessage, replyMessage);
    } catch (error) {
      _finishPending(
        pendingMessage,
        ChatMessage(
          text: 'Image generation failed. Please try again. ($error)',
          isUser: false,
          prompt: text,
          actionName: ChatActionMode.productImage.name,
        ),
      );
    }
  }

  Future<void> _completeColorSetRequest(
    String text,
    List<Uint8List> images,
    List<ChatMessage> history,
    ChatMessage pendingMessage,
  ) async {
    try {
      final result = await widget.colorSetRequest(
        message: text,
        product: widget.product,
        images: images,
        history: history,
      );
      if (widget.product != null) {
        widget.product!.detectedColorSet = result.trim();
      }
      _finishPending(
        pendingMessage,
        ChatMessage(
          text: result.trim(),
          isUser: false,
          prompt: text,
          actionName: ChatActionMode.detectColors.name,
        ),
      );
    } catch (error) {
      _finishPending(
        pendingMessage,
        ChatMessage(
          text: 'Colour detection failed. Please try again. ($error)',
          isUser: false,
          prompt: text,
          actionName: ChatActionMode.detectColors.name,
        ),
      );
    }
  }

  Future<void> _completePosterRequest(
    String text,
    List<Uint8List> images,
    List<ChatMessage> history,
    ChatMessage pendingMessage,
    ProductImageSize size,
  ) async {
    try {
      final references = _allPosterReferences(images);
      if (references.isEmpty) {
        throw StateError('Add or generate at least one product image first.');
      }
      final masterPrompt = await widget.posterPromptRequest(
        message: text,
        product: widget.product,
        images: references,
        history: history,
      );
      if (masterPrompt.trim().isEmpty) {
        throw StateError('The poster master prompt was empty.');
      }

      _updatePending(
        pendingMessage,
        kind: ChatMessageKind.crafting,
        progress: 1,
      );
      final referenceBoard = await widget.posterReferenceBuilder(references);
      final generated = await widget.productImageRequest(
        prompt: masterPrompt,
        size: size,
        referenceImage: referenceBoard,
        onProgress: (progress) => _updatePending(
          pendingMessage,
          kind: ChatMessageKind.crafting,
          progress: progress,
        ),
      );
      final reply = ChatMessage(
        text: 'Generated product poster',
        isUser: false,
        imageBytesList: [generated.bytes],
        prompt: text,
        generationPrompt: masterPrompt,
        imageWidth: generated.width,
        imageHeight: generated.height,
        modelLabel: 'FLUX Kontext Pro',
        actionName: ChatActionMode.poster.name,
      );
      if (widget.product != null) {
        widget.product!
          ..posterImage = generated.bytes
          ..posterImageUrl = null;
      }
      _finishPending(pendingMessage, reply);
    } catch (error) {
      _finishPending(
        pendingMessage,
        ChatMessage(
          text: 'Poster generation failed. Please try again. ($error)',
          isUser: false,
          prompt: text,
          actionName: ChatActionMode.poster.name,
        ),
      );
    }
  }

  List<Uint8List> _allPosterReferences(List<Uint8List> current) {
    final references = <Uint8List>[];
    void add(Uint8List? image) {
      if (image == null || references.any((item) => listEquals(item, image))) {
        return;
      }
      references.add(image);
    }

    for (final message in _messages) {
      if (!message.isUser && message.modelLabel != null) {
        for (final image in message.imageBytesList) {
          add(image);
        }
      }
    }
    for (final image in current) {
      add(image);
    }
    add(widget.product?.productImage);
    add(widget.product?.colorSetImage);
    add(widget.product?.posterImage);
    return references;
  }

  void _updatePending(
    ChatMessage pendingMessage, {
    required ChatMessageKind kind,
    required int progress,
  }) {
    pendingMessage
      ..kind = kind
      ..progress = progress.clamp(0, 100);
    if (mounted &&
        _messages.any((message) => identical(message, pendingMessage))) {
      setState(() {});
    } else if (widget.product != null) {
      ProductStore.instance.touch(widget.product!);
    }
  }

  void _finishPending(ChatMessage pendingMessage, ChatMessage replyMessage) {
    void finishRequest() {
      _replacePending(_messages, pendingMessage, replyMessage);
      if (widget.product != null) {
        _replacePending(widget.product!.chat, pendingMessage, replyMessage);
        ProductStore.instance.touch(widget.product!);
      }
      _sending = false;
    }

    if (!mounted) {
      // Product chats outlive this route. Image requests can take long enough
      // for the user to leave, so still persist their eventual result.
      if (widget.product != null) {
        _replacePending(widget.product!.chat, pendingMessage, replyMessage);
        ProductStore.instance.touch(widget.product!);
      }
      return;
    }
    setState(finishRequest);
    _scrollToBottom();
  }

  static bool _replacePending(
    List<ChatMessage> messages,
    ChatMessage pending,
    ChatMessage reply,
  ) {
    final index = messages.indexWhere((message) => identical(message, pending));
    if (index < 0) return false;
    messages[index] = reply;
    return true;
  }

  void _editMessage(int index) {
    final message = _messages[index];
    if (!message.isUser) return;
    setState(() {
      _input.text = message.prompt ?? message.text;
      _input.selection = TextSelection.collapsed(offset: _input.text.length);
      _attachedImages
        ..clear()
        ..addAll(message.imageBytesList);
      _actionMode = ChatActionMode.values.firstWhere(
        (mode) => mode.name == message.actionName,
        orElse: () => message.isImageGenerationRequest
            ? ChatActionMode.productImage
            : ChatActionMode.chat,
      );
      if (message.imageWidth != null && message.imageHeight != null) {
        _imageSize = ProductImageSize.values.firstWhere(
          (size) =>
              size.width == message.imageWidth &&
              size.height == message.imageHeight,
          orElse: () => ProductImageSize.square,
        );
      }
      _messages.removeRange(index, _messages.length);
      if (widget.product != null) {
        widget.product!.chat.removeRange(index, widget.product!.chat.length);
        ProductStore.instance.touch(widget.product!);
      }
    });
  }

  Future<void> _regenerateMessage(int index) async {
    if (_sending) return;
    var userIndex = index - 1;
    while (userIndex >= 0 && !_messages[userIndex].isUser) {
      userIndex--;
    }
    if (userIndex < 0) return;
    final source = _messages[userIndex];
    final history = _messages
        .take(userIndex)
        .where((message) => message.kind == ChatMessageKind.text)
        .toList();
    final action = ChatActionMode.values.firstWhere(
      (mode) => mode.name == source.actionName,
      orElse: () => source.isImageGenerationRequest
          ? ChatActionMode.productImage
          : ChatActionMode.chat,
    );
    final isImageRequest =
        action == ChatActionMode.productImage ||
        action == ChatActionMode.poster;
    final size = ProductImageSize.values.firstWhere(
      (item) =>
          item.width == source.imageWidth && item.height == source.imageHeight,
      orElse: () => ProductImageSize.square,
    );
    final pendingMessage = ChatMessage(
      text: isImageRequest ? 'Styling' : 'Thinking',
      isUser: false,
      kind: isImageRequest
          ? ChatMessageKind.styling
          : ChatMessageKind.responding,
      imageWidth: isImageRequest ? size.width : null,
      imageHeight: isImageRequest ? size.height : null,
      modelLabel: isImageRequest ? 'FLUX Kontext Pro' : null,
    );
    setState(() {
      _sending = true;
      _messages.removeRange(index, _messages.length);
      if (widget.product != null) {
        widget.product!.chat.removeRange(index, widget.product!.chat.length);
      }
      _record(pendingMessage);
    });
    switch (action) {
      case ChatActionMode.productImage:
        await _completeImageRequest(
          source.prompt ?? source.text,
          source.imageBytesList,
          history,
          pendingMessage,
          size,
        );
      case ChatActionMode.poster:
        await _completePosterRequest(
          source.prompt ?? source.text,
          source.imageBytesList,
          history,
          pendingMessage,
          size,
        );
      case ChatActionMode.detectColors:
        await _completeColorSetRequest(
          source.prompt ?? source.text,
          source.imageBytesList,
          history,
          pendingMessage,
        );
      case ChatActionMode.chat:
        await _completeRequest(
          source.prompt ?? source.text,
          source.imageBytesList,
          history,
          pendingMessage,
        );
    }
  }

  Future<void> _copyMessage(ChatMessage message) async {
    await Clipboard.setData(ClipboardData(text: message.text));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Message copied')));
    }
  }

  Future<void> _shareMessage(ChatMessage message) async {
    await SharePlus.instance.share(ShareParams(text: message.text));
  }

  Future<void> _downloadGeneratedImage(ChatMessage message) async {
    if (message.imageBytesList.isEmpty) return;
    final productName = (widget.product?.name ?? 'product')
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '')
        .toLowerCase();
    try {
      await FileSaver.instance.saveAs(
        name: '${productName.isEmpty ? 'product' : productName}_generated',
        bytes: message.imageBytesList.first,
        fileExtension: 'jpg',
        mimeType: MimeType.jpeg,
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Image downloaded')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not download image: $error')),
        );
      }
    }
  }

  void _useGeneratedImageAsReference(ChatMessage message) {
    if (message.imageBytesList.isEmpty || _sending) return;
    setState(() {
      for (final image in message.imageBytesList) {
        if (!_attachedImages.any((item) => listEquals(item, image))) {
          _attachedImages.add(image);
        }
      }
      _actionMode = ChatActionMode.productImage;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Added as reference')));
  }

  Future<void> _openComposerActions() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final selection = await showModalBottomSheet<_ComposerActionSelection>(
      context: context,
      backgroundColor: const Color(0xFF10121A),
      barrierColor: Colors.black.withValues(alpha: .68),
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => _ComposerActionSheet(
        initialMode: _actionMode,
        initialSize: _imageSize,
      ),
    );
    if (selection == null || !mounted) return;
    setState(() {
      _actionMode = selection.mode;
      _imageSize = selection.size;
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bgColor,
      body: AnimatedBuilder(
        animation: _flow,
        builder: (context, _) {
          final phase = _flow.value;
          return LiquidScaffold(
            phase: phase,
            child: SafeArea(
              child: Column(
                children: [
                  _stagger(_in(0, .45), _buildHeader()),
                  Expanded(
                    child: _messages.isEmpty
                        ? _stagger(_in(.18, .78), _buildEmptyState())
                        : _buildMessageList(),
                  ),
                  if (_attachedImages.isNotEmpty) _buildAttachmentStrip(),
                  _stagger(_in(.48, 1), _buildInputBar()),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
      child: Row(
        children: [
          const SparkleIcon(size: 30),
          const SizedBox(width: 12),
          ShaderMask(
            shaderCallback: (b) => liquidGradient().createShader(b),
            blendMode: BlendMode.srcIn,
            child: Text(
              widget.product?.name ?? 'Life Style AI',
              style: jost(
                fontSize: 20,
                weight: FontWeight.w700,
                letterSpacing: 1.2,
                color: Colors.white,
              ),
            ),
          ),
          const Spacer(),
          LiquidIconButton(
            icon: Icons.inventory_2_outlined,
            tooltip: 'Inventory',
            onTap: _openInventory,
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
      children: [
        LiquidCard(
          glow: true,
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ShaderMask(
                shaderCallback: (b) => liquidGradient().createShader(b),
                blendMode: BlendMode.srcIn,
                child: Text(
                  'Create. Refine. Catalogue.',
                  style: jost(
                    fontSize: 35,
                    weight: FontWeight.w800,
                    height: .98,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Upload product photos, organise inventory, and polish the final product flow before backend/API work.',
                style: jost(
                  fontSize: 14.5,
                  weight: FontWeight.w300,
                  color: mutedText,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        ..._suggestions.map(
          (s) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _SuggestionCard(
              icon: s['icon']!,
              title: s['title']!,
              subtitle: s['subtitle']!,
              onTap: () => _openQuickAction(s['title']!),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: _QuickButton(
                icon: Icons.inventory_2_outlined,
                label: 'Inventory',
                onTap: _openInventory,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _QuickButton(
                icon: Icons.add_photo_alternate_rounded,
                label: 'Upload',
                onTap: () => _pickImages(createProducts: true),
                filled: true,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMessageList() {
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      itemCount: _messages.length,
      itemBuilder: (context, i) => _MessageBubble(
        key: ObjectKey(_messages[i]),
        message: _messages[i],
        onEdit: () => _editMessage(i),
        onRegenerate: () => _regenerateMessage(i),
        onCopy: () => _copyMessage(_messages[i]),
        onShare: () => _shareMessage(_messages[i]),
        onDownloadImage: () => _downloadGeneratedImage(_messages[i]),
        onUseAsReference: () => _useGeneratedImageAsReference(_messages[i]),
      ),
    );
  }

  Widget _buildAttachmentStrip() {
    return SizedBox(
      height: 76,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        scrollDirection: Axis.horizontal,
        itemCount: _attachedImages.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, i) => Stack(
          children: [
            GestureDetector(
              onTap: () => showImageViewer(
                context,
                images: _attachedImages,
                initialIndex: i,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.memory(
                  _attachedImages[i],
                  width: 60,
                  height: 60,
                  fit: BoxFit.cover,
                ),
              ),
            ),
            Positioned(
              right: 2,
              top: 2,
              child: GestureDetector(
                onTap: () => setState(() => _attachedImages.removeAt(i)),
                child: Container(
                  decoration: const BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close, size: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBar() {
    final imageAction =
        _actionMode == ChatActionMode.productImage ||
        _actionMode == ChatActionMode.poster;
    final hasQuickAction = _actionMode != ChatActionMode.chat;
    final actionLabel = switch (_actionMode) {
      ChatActionMode.productImage => 'Generate product image',
      ChatActionMode.poster => 'Generate poster',
      ChatActionMode.detectColors => 'Detect colour set',
      ChatActionMode.chat => '',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
      child: Container(
        decoration: glassDecoration(
          radius: 30,
          glow: true,
          color: surfaceColor.withValues(alpha: .86),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasQuickAction)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 2, 4, 5),
                child: Row(
                  children: [
                    Icon(
                      _actionMode == ChatActionMode.detectColors
                          ? Icons.palette_outlined
                          : Icons.auto_awesome_rounded,
                      size: 16,
                      color: Color(0xFF64E9FF),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      actionLabel,
                      style: jost(fontSize: 12.5, weight: FontWeight.w600),
                    ),
                    const Spacer(),
                    if (imageAction)
                      Text(
                        '${_imageSize.width} × ${_imageSize.height}',
                        style: jost(fontSize: 11, color: mutedText),
                      ),
                    IconButton(
                      tooltip: 'Return to chat mode',
                      visualDensity: VisualDensity.compact,
                      onPressed: _sending
                          ? null
                          : () => setState(
                              () => _actionMode = ChatActionMode.chat,
                            ),
                      icon: const Icon(Icons.close_rounded, size: 17),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                _ComposerToolButton(
                  icon: Icons.auto_awesome_outlined,
                  tooltip: 'Quick actions',
                  selected: hasQuickAction,
                  onTap: _sending ? null : _openComposerActions,
                ),
                const SizedBox(width: 5),
                LiquidIconButton(
                  icon: Icons.add_photo_alternate_rounded,
                  tooltip: 'Gallery',
                  onTap: () => _pickImages(),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _input,
                    onSubmitted: (_) => _send(),
                    style: jost(fontSize: 15),
                    cursorColor: const Color(0xFF64E9FF),
                    textInputAction: TextInputAction.send,
                    decoration: InputDecoration(
                      hintText: switch (_actionMode) {
                        ChatActionMode.productImage =>
                          'Describe the product shot...',
                        ChatActionMode.poster => 'Describe the poster...',
                        ChatActionMode.detectColors =>
                          'Add colour detection notes...',
                        ChatActionMode.chat =>
                          'Plan your product design flow...',
                      },
                      hintStyle: jost(
                        fontSize: 15,
                        weight: FontWeight.w300,
                        color: Colors.white.withValues(alpha: .38),
                      ),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                LiquidSendButton(onTap: _send, enabled: _canSend),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ComposerActionSelection {
  const _ComposerActionSelection({required this.mode, required this.size});

  final ChatActionMode mode;
  final ProductImageSize size;
}

class _ComposerActionSheet extends StatefulWidget {
  const _ComposerActionSheet({
    required this.initialMode,
    required this.initialSize,
  });

  final ChatActionMode initialMode;
  final ProductImageSize initialSize;

  @override
  State<_ComposerActionSheet> createState() => _ComposerActionSheetState();
}

class _ComposerActionSheetState extends State<_ComposerActionSheet> {
  late ChatActionMode _mode = widget.initialMode;
  late ProductImageSize _size = widget.initialSize;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .82,
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          4,
          20,
          22 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Quick action',
              style: jost(fontSize: 18, weight: FontWeight.w700),
            ),
            const SizedBox(height: 14),
            _ActionOption(
              icon: Icons.chat_bubble_outline_rounded,
              title: 'Ask Life Style AI',
              subtitle: 'Reply with DeepSeek',
              selected: _mode == ChatActionMode.chat,
              onTap: () => setState(() => _mode = ChatActionMode.chat),
            ),
            const SizedBox(height: 8),
            _ActionOption(
              icon: Icons.auto_awesome_rounded,
              title: 'Generate product image',
              subtitle: 'DeepSeek prompt · FLUX Kontext Pro',
              selected: _mode == ChatActionMode.productImage,
              onTap: () => setState(() => _mode = ChatActionMode.productImage),
            ),
            const SizedBox(height: 8),
            _ActionOption(
              icon: Icons.palette_outlined,
              title: 'Detect colour set',
              subtitle: 'DeepSeek product colour analysis',
              selected: _mode == ChatActionMode.detectColors,
              onTap: () => setState(() => _mode = ChatActionMode.detectColors),
            ),
            const SizedBox(height: 8),
            _ActionOption(
              icon: Icons.auto_awesome_motion_outlined,
              title: 'Generate poster',
              subtitle: 'All references · master prompt · FLUX',
              selected: _mode == ChatActionMode.poster,
              onTap: () => setState(() => _mode = ChatActionMode.poster),
            ),
            if (_mode == ChatActionMode.productImage ||
                _mode == ChatActionMode.poster) ...[
              const SizedBox(height: 18),
              Text('Image size', style: jost(fontSize: 12, color: mutedText)),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<ProductImageSize>(
                  showSelectedIcon: false,
                  segments: [
                    for (final size in ProductImageSize.values)
                      ButtonSegment(
                        value: size,
                        label: Text(size.label),
                        tooltip: '${size.width} × ${size.height}',
                      ),
                  ],
                  selected: {_size},
                  onSelectionChanged: (value) =>
                      setState(() => _size = value.single),
                ),
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => Navigator.of(
                  context,
                ).pop(_ComposerActionSelection(mode: _mode, size: _size)),
                icon: Icon(
                  _mode == ChatActionMode.productImage ||
                          _mode == ChatActionMode.poster
                      ? Icons.auto_awesome_rounded
                      : Icons.check_rounded,
                ),
                label: Text(switch (_mode) {
                  ChatActionMode.productImage => 'Use image generation',
                  ChatActionMode.poster => 'Use poster generation',
                  ChatActionMode.detectColors => 'Use colour detection',
                  ChatActionMode.chat => 'Use chat',
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionOption extends StatelessWidget {
  const _ActionOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? const Color(0xFF15313A)
          : Colors.white.withValues(alpha: .035),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(
            children: [
              Icon(
                icon,
                size: 21,
                color: selected ? const Color(0xFF64E9FF) : mutedText,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: jost(fontSize: 14, weight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: jost(fontSize: 11.5, color: mutedText),
                    ),
                  ],
                ),
              ),
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_off_rounded,
                size: 19,
                color: selected ? const Color(0xFF64E9FF) : Colors.white24,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ComposerToolButton extends StatelessWidget {
  const _ComposerToolButton({
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: selected
            ? const Color(0xFF64E9FF).withValues(alpha: .16)
            : Colors.white.withValues(alpha: .06),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 42,
            height: 42,
            child: Icon(
              icon,
              size: 20,
              color: selected ? const Color(0xFF64E9FF) : mutedText,
            ),
          ),
        ),
      ),
    );
  }
}

class _QuickButton extends StatelessWidget {
  const _QuickButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.filled = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return LiquidCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 15),
      glow: filled,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: Colors.white.withValues(alpha: .86), size: 19),
          const SizedBox(width: 8),
          Text(label, style: jost(fontSize: 14, weight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final String icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return LiquidCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Text(icon, style: const TextStyle(fontSize: 22)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: jost(fontSize: 15, weight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: jost(
                    fontSize: 12.5,
                    weight: FontWeight.w300,
                    color: Colors.white.withValues(alpha: .46),
                  ),
                ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            color: Colors.white.withValues(alpha: .35),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    super.key,
    required this.message,
    required this.onEdit,
    required this.onRegenerate,
    required this.onCopy,
    required this.onShare,
    required this.onDownloadImage,
    required this.onUseAsReference,
  });
  final ChatMessage message;
  final VoidCallback onEdit;
  final VoidCallback onRegenerate;
  final VoidCallback onCopy;
  final VoidCallback onShare;
  final VoidCallback onDownloadImage;
  final VoidCallback onUseAsReference;

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    final isPending = message.kind != ChatMessageKind.text;
    final isGeneratedImage =
        !isUser &&
        message.modelLabel != null &&
        message.imageBytesList.isNotEmpty;
    final generatedAspectRatio =
        message.imageWidth != null && message.imageHeight != null
        ? message.imageWidth! / message.imageHeight!
        : null;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.all(12),
        constraints: const BoxConstraints(maxWidth: 300),
        decoration: BoxDecoration(
          gradient: isUser ? liquidGradient(opacity: .72) : null,
          color: isUser ? null : surfaceColor.withValues(alpha: .86),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(20),
            topRight: const Radius.circular(20),
            bottomLeft: Radius.circular(isUser ? 20 : 6),
            bottomRight: Radius.circular(isUser ? 6 : 20),
          ),
          border: Border.all(color: Colors.white.withValues(alpha: .07)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.imageBytesList.isNotEmpty) ...[
              GroupedMessageImages(
                images: message.imageBytesList,
                singleWidth: isGeneratedImage ? 276 : 148,
                singleAspectRatio: isGeneratedImage
                    ? generatedAspectRatio
                    : null,
                onTap: (index) => showImageViewer(
                  context,
                  images: message.imageBytesList,
                  initialIndex: index,
                  title: isGeneratedImage
                      ? 'Generated product image'
                      : 'Reference image',
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (isPending)
              StylingIndicator(
                kind: message.kind,
                progress: message.progress,
                sizeLabel:
                    message.imageWidth != null && message.imageHeight != null
                    ? '${message.imageWidth} × ${message.imageHeight}'
                    : null,
              )
            else if (message.text.isNotEmpty)
              message.isUser
                  ? Text(
                      message.text,
                      style: jost(
                        fontSize: 14.5,
                        height: 1.35,
                        color: Colors.white.withValues(alpha: .96),
                      ),
                    )
                  : AnimatedResponseText(
                      text: message.text,
                      style: jost(
                        fontSize: 14.5,
                        height: 1.35,
                        color: Colors.white.withValues(alpha: .88),
                      ),
                      animate: !message.hasAnimated,
                      onStarted: () => message.hasAnimated = true,
                      onCompleted: () => message.hasAnimated = true,
                    ),
            if (isGeneratedImage) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(
                    Icons.auto_awesome_rounded,
                    size: 14,
                    color: Color(0xFF64E9FF),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${message.imageWidth} × ${message.imageHeight} · ${message.modelLabel}',
                      style: jost(fontSize: 11, color: mutedText),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 7),
              Row(
                children: [
                  Expanded(
                    child: _ImageActionButton(
                      icon: Icons.download_rounded,
                      label: 'Download',
                      onTap: onDownloadImage,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: _ImageActionButton(
                      icon: Icons.add_photo_alternate_outlined,
                      label: 'Reference',
                      onTap: onUseAsReference,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            if (!isPending)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    formatChatTime(context, message.timestamp),
                    style: jost(fontSize: 10.5, color: Colors.white38),
                  ),
                  const SizedBox(width: 5),
                  _MessageIconButton(
                    icon: Icons.copy_all_rounded,
                    tooltip: 'Copy message',
                    onTap: onCopy,
                  ),
                  _MessageIconButton(
                    icon: Icons.share_outlined,
                    tooltip: 'Share message',
                    onTap: onShare,
                  ),
                  if (isUser)
                    _MessageIconButton(
                      icon: Icons.edit_outlined,
                      tooltip: 'Edit message',
                      onTap: onEdit,
                    )
                  else
                    _MessageIconButton(
                      icon: Icons.refresh_rounded,
                      tooltip: 'Regenerate response',
                      onTap: onRegenerate,
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _ImageActionButton extends StatelessWidget {
  const _ImageActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: .055),
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        borderRadius: BorderRadius.circular(7),
        onTap: onTap,
        child: SizedBox(
          height: 34,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 15, color: const Color(0xFF64E9FF)),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: jost(fontSize: 11.5, weight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MessageIconButton extends StatelessWidget {
  const _MessageIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: const EdgeInsets.all(6),
      iconSize: 15,
      splashRadius: 17,
      color: Colors.white.withValues(alpha: .55),
      icon: Icon(icon),
    );
  }
}
