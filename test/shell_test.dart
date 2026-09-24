import 'package:comicredr/src/app.dart';
import 'package:comicredr/src/data/app_database.dart';
import 'package:comicredr/src/providers.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(AppDatabase(NativeDatabase.memory()))],
        child: const ComicRedrApp(),
      ),
    );
    await tester.pump();
  }

  String lastCommand(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('last-command'))).data!;

  testWidgets('keys reach the reader as commands, counts included', (tester) async {
    await pumpApp(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit5);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.pump();
    expect(lastCommand(tester), 'ReaderCommand(nextStep, count: 5)');

    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pump();
    expect(lastCommand(tester), 'ReaderCommand(nextPage)');

    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.pump();
    expect(lastCommand(tester), 'ReaderCommand(firstPage)');
  });

  testWidgets('? shows the keymap generated from the bindings', (tester) async {
    await pumpApp(tester);
    await tester.sendKeyEvent(
      LogicalKeyboardKey.slash,
      physicalKey: PhysicalKeyboardKey.slash,
      character: '?',
    );
    await tester.pump();
    expect(find.text('Guided view, there and back'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('Guided view, there and back'), findsNothing);
  });

  test('the index schema opens in memory', () async {
    final db = AppDatabase(NativeDatabase.memory());
    await db
        .into(db.books)
        .insert(BooksCompanion.insert(contentKey: 'k', title: 'Daredevil 181', pageCount: 32, format: 'zip'));
    expect(await db.select(db.books).get(), hasLength(1));
    await db.close();
  });
}
