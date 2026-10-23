// Agente DENTRO do DABLIU DESK: roda o laco da IA em Dart, usando a PROPRIA
// sessao remota para VER (print do remoto) e AGIR (clicar/digitar no remoto).
// Sem localhost, sem Python, sem executor. O alvo e sempre o computador conectado.
//
// Fluxo: tira print do remoto -> manda pra IA (ferramentas proprias, estilo DIY)
// -> IA responde "clicar x,y / digitar / tecla" -> injeta na sessao -> repete.
// Cada acao que muda o remoto pede aprovacao; print e espera nao pedem. PARAR corta.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';

/// Ponte do print: o agente pede `sessionTakeScreenshot`; quando o evento
/// 'screenshot' chega no model.dart, ele chama `entregar` (gancho fino la),
/// que salva o PNG num arquivo temporario e completa o Future, SEM dialogo.
class AgentScreenshotBridge {
  static Completer<String>? _pending;
  static String? _alvoPath;

  static bool get aguardando => _pending != null;

  static Future<String> capturar(SessionID sessionId,
      {Duration timeout = const Duration(seconds: 20)}) async {
    final dir = (await getTemporaryDirectory()).path;
    final ts = DateTime.now().millisecondsSinceEpoch;
    _alvoPath = '$dir/dabliu_agente_$ts.png';
    _pending = Completer<String>();
    await bind.sessionTakeScreenshot(sessionId: sessionId, display: 0);
    try {
      return await _pending!.future.timeout(timeout);
    } finally {
      _pending = null;
    }
  }

  /// Gancho fino chamado por model.dart no evento 'screenshot'.
  /// Retorna true se o agente consumiu o print (nao mostrar dialogo).
  static Future<bool> entregar(SessionID sessionId) async {
    final p = _pending;
    final path = _alvoPath;
    if (p == null || path == null) return false;
    try {
      await bind.sessionHandleScreenshot(
          sessionId: sessionId, action: '0:$path');
    } catch (_) {}
    if (!p.isCompleted) p.complete(path);
    return true;
  }
}

enum AgentFase { parado, pensando, aprovando, agindo, feito, erro }

class AgentStep {
  final String texto;
  final bool destaque; // PROGRESSO/acao
  AgentStep(this.texto, {this.destaque = false});
}

/// Pede aprovacao ao usuario para uma acao que muda o remoto. Retorna true=ok.
typedef PedirAprovacao = Future<bool> Function(String descricaoAcao);

class AgentInSession extends ChangeNotifier {
  AgentInSession(
      {required this.sessionId,
      required this.apiKey,
      required this.modelo,
      required this.pedirAprovacao,
      this.executorUrl = '',
      this.executorToken = ''});

  final SessionID sessionId;
  final String apiKey;
  final String modelo;
  final PedirAprovacao pedirAprovacao;
  final String executorUrl;
  final String executorToken;

  static final _perigo = RegExp(
      r'(\bRemove-Item\b|\bRemove-ItemProperty\b|\brm\b|\bdel\b|\brd\b|\brmdir\b|'
      r'\bClear-Content\b|\bClear-Disk\b|\bClear-RecycleBin\b|\bFormat-Volume\b|'
      r'\bStop-Process\b|\btaskkill\b|\bshutdown\b|\bRestart-Computer\b|\breg\s+delete\b|'
      r'\bUninstall-|\bSet-ExecutionPolicy\b|\bdiskpart\b)',
      caseSensitive: false);

  final List<AgentStep> passos = [];
  AgentFase fase = AgentFase.parado;
  bool _parar = false;
  int larguraRemota = 0;
  int alturaRemota = 0;

  static const _endpoint = 'https://api.anthropic.com/v1/messages';
  static const _maxPassos = 40;

  void parar() {
    _parar = true;
    _log('PARAR pedido pelo usuario.', destaque: true);
    fase = AgentFase.parado;
    notifyListeners();
  }

  void _log(String t, {bool destaque = false}) {
    passos.add(AgentStep(t, destaque: destaque));
    notifyListeners();
  }

  void _setFase(AgentFase f) {
    fase = f;
    notifyListeners();
  }

