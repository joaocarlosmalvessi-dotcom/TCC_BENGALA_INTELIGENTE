import 'package:flutter/cupertino.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

class TelaRelatorios extends StatefulWidget {
  const TelaRelatorios({super.key});

  @override
  State<TelaRelatorios> createState() => _TelaRelatoriosState();
}

class _TelaRelatoriosState extends State<TelaRelatorios> {
  final _supabase = Supabase.instance.client;
  bool _carregando = false;

  String _nomeEmissor = '';
  String _emailEmissor = '';
  List<Map<String, dynamic>> _dadosBengalas = [];

  @override
  void initState() {
    super.initState();
    _buscarDadosParaRelatorio();
  }

  Future<void> _buscarDadosParaRelatorio() async {
    if (_carregando) return;
    setState(() => _carregando = true);
    _dadosBengalas = [];
    final user = _supabase.auth.currentUser;

    if (user != null) {
      _emailEmissor = user.email ?? 'Email não registado';
      _nomeEmissor = user.userMetadata?['nome'] ?? 'Utilizador sem nome';

      try {
        final membro = await _supabase
            .from('membros_grupo')
            .select('grupo_id')
            .eq('user_id', user.id)
            .maybeSingle();

        if (membro != null) {
          final grupoId = membro['grupo_id'];
          final dispositivosData = await _supabase
              .from('dispositivos')
              .select()
              .eq('grupo_id', grupoId);

          _dadosBengalas = dispositivosData.map<Map<String, dynamic>>((disp) {
            // Se não houver km_mensal na BD, estimamos com base no semanal para o relatório
            final double kmSemanal = disp['km_semanal']?.toDouble() ?? 0.0;
            final double kmMensal =
                disp['km_mensal']?.toDouble() ?? (kmSemanal * 4);

            return {
              'nome': disp['nome'] ?? 'Bengala Desconhecida',
              'kmDiario': disp['km_diario']?.toDouble() ?? 0.0,
              'kmSemanal': kmSemanal,
              'kmMensal': kmMensal,
              'emergencias': disp['emergencias'] ?? 0,
            };
          }).toList();
        }
      } catch (e) {
        debugPrint('Erro ao buscar dados do relatório: $e');
      }
    }
    if (mounted) setState(() => _carregando = false);
  }

  Future<void> _gerarEImprimirPDF() async {
    final pdf = pw.Document();

    // Data atual formatada (Ex: 26/09/2026 14:17)
    final agora = DateTime.now();
    final dataEmissao =
        '${agora.day.toString().padLeft(2, '0')}/${agora.month.toString().padLeft(2, '0')}/${agora.year} ${agora.hour.toString().padLeft(2, '0')}:${agora.minute.toString().padLeft(2, '0')}';

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (pw.Context context) {
          return [
            // CABEÇALHO DO RELATÓRIO
            pw.Header(
              level: 0,
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    'Relatório de Monitorização - Bengala Assistiva',
                    style: pw.TextStyle(
                      fontSize: 18,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.PdfLogo(), // Um logo genérico do PDF
                ],
              ),
            ),
            pw.SizedBox(height: 10),

            // DADOS DO EMISSOR
            pw.Container(
              padding: const pw.EdgeInsets.all(10),
              decoration: pw.BoxDecoration(
                color: PdfColors.grey200,
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    'Emitido por: $_nomeEmissor',
                    style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                  ),
                  pw.Text('E-mail: $_emailEmissor'),
                  pw.Text('Data de emissão: $dataEmissao'),
                ],
              ),
            ),
            pw.SizedBox(height: 30),

            // DADOS DOS DISPOSITIVOS
            pw.Text(
              'Estatísticas dos Dispositivos',
              style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 10),

            if (_dadosBengalas.isEmpty)
              pw.Text(
                'Nenhum dispositivo encontrado neste grupo.',
                style: const pw.TextStyle(color: PdfColors.grey700),
              )
            else
              pw.TableHelper.fromTextArray(
                context: context,
                border: pw.TableBorder.all(
                  color: PdfColors.grey400,
                  width: 0.5,
                ),
                headerAlignment: pw.Alignment.centerLeft,
                headerStyle: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.white,
                ),
                headerDecoration: const pw.BoxDecoration(
                  color: PdfColors.blueGrey800,
                ),
                cellAlignment: pw.Alignment.centerLeft,
                cellStyle: const pw.TextStyle(fontSize: 10),
                headers: [
                  'Dispositivo',
                  'KM Diário',
                  'KM Semanal',
                  'KM Mensal',
                  'Alertas de Emergência',
                ],
                data: _dadosBengalas.map((disp) {
                  return [
                    disp['nome'],
                    '${disp['kmDiario'].toStringAsFixed(1)} km',
                    '${disp['kmSemanal'].toStringAsFixed(1)} km',
                    '${disp['kmMensal'].toStringAsFixed(1)} km',
                    disp['emergencias'].toString(),
                  ];
                }).toList(),
              ),

            pw.SizedBox(height: 40),
            pw.Divider(),
            pw.Center(
              child: pw.Text(
                'Documento gerado automaticamente pelo App TCC.',
                style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey),
              ),
            ),
          ];
        },
      ),
    );

    // Abre a interface nativa para visualizar, imprimir ou partilhar o PDF
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdf.save(),
      name: 'Relatorio_Monitorizacao.pdf',
    );
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Relatórios'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _buscarDadosParaRelatorio,
          child: const Icon(CupertinoIcons.refresh),
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: _carregando
              ? const Center(child: CupertinoActivityIndicator())
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(
                      CupertinoIcons.doc_chart,
                      size: 80,
                      color: CupertinoColors.activeBlue,
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'Relatório de Atividade',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Gere um documento PDF contendo as distâncias percorridas (diárias, semanais e mensais) e o histórico de alertas de emergência das bengalas conectadas ao seu grupo.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: CupertinoColors.systemGrey),
                    ),
                    const SizedBox(height: 40),
                    CupertinoButton.filled(
                      onPressed: _gerarEImprimirPDF,
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(CupertinoIcons.printer),
                          SizedBox(width: 10),
                          Text('Gerar Relatório PDF'),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
