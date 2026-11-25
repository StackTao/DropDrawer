import 'package:dropdrawer_app/models/models.dart';
import 'package:dropdrawer_app/state/drawer_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'same-node registrations count once while same-name devices stay distinct',
    () {
      final controller = DropDrawerController();
      addTearDown(controller.dispose);
      controller.deviceId = 'local';

      DeviceInfo device(
        String id, {
        String platform = 'windows',
        String? nodeId = 'shared-node',
        bool online = true,
      }) => DeviceInfo(
        id: id,
        userId: 'user',
        name: 'Workstation',
        platform: platform,
        irohNodeId: nodeId,
        directAddrs: [],
        online: online,
      );

      controller.devices = [
        device('old', online: false),
        device('online-alias'),
        device('local'),
        device('other-computer', nodeId: 'different-node'),
        device('ios-simulator', platform: 'ios'),
        device('without-native-node', nodeId: null),
      ];

      expect(controller.displayedDevices.map((device) => device.id), [
        'local',
        'other-computer',
        'ios-simulator',
        'without-native-node',
      ]);
      expect(controller.onlineDeviceCount, 4);

      controller.devices[2] = device('local', online: false);
      expect(controller.displayedDevices.first.id, 'online-alias');
      expect(controller.onlineDeviceCount, 4);
    },
  );
}
