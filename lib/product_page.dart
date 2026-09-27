import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import 'ai_service.dart';
import 'chat_screen.dart';
import 'liquid_ui.dart';
import 'message_ui.dart';
import 'models.dart';

typedef DescriptionRequest =
    Future<String> Function({
      required Product product,
      required ProductDescriptionTemplate template,
    });

class ProductPage extends StatefulWidget {
  const ProductPage({
    super.key,
    required this.productId,
    this.descriptionRequest = AiService.productDescription,
  });

  final String productId;
  final DescriptionRequest descriptionRequest;

  @override
  State<ProductPage> createState() => _ProductPageState();
}

class _ProductPageState extends State<ProductPage>
    with TickerProviderStateMixin {
  final PageController _page = PageController();
  final TextEditingController _refController = TextEditingController();
  late final AnimationController _flow = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 10),
  )..repeat();
  int _imageIndex = 0;

  Product? get _product => ProductStore.instance.byId(widget.productId);

  @override
  void initState() {
    super.initState();
    final p = _product;
    _refController.text = p?.referenceDescription ?? '';
  }

  @override
  void dispose() {
    _page.dispose();
    _refController.dispose();
    _flow.dispose();
    super.dispose();
  }

  Future<void> _pickImage(Product p, _ImageSlot slot) async {
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 82,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      switch (slot) {
        case _ImageSlot.product:
          p
            ..productImage = bytes
            ..productImageUrl = null;
        case _ImageSlot.color:
          p
            ..colorSetImage = bytes
            ..colorSetImageUrl = null;
        case _ImageSlot.poster:
          p
            ..posterImage = bytes
            ..posterImageUrl = null;
      }
      ProductStore.instance.touch(p);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not open gallery: $e')));
      }
    }
  }

  void _copyDescription(Product p) {
    Clipboard.setData(ClipboardData(text: p.generatedDescription));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Description copied')));
  }

  Future<void> _shareProduct(Product p) async {
    await SharePlus.instance.share(
      ShareParams(text: '${p.name}\n\n${p.generatedDescription}'),
    );
  }

  Future<void> _shareOrSaveImage(
    Product p,
    Uint8List? bytes,
    String label,
  ) async {
    if (bytes == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('No $label image yet')));
      return;
    }
    await SharePlus.instance.share(
      ShareParams(
        text: '${p.name} - $label image',
        files: [
          XFile.fromData(
            bytes,
            name: '${p.name.replaceAll(' ', '_')}_$label.png',
            mimeType: 'image/png',
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: ListenableBuilder(
          listenable: ProductStore.instance,
          builder: (context, _) => Text(
            _product?.name ?? 'Product',
            style: jost(fontSize: 18, weight: FontWeight.w700),
          ),
        ),
        actions: [
          ListenableBuilder(
            listenable: ProductStore.instance,
            builder: (context, _) {
              final p = _product;
              return LiquidIconButton(
                icon: Icons.notes_rounded,
                tooltip: 'Reference details',
                onTap: p == null ? () {} : () => _showReferenceSheet(p),
              );
            },
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: AnimatedBuilder(
        animation: _flow,
        builder: (context, _) => LiquidScaffold(
          phase: _flow.value,
          child: SafeArea(
            top: false,
            child: ListenableBuilder(
              listenable: ProductStore.instance,
              builder: (context, _) {
                final p = _product;
                if (p == null) {
                  return Center(
                    child: Text(
                      'Product not found',
                      style: jost(color: mutedText),
                    ),
                  );
                }
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                  children: [
                    _HeroOverview(
                      product: p,
                      page: _page,
                      imageIndex: _imageIndex,
                      onChanged: (i) => setState(() => _imageIndex = i),
                      onPick: _pickImage,
                    ),
                    if (p.colorVariants.any(
                      (variant) => variant.imageBytes != null,
                    )) ...[
                      const SizedBox(height: 16),
                      _ColorVariantGallery(product: p),
                    ],
                    const SizedBox(height: 16),
                    _ActionGrid(
                      product: p,
                      onShare: _shareProduct,
                      onSaveImage: () =>
                          _shareOrSaveImage(p, _currentBytes(p), 'current'),
                      onChat: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ChatScreen(product: p),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _DescriptionPanel(
                      product: p,
                      onCopy: () => _copyDescription(p),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Uint8List? _currentBytes(Product p) {
    return switch (_imageIndex) {
      0 => p.productImage,
      1 => p.colorSetImage,
      _ => p.posterImage,
    };
  }

  void _showReferenceSheet(Product p) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _LiquidSheet(
        title: 'Reference Description',
        child: _ReferenceEditor(
          product: p,
          controller: _refController,
          descriptionRequest: widget.descriptionRequest,
        ),
      ),
    );
  }
}

class _ReferenceEditor extends StatefulWidget {
  const _ReferenceEditor({
    required this.product,
    required this.controller,
    required this.descriptionRequest,
  });

  final Product product;
  final TextEditingController controller;
  final DescriptionRequest descriptionRequest;

  @override
  State<_ReferenceEditor> createState() => _ReferenceEditorState();
}

class _ReferenceEditorState extends State<_ReferenceEditor> {
  ProductDescriptionTemplate _template = ProductDescriptionTemplate.whatsapp;
  bool _generating = false;

  Future<void> _generate() async {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _generating = true);
    try {
      widget.product.referenceDescription = widget.controller.text.trim();
      final description = await widget.descriptionRequest(
        product: widget.product,
        template: _template,
      );
      widget.product.description = description.trim();
      ProductStore.instance.touch(widget.product);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${_template.label} description generated')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Description generation failed: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: widget.controller,
          onChanged: (value) {
            widget.product.referenceDescription = value;
            ProductStore.instance.touch(widget.product);
          },
          minLines: 3,
          maxLines: 6,
          style: jost(height: 1.4),
          cursorColor: const Color(0xFF64E9FF),
          decoration: InputDecoration(
            hintText:
                'Add fabric, colours, sizes, price and any product notes...',
            hintStyle: jost(
              color: Colors.white.withValues(alpha: .35),
              weight: FontWeight.w300,
            ),
            border: InputBorder.none,
          ),
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<ProductDescriptionTemplate>(
          initialValue: _template,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'Description format',
            labelStyle: jost(fontSize: 12, color: mutedText),
            filled: true,
            fillColor: Colors.white.withValues(alpha: .045),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: strokeColor),
            ),
          ),
          dropdownColor: const Color(0xFF171A24),
          items: ProductDescriptionTemplate.values
              .map(
                (template) => DropdownMenuItem(
                  value: template,
                  child: Text(
                    '${template.label} - ${template.subtitle}',
                    overflow: TextOverflow.ellipsis,
                    style: jost(fontSize: 12.5),
                  ),
                ),
              )
              .toList(),
          onChanged: _generating
              ? null
              : (value) => setState(() => _template = value ?? _template),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _generating ? null : _generate,
            icon: _generating
                ? const SizedBox(
                    width: 17,
                    height: 17,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome_rounded),
            label: Text(
              _generating
                  ? 'Generating description...'
                  : 'Generate description',
            ),
          ),
        ),
      ],
    );
  }
}

enum _ImageSlot { product, color, poster }

class _HeroOverview extends StatelessWidget {
  const _HeroOverview({
    required this.product,
    required this.page,
    required this.imageIndex,
    required this.onChanged,
    required this.onPick,
  });
  final Product product;
  final PageController page;
  final int imageIndex;
  final ValueChanged<int> onChanged;
  final Future<void> Function(Product, _ImageSlot) onPick;

  @override
  Widget build(BuildContext context) {
    final slides = [
      _SlideData(
        'Main product',
        product.productImage,
        _ImageSlot.product,
        Icons.checkroom_outlined,
      ),
      _SlideData(
        'Colour set',
        product.colorSetImage,
        _ImageSlot.color,
        Icons.palette_outlined,
      ),
      _SlideData(
        'Poster image',
        product.posterImage,
        _ImageSlot.poster,
        Icons.auto_awesome_motion_outlined,
      ),
    ];
    return LiquidCard(
      glow: true,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 350,
            child: PageView.builder(
              controller: page,
              onPageChanged: onChanged,
              itemCount: slides.length,
              itemBuilder: (context, i) => _ImageSlide(
                data: slides[i],
                onPick: () => onPick(product, slides[i].slot),
                onView: () => _openImage(context, slides[i]),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              slides.length,
              (i) => AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                width: imageIndex == i ? 22 : 7,
                height: 7,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(99),
                  gradient: imageIndex == i ? liquidGradient() : null,
                  color: imageIndex == i
                      ? null
                      : Colors.white.withValues(alpha: .18),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _openImage(BuildContext context, _SlideData slide) {
    if (slide.bytes == null) return;
    showImageViewer(context, images: [slide.bytes!], title: slide.title);
  }
}

class _ColorVariantGallery extends StatelessWidget {
  const _ColorVariantGallery({required this.product});

  final Product product;

  @override
  Widget build(BuildContext context) {
    final colors = product.colorVariants
        .where((variant) => variant.imageBytes != null)
        .toList();
    return LiquidCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.palette_outlined,
                color: Color(0xFF64E9FF),
                size: 19,
              ),
              const SizedBox(width: 8),
              Text(
                'Colour set images',
                style: jost(fontSize: 14, weight: FontWeight.w700),
              ),
              const Spacer(),
              Text('${colors.length}', style: jost(color: mutedText)),
            ],
          ),
          const SizedBox(height: 10),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: colors.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: .82,
            ),
            itemBuilder: (context, index) {
              final color = colors[index];
              return InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => showImageViewer(
                  context,
                  images: [color.imageBytes!],
                  title: color.name,
                ),
                child: Ink(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .04),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(8),
                          ),
                          child: Image.memory(
                            color.imageBytes!,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          color.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: jost(fontSize: 12.5, weight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SlideData {
  const _SlideData(this.title, this.bytes, this.slot, this.icon);
  final String title;
  final Uint8List? bytes;
  final _ImageSlot slot;
  final IconData icon;
}

class _ImageSlide extends StatelessWidget {
  const _ImageSlide({
    required this.data,
    required this.onPick,
    required this.onView,
  });
  final _SlideData data;
  final VoidCallback onPick;
  final VoidCallback onView;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: GestureDetector(
              onTap: data.bytes == null ? onPick : onView,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .04),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: strokeColor),
                  ),
                  child: data.bytes == null
                      ? Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              data.icon,
                              size: 56,
                              color: Colors.white.withValues(alpha: .26),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Add ${data.title}',
                              style: jost(
                                fontSize: 16,
                                weight: FontWeight.w600,
                                color: mutedText,
                              ),
                            ),
                          ],
                        )
                      : Image.memory(data.bytes!, fit: BoxFit.contain),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionGrid extends StatelessWidget {
  const _ActionGrid({
    required this.product,
    required this.onShare,
    required this.onSaveImage,
    required this.onChat,
  });
  final Product product;
  final Future<void> Function(Product) onShare;
  final VoidCallback onSaveImage;
  final VoidCallback onChat;

  @override
  Widget build(BuildContext context) {
    final actions = [
      (Icons.download_rounded, 'Save', onSaveImage),
      (Icons.ios_share_rounded, 'Share', () => onShare(product)),
      (Icons.chat_bubble_outline_rounded, 'Chat', onChat),
    ];
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: actions
          .map((a) => _PillAction(icon: a.$1, label: a.$2, onTap: a.$3))
          .toList(),
    );
  }
}

class _DescriptionPanel extends StatelessWidget {
  const _DescriptionPanel({required this.product, required this.onCopy});
  final Product product;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return LiquidCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SparkleIcon(size: 20),
              const SizedBox(width: 8),
              Text(
                'Generated product description',
                style: jost(fontSize: 16, weight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: onCopy,
            child: Text(
              product.generatedDescription,
              style: jost(
                fontSize: 14.5,
                height: 1.45,
                color: Colors.white.withValues(alpha: .84),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LiquidSheet extends StatelessWidget {
  const _LiquidSheet({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 14,
        right: 14,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 14,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .85,
        ),
        child: LiquidCard(
          padding: EdgeInsets.zero,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(title, style: jost(fontSize: 19, weight: FontWeight.w700)),
                const SizedBox(height: 12),
                child,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PillAction extends StatelessWidget {
  const _PillAction({
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
      color: Colors.white.withValues(alpha: .065),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 17, color: Colors.white.withValues(alpha: .82)),
              const SizedBox(width: 7),
              Text(label, style: jost(fontSize: 12.5, weight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}
