// LICENCA POR PC do DABLIU DESK (molde do PROSPECTOR, 03/11/2026).
//
// O servidor (Documents/AGENTE-REMOTO/LICENCAS, no Vercel) ASSINA cada resposta
// com Ed25519; aqui so vale o que a CHAVE_PUBLICA confere. A resposta assinada
// vale 7 dias sem internet (folga_ate); confere de novo a cada poucas horas,
// entao pausar/cancelar no painel derruba o app em pouco tempo. Relogio voltado
// para tras nao estica a folga (guardamos o maior horario ja visto).
//
// Enquanto kLicencaLigada == false (servidor ainda nao publicado), o portao e
// transparente: o app roda normal, nada muda. Quando o servidor estiver no ar,
// basta por a URL em kLicencaServidorPadrao e ligar kLicencaLigada = true.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as crypto;
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_hbb/models/platform_model.dart';

const bool kLicencaLigada = false; // vira true quando o servidor estiver no ar
const String kLicencaServidorPadrao = 'https://wdask-licencas.vercel.app';
const String kLicencaChavePublica = 'E8mtYXZOnxTAX4x8EobIeaQY1rYf9MfjVvx8yVkq1lM=';
const String kLicencaVersao = '1.5.1';
const int kLicencaConferirHoras = 4;
const String _kOpt = 'dabliu-licenca'; // json guardado neste PC
const String _kOptUrl = 'dabliu-licenca-url'; // override opcional da URL
const String _kOptUuid = 'dabliu-licenca-uuid'; // id de reserva se faltar o ID

String _servidor() {
  try {
    final u = bind.mainGetLocalOption(key: _kOptUrl).trim();
    if (u.isNotEmpty) return u;
  } catch (_) {}
  return kLicencaServidorPadrao;
}

// ---------------------------------------------------------------------------
// Este PC
// ---------------------------------------------------------------------------
String _pcIdCache = '';

Future<String> carregarPcId() async {
  if (_pcIdCache.isNotEmpty) return _pcIdCache;
  var id = '';
  try {
    id = (await bind.mainGetMyId()).trim();
  } catch (_) {}
  if (id.isEmpty) {
    try {
      id = bind.mainGetLocalOption(key: _kOptUuid).trim();
      if (id.isEmpty) {
        id = '${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(Object())}';
        bind.mainSetLocalOption(key: _kOptUuid, value: id);
      }
    } catch (_) {}
  }
  _pcIdCache = crypto.sha256.convert(utf8.encode('DABLIU|$id')).toString();
  return _pcIdCache;
}

String pcId() => _pcIdCache;

String codigoCurto() {
  final p = pcId().toUpperCase();
  if (p.length < 12) return p;
  return '${p.substring(0, 4)}-${p.substring(4, 8)}-${p.substring(8, 12)}';
}

String _pcNome() {
  try {
    return Platform.localHostname;
  } catch (_) {
    return 'PC';
  }
}

// ---------------------------------------------------------------------------
// A licenca guardada
// ---------------------------------------------------------------------------
Map<String, dynamic> _ler() {
  try {
    final s = bind.mainGetLocalOption(key: _kOpt).trim();
    if (s.isNotEmpty) return (jsonDecode(s) as Map).cast<String, dynamic>();
  } catch (_) {}
  return {};
}

void _gravar(Map<String, dynamic> d) {
  try {
    bind.mainSetLocalOption(key: _kOpt, value: jsonEncode(d));
  } catch (_) {}
}

Uint8List _b64d(String s) =>
    base64Url.decode(s + '=' * ((4 - s.length % 4) % 4));

/// Os dados da licenca se a assinatura confere e e deste PC; senao null.
Map<String, dynamic>? abrir(String token) {
  try {
    final p = token.split('.');
    if (p.length != 2) return null;
    final corpo = _b64d(p[0]);
    final assin = _b64d(p[1]);
    final pub = ed.PublicKey(base64.decode(kLicencaChavePublica));
    if (!ed.verify(pub, corpo, assin)) return null;
    final dados = (jsonDecode(utf8.decode(corpo)) as Map).cast<String, dynamic>();
    return dados['pc'] == pcId() ? dados : null;
  } catch (_) {
    return null;
  }
}

double _agoraS() => DateTime.now().millisecondsSinceEpoch / 1000.0;

