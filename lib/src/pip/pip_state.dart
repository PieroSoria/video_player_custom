import 'package:flutter/foundation.dart';

/// Player rendered by the native PiP window, shared without importing the API.
final ValueNotifier<int?> pipPlayerId = ValueNotifier<int?>(null);

// Tokens distinguish a live controller from a disposed player whose native
// callback or enter reply is still queued, even if its identifier is reused.
final Map<int, Object> _livePlayers = <int, Object>{};

void registerPipPlayer(int playerId) {
  _livePlayers[playerId] = Object();
}

Object? pipPlayerToken(int playerId) => _livePlayers[playerId];

void releasePipPlayer(int playerId) {
  _livePlayers.remove(playerId);
  if (pipPlayerId.value == playerId) {
    pipPlayerId.value = null;
  }
}
