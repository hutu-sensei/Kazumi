import 'package:dio/dio.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/request/core/ech_adapter.dart';
import 'package:kazumi/services/network/bangumi_acceleration.dart';
import 'package:kazumi/services/network/rules_mirror.dart';
import 'package:kazumi/utils/bangumi_mirror_credentials.dart';

class BangumiAccelerationInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final uri = options.uri;
    if (ApiEndpoints.bangumiPublicApiHosts.contains(uri.host)) {
      switch (BangumiAcceleration.current) {
        case BangumiAcceleration.direct:
          break;
        case BangumiAcceleration.ech:
          options.path = uri.replace(scheme: 'https').toString();
          options.queryParameters = {};
          options.requireEch();
        case BangumiAcceleration.mirror:
          // 自编译包没有签名凭据，签名镜像会对搜索返回 401。
          // 仅搜索接口改走免签名镜像；每日放送、趋势、详情等路径
          // 仍走上游镜像，因为免签名镜像未实现 /p1/* 且会返回假 200。
          final bool unsignedSearch = !hasBangumiMirrorCredentials &&
              options.method == 'POST' &&
              uri.path == '/v0/search/subjects';
          final String mirrorBase = unsignedSearch
              ? ApiEndpoints.bangumiUnsignedMirrorDomain
              : ApiEndpoints.bangumiMirrorDomain;
          options.path =
              mirrorBase + uri.path + (uri.hasQuery ? '?${uri.query}' : '');
          options.queryParameters = {};
      }
    }
    handler.next(options);
  }
}

class RulesMirrorInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final url = options.uri.toString();
    if (url.startsWith(ApiEndpoints.pluginShop)) {
      switch (RulesMirror.current) {
        case RulesMirror.direct:
          break;
        case RulesMirror.ghProxy:
          options.path = ApiEndpoints.ghProxyMirror + url;
          options.requireEch();
        case RulesMirror.ghfast:
          options.path = ApiEndpoints.ghfastMirror + url;
        case RulesMirror.gitcode:
          options.path =
              ApiEndpoints.gitcodeMirror +
              url.substring(ApiEndpoints.pluginShop.length);
      }
    }
    handler.next(options);
  }
}
