import 'dart:async';
import 'dart:convert';

import 'package:dlna_dart/dlna.dart';
import 'package:flutter/foundation.dart';
import 'package:kazumi/services/logging/logger.dart';

/// 一次 DLNA 投屏的完整会话。
///
/// 旧实现只有「setUrl + play」两行，投出去就撒手，既不知道设备叫什么，
/// 也不知道播到哪儿了。这里把设备、进度、传输状态集中托管，UI 通过
/// [ChangeNotifier] 订阅刷新即可。
///
/// 协议能力说明（UPnP AVTransport:1）：
/// - 进度：GetPositionInfo 返回 RelTime / TrackDuration，可做整集进度条；
/// - 跳转：Seek(Unit=REL_TIME) 支持绝对时间点，拖哪跳哪；
/// - 上下集：Next/Previous 只对带播放列表的接收端有效，本项目改为客户端
///   重新 SetAVTransportURI，因此天然具备「自动续投」能力；
/// - 倍速：标准里 Play 动作带 Speed 参数，但绝大多数接收端只认 1，
///   因此这里做「尝试 + 优雅降级」，并把结果缓存到 [speedSupported]。
class CastController extends ChangeNotifier {
  CastController._();

  static final CastController instance = CastController._();

  static const List<double> speedPresets = <double>[
    0.5,
    0.75,
    1,
    1.25,
    1.5,
    2,
  ];

  DLNAManager? _manager;
  StreamSubscription<Map<String, DLNADevice>>? _discoverySubscription;
  DLNADevice? _device;
  Timer? _pollTimer;

  List<DLNADevice> devices = const <DLNADevice>[];
  bool discovering = false;
  bool connecting = false;

  String? deviceName;
  String? deviceType;
  String? currentTitle;
  String? currentUrl;

  bool casting = false;
  String transportState = 'STOPPED';
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  double speed = 1;
  bool? speedSupported;
  bool seekSupported = true;

  /// 本集在接收端播完时的回调，由播放页注入，用于自动续投下一集。
  Future<void> Function()? onCastFinished;

  bool _finishArmed = false;
  DateTime? _lastFinishAt;
  bool _userSeeking = false;
  bool _polling = false;

  bool get playing => transportState == 'PLAYING';
  bool get hasDevice => _device != null;

  // ---------------------------------------------------------------- 设备发现

  Future<void> startDiscovery() async {
    if (discovering) {
      return;
    }
    discovering = true;
    notifyListeners();
    try {
      await _discoverySubscription?.cancel();
      _discoverySubscription = null;
      _manager?.stop();
      final DLNAManager manager = DLNAManager();
      _manager = manager;
      final DeviceManager deviceManager = await manager.start();
      _discoverySubscription = deviceManager.devices.stream.listen((map) {
        devices = map.values.toList()
          ..sort((DLNADevice a, DLNADevice b) =>
              a.info.friendlyName.compareTo(b.info.friendlyName));
        notifyListeners();
      });
    } catch (error) {
      KazumiLogger().e('CastController: discovery failed', error: error);
      discovering = false;
      notifyListeners();
    }
  }

  Future<void> stopDiscovery() async {
    await _discoverySubscription?.cancel();
    _discoverySubscription = null;
    try {
      _manager?.stop();
    } catch (_) {
      // 停止发现失败不影响后续投屏
    }
    _manager = null;
    discovering = false;
    notifyListeners();
  }

  Future<void> connect(DLNADevice device) async {
    _device = device;
    deviceName = device.info.friendlyName;
    final List<String> segments = device.info.deviceType.split(':');
    deviceType = segments.length > 3 ? segments[3] : device.info.deviceType;
    speed = 1;
    speedSupported = null;
    seekSupported = true;
    await stopDiscovery();
    notifyListeners();
  }

  // ------------------------------------------------------------------ 投屏

  /// 投一个新地址（首次投屏、换集、换设备都走这里）。
  Future<bool> cast(String url, {String? title}) async {
    final DLNADevice? device = _device;
    if (device == null || url.isEmpty) {
      return false;
    }
    connecting = true;
    notifyListeners();
    try {
      // 部分接收端会忽略重复的 SetAVTransportURI，先 Stop 清场。
      await _safeStop(device);
      await device.setUrl(url, title: title ?? '');
      await device.play();
    } catch (error) {
      KazumiLogger().e('CastController: cast failed', error: error);
      connecting = false;
      casting = false;
      notifyListeners();
      return false;
    }
    currentUrl = url;
    currentTitle = title;
    casting = true;
    connecting = false;
    transportState = 'PLAYING';
    position = Duration.zero;
    _finishArmed = false;
    _startPolling();
    notifyListeners();
    return true;
  }

  /// 换集续投：设备不变，只把新的播放地址推过去。
  Future<bool> recast(String url, {String? title}) async {
    if (!casting) {
      return false;
    }
    return cast(url, title: title);
  }

  Future<void> togglePlay() async {
    final DLNADevice? device = _device;
    if (device == null || !casting) {
      return;
    }
    try {
      if (playing) {
        await device.pause();
        transportState = 'PAUSED_PLAYBACK';
      } else {
        final bool ok = await _playWithSpeed(device, speed);
        if (!ok) {
          await device.play();
        }
        transportState = 'PLAYING';
      }
    } catch (error) {
      KazumiLogger().e('CastController: toggle play failed', error: error);
    }
    notifyListeners();
  }

  void beginUserSeek() {
    _userSeeking = true;
  }

  void endUserSeek() {
    _userSeeking = false;
  }

