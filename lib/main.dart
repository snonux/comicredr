import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app.dart';

/// `comicredr [book.cbz]` opens the book straight away.
void main(List<String> args) {
  runApp(ProviderScope(child: ComicRedrApp(initialPath: args.isEmpty ? null : args.first)));
}
