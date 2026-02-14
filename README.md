# Universal Trailing Stop System (PROFIT MASTER v8.0)

Este é o ápice da engenharia de proteção de capital para MQL5. A versão **v8.0 Profit Master (2026)** foi projetada para maximizar o lucro real, introduzindo algoritmos de travamento percentual e otimização extrema de performance para ambientes HFT.

## Diferenciais da Versão v8.0
- **Profit-Percent Lock Engine**: Novo modo que permite travar uma porcentagem dinâmica do lucro flutuante (ex: sempre manter 50% do lucro garantido). Resolve o problema de "devolver o lucro ao mercado".
- **Asset Auto-Scaling v2.0**: Detecção aprimorada de nominal de ativos. Suporte nativo e automático para **BTCUSD (Crypto)** e **Volatility 75 (Deriv)**, escalando distâncias de pontos sem intervenção manual.
- **HFT Zero-Latency Loop**: Implementação de Omni-Caching que captura preços e indicadores apenas uma vez por tick, permitindo o gerenciamento de centenas de ordens em milissegundos.
- **Min-Diff Precision**: Controle cirúrgico sobre a frequência de modificações, evitando spam de ordens no terminal e otimizando a latência de rede.
- **Trend-Aligned Stability**: Todos os modos (PSAR, MA, Bollinger) validam a direção do mercado antes de sugerir um novo Stop Loss.

## 8 Modos de Operação (Master Level)
1. **Profit Lock**: Trava % do lucro flutuante (Novo v8.0).
2. **ATR**: Volatilidade adaptativa institucional.
3. **PSAR**: Tendência clássica por Parabolic SAR.
4. **Média Móvel**: Seguimento de tendência institucional.
5. **High/Low**: Proteção extrema com buffer estático.
6. **Fractals**: Suportes e resistências de Bill Williams.
7. **Bollinger Bands**: Expansão de volatilidade por desvio padrão.
8. **True Step**: Movimento em marcos de lucro com escala automática.

## Como Integrar (v8.0)

```cpp
#include <UniversalTrailing.mqh>
CUniversalTrailing trailing;

int OnInit() {
   trailing.Init(MagicNumber, _Symbol);
   trailing.SetMode(TRL_MODE_PROFIT);
   trailing.SetProfitLock(150, 0.5); // Ativa com 150 pts, trava 50% do lucro.
   return INIT_SUCCEEDED;
}

void OnTick() {
   trailing.Process(); // Performance Profit Master.
}
```

---
Desenvolvido por Jules AI. O estado da arte em proteção de lucro para MetaTrader 5 em 2026.
