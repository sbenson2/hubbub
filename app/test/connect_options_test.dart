import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' show RTCIceTransportPolicy;
import 'package:hubbub/room_adapter.dart';
import 'package:hubbub/src/rust/api/hubbub.dart' show AppIceServer;

void main() {
  test('the_credentials_ice_server_becomes_the_only_relay_only_ice_server', () {
    const ice = AppIceServer(
        url: 'turn:192.168.1.5:50000?transport=udp', username: 'hbuser', credential: 'secret');
    final o = connectOptionsFor(ice);
    final cfg = o.rtcConfiguration;
    expect(o.autoSubscribe, isFalse);
    expect(cfg.iceServers, hasLength(1));
    expect(cfg.iceServers!.single.urls, [ice.url]);
    expect(cfg.iceServers!.single.username, 'hbuser');
    expect(cfg.iceServers!.single.credential, 'secret');
    // LiveKit offers only loopback candidates; the relay is the only path that works.
    expect(cfg.iceTransportPolicy, RTCIceTransportPolicy.relay);
  });

  test('no_ice_server_leaves_the_defaults', () {
    final o = connectOptionsFor(null);
    expect(o.autoSubscribe, isFalse);
    expect(o.rtcConfiguration.iceServers, isNull);
    expect(o.rtcConfiguration.iceTransportPolicy, isNull);
  });
}
