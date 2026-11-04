import 'package:flutter/cupertino.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'main.dart'; // Para o botão de Sair conseguir aceder à TelaLogin

class TelaPerfil extends StatefulWidget {
  const TelaPerfil({super.key});

  @override
  State<TelaPerfil> createState() => _TelaPerfilState();
}

class _TelaPerfilState extends State<TelaPerfil> {
  final _supabase = Supabase.instance.client;

  final _nomeController = TextEditingController();
  final _telefoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _senhaController = TextEditingController();

  bool _carregando = false;

  @override
  void initState() {
    super.initState();
    _carregarDados();
  }

  @override
  void dispose() {
    _nomeController.dispose();
    _telefoneController.dispose();
    _emailController.dispose();
    _senhaController.dispose();
    super.dispose();
  }

  // Busca os dados que estão guardados na base de dados
  void _carregarDados() {
    final user = _supabase.auth.currentUser;
    if (user != null) {
      _emailController.text = user.email ?? '';
      _nomeController.text = user.userMetadata?['nome'] ?? '';
      _telefoneController.text = user.userMetadata?['telefone'] ?? '';
    }
  }

  void _mostrarAlerta(String titulo, String mensagem) {
    if (!mounted) return;
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

  // Atualiza Nome e Telefone (Guardados nos metadados do utilizador)
  Future<void> _salvarDadosPessoais() async {
    setState(() => _carregando = true);
    try {
      await _supabase.auth.updateUser(
        UserAttributes(
          data: {
            'nome': _nomeController.text.trim(),
            'telefone': _telefoneController.text.trim(),
          },
        ),
      );
      _mostrarAlerta('Sucesso', 'Os teus dados pessoais foram atualizados!');
    } catch (e) {
      _mostrarAlerta('Erro', e.toString());
    }
    if (mounted) setState(() => _carregando = false);
  }

  // Atualiza o E-mail (O Supabase envia e-mail de confirmação automaticamente)
  Future<void> _atualizarEmail() async {
    if (_emailController.text.trim().isEmpty) return;

    setState(() => _carregando = true);
    try {
      await _supabase.auth.updateUser(
        UserAttributes(email: _emailController.text.trim()),
      );
      _mostrarAlerta(
        'Verifica a Caixa de Entrada',
        'Enviámos um link de confirmação para o teu novo e-mail. A alteração só será feita após a confirmação.',
      );
    } catch (e) {
      _mostrarAlerta('Erro', e.toString());
    }
    if (mounted) setState(() => _carregando = false);
  }

  // Atualiza a Senha diretamente
  Future<void> _atualizarSenha() async {
    if (_senhaController.text.trim().isEmpty) {
      _mostrarAlerta('Atenção', 'Digita uma nova palavra-passe.');
      return;
    }

    setState(() => _carregando = true);
    try {
      await _supabase.auth.updateUser(
        UserAttributes(password: _senhaController.text),
      );
      if (!mounted) return;
      _senhaController.clear();
      _mostrarAlerta(
        'Sucesso',
        'A tua palavra-passe foi alterada com sucesso!',
      );
    } catch (e) {
      _mostrarAlerta('Erro', e.toString());
    }
    if (mounted) setState(() => _carregando = false);
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('Meu Perfil')),
      child: SafeArea(
        child: _carregando
            ? const Center(child: CupertinoActivityIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 140),
                children: [
                  const Text(
                    'Dados Pessoais',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  CupertinoTextField(
                    controller: _nomeController,
                    placeholder: 'Nome Completo',
                    padding: const EdgeInsets.all(16),
                    prefix: const Padding(
                      padding: EdgeInsets.only(left: 10),
                      child: Icon(
                        CupertinoIcons.person,
                        color: CupertinoColors.systemGrey,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  CupertinoTextField(
                    controller: _telefoneController,
                    placeholder: 'Número de Telefone',
                    keyboardType: TextInputType.phone,
                    padding: const EdgeInsets.all(16),
                    prefix: const Padding(
                      padding: EdgeInsets.only(left: 10),
                      child: Icon(
                        CupertinoIcons.phone,
                        color: CupertinoColors.systemGrey,
                      ),
                    ),
                  ),
                  const SizedBox(height: 15),
                  CupertinoButton.filled(
                    onPressed: _salvarDadosPessoais,
                    child: const Text('Guardar Dados Pessoais'),
                  ),

                  const SizedBox(height: 40),
                  const Text(
                    'Segurança',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),

                  CupertinoTextField(
                    controller: _emailController,
                    placeholder: 'Novo E-mail',
                    keyboardType: TextInputType.emailAddress,
                    padding: const EdgeInsets.all(16),
                    prefix: const Padding(
                      padding: EdgeInsets.only(left: 10),
                      child: Icon(
                        CupertinoIcons.mail,
                        color: CupertinoColors.systemGrey,
                      ),
                    ),
                  ),
                  const SizedBox(height: 5),
                  CupertinoButton(
                    onPressed: _atualizarEmail,
                    child: const Text('Atualizar E-mail'),
                  ),

                  const SizedBox(height: 20),
                  CupertinoTextField(
                    controller: _senhaController,
                    placeholder: 'Nova Palavra-passe',
                    obscureText: true,
                    padding: const EdgeInsets.all(16),
                    prefix: const Padding(
                      padding: EdgeInsets.only(left: 10),
                      child: Icon(
                        CupertinoIcons.lock,
                        color: CupertinoColors.systemGrey,
                      ),
                    ),
                  ),
                  const SizedBox(height: 5),
                  CupertinoButton(
                    onPressed: _atualizarSenha,
                    child: const Text('Atualizar Palavra-passe'),
                  ),

                  const SizedBox(height: 40),
                  Container(height: 1, color: CupertinoColors.systemGrey5),
                  const SizedBox(height: 20),

                  CupertinoButton(
                    onPressed: () async {
                      try {
                        await _supabase.auth.signOut();
                        if (!context.mounted) return;
                        Navigator.of(
                          context,
                          rootNavigator: true,
                        ).pushReplacement(
                          CupertinoPageRoute(
                            builder: (context) => const TelaLogin(),
                          ),
                        );
                      } catch (e) {
                        _mostrarAlerta('Erro ao sair', e.toString());
                      }
                    },
                    child: const Text(
                      'Sair da Conta',
                      style: TextStyle(
                        color: CupertinoColors.destructiveRed,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
      ),
    );
  }
}