  bool get temExecutor => executorUrl.trim().isNotEmpty;

  // ---- ferramentas que a IA pode chamar (estilo DIY, robusto a versao da API) ----
  List<Map<String, dynamic>> _ferramentas() => [
        if (temExecutor)
          {
            'name': 'comando',
            'description':
                'Roda um comando PowerShell NO computador conectado (o remoto) e devolve a '
                    'saida (stdout/stderr/exit). Use para DIAGNOSTICAR e AGIR no sistema: '
                    'processos, CPU/memoria/disco, servicos, rede, arquivos/pastas, programas, '
                    'janelas. PREFIRA isto a clicar quando der por comando.',
            'input_schema': {
              'type': 'object',
              'properties': {
                'comando': {
                  'type': 'string',
                  'description': 'O comando PowerShell a executar no PC conectado.'
                }
              },
              'required': ['comando']
            },
          },
        {
          'name': 'tirar_print',
          'description':
              'Tira um print da tela do COMPUTADOR CONECTADO para voce ver antes de agir.',
          'input_schema': {'type': 'object', 'properties': {}},
        },
        {
          'name': 'clicar',
          'description':
              'Clica no computador conectado em (x,y) em pixels do print (origem no canto superior esquerdo).',
          'input_schema': {
            'type': 'object',
            'properties': {
              'x': {'type': 'integer'},
              'y': {'type': 'integer'},
              'botao': {
                'type': 'string',
                'enum': ['left', 'right', 'double']
              }
            },
            'required': ['x', 'y']
          },
        },
        {
          'name': 'digitar',
          'description': 'Digita um texto no computador conectado (clique no campo antes).',
          'input_schema': {
            'type': 'object',
            'properties': {
              'texto': {'type': 'string'}
            },
            'required': ['texto']
          },
        },
        {
          'name': 'tecla',
          'description':
              'Aperta uma tecla ou combinacao no remoto, ex.: Return, Escape, ctrl+c, win+r.',
          'input_schema': {
            'type': 'object',
            'properties': {
              'teclas': {'type': 'string'}
            },
            'required': ['teclas']
          },
        },
      ];

