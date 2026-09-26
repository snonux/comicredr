import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/panel_store.dart';
import '../data/progress_store.dart';
import '../data/read_log_store.dart';
import '../data/settings_store.dart';
import '../data/sidecar.dart';
import '../data/sidecar_sync.dart';
import '../library/providers.dart';
import '../providers.dart';
import 'model_detector.dart';
import 'panel_detector.dart';

final progressStoreProvider = Provider<ProgressStore>((ref) {
  final store = ProgressStore(ref.watch(databaseProvider));
  ref.onDispose(store.flush);
  return store;
});

/// The sidecars beside the books. Pending writes go out when the app is
/// disposed.
final sidecarSyncProvider = Provider<SidecarSync>((ref) {
  final settings = ref.watch(settingsStoreProvider);
  final sync = SidecarSync(
    ref.watch(databaseProvider),
    progress: ref.watch(progressStoreProvider),
    coverDir: ref.watch(coverDirProvider),
    writeAllowed: () async => await settings.loadBool(SettingsStore.writeSidecars).catchError((_) => null) ?? true,
    storeDir: () => settings.loadString(SettingsStore.sidecarDir),
  );
  ref.onDispose(sync.flush);
  return sync;
});

/// Another device's later position in the book just opened, which the
/// reader offers rather than jumps to (design plan section 7).
typedef PositionOffer = ({String path, String contentKey, SidecarProgress at});

final positionOfferProvider = NotifierProvider<PositionOfferNotifier, PositionOffer?>(PositionOfferNotifier.new);

class PositionOfferNotifier extends Notifier<PositionOffer?> {
  @override
  PositionOffer? build() => null;

  void set(PositionOffer? offer) => state = offer;
}

final readLogStoreProvider = Provider<ReadLogStore>((ref) => ReadLogStore(ref.watch(databaseProvider)));

final panelStoreProvider = Provider<PanelStore>((ref) => PanelStore(ref.watch(databaseProvider)));

final settingsStoreProvider = Provider<SettingsStore>((ref) => SettingsStore(ref.watch(databaseProvider)));

final markStoreProvider = Provider<MarkStore>((ref) => MarkStore(ref.watch(databaseProvider)));

/// The trained model, built in or installed by the user (see [findModel]),
/// classic CV when there is none.
final panelDetectorProvider = FutureProvider<PanelDetector>((ref) async {
  final path = await findModel();
  debugPrint(path == null ? 'Panel detector: classic CV (no model)' : 'Panel detector: model $path');
  return PanelDetector(model: path == null ? null : await ModelDetector.open(path));
});
