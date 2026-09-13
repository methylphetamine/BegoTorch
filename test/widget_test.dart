// Tests for BegoTorch.
//
// BegoTorch writes the torch brightness directly; it never uses su / Magisk /
// KernelSU / APatch. The write authority is granted by the component manifest
// (config/begotorch.cml) that is fused into the flashed package. CI validates
// that manifest contract here: the app must target the same node the manifest
// authorises, and the shipped APK flow must not depend on any su binary.
//
// The widget smoke tests never tap the dial, so no device write can fire on CI.

import 'dart:convert';
import 'dart:io';

import 'package:begotorch/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() {
    // SharedPreferences needs a mock before any widget that reads it
    // is pumped. Set up a global mock with no saved values.
    SharedPreferences.setMockInitialValues({});
  });

  group('no-su contract', () {
    test('the app targets the mt6360 torch node directly', () {
      // BegoTorch writes the brightness straight to this node; there is no su
      // escalation path in the app anymore (the old kSuCandidates list was
      // removed entirely). The contract we keep is the device node itself.
      expect(
        kTorchDevice,
        '/sys/devices/platform/flashlights_mt6360/torchbrightness',
      );
    });

    test(
      'component manifest grants write on the same node the app writes',
      () async {
        // The privileges are baked into config/begotorch.cml at flash time.
        // Keep them in lockstep with the Dart constant so a renamed node never
        // silently splits the two.
        final File cml = File('config/begotorch.cml');
        final String raw = await cml.readAsString();

        // Fuchsia CML files permit // comments; dart:convert does not. Strip
        // them before decoding so this test validates the live manifest.
        final String text = raw
            .split('\n')
            .where((String line) => !line.trim().startsWith('//'))
            .join('\n');

        // dart:convert decodes JSON objects to Map<String, Object?> at runtime;
        // cast once per level and traverse. A missing key surfaces as a failed
        // (null-cast) assertion below instead of silently passing.
        final Map<String, Object?> root =
            jsonDecode(text) as Map<String, Object?>;
        final Map<String, Object?> sandbox =
            root['sandbox'] as Map<String, Object?>;
        final Map<String, Object?> filesystem =
            sandbox['filesystem'] as Map<String, Object?>;

        final Object? nodeVal = filesystem[kTorchDevice];
        expect(nodeVal, isNotNull);

        final Map<String, Object?> nodeEntry = nodeVal as Map<String, Object?>;
        final List<Object?> rights = nodeEntry['rights'] as List<Object?>;

        expect(rights, contains('Write'));
        expect(rights, contains('Read'));
      },
    );
  });

  testWidgets('renders the torch dial and initial value', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const BegoTorchApp());

    expect(find.text('Torch'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    // The dial is rendered as a CustomPaint with a _DialPainter, identifiable
    // by its key.
    expect(find.byKey(const ValueKey<String>('torch_dial')), findsOneWidget);
  });

  group('settings / icon chooser', () {
    testWidgets('navigates to settings and shows icon variants', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(const BegoTorchApp());

      // Tap the settings icon in the app bar.
      await tester.tap(find.byIcon(Icons.settings));
      await tester.pumpAndSettle();

      // Settings page title is visible.
      expect(find.text('Settings'), findsOneWidget);

      // All built-in icon variants are offered.
      for (final TorchIcon icon in kTorchIcons) {
        expect(find.text(icon.label), findsOneWidget);
      }

      // The default selection is 'Selected' next to the first icon.
      expect(find.text('Selected'), findsOneWidget);
    });

    testWidgets('selecting an icon persists it and shows it on home', (
      WidgetTester tester,
    ) async {
      // SharedPreferences needs a mock in tests.
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(const BegoTorchApp());

      await tester.tap(find.byIcon(Icons.settings));
      await tester.pumpAndSettle();

      // kTorchIcons order: torch, star, moon, sun.
      // Tap the Star variant (the tap target is the RadioListTile itself).
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey<String>('icon_option_star')),
          matching: find.text('Star'),
        ),
      );
      await tester.pumpAndSettle();

      // 'Star' should now be the selected one (only one 'Selected' label),
      // and the stored preference must match the tapped variant.
      expect(find.text('Selected'), findsOneWidget);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kPrefIcon), 'star');

      // Returning to home must show the persisted choice.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Star'), findsOneWidget);
    });

    test('iconForId returns the first icon for an unknown id', () {
      expect(iconForId('nonexistent'), same(kTorchIcons.first));
    });

    test('iconForId returns the matching variant', () {
      expect(iconForId('moon'), same(kTorchIcons[2]));
      expect(iconForId('torch'), same(kTorchIcons.first));
    });

    test('kTorchIcons is non-empty and has unique ids', () {
      expect(kTorchIcons, isNotEmpty);
      final ids = kTorchIcons.map((i) => i.id).toSet();
      expect(ids.length, kTorchIcons.length);
    });
  });
}
