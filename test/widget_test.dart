// Tests for BegoTorch.
//
// BegoTorch writes the torch brightness directly; it never uses su / Magisk /
// KernelSU / APatch. The write is possible because the powa_karnal kernel
// ships the torch node world-writable (0666) and the TWRP-flashable zip
// installs the app as a system priv-app. CI validates the app-side contract:
// the app must target the exact node the kernel exposes, and no su escalation
// path may creep back in.
//
// The widget smoke tests never tap the dial, so no device write can fire on CI.

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
      // escalation path in the app (the old kSuCandidates list was removed
      // entirely). The powa_karnal kernel ships this node world-writable
      // (0666) so the direct write works from an unprivileged app.
      expect(
        kTorchDeviceCustom,
        '/sys/devices/platform/flashlights_mt6360/torchbrightness',
      );
    });

    test('the installer places the app in priv-app', () {
      // Contract with the TWRP package: flash.sh must install the APK where
      // Android's package manager scans it (priv-app). If this drifts, the
      // zip would silently stop installing the app at all.
      final flashScript = File('twrp/flash.sh').readAsStringSync();
      expect(flashScript, contains('priv-app'));
      expect(flashScript, contains('base.apk'));
      expect(flashScript, contains('/system_root'));
      expect(flashScript, contains('/system'));
    });

    test('no process execution / su escalation path exists in the app', () {
      // Guard against regression: the app must only do direct file IO on the
      // torch node. Any Process.run/Process.start (the old su mechanism used
      // Process.run) indicates an escalation path creeping back in.
      final source = File('lib/main.dart').readAsStringSync();
      expect(source.contains('Process.run'), isFalse,
          reason: 'direct file writes only — no external processes');
      expect(source.contains('Process.start'), isFalse,
          reason: 'direct file writes only — no external processes');
      expect(source.contains('kSuCandidates'), isFalse,
          reason: 'the old su candidate probe was removed');
    });
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
