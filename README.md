# Universal Trailing Stop System (PRO)

Este é um sistema de Trailing Stop de "Próximo Nível" para MQL5, desenvolvido para ser extremamente robusto, inteligente e adaptável.

## Diferenciais
- **Adaptativo por Volatilidade**: No modo ATR, o multiplicador se ajusta automaticamente se a volatilidade do mercado disparar.
- **8 Modos de Operação**: ATR, PSAR, Médias Móveis, High/Low, Fractals, Bollinger Bands, Degrau Fixo e Shadow (Sombra da Vela).
- **Proteção Total**: Verifica níveis de Stop (`SYMBOL_TRADE_STOPS_LEVEL`) e Freeze (`SYMBOL_TRADE_FREEZE_LEVEL`) antes de cada tentativa de modificação, evitando erros comuns.
- **Compatibilidade Universal**: Funciona em Forex, Índices, Criptomoedas e ativos Sintéticos (como os da Deriv).
- **Fácil Integração**: Pode ser anexado a qualquer Expert Advisor com apenas 3 linhas de código.

## Como Usar

1. Copie `UniversalTrailing.mqh` para a pasta `MQL5/Include`.
2. No seu EA, inclua a biblioteca:
   ```cpp
   #include <UniversalTrailing.mqh>
   ```
3. Inicialize no `OnInit`:
   ```cpp
   CUniversalTrailing trailing;
   trailing.Init(MagicNumber, _Symbol);
   trailing.SetMode(TRL_MODE_ATR);
   trailing.SetATR(14, 2.0);
   ```
4. Chame o processamento no `OnTick`:
   ```cpp
   trailing.Process();
   ```

## Parâmetros de Trailing
- **ATR**: Trailing baseado na volatilidade real do mercado.
- **PSAR**: Segue o indicador Parabolic SAR para saídas de tendência.
- **High/Low**: Coloca o Stop atrás da mínima/máxima das últimas X velas.
- **Fractals**: Usa fractais de suporte e resistência confirmados.
- **Bollinger**: Trail pela banda inferior (em compras) ou superior (em vendas).
- **Shadow**: Trail agressivo atrás da sombra da vela anterior.

---
Desenvolvido por Jules AI.
