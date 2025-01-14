import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import '/src/internal/http/descope_client.dart';
import '/src/internal/others/error.dart';
import '/src/internal/routes/shared.dart';
import '/src/sdk/routes.dart';
import '/src/types/error.dart';
import '/src/types/responses.dart';

const _defaultRedirectURL = 'descopeauth://flow';

class Flow extends DescopeFlow {
  static const _mChannel = MethodChannel('descope_flutter/methods');
  static const _eChannel = EventChannel('descope_flutter/events');
  static final _random = Random.secure();
  static final _sha256 = Sha256();

  final DescopeClient client;
  _FlowRunner? _current;

  Flow(this.client);

  @override
  Future<AuthenticationResponse> start(String flowUrl, {String? deepLinkUrl}) async {
    // cancel any previous still running flows
    _current?.completer?.completeError(DescopeException.flowCancelled);

    // prepare a new flow runner
    final runner = _FlowRunner(flowUrl, deepLinkUrl);
    final uri = await _prepareInitialRequest(runner);
    _current = runner;

    try {
      // invoke a platform method call
      await _mChannel.invokeMethod('startFlow', {'url': uri.toString()});
      _listenToEventsIfNeeded();
      final completer = Completer<AuthenticationResponse>();
      runner.completer = completer;
      return completer.future;
    } on PlatformException {
      throw DescopeException.flowFailed.add(message: 'Flow launch failed');
    }
  }

  @override
  Future<void> resume(Uri incomingUri) async {
    final runner = _current;
    if (runner == null) {
      throw DescopeException.flowFailed.add(message: 'No flow to resume');
    }

    // For some reason '#' are decoded in this string, need to re-encode
    // to correctly process query parameters
    incomingUri = Uri.parse(incomingUri.toString().replaceAll('#', '%23'));
    var uri = Uri.parse(runner.flowUrl);
    uri = uri.replace(queryParameters: incomingUri.queryParameters);
    try {
      await _mChannel.invokeMethod('startFlow', {'url': uri.toString()});
    } on PlatformException {
      throw DescopeException.flowFailed.add(message: 'Flow resume failed');
    }
  }

  @override
  void exchange(Uri incomingUri) {
    final runner = _current;
    final codeVerifier = runner?.codeVerifier;
    final completer = runner?.completer;
    if (runner == null || codeVerifier == null || completer == null) {
      throw DescopeException.flowFailed.add(message: 'No flow pending exchange');
    }

    _current = null;
    final authorizationCode = incomingUri.queryParameters['code'];
    if (authorizationCode == null) {
      final e = DescopeException.flowFailed.add(message: 'No code parameter on incoming URI');
      completer.completeError(e);
      throw e;
    }

    _exchange(authorizationCode, codeVerifier, completer);
  }

  // Internal

  void _listenToEventsIfNeeded() {
    if (!_isIOS()) {
      return;
    }
    StreamSubscription? subscription;
    subscription = _eChannel.receiveBroadcastStream().listen((event) {
      final str = event as String;
      switch (str) {
        case 'canceled':
          _completeWithError(DescopeException.flowCancelled.add(message: 'Flow canceled by user'));
          break;
        case '':
          _completeWithError(DescopeException.flowFailed.add(message: 'Unexpected error running flow'));
          break;
        default:
          try {
            final uri = Uri.parse(str);
            exchange(uri);
          } on Exception {
            _completeWithError(DescopeException.flowFailed.add(message: 'Unexpected URI received from flow'));
          }
      }
      subscription?.cancel();
    }, onError: (_) {
      _completeWithError(DescopeException.flowFailed.add(message: 'Authentication failed'));
      subscription?.cancel();
    });
  }

  void _completeWithError(DescopeException exception) {
    _current?.completer?.completeError(exception);
    _current = null;
  }

  Future<void> _exchange(String authorizationCode, String codeVerifier, Completer<AuthenticationResponse> completer) async {
    final authResponse = (await client.flowExchange(authorizationCode, codeVerifier)).toAuthenticationResponse();
    completer.complete(authResponse);
  }

  Future<Uri> _prepareInitialRequest(_FlowRunner runner) async {
    final randomBytes = _createRandomBytes();
    final hashedBytes = await _sha256.hash(randomBytes);

    final codeVerifier = base64UrlEncode(randomBytes);
    final codeChallenge = base64UrlEncode(hashedBytes.bytes);

    try {
      var uri = Uri.parse(runner.flowUrl);
      final params = Map<String, String>.from(uri.queryParameters);
      params['ra-callback'] = _isIOS() ? _defaultRedirectURL : (runner.deepLinkUrl ?? _defaultRedirectURL);
      params['ra-challenge'] = codeChallenge;
      var initiator = _platformString();
      if (initiator != null) {
        params['ra-initiator'] = initiator;
      }

      uri = uri.replace(queryParameters: params);
      runner.codeVerifier = codeVerifier;
      return uri;
    } on Exception catch (e) {
      throw DescopeException.flowFailed.add(message: 'Invalid flow URL', cause: e);
    }
  }

  static List<int> _createRandomBytes([int length = 32]) {
    return List<int>.generate(length, (i) => _random.nextInt(256));
  }

  static String? _platformString() {
    if (kIsWeb) {
      return 'web';
    } else if (Platform.isAndroid) {
      return 'android';
    } else if (Platform.isIOS) {
      return 'ios';
    } else if (Platform.isMacOS) {
      return 'macos';
    } else if (Platform.isWindows) {
      return 'windows';
    }
    return null;
  }

  static bool _isIOS() {
    return !kIsWeb && Platform.isIOS;
  }
}

class _FlowRunner {
  final String flowUrl;
  final String? deepLinkUrl;
  String? codeVerifier;
  Completer<AuthenticationResponse>? completer;

  _FlowRunner(this.flowUrl, [this.deepLinkUrl]);
}
