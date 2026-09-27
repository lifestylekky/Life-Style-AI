import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'liquid_ui.dart';
import 'models.dart';
import 'product_page.dart';

class InventoryPage extends StatefulWidget {
  const InventoryPage({super.key});

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage>
    with SingleTickerProviderStateMixin {
  final TextEditingController _search = TextEditingController();
  bool _gridView = true;
  late final AnimationController _flow = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 10),
  )..repeat();

  @override
  void dispose() {
    _search.dispose();
    _flow.dispose();
    super.dispose();
  }

  Future<void> _pickImages() async {
    try {
      final files = await ImagePicker().pickMultiImage();
      if (files.isEmpty) return;
      for (final f in files) {
        ProductStore.instance.createProduct(imageBytes: await f.readAsBytes());
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not open gallery: $e')));
      }
    }
  }

  Future<bool> _confirmDelete(Product p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: surfaceColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: const BorderSide(color: strokeColor),
        ),
        title: Text(
          'Delete product?',
          style: jost(fontSize: 20, weight: FontWeight.w700),
        ),
        content: Text(
          'This will remove ${p.name} from the local inventory.',
          style: jost(color: mutedText, height: 1.35),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel', style: jost(color: mutedText)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              'Delete',
              style: jost(
                color: const Color(0xFFFF7A8A),
                weight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    if (ok == true) ProductStore.instance.deleteProduct(p);
    return false;
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
        title: ShaderMask(
          shaderCallback: (b) => liquidGradient().createShader(b),
          blendMode: BlendMode.srcIn,
          child: Text(
            'Inventory',
            style: jost(fontSize: 20, weight: FontWeight.w700),
          ),
        ),
        actions: [
          LiquidIconButton(
            icon: _gridView
                ? Icons.view_list_outlined
                : Icons.grid_view_rounded,
            onTap: () => setState(() => _gridView = !_gridView),
            tooltip: _gridView ? 'List view' : 'Grid view',
          ),
          const SizedBox(width: 8),
          LiquidIconButton(
            icon: Icons.add_photo_alternate_rounded,
            onTap: _pickImages,
            tooltip: 'Upload images',
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
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: _SearchBar(
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                Expanded(
                  child: ListenableBuilder(
                    listenable: ProductStore.instance,
                    builder: (context, _) {
                      final q = _search.text.trim().toLowerCase();
                      final products = ProductStore.instance.products.where((
                        p,
                      ) {
                        if (q.isEmpty) return true;
                        return p.name.toLowerCase().contains(q) ||
                            p.generatedDescription.toLowerCase().contains(q) ||
                            p.referenceDescription.toLowerCase().contains(q);
                      }).toList();
                      if (ProductStore.instance.products.isEmpty) {
                        return _emptyState();
                      }
                      if (products.isEmpty) return _noSearchResults();
                      if (_gridView) {
                        return GridView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                          itemCount: products.length,
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2,
                                crossAxisSpacing: 10,
                                mainAxisSpacing: 10,
                                childAspectRatio: .76,
                              ),
                          itemBuilder: (context, i) => _ProductGridCard(
                            product: products[i],
                            onDelete: () => _confirmDelete(products[i]),
                          ),
                        );
                      }
                      return ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                        itemCount: products.length,
                        itemBuilder: (context, i) => _ProductCard(
                          product: products[i],
                          onDelete: () => _confirmDelete(products[i]),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SparkleIcon(size: 58),
          const SizedBox(height: 16),
          Text(
            'No products yet',
            style: jost(fontSize: 19, weight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            'Upload product images to get started',
            style: jost(
              fontSize: 14,
              weight: FontWeight.w300,
              color: mutedText,
            ),
          ),
          const SizedBox(height: 20),
          _GradientButton(
            label: 'Upload Image',
            icon: Icons.add_photo_alternate_rounded,
            onTap: _pickImages,
          ),
        ],
      ),
    );
  }

  Widget _noSearchResults() => Center(
    child: Text('No matching products', style: jost(color: mutedText)),
  );
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.controller, required this.onChanged});
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: glassDecoration(
        radius: 22,
        color: surfaceColor.withValues(alpha: .82),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: jost(fontSize: 14.5),
        cursorColor: const Color(0xFF64E9FF),
        decoration: InputDecoration(
          icon: Icon(
            Icons.search_rounded,
            color: Colors.white.withValues(alpha: .5),
          ),
          hintText: 'Search products, colours, descriptions...',
          hintStyle: jost(
            fontSize: 14,
            color: Colors.white.withValues(alpha: .36),
            weight: FontWeight.w300,
          ),
          border: InputBorder.none,
        ),
      ),
    );
  }
}

