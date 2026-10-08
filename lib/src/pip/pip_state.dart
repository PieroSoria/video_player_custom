import 'package:flutter/foundation.dart';

/// Player rendered by the native PiP window, shared without importing the API.
final ValueNotifier<int?> pipPlayerId = ValueNotifier<int?>(null);

// Tokens distinguish a live controller from a disposed player whose native
// callback or enter reply is still queued, even if its identifier is reused.
final Map<int, Object> _livePlayers = <int, Object>{};
final Map<int, int> _accentColors = <int, int>{};

void registerPipPlayer(int playerId) {
  _livePlayers[playerId] = Object();
  _accentColors.remove(playerId);
}

Object? pipPlayerToken(int playerId) => _livePlayers[playerId];

/// Retains the last mounted theme while the controller outlives its widget.
void rememberPipAccentColor(int playerId, int color) {
  if (_livePlayers.containsKey(playerId)) _accentColors[playerId] = color;
}

int? pipAccentColor(int playerId) => _accentColors[playerId];

void releasePipPlayer(int playerId) {
  _livePlayers.remove(playerId);
  _accentColors.remove(playerId);
  if (pipPlayerId.value == playerId) {
    pipPlayerId.value = null;
  }
}
