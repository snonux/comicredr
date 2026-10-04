import 'dart:async';

import 'package:comicredr/src/android_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const storage = MethodChannel('org.snonux.comicredr/storage');
  late List<String> calls;
  bool? granted;
  late bool allFiles;
  bool? answer;

  setUp(() {
    calls = [];
    granted = false;
    allFiles = false;
    answer = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(storage, (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'hasAllFilesAccess' => granted,
        'usesAllFilesAccess' => allFiles,
        _ => null,
      };
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(storage, null);
  });

  Future<void> request(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => answer = await hasAndroidStorageAccess(context, storage),
              child: const Text('Open comic'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open comic'));
    await tester.pumpAndSettle();
  }

  testWidgets('Android 7–10 explains the runtime dialog and requests access; retry still checks permission', (
    tester,
  ) async {
    await request(tester);
    expect(find.text('Allow access'), findsOneWidget);
    expect(find.textContaining('Storage permission in the Android dialog'), findsOneWidget);
    expect(find.text('Open settings'), findsNothing);
    await tester.tap(find.text('Allow access'));
    await tester.pumpAndSettle();
    expect(answer, isFalse);
    expect(calls.last, 'requestAllFilesAccess');

    // A denied request must leave the gate in place on the next attempt.
    await tester.tap(find.text('Open comic'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    granted = true;
    await tester.tap(find.text('Open comic'));
    await tester.pumpAndSettle();
    expect(answer, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('Android 11+ explains All files access and opens Settings', (tester) async {
    allFiles = true;
    await request(tester);
    expect(find.text('Open settings'), findsOneWidget);
    expect(find.textContaining('"All files access", on a settings page'), findsOneWidget);
    expect(find.text('Allow access'), findsNothing);
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    expect(answer, isFalse);
    expect(calls.last, 'requestAllFilesAccess');
  });

  testWidgets('Not now and dismissing the explanation never request permission', (tester) async {
    await request(tester);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(answer, isFalse);
    expect(calls, isNot(contains('requestAllFilesAccess')));
    await tester.tap(find.text('Open comic'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(answer, isFalse);
    expect(calls, isNot(contains('requestAllFilesAccess')));
  });

  testWidgets('existing permission bypasses the explanation and does not request again', (tester) async {
    granted = true;
    await request(tester);
    expect(answer, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
    expect(calls, ['hasAllFilesAccess']);
  });

  testWidgets('a null permission result never grants access', (tester) async {
    granted = null;
    await request(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(answer, isFalse);
  });

  testWidgets('a platform failure propagates without granting or requesting access', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(storage, (call) async {
      calls.add(call.method);
      throw PlatformException(code: 'unavailable', message: 'Storage check failed');
    });
    late BuildContext screen;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            screen = context;
            return const SizedBox();
          },
        ),
      ),
    );
    await expectLater(hasAndroidStorageAccess(screen, storage), throwsA(isA<PlatformException>()));
    expect(calls, ['hasAllFilesAccess']);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('a disposed screen cannot open a permission explanation after a slow check', (tester) async {
    final check = Completer<bool>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(storage, (call) async {
      calls.add(call.method);
      return check.future;
    });
    BuildContext? screen;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            screen = context;
            return const SizedBox();
          },
        ),
      ),
    );
    final result = hasAndroidStorageAccess(screen!, storage);
    await tester.pumpWidget(const SizedBox());
    check.complete(false);
    expect(await result, isFalse);
    expect(calls, ['hasAllFilesAccess']);
    expect(tester.takeException(), isNull);
  });
}
