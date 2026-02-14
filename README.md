# Universal Trailing Stop System (OMNI-ADAPTIVE MASTER v7.0)

Esta é a versão definitiva e mais otimizada da engenharia de proteção de capital para MQL5. A versão **v7.0 Omni-Adaptive (2026)** foi projetada para resolver problemas de performance em ambientes multi-ativos e garantir a adaptação automática a qualquer classe de ativo (Forex, Crypto, Índices e Sintéticos).

## Diferenciais da Versão v7.0
- **Omni-Caching Engine**: Preços (Máximas e Mínimas) e indicadores são cacheados uma única vez por tick cluster, eliminando redundantemente chamadas pesadas ao terminal (HFT Ready).
- **Asset Auto-Scaling**: Detecta automaticamente o valor nominal do ativo e escala todos os parâmetros de pontos (Step, Distâncias, BE). Resolvido o problema de "não se adaptar" a ativos como BTCUSD ou Volatility 75 (Deriv).
- **Cluster Mode (Unified SL)**: Permite que todas as ordens de uma pirâmide ou grid sejam movidas para o mesmo Stop Loss "mestre", otimizando o gerenciamento de risco do grupo.
- **HFT Optimized Scanning**: O loop de posições agora usa seleção por ticket e filtragem imediata, sendo capaz de processar centenas de posições com latência desprezível.
- **Trend-Aligned Validation**: PSAR, MA e Bollinger agora possuem lógica de alinhamento de tendência, impedindo movimentos do SL quando o indicador sugere que o preço está na zona contrária.

## 8 Modos de Operação (Omni-Adaptive)
1. **ATR**: Volatilidade adaptativa quantitativa (Dual-Handle).
2. **PSAR**: Tendência clássica por Parabolic SAR (Validado).
3. **Média Móvel**: Seguimento de tendência institucional (Validado).
4. **High/Low**: Proteção estrutural por extremos (Cached).
5. **Fractals**: Suportes e resistências de Bill Williams (Lazy Init).
6. **Bollinger Bands**: Gestão de risco por desvio padrão.
7. **True Step**: Movimento em marcos de lucro com escala automática.
8. **Shadow**: Colagem cirúrgica nos pavios (sombras) dos candles (v7.0).

## Como Integrar (v7.0)

```cpp
#include <UniversalTrailing.mqh>
CUniversalTrailing trailing;

int OnInit() {
   trailing.Init(MagicNumber, _Symbol);
   trailing.SetAdaptiveScaling(true); // Auto-adaptação para Deriv/Crypto
   trailing.SetMode(TRL_MODE_ATR);
   return INIT_SUCCEEDED;
}

void OnTick() {
   trailing.Process(); // Engine de alta performance com Omni-Caching.
}
```

---
Desenvolvido por Jules AI. Engenharia cirúrgica para traders profissionais em 2026.
