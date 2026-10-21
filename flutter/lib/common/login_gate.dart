// DABLIU-DESK: o app so libera o uso depois do login no nosso servidor de
// contas (rustdesk-api no VPS). Fechar a janela de login sem entrar faz ela
// voltar; sair da conta tambem traz o login de volta.
import 'dart:async';

import 'package:url_launcher/url_launcher.dart';

import '../common.dart';
import '../models/platform_model.dart';
import 'widgets/login.dart';

const String kDabliuContas = 'http://163.176.37.43:21114';

bool _exigindoLogin = false;
bool _portaIniciada = false;

bool _logado() => bind.mainGetLocalOption(key: 'access_token').isNotEmpty;

Future<void> abrirCadastroDabliu() async {
  await launchUrl(Uri.parse('$kDabliuContas/_admin/#/register'),
      mode: LaunchMode.externalApplication);
}

Future<void> exigirLogin() async {
  if (_exigindoLogin || bind.isDisableAccount()) return;
  _exigindoLogin = true;
  try {
    while (!_logado()) {
      await loginDialog();
      await Future.delayed(const Duration(milliseconds: 300));
    }
  } finally {
    _exigindoLogin = false;
  }
}

void iniciarPortaDeLogin() {
  if (_portaIniciada) return;
  _portaIniciada = true;
  gFFI.userModel.userName.listen((nome) {
    if (nome.isEmpty) {
      Future.delayed(const Duration(milliseconds: 500), exigirLogin);
    }
  });
  Future.delayed(const Duration(milliseconds: 800), exigirLogin);
}