class _ProductGridCard extends StatelessWidget {
  const _ProductGridCard({required this.product, required this.onDelete});

  final Product product;
  final Future<bool> Function() onDelete;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ProductPage(productId: product.id)),
        ),
        child: Ink(
          decoration: BoxDecoration(
            color: surfaceColor.withValues(alpha: .84),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white.withValues(alpha: .08)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(8),
                      ),
                      child: product.productImage != null
                          ? Image.memory(
                              product.productImage!,
                              fit: BoxFit.cover,
                            )
                          : Container(
                              color: Colors.white.withValues(alpha: .04),
                              child: const Icon(
                                Icons.image_outlined,
                                color: Colors.white38,
                              ),
                            ),
                    ),
                    Positioned(
                      right: 4,
                      top: 4,
                      child: IconButton.filledTonal(
                        tooltip: 'Delete product',
                        visualDensity: VisualDensity.compact,
                        onPressed: () {
                          onDelete();
                        },
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 17,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      product.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: jost(fontSize: 14, weight: FontWeight.w700),
                    ),
                    const SizedBox(height: 7),
                    _LayerBadges(product: product),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({required this.product, required this.onDelete});
  final Product product;
  final Future<bool> Function() onDelete;

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: ValueKey(product.id),
      direction: DismissDirection.startToEnd,
      confirmDismiss: (_) => onDelete(),
      background: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.only(left: 22),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: const Color(0x33FF4D6D),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: const Color(0x66FF4D6D)),
        ),
        child: const Icon(
          Icons.delete_outline_rounded,
          color: Color(0xFFFF7A8A),
          size: 30,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: LiquidCard(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ProductPage(productId: product.id),
            ),
          ),
          padding: const EdgeInsets.all(12),
          glow: true,
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: product.productImage != null
                    ? Image.memory(
                        product.productImage!,
                        width: 72,
                        height: 72,
                        fit: BoxFit.cover,
                      )
                    : Container(
                        width: 72,
                        height: 72,
                        color: Colors.white.withValues(alpha: .05),
                        child: const Icon(
                          Icons.image_outlined,
                          color: Colors.white38,
                        ),
                      ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      product.name,
                      style: jost(fontSize: 15.5, weight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    _LayerBadges(product: product),
                    const SizedBox(height: 5),
                    Text(
                      'Swipe right to delete • tap for overview',
                      style: jost(
                        fontSize: 12,
                        weight: FontWeight.w300,
                        color: Colors.white.withValues(alpha: .42),
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
        ),
      ),
    );
  }
}

class _LayerBadges extends StatelessWidget {
  const _LayerBadges({required this.product});
  final Product product;

  @override
  Widget build(BuildContext context) {
    Widget dot(String label, bool filled) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: filled
                ? const Color(0xFF64E9FF)
                : Colors.white.withValues(alpha: .15),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: jost(
            fontSize: 11,
            weight: FontWeight.w300,
            color: Colors.white.withValues(alpha: .52),
          ),
        ),
      ],
    );
    return Wrap(
      spacing: 10,
      runSpacing: 4,
      children: [
        dot('Image', product.productImage != null),
        dot('Colours', product.colorSetImage != null),
        dot('Poster', product.posterImage != null),
        dot('Desc', product.description.isNotEmpty),
      ],
    );
  }
}

class _GradientButton extends StatelessWidget {
  const _GradientButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          decoration: glassDecoration(
            radius: 24,
            glow: true,
            gradient: liquidGradient(opacity: .62),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Text(label, style: jost(fontSize: 15, weight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }
}
