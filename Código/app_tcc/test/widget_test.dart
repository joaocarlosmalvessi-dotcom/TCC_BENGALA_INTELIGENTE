import 'package:app_tcc/main.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await Supabase.initialize(
      url: 'https://test.invalid',
      publishableKey: 'test-publishable-key',
      authOptions: FlutterAuthClientOptions(
        pkceAsyncStorage: _MemoryAuthStorage(),
        persistSession: false,
        autoRefreshToken: false,
        detectSessionInUri: false,
      ),
    );
  });

  tearDownAll(() async {
    await Supabase.instance.dispose();
  });

  testWidgets('Abre login com campos e ações de autenticação', (tester) async {
    await tester.pumpWidget(const MeuAppiOS());
    await tester.pumpAndSettle();
    expect(find.text('Login TCC'), findsOneWidget);
    expect(find.byType(CupertinoTextField), findsNWidgets(2));
    expect(find.text('Entrar'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final acao in ['Entrar', 'Não tenho conta. Registar']) {
    testWidgets('$acao valida campos vazios antes de chamar a rede', (
      tester,
    ) async {
      await tester.pumpWidget(const MeuAppiOS());
      await tester.pumpAndSettle();
      await tester.tap(find.text(acao));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoAlertDialog), findsOneWidget);
      expect(find.text('Atenção'), findsOneWidget);
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Remover e reabrir login libera os recursos da tela', (
    tester,
  ) async {
    await tester.pumpWidget(const MeuAppiOS());
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(CupertinoTextField).first,
      'pessoa@exemplo.com',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(const MeuAppiOS());
    await tester.pumpAndSettle();
    expect(find.text('pessoa@exemplo.com'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _MemoryAuthStorage extends GotrueAsyncStorage {
  final _values = <String, String>{};

  @override
  Future<String?> getItem({required String key}) async => _values[key];

  @override
  Future<void> setItem({required String key, required String value}) async {
    _values[key] = value;
  }

  @override
  Future<void> removeItem({required String key}) async {
    _values.remove(key);
  }
}
