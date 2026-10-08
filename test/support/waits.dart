import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

/// Settles with [settle] until [check] passes, and reports its last failure
/// after [tries] rounds in vain.
///
/// What the app does off the test's clock (the database and its streams, a
/// book's worker isolate, the scanner) takes real time, and more of it on a
/// loaded machine: a test that looked after a fixed while failed there
/// (task 773, a third of the runs with eight copies of a test at once). So a
/// check of what such work leaves behind waits for it. [check] is run
/// outside `runAsync`, where a failure inside would be reported as an error
/// of the test rather than tried again; read the database with `runAsync`
/// before the check, as [eventuallyAsync] does. The default rounds give a
/// [settle] of a few hundred milliseconds of real time some 30 s or more.
Future<void> eventually(
  WidgetTester tester,
  void Function() check, {
  required Future<void> Function(WidgetTester) settle,
  int tries = 80,
}) async {
  for (var i = 0; ; i++) {
    try {
      check();
      return;
    } on TestFailure {
      if (i >= tries) rethrow;
    }
    await settle(tester);
  }
}

/// [eventually] for a check of something read with `runAsync`, such as the
/// database's rows: [read] is called in real time each round, [check] then
/// looks at what it gave.
Future<void> eventuallyAsync<T>(
  WidgetTester tester,
  Future<T> Function() read,
  void Function(T value) check, {
  required Future<void> Function(WidgetTester) settle,
  int tries = 80,
}) async {
  for (var i = 0; ; i++) {
    final value = await whilePumping(tester, read);
    try {
      check(value);
      return;
    } on TestFailure {
      if (i >= tries) rethrow;
    }
    await settle(tester);
  }
}

/// Runs [work] in real time, as `tester.runAsync` does, but pumps the test's
/// frames until it is done instead of waiting for it in one `runAsync`.
///
/// Work that goes through the app's database can wait for work the app
/// started on the test's clock: a reset, a move or a saved position holds
/// the database while it awaits, and goes on only when the test pumps. A
/// `runAsync` that waits for its query then waits for good, which is the
/// hang to the ten-minute timeout seen in bookmarks_test and
/// multi_select_test under load (task 773): with the machine slow, the app's
/// work had not finished when the test read the index. Fails after [rounds]
/// rounds of some 50 ms of real time each.
Future<T> whilePumping<T>(WidgetTester tester, Future<T> Function() work, {int rounds = 1200}) async {
  var finished = false;
  late T value;
  Object? error;
  StackTrace? stack;
  await tester.runAsync(() async {
    unawaited(
      work()
          .then<void>((v) => value = v, onError: (Object e, StackTrace s) => (error, stack) = (e, s))
          .whenComplete(() => finished = true),
    );
  });
  for (var i = 0; !finished; i++) {
    if (i >= rounds) fail('Real-time work did not finish while the test pumped');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    if (!finished) await tester.pump();
  }
  if (error case final e?) Error.throwWithStackTrace(e, stack!);
  return value;
}