  Future<void> seekTo(Duration target) async {
    final DLNADevice? device = _device;
    if (device == null || !casting) {
      return;
    }
    int milliseconds = target.inMilliseconds;
    if (milliseconds < 0) {
      milliseconds = 0;
    }
    if (duration > Duration.zero &&
        milliseconds > duration.inMilliseconds) {
      milliseconds = duration.inMilliseconds;
    }
    final Duration clamped = Duration(milliseconds: milliseconds);
    try {
      await device.seek(formatHms(clamped));
      position = clamped;
      notifyListeners();
    } catch (error) {
      seekSupported = false;
      KazumiLogger().e('CastController: seek failed', error: error);
      notifyListeners();
    }
  }

  Future<void> seekBy(int seconds) {
    return seekTo(position + Duration(seconds: seconds));
  }

  /// 尝试设置倍速。返回 false 表示接收端拒绝（绝大多数设备都会拒绝）。
  Future<bool> setSpeed(double value) async {
    final DLNADevice? device = _device;
    if (device == null || !casting) {
      return false;
    }
    final bool ok = await _playWithSpeed(device, value);
    speedSupported = ok;
    speed = ok ? value : 1;
    notifyListeners();
    return ok;
  }

  Future<void> stopCasting() async {
    final DLNADevice? device = _device;
    _pollTimer?.cancel();
    _pollTimer = null;
    try {
      if (device != null) {
        await device.stop();
      }
    } catch (error) {
      KazumiLogger().w('CastController: stop failed', error: error);
    }
    casting = false;
    transportState = 'STOPPED';
    position = Duration.zero;
    duration = Duration.zero;
    _finishArmed = false;
    notifyListeners();
  }

  Future<void> disconnect() async {
    await stopCasting();
    _device = null;
    deviceName = null;
    deviceType = null;
    currentUrl = null;
    currentTitle = null;
    notifyListeners();
  }

  // ------------------------------------------------------------------ 内部

  Future<void> _safeStop(DLNADevice device) async {
    try {
      await device.stop();
    } catch (_) {
      // 空闲状态下 Stop 报错是正常现象
    }
  }

  Future<bool> _playWithSpeed(DLNADevice device, double value) async {
    if (value == 1) {
      try {
        await device.play();
        return true;
      } catch (_) {
        return false;
      }
    }
    final String xml = '''<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <Speed>${_speedValue(value)}</Speed>
    </u:Play>
  </s:Body>
</s:Envelope>''';
    try {
      await device.request('Play', utf8.encode(xml));
      return true;
    } catch (_) {
      return false;
    }
  }

  String _speedValue(double value) {
    if (value == 0.5) {
      return '1/2';
    }
    if (value == 0.75) {
      return '3/4';
    }
    if (value == 1.25) {
      return '5/4';
    }
    if (value == 1.5) {
      return '3/2';
    }
    if (value == value.roundToDouble()) {
      return value.toInt().toString();
    }
    return value.toStringAsFixed(2);
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) {
      unawaited(_pollOnce());
    });
  }

  Future<void> _pollOnce() async {
    final DLNADevice? device = _device;
    if (device == null || !casting || _polling) {
      return;
    }
    _polling = true;
    try {
      final String positionXml = await device.position();
      final RegExpMatch? durationMatch =
          RegExp(r'<TrackDuration>(.*?)</TrackDuration>', dotAll: true)
              .firstMatch(positionXml);
      final RegExpMatch? positionMatch =
          RegExp(r'<RelTime>(.*?)</RelTime>', dotAll: true)
              .firstMatch(positionXml);
      if (durationMatch != null) {
        final Duration parsed = parseHms(durationMatch.group(1)!);
        if (parsed > Duration.zero) {
          duration = parsed;
        }
      }
      if (positionMatch != null && !_userSeeking) {
        position = parseHms(positionMatch.group(1)!);
      }
      final String transportXml = await device.getTransportInfo();
      final RegExpMatch? stateMatch = RegExp(
        r'<CurrentTransportState>(.*?)</CurrentTransportState>',
        dotAll: true,
      ).firstMatch(transportXml);
      if (stateMatch != null) {
        transportState = stateMatch.group(1)!.trim();
      }
      _checkFinished();
      notifyListeners();
    } catch (_) {
      // 单次轮询失败不打断会话，避免日志刷屏
    } finally {
      _polling = false;
    }
  }

  void _checkFinished() {
    if (duration <= Duration.zero || transportState == 'PAUSED_PLAYBACK') {
      return;
    }
    final Duration remaining = duration - position;
    if (remaining > const Duration(seconds: 3)) {
      _finishArmed = true;
      return;
    }
    if (!_finishArmed) {
      return;
    }
    final DateTime now = DateTime.now();
    if (_lastFinishAt != null &&
        now.difference(_lastFinishAt!) < const Duration(seconds: 8)) {
      return;
    }
    _lastFinishAt = now;
    _finishArmed = false;
    final Future<void> Function()? callback = onCastFinished;
    if (callback != null) {
      unawaited(callback());
    }
  }

  static Duration parseHms(String raw) {
    final String text = raw.trim();
    if (text.isEmpty || text.contains('NOT_IMPLEMENTED')) {
      return Duration.zero;
    }
    final String core = text.split('.').first;
    int seconds = 0;
    for (final String part in core.split(':')) {
      seconds = seconds * 60 + (int.tryParse(part.trim()) ?? 0);
    }
    return Duration(seconds: seconds);
  }

  static String formatHms(Duration value) {
    int total = value.inSeconds;
    if (total < 0) {
      total = 0;
    }
    final int hours = total ~/ 3600;
    final int minutes = (total % 3600) ~/ 60;
    final int seconds = total % 60;
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
}