/// Como esta a licenca agora, so com o que esta guardado (sem rede).
Map<String, dynamic> estado() {
  if (!kLicencaLigada) return {'ok': true, 'motivo': '', 'dispensada': true};
  final g = _ler();
  final agora = _agoraS();
  final base = <String, dynamic>{
    'ok': false,
    'codigo_pc': codigoCurto(),
    'chave': g['chave'] ?? '',
    'servidor': _servidor(),
  };
  final token = (g['token'] ?? '').toString();
  if (token.isEmpty) {
    return {...base, 'motivo': 'este PC ainda nao tem licenca', 'sem_chave': true};
  }
  final d = abrir(token);
  if (d == null) {
    return {...base, 'motivo': 'a licenca guardada nao vale para este PC', 'sem_chave': true};
  }
  final visto = (g['maior_horario'] as num?)?.toDouble() ?? 0;
  base.addAll({
    'plano': d['plano'],
    'cliente': d['cliente'],
    'vence': d['vence'],
    'status': d['status'],
    'max_pcs': d['max_pcs'],
  });
  if (agora < visto - 3600) {
    return {...base, 'motivo': 'o relogio do PC esta atrasado; acerte a data e a hora'};
  }
  if (d['status'] != 'ativa') {
    return {...base, 'motivo': (d['motivo'] ?? 'licenca ${d['status']}').toString()};
  }
  final vence = (d['vence'] ?? '').toString();
  if (vence.isNotEmpty) {
    try {
      final t = DateTime.parse(vence.replaceAll('Z', '+00:00'))
              .millisecondsSinceEpoch /
          1000.0;
      if (t < agora) return {...base, 'motivo': 'a mensalidade venceu'};
    } catch (_) {}
  }
  final folga = (d['folga_ate'] as num?)?.toDouble() ?? 0;
  if (agora > folga) {
    return {
      ...base,
      'motivo': 'faz mais de 7 dias que o DABLIU DESK nao confere a licenca: ligue a internet'
    };
  }
  return {...base, 'ok': true, 'motivo': ''};
}

bool liberado() => estado()['ok'] == true;

void marcarHorario() {
  final g = _ler();
  final agora = _agoraS();
  if (agora > ((g['maior_horario'] as num?)?.toDouble() ?? 0)) {
    g['maior_horario'] = agora;
    _gravar(g);
  }
}

// ---------------------------------------------------------------------------
// Conversa com o servidor
// ---------------------------------------------------------------------------
Future<Map<String, dynamic>> conferir({String? chave, bool ativar = false}) async {
  final g = _ler();
  chave = chave ?? (g['chave']?.toString());
  if (chave == null || chave.isEmpty) return estado();
  await carregarPcId();
  final corpo = jsonEncode({
    'chave': chave,
    'pc_id': pcId(),
    'pc_nome': _pcNome(),
    'versao': kLicencaVersao,
    'ativar': ativar,
  });
  final base = _servidor().replaceAll(RegExp(r'/+$'), '');
  http.Response r;
  try {
    r = await http
        .post(Uri.parse('$base/api/conferir'),
            headers: {'Content-Type': 'application/json'}, body: corpo)
        .timeout(const Duration(seconds: 20));
  } catch (e) {
    if (ativar) throw 'sem conexao com o servidor de licencas';
    return estado();
  }
  Map<String, dynamic> resp = {};
  try {
    resp = (jsonDecode(utf8.decode(r.bodyBytes)) as Map).cast<String, dynamic>();
  } catch (_) {}
  if (r.statusCode != 200) {
    if (ativar) {
      throw (resp['erro']?.toString() ??
          'o servidor de licencas recusou (${r.statusCode})');
    }
    return estado();
  }
  final token = resp['licenca']?.toString();
  if (token == null || abrir(token) == null) {
    if (ativar) throw 'resposta do servidor de licencas nao confere';
    return estado();
  }
  final dados = abrir(token)!;
  g['chave'] = dados['chave'];
  g['token'] = token;
  final nowS = _agoraS();
  final maior = (g['maior_horario'] as num?)?.toDouble() ?? 0;
  g['maior_horario'] = nowS > maior ? nowS : maior;
  g['conferida_em'] = nowS;
  _gravar(g);
  final e = estado();
  if (ativar && e['ok'] != true) throw (e['motivo']?.toString() ?? 'licenca invalida');
  return e;
}

Future<Map<String, dynamic>> ativarLicenca(String chave) =>
    conferir(chave: chave, ativar: true);

// ---------------------------------------------------------------------------
// O portao: embrulha a tela inicial. Desligado, deixa passar direto.
// ---------------------------------------------------------------------------
class LicencaPortao extends StatefulWidget {
  final Widget child;
  const LicencaPortao({Key? key, required this.child}) : super(key: key);