  String _system() =>
      'Voce e um tecnico de informatica operando o COMPUTADOR CONECTADO (remoto) '
      'pelo DABLIU DESK, em pt-BR. Tudo que voce faz acontece NELE, nunca no PC do '
      'operador. Trabalhe assim: 1) tire um print para VER, 2) diagnostique, 3) aja '
      'com clicar/digitar/tecla, 4) confira com OUTRO print depois de CADA acao. '
      'Clique com PRECISAO: mire o CENTRO do elemento usando as coordenadas exatas do '
      'tamanho informado no print; se o clique nao surtir efeito, tire um print e '
      'CORRIJA a posicao em vez de repetir no mesmo lugar. Para trazer a janela certa '
      'para frente antes de agir, use a ferramenta tecla (ex.: alt+tab, ou win para o '
      'menu Iniciar). Explique em 1 linha antes de cada acao. Peca o minimo de acoes. '
      '${temExecutor ? 'Voce TAMBEM tem a ferramenta comando: PowerShell direto no PC '
          'conectado. PREFIRA comando para diagnosticar e agir no sistema (processos, '
          'servicos, disco, rede, arquivos, programas, listar/trazer janelas) - e mais '
          'confiavel que clicar; use a tela so quando nao der por comando. ' : ''}'
      'Para tarefas no NAVEGADOR do remoto: '
      '${temExecutor ? 'abra a pagina com comando (ex.: Start-Process "https://..."), ' : ''}'
      'depois interaja pela tela com clicar/digitar (confira com print). '
      'Ao terminar, responda um resumo curto comecando com "PRONTO:".';

  Future<void> executar(String tarefa,
      {List<Map<String, dynamic>> anexos = const []}) async {
    _parar = false;
    passos.clear();
    _setFase(AgentFase.pensando);
    _log('Tarefa: $tarefa');
    if (anexos.isNotEmpty) _log('(${anexos.length} imagem(ns) anexada(s) de contexto)');

    final mensagens = <Map<String, dynamic>>[
      {
        'role': 'user',
        'content': [
          ...anexos,
          {'type': 'text', 'text': tarefa}
        ]
      }
    ];

    try {
      for (var passo = 0; passo < _maxPassos; passo++) {
        if (_parar) {
          _log('Interrompido.', destaque: true);
          _setFase(AgentFase.parado);
          return;
        }
        _setFase(AgentFase.pensando);
        final resp = await _chamarIA(mensagens);
        if (resp == null) {
          _setFase(AgentFase.erro);
          return;
        }
        final content = (resp['content'] as List?) ?? [];
        mensagens.add({'role': 'assistant', 'content': content});

        // texto da IA
        for (final b in content) {
          if (b is Map && b['type'] == 'text') {
            final t = (b['text'] ?? '').toString().trim();
            if (t.isNotEmpty) _log(t);
          }
        }

        if (resp['stop_reason'] != 'tool_use') {
          _setFase(AgentFase.feito);
          return;
        }

        // executa as ferramentas pedidas
        final resultados = <Map<String, dynamic>>[];
        for (final b in content) {
          if (b is! Map || b['type'] != 'tool_use') continue;
          if (_parar) {
            _setFase(AgentFase.parado);
            return;
          }
          final nome = b['name'];
          final entrada = (b['input'] as Map?) ?? {};
          final id = b['id'];
          final r = await _executarFerramenta(nome, entrada);
          resultados.add({
            'type': 'tool_result',
            'tool_use_id': id,
            'content': r,
          });
        }
        mensagens.add({'role': 'user', 'content': resultados});
      }
      _log('Atingi o limite de passos.', destaque: true);
      _setFase(AgentFase.feito);
    } catch (e) {
      _log('ERRO: $e', destaque: true);
      _setFase(AgentFase.erro);
    }
  }

  // ---- MODO MONITOR: observa o remoto em ciclos e so AVISA (nao age) ----
  Future<void> monitorar(String foco, {int intervaloSeg = 20}) async {
    _parar = false;
    passos.clear();
    _setFase(AgentFase.pensando);
    _log('MONITORANDO: ${foco.isEmpty ? 'a tela' : foco} '
        '(a cada ${intervaloSeg}s). PARAR encerra.', destaque: true);
    final mensagens = <Map<String, dynamic>>[];
    try {
      while (!_parar) {
        _setFase(AgentFase.agindo);
        final img = await _print();
        if (_parar) break;
        mensagens.add({
          'role': 'user',
          'content': [
            ...img,
            {
              'type': 'text',
              'text':
                  'Voce MONITORA o PC conectado (nao aja, so observe). Foco: '
                      '"${foco.isEmpty ? 'estado geral da tela' : foco}". Olhe o print e '
                      'responda em 1-2 linhas: o estado atual e se mudou algo relevante '
                      'desde o ultimo ciclo. Se exigir atencao/acao humana, COMECE com '
                      '"ATENCAO:". Caso contrario, comece com "ok:".'
            }
          ]
        });
        _setFase(AgentFase.pensando);
        final resp = await _chamarIA(mensagens);
        if (resp == null) {
          _setFase(AgentFase.erro);
          return;
        }
        final content = (resp['content'] as List?) ?? [];
        mensagens.add({'role': 'assistant', 'content': content});
        for (final b in content) {
          if (b is Map && b['type'] == 'text') {
            final t = (b['text'] ?? '').toString().trim();
            if (t.isNotEmpty) {
              _log(t, destaque: t.toUpperCase().startsWith('ATENCAO'));
            }
          }
        }
        if (mensagens.length > 8) {
          mensagens.removeRange(0, mensagens.length - 8);
        }
        if (_parar) break;
        _setFase(AgentFase.agindo);
        for (var s = 0; s < intervaloSeg && !_parar; s++) {
          await Future.delayed(const Duration(seconds: 1));
        }
      }
    } catch (e) {
      _log('ERRO no monitor: $e', destaque: true);
    }
    _setFase(AgentFase.parado);
    _log('Monitoramento encerrado.', destaque: true);
  }

  Future<dynamic> _executarFerramenta(String? nome, Map entrada) async {
    switch (nome) {
      case 'comando':
        final cmd = (entrada['comando'] ?? '').toString();
        if (!temExecutor) {
          return 'Executor nao configurado (Config. > Agente). Sem ele nao da pra '
              'rodar comando no PC conectado; use clicar/digitar na tela.';
        }
        if (_perigo.hasMatch(cmd)) {
          final ok = await _aprovar('rodar no PC conectado: $cmd');
          if (!ok) return 'Usuario NEGOU o comando.';
        } else {
          _setFase(AgentFase.agindo);
        }
        _log('[comando] $cmd');
        return await _rodarComando(cmd);
      case 'tirar_print':
        _setFase(AgentFase.agindo);
        return await _print();
      case 'clicar':
        final x = (entrada['x'] as num?)?.toInt() ?? 0;
        final y = (entrada['y'] as num?)?.toInt() ?? 0;
        final botao = (entrada['botao'] ?? 'left').toString();
        final ok = await _aprovar('clicar ($botao) em ($x,$y) no computador conectado');
        if (!ok) return 'Usuario NEGOU o clique.';
        await _clicar(x, y, botao);
        return 'cliquei ($botao) em ($x,$y)';
      case 'digitar':
        final texto = (entrada['texto'] ?? '').toString();
        final ok = await _aprovar('digitar "${texto.length > 40 ? '${texto.substring(0, 40)}...' : texto}" no computador conectado');
        if (!ok) return 'Usuario NEGOU a digitacao.';
        await _digitar(texto);
        return 'texto digitado';
      case 'tecla':
        final teclas = (entrada['teclas'] ?? '').toString();
        final ok = await _aprovar('tecla "$teclas" no computador conectado');
        if (!ok) return 'Usuario NEGOU a tecla.';
        await _tecla(teclas);
        return 'tecla $teclas enviada';
    }
    return 'ferramenta desconhecida: $nome';
  }

  Future<bool> _aprovar(String desc) async {
    _setFase(AgentFase.aprovando);
    _log('Pede OK: $desc', destaque: true);
    final ok = await pedirAprovacao(desc);
    _log(ok ? 'Aprovado.' : 'Negado.');
    _setFase(AgentFase.agindo);
    return ok;
  }

  // ---- VER: print do remoto como bloco de imagem para a IA ----
  Future<List<Map<String, dynamic>>> _print() async {
    final path = await AgentScreenshotBridge.capturar(sessionId);
    final bytes = await File(path).readAsBytes();
    try {
      await File(path).delete();
    } catch (_) {}
    int w = 0, h = 0;
    if (bytes.length >= 24) {
      w = (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
      h = (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
    }
    final b64 = base64Encode(bytes);
    _log('[print do remoto $w x $h]');
    return [
      {
        'type': 'image',
        'source': {'type': 'base64', 'media_type': 'image/png', 'data': b64}
      },
      {
        'type': 'text',
        'text':
            'Print do computador conectado: $w x $h pixels. (0,0) e o canto superior '
            'esquerdo e ($w,$h) o inferior direito. Ao clicar, use coordenadas EXATAS '
            'dentro desse tamanho, mirando o CENTRO do elemento alvo.'
      }
    ];
  }

  // ---- AGIR: injeta na sessao remota ----
  Future<void> _clicar(int x, int y, String botao) async {
    // move e clica em coordenada absoluta do remoto
    await bind.sessionSendMouse(
        sessionId: sessionId, msg: jsonEncode({'x': '$x', 'y': '$y'}));
    await Future.delayed(const Duration(milliseconds: 60));
    final b = botao == 'right' ? 'right' : 'left';
    final vezes = botao == 'double' ? 2 : 1;
    for (var i = 0; i < vezes; i++) {
      await bind.sessionSendMouse(
          sessionId: sessionId,
          msg: jsonEncode({'type': 'down', 'x': '$x', 'y': '$y', 'buttons': b}));
      await bind.sessionSendMouse(
          sessionId: sessionId,
          msg: jsonEncode({'type': 'up', 'x': '$x', 'y': '$y', 'buttons': b}));
      if (vezes > 1) await Future.delayed(const Duration(milliseconds: 80));
    }
  }

  Future<void> _digitar(String texto) async {
    await bind.sessionInputString(sessionId: sessionId, value: texto);
  }

  Future<void> _tecla(String teclas) async {
    final partes = teclas
        .split('+')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final mods = <String>[];
    String? principal;
    for (final p in partes) {
      final l = p.toLowerCase();
      if (['ctrl', 'control', 'alt', 'shift', 'win', 'super', 'meta', 'cmd']
          .contains(l)) {
        mods.add(l == 'control' ? 'ctrl' : (l == 'super' || l == 'cmd' || l == 'meta' ? 'win' : l));
      } else {
        principal = p;
      }
    }
    for (final m in mods) {
      bind.sessionInputKey(
          sessionId: sessionId,
          name: m,
          down: true,
          press: false,
          alt: false,
          ctrl: false,
          shift: false,
          command: false);
    }
    if (principal != null) {
      bind.sessionInputKey(
          sessionId: sessionId,
          name: principal,
          down: false,
          press: true,
          alt: mods.contains('alt'),
          ctrl: mods.contains('ctrl'),
          shift: mods.contains('shift'),
          command: mods.contains('win'));
    }
    for (final m in mods.reversed) {
      bind.sessionInputKey(
          sessionId: sessionId,
          name: m,
          down: false,
          press: false,
          alt: false,
          ctrl: false,
          shift: false,
          command: false);
    }
  }

  // ---- AGIR no sistema: PowerShell no remoto pelo executor (tunel) ----
  Map<String, dynamic>? _alvo; // identidade do executor (trava troca de PC)

  Future<Map<String, dynamic>?> _identidade(String base) async {
    if (_alvo != null) return _alvo;
    try {
      final r = await http
          .post(Uri.parse('$base/identidade'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'token': executorToken}))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode == 200) {
        _alvo = (jsonDecode(utf8.decode(r.bodyBytes)) as Map)
            .cast<String, dynamic>();
      }
    } catch (_) {}
    return _alvo;
  }

  Future<String> _rodarComando(String cmd) async {
    try {
      final base = executorUrl.trim().replaceAll(RegExp(r'/+$'), '');
      final alvo = await _identidade(base);
      if (alvo == null) {
        return 'ERRO: o Executor nao respondeu /identidade. Confira URL, token e o '
            'tunel do DABLIU DESK (porta encaminhada para 127.0.0.1 do remoto).';
      }
      final r = await http
          .post(Uri.parse('$base/cmd'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(
                  {'token': executorToken, 'comando': cmd, 'alvo': alvo}))
          .timeout(const Duration(seconds: 120));
      if (r.statusCode != 200) {
        return 'ERRO do executor (${r.statusCode}): '
            '${r.body.substring(0, r.body.length > 300 ? 300 : r.body.length)}';
      }
      final d = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      final saida = (d['saida'] ?? d['output'] ?? '').toString();
      return 'exit=${d['exit'] ?? d['code'] ?? '?'}\n$saida';
    } catch (e) {
      return 'ERRO ao falar com o executor ($executorUrl): $e';
    }
  }

  // ---- IA: Claude Messages API direto do app ----
  Future<Map<String, dynamic>?> _chamarIA(
      List<Map<String, dynamic>> mensagens) async {
    try {
      final r = await http.post(
        Uri.parse(_endpoint),
        headers: {
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01',
          'content-type': 'application/json',
        },
        body: jsonEncode({
          'model': modelo,
          'max_tokens': 4000,
          'system': _system(),
          'tools': _ferramentas(),
          'messages': mensagens,
        }),
      );
      if (r.statusCode != 200) {
        _log('ERRO da IA (${r.statusCode}): ${r.body.substring(0, r.body.length > 300 ? 300 : r.body.length)}',
            destaque: true);
        return null;
      }
      return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    } catch (e) {
      _log('ERRO de rede com a IA: $e', destaque: true);
      return null;
    }
  }
}

