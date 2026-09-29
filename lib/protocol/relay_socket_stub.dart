/// Web relay socket: the browser manages the upgrade itself and already
/// sends Origin/Referer for the page, so custom headers are not possible
/// (and not needed).
library;

import 'package:web_socket_channel/web_socket_channel.dart';

WebSocketChannel connectRelaySocket(Uri uri, Map<String, String> headers) {
  return WebSocketChannel.connect(uri);
}
