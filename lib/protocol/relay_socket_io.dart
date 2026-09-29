/// Native (dart:io) relay socket: carries custom upgrade headers so the
/// handshake matches what the browser sends from the remote page.
library;

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

WebSocketChannel connectRelaySocket(Uri uri, Map<String, String> headers) {
  return IOWebSocketChannel.connect(uri, headers: headers);
}