/// Painel do Agente, compartilhado entre desktop e mobile. Abra via showDialog.
/// Le a chave/modelo salvos em Configuracoes (kOptionAgentApiKey/Modelo).
class AgentPanel extends StatefulWidget {
  final SessionID sessionId;
  const AgentPanel({Key? key, required this.sessionId}) : super(key: key);

  @override
  State<AgentPanel> createState() => _AgentPanelState();
}

class _AgentPanelState extends State<AgentPanel> {
  final _keyCtrl = TextEditingController();
  final _modeloCtrl = TextEditingController(text: 'claude-sonnet-5-5');
  final _tarefaCtrl = TextEditingController();
  final _scroll = ScrollController();
  AgentInSession? _agent;
  String _executorUrl = '';
  String _executorToken = '';
  final List<Map<String, dynamic>> _anexos = [];

  @override
  void initState() {
    super.initState();
    try {
      final k = bind.mainGetLocalOption(key: kOptionAgentApiKey);
      if (k.isNotEmpty) _keyCtrl.text = k;
      final m = bind.mainGetLocalOption(key: kOptionAgentModelo);
      if (m.isNotEmpty) _modeloCtrl.text = m;
      _executorUrl = bind.mainGetLocalOption(key: kOptionAgentExecutorUrl);
      _executorToken = bind.mainGetLocalOption(key: kOptionAgentExecutorToken);
    } catch (_) {}
  }

