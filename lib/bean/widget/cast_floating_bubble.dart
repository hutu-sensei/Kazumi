import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/pages/player/cast_control_sheet.dart';
import 'package:kazumi/pages/player/cast_device_sheet.dart';
import 'package:kazumi/services/player/cast_controller.dart';

/// 投屏中离开播放页后，浮在主页上的「投屏中」气泡。
///
/// - 只在 [CastController.casting] 且播放页已销毁时出现；
/// - 可拖动，松手自动吸附到最近的左右边缘并缩小贴边；
/// - 点击展开并打开投屏控制面板。
class CastFloatingBubble extends StatefulWidget {
  const CastFloatingBubble({super.key});

  @override
  State<CastFloatingBubble> createState() => _CastFloatingBubbleState();
}

class _CastFloatingBubbleState extends State<CastFloatingBubble> {
  static const double _size = 56;
  static const double _margin = 12;
  static const double _collapsedScale = 0.74;

  final CastController _cast = CastController.instance;

  Offset? _offset;
  bool _dragging = false;
  bool _collapsed = false;
  bool _onRight = true;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _cast,
      builder: (BuildContext context, Widget? child) {
        if (!_cast.casting || _cast.playerPageAttached) {
          return const SizedBox.shrink();
        }
        final Size screen = MediaQuery.sizeOf(context);
        final Offset offset = _offset ?? _defaultOffset(screen);
        return Stack(
          children: <Widget>[
            AnimatedPositioned(
              duration: _dragging
                  ? Duration.zero
                  : const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              left: offset.dx,
              top: offset.dy,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (DragStartDetails details) {
                  setState(() {
                    _dragging = true;
                    _collapsed = false;
                  });
                },
                onPanUpdate: (DragUpdateDetails details) {
                  setState(() {
                    _offset = _clamp(offset + details.delta, screen);
                  });
                },
                onPanEnd: (DragEndDetails details) => _settle(screen),
                onTap: _openPanel,
                child: Tooltip(
                  message: '投屏中 · 点击打开控制面板',
                  child: AnimatedScale(
                    scale: _collapsed ? _collapsedScale : 1,
                    alignment:
                        _onRight ? Alignment.centerRight : Alignment.centerLeft,
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    child: _buildBubble(context),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildBubble(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool paused = !_cast.playing;
    final double progress = _cast.duration.inMilliseconds > 0
        ? (_cast.position.inMilliseconds / _cast.duration.inMilliseconds)
            .clamp(0.0, 1.0)
            .toDouble()
        : 0;
    return Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: theme.colorScheme.primaryContainer,
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.35),
          width: 1.5,
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          SizedBox(
            width: _size - 10,
            height: _size - 10,
            child: CircularProgressIndicator(
              value: progress > 0 ? progress : null,
              strokeWidth: 2.5,
              backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.12),
            ),
          ),
          Icon(
            paused ? Icons.pause_rounded : Icons.cast_connected,
            size: 22,
            color: theme.colorScheme.onPrimaryContainer,
          ),
        ],
      ),
    );
  }

  Offset _defaultOffset(Size screen) {
    final double top = screen.height * 0.62;
    return Offset(screen.width - _size - _margin, top);
  }

  Offset _clamp(Offset value, Size screen) {
    final double maxX = screen.width - _size - _margin;
    final double maxY = screen.height - _size - _margin - 48;
    return Offset(
      value.dx.clamp(_margin, maxX).toDouble(),
      value.dy.clamp(_margin + 24, maxY).toDouble(),
    );
  }

  /// 松手后吸附到最近的左右边缘，并缩小贴边。
  void _settle(Size screen) {
    final Offset current = _offset ?? _defaultOffset(screen);
    final bool onRight = current.dx + _size / 2 > screen.width / 2;
    final double scaled = _size * _collapsedScale;
    final double targetX = onRight ? screen.width - scaled - 4 : 4;
    final double targetY = current.dy
        .clamp(_margin + 24, screen.height - _size - _margin - 48)
        .toDouble();
    setState(() {
      _dragging = false;
      _onRight = onRight;
      _collapsed = true;
      _offset = Offset(targetX, targetY);
    });
  }

  Future<void> _openPanel() async {
    setState(() => _collapsed = false);
    final BuildContext? navigatorContext = rootNavigatorKey.currentContext;
    if (navigatorContext == null) {
      return;
    }
    await showCastControlSheet(
      navigatorContext,
      onSwitchDevice: _switchDevice,
      onStopCasting: _stopCasting,
      // 播放页已经销毁，这里没有换集能力，面板会自动置灰并给出提示。
      onEpisodeSkip: null,
    );
  }

  Future<void> _switchDevice() async {
    final BuildContext? navigatorContext = rootNavigatorKey.currentContext;
    if (navigatorContext == null) {
      return;
    }
    final device = await showCastDeviceSheet(navigatorContext);
    if (device == null) {
      return;
    }
    await _cast.connect(device);
    final String url = _cast.currentUrl ?? '';
    final bool ok = await _cast.cast(url, title: _cast.currentTitle);
    if (!ok) {
      KazumiDialog.showToast(message: '切换设备失败，请重试');
    }
  }

  Future<void> _stopCasting() async {
    _cast.onCastFinished = null;
    await _cast.disconnect();
    KazumiDialog.showToast(message: '已停止投屏');
  }
}