  @override
  State<LicencaPortao> createState() => _LicencaPortaoState();
}

class _LicencaPortaoState extends State<LicencaPortao> {
  Map<String, dynamic>? _e;
  Timer? _t;
  double _ultimaConferida = 0;

  @override
  void initState() {
    super.initState();
    if (kLicencaLigada) _iniciar();
  }

  Future<void> _iniciar() async {
    await carregarPcId();
    if (mounted) setState(() => _e = estado());
    await _conferirSeHora(force: true);
    _t = Timer.periodic(const Duration(minutes: 20), (_) async {
      marcarHorario();
      await _conferirSeHora();
      if (mounted) setState(() => _e = estado());
    });
  }

  Future<void> _conferirSeHora({bool force = false}) async {
    if (!force && _agoraS() - _ultimaConferida < kLicencaConferirHoras * 3600) {
      return;
    }
    _ultimaConferida = _agoraS();
    try {
      await conferir();
    } catch (_) {}
    if (mounted) setState(() => _e = estado());
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!kLicencaLigada) return widget.child;
    final e = _e;
    if (e == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (e['ok'] == true) return widget.child;
    return AtivarLicencaTela(
      estado: e,
      aoMudar: () async {
        if (mounted) setState(() => _e = estado());
      },
    );
  }
}

// ---------------------------------------------------------------------------
// A tela de ativacao (quando nao ha licenca valida)
// ---------------------------------------------------------------------------
class AtivarLicencaTela extends StatefulWidget {
  final Map<String, dynamic> estado;
  final Future<void> Function() aoMudar;
  const AtivarLicencaTela(
      {Key? key, required this.estado, required this.aoMudar})
      : super(key: key);

  @override
  State<AtivarLicencaTela> createState() => _AtivarLicencaTelaState();
}

class _AtivarLicencaTelaState extends State<AtivarLicencaTela> {
  final _ctrl = TextEditingController();
  bool _rodando = false;
  String _erro = '';

  @override
  void initState() {
    super.initState();
    _ctrl.text = (widget.estado['chave'] ?? '').toString();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _ativar() async {
    final chave = _ctrl.text.trim();
    if (chave.isEmpty || _rodando) return;
    setState(() {
      _rodando = true;
      _erro = '';
    });
    try {
      await ativarLicenca(chave);
      await widget.aoMudar();
    } catch (e) {
      if (mounted) setState(() => _erro = e.toString());
    } finally {
      if (mounted) setState(() => _rodando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final codigo = (widget.estado['codigo_pc'] ?? '').toString();
    final motivo = (widget.estado['motivo'] ?? '').toString();
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.vpn_key_outlined, size: 26),
                    const SizedBox(width: 10),
                    const Expanded(
                        child: Text('Ativar o DABLIU DESK',
                            style: TextStyle(
                                fontSize: 20, fontWeight: FontWeight.bold))),
                  ]),
                  const SizedBox(height: 12),
                  if (motivo.isNotEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                          color: Colors.orange.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(6)),
                      child: Text(motivo),
                    ),
                  const SizedBox(height: 16),
                  const Text('Digite a chave de acesso (WDSK-XXXX-XXXX-XXXX-XXXX):'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _ctrl,
                    enabled: !_rodando,
                    autocorrect: false,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                      hintText: 'WDSK-____-____-____-____',
                    ),
                    onSubmitted: (_) => _ativar(),
                  ),
                  const SizedBox(height: 12),
                  Row(children: [
                    ElevatedButton(
                      onPressed: _rodando ? null : _ativar,
                      child: _rodando
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Ativar'),
                    ),
                    const SizedBox(width: 12),
                    if (_erro.isNotEmpty)
                      Expanded(
                          child: Text(_erro,
                              style: const TextStyle(color: Colors.redAccent))),
                  ]),
                  const SizedBox(height: 20),
                  const Divider(),
                  const SizedBox(height: 8),
                  const Text('Código deste PC (passe a quem vende, para liberar):',
                      style: TextStyle(fontSize: 12)),
                  const SizedBox(height: 4),
                  Row(children: [
                    SelectableText(codigo,
                        style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 16,
                            fontWeight: FontWeight.bold)),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 16),
                      tooltip: 'Copiar',
                      onPressed: () => Clipboard.setData(ClipboardData(text: codigo)),
                    ),
                  ]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