  @override
  void dispose() {
    _agent?.removeListener(_onAgent);
    _agent?.parar();
    _keyCtrl.dispose();
    _modeloCtrl.dispose();
    _tarefaCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool get _rodando =>
      _agent != null &&
      (_agent!.fase == AgentFase.pensando ||
          _agent!.fase == AgentFase.agindo ||
          _agent!.fase == AgentFase.aprovando);

  void _onAgent() {
    if (mounted) setState(() {});
  }

  Future<bool> _pedirAprovacao(String desc) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Aprovar acao no computador conectado'),
        content: Text(desc),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Negar')),
          ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Aprovar')),
        ],
      ),
    );
    return ok ?? false;
  }

  AgentInSession? _criarAgente() {
    final key = _keyCtrl.text.trim();
    if (key.isEmpty || _rodando) return null;
    try {
      bind.mainSetLocalOption(key: kOptionAgentApiKey, value: key);
      bind.mainSetLocalOption(
          key: kOptionAgentModelo, value: _modeloCtrl.text.trim());
    } catch (_) {}
    _agent?.removeListener(_onAgent);
    final agent = AgentInSession(
      sessionId: widget.sessionId,
      apiKey: key,
      modelo: _modeloCtrl.text.trim().isEmpty
          ? 'claude-sonnet-5-5'
          : _modeloCtrl.text.trim(),
      pedirAprovacao: _pedirAprovacao,
      executorUrl: _executorUrl,
      executorToken: _executorToken,
    );
    agent.addListener(_onAgent);
    setState(() => _agent = agent);
    return agent;
  }

  void _enviar() {
    final tarefa = _tarefaCtrl.text.trim();
    if (tarefa.isEmpty) return;
    final agent = _criarAgente();
    if (agent == null) return;
    final anexos = List<Map<String, dynamic>>.from(_anexos);
    setState(_anexos.clear);
    agent.executar(tarefa, anexos: anexos);
  }

  void _monitorar() {
    final agent = _criarAgente();
    if (agent == null) return;
    agent.monitorar(_tarefaCtrl.text.trim());
  }

  Future<void> _anexarImagem() async {
    try {
      final res = await FilePicker.platform
          .pickFiles(type: FileType.image, withData: true);
      if (res == null || res.files.isEmpty) return;
      final f = res.files.first;
      final bytes = f.bytes ??
          (f.path != null ? await File(f.path!).readAsBytes() : null);
      if (bytes == null) return;
      final ext = (f.extension ?? 'png').toLowerCase();
      final media = (ext == 'jpg' || ext == 'jpeg')
          ? 'image/jpeg'
          : ext == 'webp'
              ? 'image/webp'
              : ext == 'gif'
                  ? 'image/gif'
                  : 'image/png';
      setState(() {
        _anexos.add({
          'type': 'image',
          'source': {
            'type': 'base64',
            'media_type': media,
            'data': base64Encode(bytes)
          },
        });
      });
    } catch (_) {}
  }

  String _faseTexto(AgentFase f) {
    switch (f) {
      case AgentFase.pensando:
        return 'pensando...';
      case AgentFase.aprovando:
        return 'aguardando sua aprovacao...';
      case AgentFase.agindo:
        return 'agindo no computador conectado...';
      case AgentFase.feito:
        return 'concluido';
      case AgentFase.erro:
        return 'erro';
      case AgentFase.parado:
        return '';
    }
  }

  Widget _caixaPassos() {
    final passos = _agent?.passos ?? const <AgentStep>[];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
    return Container(
      width: double.infinity,
      height: 200,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
          color: Colors.black26, borderRadius: BorderRadius.circular(6)),
      child: passos.isEmpty
          ? const Text('(sem atividade ainda)',
              style: TextStyle(fontFamily: 'monospace', fontSize: 12))
          : ListView.builder(
              controller: _scroll,
              itemCount: passos.length,
              itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: Text(passos[i].texto,
                        style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            fontWeight: passos[i].destaque
                                ? FontWeight.bold
                                : FontWeight.normal)),
                  )),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fase = _agent?.fase ?? AgentFase.parado;
    final larg = (MediaQuery.of(context).size.width - 48).clamp(0.0, 560.0);
    return PopScope(
      canPop: !_rodando,
      child: AlertDialog(
        title: Row(children: [
          const Icon(Icons.smart_toy_outlined, size: 20),
          const SizedBox(width: 8),
          const Expanded(child: Text('Agente')),
        ]),
        content: SizedBox(
          width: larg,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                    'O agente age NO computador conectado pela propria sessao: '
                    've a tela, clica e digita nele. Cada acao pede aprovacao.'),
                const SizedBox(height: 8),
                TextField(
                  enabled: !_rodando,
                  obscureText: true,
                  controller: _keyCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Chave da IA (ou defina nas Config.)'),
                ),
                const SizedBox(height: 8),
                TextField(
                  enabled: !_rodando,
                  controller: _modeloCtrl,
                  decoration: const InputDecoration(labelText: 'Modelo'),
                ),
                const SizedBox(height: 6),
                Row(children: [
                  Icon(
                      _executorUrl.trim().isEmpty
                          ? Icons.terminal_outlined
                          : Icons.terminal,
                      size: 16,
                      color: _executorUrl.trim().isEmpty
                          ? Colors.grey
                          : Colors.greenAccent),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _executorUrl.trim().isEmpty
                          ? 'Executor: nao configurado (so ve/clica na tela)'
                          : 'Executor: ativo (PowerShell no PC conectado)',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                TextField(
                  controller: _tarefaCtrl,
                  enabled: !_rodando,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                      labelText: 'Tarefa', hintText: 'ex.: abra o menu Iniciar'),
                ),
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 6, children: [
                  ElevatedButton(
                      onPressed: _rodando ? null : _enviar,
                      child: const Text('Enviar')),
                  OutlinedButton.icon(
                      onPressed: _rodando ? null : _monitorar,
                      icon: const Icon(Icons.visibility_outlined, size: 16),
                      label: const Text('Monitorar')),
                  OutlinedButton.icon(
                      onPressed: _rodando ? null : _anexarImagem,
                      icon: const Icon(Icons.image_outlined, size: 16),
                      label: Text(_anexos.isEmpty
                          ? 'Anexar imagem'
                          : 'Imagem (${_anexos.length})')),
                  ElevatedButton(
                      onPressed: _rodando ? () => _agent?.parar() : null,
                      style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.redAccent),
                      child: const Text('PARAR')),
                ]),
                const SizedBox(height: 6),
                Text(_faseTexto(fase)),
                const SizedBox(height: 10),
                const Text('Agente ao vivo',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                _caixaPassos(),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: _rodando ? null : () => Navigator.of(context).pop(),
              child: const Text('Fechar'))
        ],
      ),
    );
  }
}
