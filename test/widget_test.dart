import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as image_lib;

import 'package:life_style_ai/main.dart';
import 'package:life_style_ai/chat_screen.dart';
import 'package:life_style_ai/flux_service.dart';
import 'package:life_style_ai/liquid_ui.dart';
import 'package:life_style_ai/message_ui.dart';
import 'package:life_style_ai/models.dart';
import 'package:life_style_ai/product_page.dart';
import '../tool/flux_proxy.dart' as flux_proxy;

void main() {
  test('FLUX proxy preserves the local port in callback URLs', () {
    expect(
      flux_proxy.buildProxyOrigin(
        requestedScheme: 'http',
        requestedAuthority: '127.0.0.1:8787',
        hostHeader: '127.0.0.1:8787',
      ),
      'http://127.0.0.1:8787',
    );
  });

  test(
    'FLUX service submits, polls, and downloads the generated image',
    () async {
      final reference = Uint8List.fromList([1, 2, 3]);
      final progress = <int>[];
      final client = MockClient((request) async {
        if (request.method == 'POST') {
          expect(
            request.url.path,
            '/functions/v1/flux-proxy/v1/flux-pro-1.1',
          );
          expect(request.url.host, 'xlgkxryniiokathvmtxo.supabase.co');
          expect(request.headers['x-key'], isNull);
          expect(request.headers, contains('x-app-token'));
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['prompt'], 'Studio product photo');
          expect(body['width'], 1024);
          expect(body['height'], 768);
          expect(body['image_prompt'], base64Encode(reference));
          return http.Response(
            jsonEncode({
              'id': 'generation-1',
              'polling_url': 'http://127.0.0.1:8787/v1/get_result?id=1',
            }),
            200,
          );
        }
        if (request.url.path == '/v1/get_result') {
          return http.Response(
            jsonEncode({
              'status': 'Ready',
              'result': {'sample': 'https://cdn.example.com/result.jpg'},
            }),
            200,
          );
        }
        return http.Response.bytes([9, 8, 7], 200);
      });

      final result = await FluxService.generateProductImage(
        prompt: 'Studio product photo',
        size: ProductImageSize.landscape,
        referenceImage: reference,
        onProgress: progress.add,
        client: client,
      );

      expect(result.bytes, [9, 8, 7]);
      expect(result.width, 1024);
      expect(result.height, 768);
      expect(progress.last, 100);
    },
  );

  testWidgets('greeting types then transitions to the chat UI', (tester) async {
    await tester.pumpWidget(const LifeStyleApp());

    // Greeting is on screen first.
    expect(find.byType(GreetingScreen), findsOneWidget);

    // Advance far enough for typing + hold + transition to complete.
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 2));

    // Chat UI should now be visible.
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.text('Create. Refine. Catalogue.'), findsOneWidget);

    // Dispose the tree so pending timers/animations are cancelled cleanly.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('image chat finishes after the chat route is disposed', (
    tester,
  ) async {
    final image = Uint8List.fromList(
      File('preview-greeting.png').readAsBytesSync(),
    );
    final product = Product(id: 'test-product', name: 'Test product');
    product.chat.add(
      ChatMessage(
        text: 'Use this reference',
        isUser: true,
        imageBytesList: [image],
        prompt: 'Use this reference',
      ),
    );

    final response = Completer<String>();
    final requestStarted = Completer<void>();
    late List<Uint8List> sentImages;

    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          product: product,
          productNameRequest: (_) async => 'Cotton Nightwear',
          chatRequest:
              ({
                required message,
                product,
                images = const [],
                history = const [],
              }) {
                sentImages = images;
                requestStarted.complete();
                return response.future;
              },
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Edit message'));
    await tester.pump();
    expect(product.chat, isEmpty);
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump(const Duration(milliseconds: 60));
    expect(requestStarted.isCompleted, isTrue);

    expect(sentImages, hasLength(1));
    expect(sentImages.single, same(image));
    expect(product.name, 'Cotton Nightwear');
    expect(product.chat, hasLength(2));
    expect(product.chat.first.imageBytesList.single, same(image));
    expect(product.chat.first.text, 'Use this reference');
    expect(product.chat.last.kind, ChatMessageKind.responding);

    await tester.pumpWidget(const SizedBox());
    response.complete('Reference received');
    await tester.pump();

    expect(product.chat, hasLength(2));
    expect(product.chat.first.imageBytesList.single, same(image));
    expect(product.chat.last.text, 'Reference received');
    expect(product.chat.where((message) => message.text == 'Styling'), isEmpty);
  });

  testWidgets('product image action runs prompt and FLUX generation flow', (
    tester,
  ) async {
    final image = Uint8List.fromList(
      File('preview-greeting.png').readAsBytesSync(),
    );
    final product = Product(id: 'image-product', name: 'Reference bag');
    product.chat.add(
      ChatMessage(
        text: 'Create a clean hero shot',
        isUser: true,
        imageBytesList: [image],
        prompt: 'Create a clean hero shot',
      ),
    );

    final promptResponse = Completer<String>();
    final imageResponse = Completer<GeneratedProductImage>();
    late String fluxPrompt;
    late ProductImageSize requestedSize;
    late Uint8List capturedReferenceImage;

    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          product: product,
          productNameRequest: (_) async => 'Structured Handbag',
          imagePromptRequest:
              ({
                required message,
                product,
                images = const [],
                history = const [],
              }) {
                expect(message, 'Create a clean hero shot');
                expect(images.single, same(image));
                return promptResponse.future;
              },
          productImageRequest:
              ({required prompt, required size, referenceImage, onProgress}) {
                fluxPrompt = prompt;
                requestedSize = size;
                capturedReferenceImage = referenceImage as Uint8List;
                onProgress?.call(48);
                return imageResponse.future;
              },
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Edit message'));
    await tester.pump();
    await tester.tap(find.byTooltip('Quick actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.ensureVisible(find.text('Generate product image'));
    expect(find.text('Detect colour set'), findsOneWidget);
    expect(find.text('Generate poster'), findsOneWidget);
    await tester.tap(find.text('Generate product image'));
    await tester.pump();
    await tester.ensureVisible(find.text('Portrait'));
    await tester.tap(find.text('Portrait'));
    await tester.pump();
    await tester.tap(find.text('Use image generation'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('768 × 1024'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('Styling your product'), findsOneWidget);

    promptResponse.complete('Premium studio product photograph');
    await tester.pump();
    expect(find.text('Crafting product image'), findsOneWidget);
    expect(find.text('48%'), findsOneWidget);
    expect(fluxPrompt, 'Premium studio product photograph');
    expect(requestedSize, ProductImageSize.portrait);
    expect(capturedReferenceImage, same(image));

    imageResponse.complete(
      GeneratedProductImage(
        bytes: image,
        sourceUrl: 'https://example.com/generated.jpg',
        width: 768,
        height: 1024,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(product.chat.last.text, 'Generated product image');
    expect(product.chat.last.imageBytesList.single, same(image));
    await tester.drag(find.byType(ListView).first, const Offset(0, -420));
    await tester.pump();
    expect(
      find.text('Generated product image', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('768 × 1024 · FLUX Kontext Pro'), findsOneWidget);
    expect(product.posterImage, same(image));
    expect(find.text('Download'), findsOneWidget);
    expect(find.text('Reference'), findsOneWidget);

    await tester.tap(find.text('Reference'));
    await tester.pump();
    expect(find.text('Added as reference'), findsOneWidget);
    expect(find.text('Generate product image'), findsOneWidget);

    await tester.tap(find.byType(GroupedMessageImages).last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byTooltip('Close image viewer'), findsOneWidget);
    expect(find.text('Generated product image'), findsWidgets);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('poster action sends all references through the master prompt', (
    tester,
  ) async {
    final first = image_lib.Image(width: 8, height: 8);
    image_lib.fill(first, color: image_lib.ColorRgb8(220, 40, 70));
    final second = image_lib.Image(width: 8, height: 8);
    image_lib.fill(second, color: image_lib.ColorRgb8(30, 110, 210));
    final productImage = Uint8List.fromList(image_lib.encodeJpg(first));
    final generatedImage = Uint8List.fromList(image_lib.encodeJpg(second));
    final product = Product(id: 'poster-product', name: 'Cotton Nightwear')
      ..productImage = productImage;
    product.chat.add(
      ChatMessage(
        text: 'Generated product image',
        isUser: false,
        imageBytesList: [generatedImage],
        modelLabel: 'FLUX Kontext Pro',
        imageWidth: 1024,
        imageHeight: 1024,
      ),
    );
    late List<Uint8List> promptReferences;
    late Uint8List fluxReference;
    final generationStarted = Completer<void>();

    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          product: product,
          posterPromptRequest:
              ({
                required message,
                product,
                images = const [],
                history = const [],
              }) async {
                promptReferences = images;
                return 'Premium ecommerce campaign poster';
              },
          posterReferenceBuilder: (images) async {
            expect(images, hasLength(2));
            return Uint8List.fromList([1, 2, 3]);
          },
          productImageRequest:
              ({
                required prompt,
                required size,
                referenceImage,
                onProgress,
              }) async {
                expect(prompt, 'Premium ecommerce campaign poster');
                fluxReference = referenceImage as Uint8List;
                generationStarted.complete();
                onProgress?.call(100);
                return GeneratedProductImage(
                  bytes: generatedImage,
                  sourceUrl: 'https://example.com/poster.jpg',
                  width: size.width,
                  height: size.height,
                );
              },
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField).last, 'Create launch poster');
    await tester.tap(find.byTooltip('Quick actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.drag(
      find.byType(SingleChildScrollView).last,
      const Offset(0, -260),
    );
    await tester.pump();
    await tester.tap(find.text('Generate poster'));
    await tester.pump();
    await tester.tap(find.text('Use poster generation'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Generate poster'), findsOneWidget);
    expect(find.text('Create launch poster'), findsOneWidget);
    await tester.tap(find.byType(LiquidSendButton));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(product.chat, hasLength(3));
    expect(promptReferences, hasLength(2));
    await tester.runAsync(
      () => generationStarted.future.timeout(const Duration(seconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 800));

    expect(promptReferences, hasLength(2));
    expect(fluxReference, isNotEmpty);
    expect(product.posterImage, same(generatedImage));
    expect(product.chat.last.text, 'Generated product poster');
  });

  testWidgets('reference notes generate and save a templated description', (
    tester,
  ) async {
    final product = ProductStore.instance.createProduct(
      name: 'Cotton Nightwear',
    );
    late ProductDescriptionTemplate requestedTemplate;

    await tester.pumpWidget(
      MaterialApp(
        home: ProductPage(
          productId: product.id,
          descriptionRequest: ({required product, required template}) async {
            requestedTemplate = template;
            expect(product.referenceDescription, contains('Rs 2450'));
            expect(product.referenceDescription, contains('M-XXL'));
            return 'Cotton Nightwear\nSizes: M-XXL\nPrice: Rs 2450';
          },
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Reference details'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(
      find.byType(TextField).last,
      'soft cotton, size M-XXL, Rs 2450',
    );
    await tester.tap(find.textContaining('Catalogue -'));
    await tester.pump();
    await tester.tap(find.textContaining('WhatsApp -').last);
    await tester.pump();
    await tester.ensureVisible(find.text('Generate description'));
    await tester.tap(find.text('Generate description'));
    await tester.pump();

    expect(requestedTemplate, ProductDescriptionTemplate.whatsapp);
    expect(product.description, contains('Price: Rs 2450'));
    expect(find.text('WhatsApp description generated'), findsOneWidget);
  });
}
