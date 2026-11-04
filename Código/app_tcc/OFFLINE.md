# Leituras da bengala sem acesso ao banco

Cada pacote recebido por Bluetooth é salvo em uma transação no banco local
`bengala_offline.db`, na pasta privada de suporte do aplicativo. A mesma transação
guarda o estado do sinal de emergência. A fila não é apagada ao fechar o app,
reiniciar o celular, sair da conta ou perder a conexão com o Supabase.

O envio acontece independentemente da recepção Bluetooth. O app tenta enviar ao
receber dados, a cada 20 segundos enquanto está executando, ao retornar ao primeiro
plano e após mudanças de sessão. Uma falha impõe um intervalo de 20 segundos entre
tentativas. Apenas uma sincronização é executada por vez; cada leitura só sai da
fila depois da confirmação do servidor. Um aviso indica a quantidade pendente.

O servidor recebe um identificador único por pacote e grava sensores, histórico
GPS e emergência em uma única transação. Se a resposta se perder, o mesmo ID é
reenviado e o banco não cria duplicatas. O horário guardado é o da coleta no celular
(portanto depende do relógio dele), mesmo que o envio aconteça depois. Dados antigos
entram no histórico, mas não sobrescrevem a última leitura de outra sincronização.

As leituras permanecem vinculadas à conta original e só são enviadas quando essa
conta está conectada. O servidor verifica novamente a conta e o grupo. Rejeições
de permissão também preservam a fila; é preciso restaurar o acesso correto para
que o envio seja aceito.

Uma bengala precisa ser vinculada com internet uma vez nesta versão. O app guarda
esse vínculo por conta e permite reconectar pelo Bluetooth sem consultar o banco.
O primeiro vínculo e um novo login continuam dependendo de acesso ao Supabase.

O envio automático funciona enquanto o sistema permite que o aplicativo execute.
Não foi adicionado um serviço de segundo plano: se o Android/iOS suspender ou fechar
o app, a fila já gravada será retomada na próxima abertura. Não é possível receber
novos sinais BLE com o aplicativo encerrado. Desinstalar o app ou limpar seus dados
remove também a fila local. Falhas de gravação, como falta de espaço, são informadas
na tela; nenhuma fila consegue garantir armazenamento sem espaço disponível.

## Banco e validação

Depois da migração de emergências, aplicar
`supabase/migrations/202611010002_sincronizacao_offline.sql` no mesmo projeto.

- `flutter test --no-pub` testa persistência real em arquivo, retomada, isolamento
  por conta, falhas parciais, resposta perdida, concorrência e estado do alarme.
- `supabase/tests/offline.mjs` valida o protocolo no PostgreSQL isolado com PGlite,
  incluindo rollback completo, autorização e pacotes fora de ordem.
- No celular: vincular uma bengala, desligar Wi-Fi e dados móveis mantendo BLE,
  acionar uma emergência e movimentar a bengala. Conferir o contador pendente,
  fechar/reabrir o app e voltar a conexão. Confirmar o histórico e o horário
  original do alerta, sem duplicatas.
