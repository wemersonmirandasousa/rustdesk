// DABLIU-DESK: o celular avisa o nosso servidor de contas que esta com o app
// instalado (aparece no painel de administrador, em Dispositivos). No PC quem
// faz isso e o proprio servico (src/hbbs_http/sync.rs); no iPhone esse envio
// nao existe e no Android so roda com o compartilhamento de tela ligado.
import 'dart:async';
import 'dart:convert';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../common.dart';
import '../models/platform_model.dart';

Timer? _batimento;

Future<Map<String, String>> _dadosDoAparelho() async {
  final info = DeviceInfoPlugin();
  if (isAndroid) {
    final a = await info.androidInfo;
    return {
      'hostname': '${a.manufacturer} ${a.model}',
      'os': 'Android ${a.version.release}',
    };
  }
  final i = await info.iosInfo;
  return {
    'hostname': '${i.name} (${i.utsname.machine})',
    'os': 'iOS ${i.systemVersion}',
  };
}

Future<void> _enviar(String url, Map<String, dynamic> corpo) async {
  await http
      .post(Uri.parse(url),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(corpo))
      .timeout(const Duration(seconds: 15));
}

Future<void> registrarAparelho() async {
  if (!(isAndroid || isIOS) || _batimento != null) return;
  try {
    final api = await bind.mainGetApiServer();
    if (api.isEmpty) return;
    final id = await bind.mainGetMyId();
    final uuid = await bind.mainGetUuid();
    final dados = await _dadosDoAparelho();
    await _enviar('$api/api/sysinfo', {
      'id': id,
      'uuid': uuid,
      'hostname': dados['hostname'],
      'os': dados['os'],
      'username': '',
      'version': await bind.mainGetVersion(),
      'cpu': '',
      'memory': '',
    });
    batida() => _enviar('$api/api/heartbeat', {'id': id, 'uuid': uuid})
        .catchError((e) => debugPrint('registro heartbeat: $e'));
    await batida();
    _batimento = Timer.periodic(const Duration(minutes: 1), (_) => batida());
  } catch (e) {
    debugPrint('registro do aparelho falhou: $e');
  }
}
