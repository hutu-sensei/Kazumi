import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/dialog/material_bottom_sheet.dart';
import 'package:kazumi/services/player/cast_controller.dart';
import 'package:kazumi/utils/format.dart';

/// 打开投屏控制面板。
///
/// [onSwitchDevice] 由播放页负责「关面板 → 选设备 → 重新投屏」的完整流程；
/// [onEpisodeSkip] 传入 'next' / 'prev'，由播放页调用真正的换集逻辑，
/// 换集后 [CastController] 会自动把新地址推给接收端（自动续投）。
Future<void> showCastControlSheet(
  BuildContext context, {
  required Future<void> Function() onSwitchDevice,
  required Future<void> Function() onStopCasting,
  required Future<void> Function(String direction) onEpisodeSkip,
}) {
  return showAdaptiveBottomSheet<void>(
    context: context,
    maxHeightFactor: 0.85,
    compactLandscapeMaxHeightFactor: 0.95,
    builder: (BuildContext context) => CastControlSheet(
      onSwitchDevice: onSwitchDevice,
      onStopCasting: onStopCasting,
      onEpisodeSkip: onEpisodeSkip,
    ),
  );
}

class CastControlSheet extends StatefulWidget {
  const CastControlSheet({
    super.key,
    required this.onSwitchDevice,
    required this.onStopCasting,
    required this.onEpisodeSkip,
  });

  final Future<void> Function() onSwitchDevice;
  final Future<void> Function() onStopCasting;
  final Future<void> Function(String direction) onEpisodeSkip;

  @override
  State<CastControlSheet> createState() => _CastControlSheetState();
}

class _CastControlSheetState extends State<CastControlSheet> {
  final CastController _cast = CastController.instance;

  /// 拖动中的临时秒数；null 表示跟随接收端上报的真实进度。
  double? _dragSeconds;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _cast,
      builder: (BuildContext context, Widget? child) {
          final ThemeData theme = Theme.of(context);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              MaterialBottomSheetHeader(
                title: '投屏控制',
                description: _cast.currentTitle ?? '正在投屏',
                leading: const Icon(Icons.cast_connected),
                onClose: () => Navigator.of(context).pop(),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: materialBottomSheetContentPadding,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _buildDeviceRow(context, theme),
                      const SizedBox(height: 20),
                      _buildProgress(context, theme),
                      const SizedBox(height: 4),
                      _buildTransportRow(context),
                      const SizedBox(height: 20),
                      _buildSpeedSection(context, theme),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () async {
                            Navigator.of(context).pop();
                            await widget.onStopCasting();
                          },
                          icon: const Icon(Icons.stop_circle_outlined),
                          label: const Text('停止投屏'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
      },
    );
  }

  Widget _buildDeviceRow(BuildContext context, ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.cast_connected, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  _cast.deviceName ?? '未连接设备',
                  style: theme.textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  _statusText(),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await widget.onSwitchDevice();
            },
            child: const Text('切换设备'),
          ),
        ],
      ),
    );
  }

  Widget _buildProgress(BuildContext context, ThemeData theme) {
    final bool seekable = _cast.duration > Duration.zero;
    final double maxSeconds =
        seekable ? _cast.duration.inSeconds.toDouble() : 1;
    final double raw = _dragSeconds ?? _cast.position.inSeconds.toDouble();
    final double value = raw.clamp(0, maxSeconds).toDouble();
    final Duration displayPosition = _dragSeconds != null
        ? Duration(seconds: _dragSeconds!.round())
        : _cast.position;
    return Column(
      children: <Widget>[
        Slider(
          value: value,
          max: maxSeconds,
          onChanged:
              seekable ? (double next) => setState(() => _dragSeconds = next) : null,
          onChangeStart: seekable ? _handleSeekStart : null,
          onChangeEnd: seekable ? _handleSeekEnd : null,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text(
                durationToString(displayPosition),
                style: theme.textTheme.labelMedium,
              ),
              Text(
                seekable ? durationToString(_cast.duration) : '接收端未上报时长',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: seekable ? null : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTransportRow(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: <Widget>[
        IconButton(
          tooltip: '上一集',
          onPressed: () => widget.onEpisodeSkip('prev'),
          icon: const Icon(Icons.skip_previous_rounded),
        ),
        IconButton(
          tooltip: '后退 10 秒',
          onPressed: () => _cast.seekBy(-10),
          icon: const Icon(Icons.replay_10_rounded),
        ),
        IconButton.filled(
          tooltip: _cast.playing ? '暂停' : '播放',
          iconSize: 32,
          onPressed: _cast.togglePlay,
          icon: Icon(
            _cast.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          ),
        ),
        IconButton(
          tooltip: '前进 10 秒',
          onPressed: () => _cast.seekBy(10),
          icon: const Icon(Icons.forward_10_rounded),
        ),
        IconButton(
          tooltip: '下一集',
          onPressed: () => widget.onEpisodeSkip('next'),
          icon: const Icon(Icons.skip_next_rounded),
        ),
      ],
    );
  }

  Widget _buildSpeedSection(BuildContext context, ThemeData theme) {
    final bool unsupported = _cast.speedSupported == false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text('播放速度', style: theme.textTheme.titleSmall),
            const SizedBox(width: 8),
            if (unsupported)
              Text(
                '接收端不支持',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final double preset in CastController.speedPresets)
              ChoiceChip(
                label: Text('${_speedLabel(preset)}×'),
                selected: (_cast.speed - preset).abs() < 0.01,
                onSelected: (_) => _applySpeed(preset),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '倍速属于 DLNA 的扩展能力，多数电视 / 投影接收端只认 1×，不支持时会自动回落。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  String _statusText() {
    switch (_cast.transportState) {
      case 'PLAYING':
        return '正在播放 · 进度实时同步';
      case 'PAUSED_PLAYBACK':
        return '已暂停';
      case 'TRANSITIONING':
        return '正在切换片源…';
      default:
        return _cast.connecting ? '正在建立连接…' : '已连接';
    }
  }

  String _speedLabel(double value) {
    if (value == value.roundToDouble()) {
      return value.toInt().toString();
    }
    return value.toString();
  }

  void _handleSeekStart(double value) {
    _cast.beginUserSeek();
    setState(() => _dragSeconds = value);
  }

  Future<void> _handleSeekEnd(double value) async {
    await _cast.seekTo(Duration(seconds: value.round()));
    _cast.endUserSeek();
    if (mounted) {
      setState(() => _dragSeconds = null);
    }
  }

  Future<void> _applySpeed(double value) async {
    final bool ok = await _cast.setSpeed(value);
    if (!ok && mounted) {
      KazumiDialog.showToast(message: '该接收端不支持倍速，已回到 1.0×');
    }
  }
}
