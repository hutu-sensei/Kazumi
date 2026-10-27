import 'dart:async';

import 'package:dlna_dart/dlna.dart';
import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/dialog/material_bottom_sheet.dart';
import 'package:kazumi/services/player/cast_controller.dart';

/// 选择投屏设备，返回被选中的设备；用户取消则返回 null。
Future<DLNADevice?> showCastDeviceSheet(BuildContext context) {
  return showAdaptiveBottomSheet<DLNADevice>(
    context: context,
    maxHeightFactor: 0.72,
    compactLandscapeMaxHeightFactor: 0.95,
    builder: (BuildContext context) => const CastDeviceSheet(),
  );
}

class CastDeviceSheet extends StatefulWidget {
  const CastDeviceSheet({super.key});

  @override
  State<CastDeviceSheet> createState() => _CastDeviceSheetState();
}

class _CastDeviceSheetState extends State<CastDeviceSheet> {
  final CastController _cast = CastController.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_cast.startDiscovery());
  }

  @override
  void dispose() {
    unawaited(_cast.stopDiscovery());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
          MaterialBottomSheetHeader(
            title: '选择投屏设备',
            description: _cast.discovering
                ? '正在搜索同一局域网内的 DLNA 设备…'
                : '点击设备即可开始投屏',
            leading: const Icon(Icons.cast),
            onClose: () => Navigator.of(context).pop(),
            trailing: IconButton(
              tooltip: '重新搜索',
              onPressed: _cast.discovering
                  ? null
                  : () => unawaited(_cast.startDiscovery()),
              icon: const Icon(Icons.refresh_rounded),
            ),
          ),
          Flexible(
            child: AnimatedBuilder(
              animation: _cast,
              builder: (BuildContext context, Widget? child) {
                if (_cast.devices.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 40),
                    child: Row(
                      children: <Widget>[
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '请确认投影仪已开机，且与手机连在同一个 WiFi 下',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }
                return ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                  itemCount: _cast.devices.length,
                  itemBuilder: (BuildContext context, int index) {
                    final DLNADevice device = _cast.devices[index];
                    final bool isCurrent =
                        _cast.deviceName == device.info.friendlyName;
                    return ListTile(
                      leading: Icon(
                        _deviceIcon(device.info.deviceType),
                        color: isCurrent ? theme.colorScheme.primary : null,
                      ),
                      title: Text(device.info.friendlyName),
                      subtitle: Text(_deviceLabel(device.info.deviceType)),
                      trailing: isCurrent
                          ? Icon(
                              Icons.check_circle_rounded,
                              color: theme.colorScheme.primary,
                            )
                          : null,
                      onTap: () => Navigator.of(context).pop(device),
                    );
                  },
                );
              },
            ),
          ),
      ],
    );
  }

  String _deviceLabel(String deviceType) {    final List<String> segments = deviceType.split(':');
    if (segments.length > 3) {
      return segments[3];
    }
    return deviceType;
  }

  IconData _deviceIcon(String deviceType) {
    switch (_deviceLabel(deviceType)) {
      case 'MediaRenderer':
        return Icons.cast_connected;
      case 'MediaServer':
        return Icons.storage_rounded;
      case 'InternetGatewayDevice':
        return Icons.router;
      case 'DigitalSecurityCamera':
        return Icons.videocam_outlined;
      default:
        return Icons.devices_other;
    }
  }
}
