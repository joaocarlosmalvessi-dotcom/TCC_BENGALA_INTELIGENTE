import 'dart:async';
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'sincronizacao_bengala.dart';
import 'tela_grupo.dart';
import 'tela_bluetooth.dart';
import 'tela_dispositivos.dart';
import 'tela_relatorios.dart';
import 'tela_perfil.dart';

// Classe auxiliar que ensina o Flutter a aceitar arrasto com o rato do rato no PC
class ArrastarComRatoScrollBehavior extends ScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
  };
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'https://jewjbsdvknzalvldwrzw.supabase.co',
    publishableKey: 'sb_publishable_8R6A4d8-VjURmQrTDUH9DA_GvXOZgrw',
  );

  await DadosBengalaService.inicializar();
  runApp(const MeuAppiOS());
}

class MeuAppiOS extends StatelessWidget {
  const MeuAppiOS({super.key});

  @override
  Widget build(BuildContext context) {
    return CupertinoApp(
      title: 'App TCC',
      theme: const CupertinoThemeData(primaryColor: CupertinoColors.activeBlue),
      scrollBehavior: ArrastarComRatoScrollBehavior(), // Aplica a regra do rato no app inteiro
      home: const TelaLogin(),
    );
  }
}

class TelaLogin extends StatefulWidget {
  const TelaLogin({super.key});

  @override
  State<TelaLogin> createState() => _TelaLoginState();
}

class _TelaLoginState extends State<TelaLogin> {
  final _emailController = TextEditingController();
  final _senhaController = TextEditingController();
  bool _carregando = false;
  bool _navegando = false;
  StreamSubscription<AuthState>? _authSubscription;

  @override
  void initState() {
    super.initState();
    _authSubscription = Supabase.instance.client.auth.onAuthStateChange.listen((
      data,
    ) {
      final session = data.session;
      if (session != null && mounted && !_navegando) {
        _navegando = true;
        Navigator.of(context).pushReplacement(
          CupertinoPageRoute(builder: (context) => const TelaLogada()),
        );
      }
    });
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _emailController.dispose();
    _senhaController.dispose();
    super.dispose();
  }

  Future<void> _registrar() async {
    if (_emailController.text.trim().isEmpty ||
        _senhaController.text.trim().isEmpty) {
      _mostrarAlerta(
        'Atenção',
        'Por favor, preenche o e-mail e a palavra-passe antes de registar.',
      );
      return;
    }
    setState(() => _carregando = true);
    try {
      await Supabase.instance.client.auth.signUp(
        email: _emailController.text.trim(),
        password: _senhaController.text,
        emailRedirectTo: 'io.supabase.apptcc://login-callback',
      );
      _mostrarAlerta(
        'Sucesso',
        'Verifica o teu e-mail para confirmar a conta!',
      );
    } catch (e) {
      _mostrarAlerta('Erro', e.toString());
    }
    if (mounted) setState(() => _carregando = false);
  }

  Future<void> _entrar() async {
    if (_emailController.text.trim().isEmpty ||
        _senhaController.text.trim().isEmpty) {
      _mostrarAlerta(
        'Atenção',
        'Por favor, preenche o e-mail e a palavra-passe para entrar.',
      );
      return;
    }
    setState(() => _carregando = true);
    try {
      await Supabase.instance.client.auth.signInWithPassword(
        email: _emailController.text.trim(),
        password: _senhaController.text,
      );
    } catch (e) {
      _mostrarAlerta('Erro', e.toString());
    }
    if (mounted) setState(() => _carregando = false);
  }

  void _mostrarAlerta(String titulo, String mensagem) {
    if (!mounted || _navegando) return;
    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(titulo),
        content: Text(mensagem),
        actions: [
          CupertinoDialogAction(
            child: const Text('OK'),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('Login TCC')),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CupertinoTextField(
                controller: _emailController,
                placeholder: 'E-mail',
                keyboardType: TextInputType.emailAddress,
                padding: const EdgeInsets.all(16),
              ),
              const SizedBox(height: 16),
              CupertinoTextField(
                controller: _senhaController,
                placeholder: 'Palavra-passe',
                obscureText: true,
                padding: const EdgeInsets.all(16),
              ),
              const SizedBox(height: 24),
              if (_carregando)
                const CupertinoActivityIndicator()
              else ...[
                CupertinoButton.filled(
                  onPressed: _entrar,
                  child: const Text('Entrar'),
                ),
                const SizedBox(height: 16),
                CupertinoButton(
                  onPressed: _registrar,
                  child: const Text('Não tenho conta. Registar'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class TelaLogada extends StatefulWidget {
  const TelaLogada({super.key});

  @override
  State<TelaLogada> createState() => _TelaLogadaState();
}

class _TelaLogadaState extends State<TelaLogada> {
  int _indiceAtual = 0;
  late PageController _pageController; // O controlador que anima as páginas

  @override
  void initState() {
    super.initState();
    // Inicia o controlador na página atual (0)
    _pageController = PageController(initialPage: _indiceAtual);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      child: Stack(
        children: [
          // Substituímos a página estática por um PageView arrastável
          PageView(
            controller: _pageController,
            physics: const BouncingScrollPhysics(), // Dá aquele efeitinho elástico do iOS ao bater nas bordas
            onPageChanged: (index) {
              // Atualiza o botão da barra quando arrastas a página com o dedo
              setState(() {
                _indiceAtual = index;
              });
            },
            children: const [
              TelaGrupo(),
              TelaBluetooth(),
              TelaDispositivos(),
              TelaRelatorios(),
              TelaPerfil(),
            ],
          ),

          if (DadosBengalaService.instancia != null)
            Positioned(
              bottom: 114,
              left: 20,
              right: 20,
              child: AvisoSincronizacao(
                fila: DadosBengalaService.instancia!.fila,
              ),
            ),

          // A Barra Inferior Flutuante
          Positioned(
            bottom: 30,
            left: 20,
            right: 20,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(40),
                boxShadow: [
                  BoxShadow(
                    color: CupertinoColors.black.withValues(alpha: 0.15),
                    blurRadius: 25,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(40),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(
                    height: 75,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: CupertinoColors.white.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(40),
                      border: Border.all(
                        color: CupertinoColors.white.withValues(alpha: 0.8),
                        width: 1.2,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _construirBotao(
                          CupertinoIcons.group_solid,
                          CupertinoIcons.group,
                          0,
                          'Grupo',
                        ),
                        _construirBotao(
                          CupertinoIcons.bluetooth,
                          CupertinoIcons.bluetooth,
                          1,
                          'Config',
                        ),
                        _construirBotao(
                          CupertinoIcons.map_pin_ellipse,
                          CupertinoIcons.map_pin_ellipse,
                          2,
                          'Bengala',
                        ),
                        _construirBotao(
                          CupertinoIcons.doc_text_fill,
                          CupertinoIcons.doc_text,
                          3,
                          'Relatório',
                        ),
                        _construirBotao(
                          CupertinoIcons.person_solid,
                          CupertinoIcons.person,
                          4,
                          'Perfil',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _construirBotao(
    IconData iconeAtivo,
    IconData iconeInativo,
    int indice,
    String rotulo,
  ) {
    final bool ativo = _indiceAtual == indice;

    return GestureDetector(
      onTap: () {
        // Ao clicar no botão, ele anima o ecrã até à página certa
        _pageController.animateToPage(
          indice,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOutCubic,
        );
      },
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: ativo
              ? CupertinoColors.activeBlue.withValues(alpha: 0.15)
              : CupertinoColors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              ativo ? iconeAtivo : iconeInativo,
              color: ativo
                  ? CupertinoColors.activeBlue
                  : CupertinoColors.black.withValues(alpha: 0.6),
              size: ativo ? 26 : 24,
            ),
            const SizedBox(height: 3),
            Text(
              rotulo,
              style: TextStyle(
                fontSize: 10,
                fontWeight: ativo ? FontWeight.bold : FontWeight.w500,
                color: ativo
                    ? CupertinoColors.activeBlue
                    : CupertinoColors.black.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
