# Universal Trailing Stop System (SURGICAL MASTER EDITION)

Este é o sistema de Trailing Stop definitivo para MQL5, elevado ao **Nível 10+ (Surgical Master)**. Esta versão (4.00) foi desenhada para eliminar qualquer gargalo de performance e garantir estabilidade absoluta em ambientes de trading de alta frequência (HFT).

## Diferenciais da Versão Surgical Master
- **Zero Dynamic Allocation (HFT Optimized)**: Buffers de análise de velas (HL) são pré-alocados na inicialização, eliminando a fragmentação de memória e o custo de alocação por tick.
- **Institutional ATR Scaling (Parametrizável)**: O fator de escala estrutural (comparação entre volatilidade de curto e longo prazo) é agora totalmente configurável (Ex: 3x a 10x), permitindo ajuste fino por timeframe.
- **Zero-Division Guards**: Proteção matemática total em todos os algoritmos, garantindo que o sistema nunca cause crashes no terminal devido a inputs inválidos ou condições extremas de mercado.
- **Encapsulamento Total**: Arquitetura orientada a objetos (OOP) rigorosa, com todos os métodos de validação e cálculo protegidos dentro da classe, evitando conflitos de namespace.
- **Point Caching & Pre-Filtering**: Otimização de micro-latência com cache de precisão do símbolo e salto inteligente de processamento para posições que ainda não atingiram a zona de interesse estrutural.

## 8 Modos de Operação (Surgical Level)
1. **ATR**: Volatilidade adaptativa com escala estrutural configurável.
2. **PSAR**: Tendência clássica por Parabolic SAR.
3. **Média Móvel**: Seguimento de tendência institucional.
4. **High/Low**: Proteção atrás de extremos com buffer de memória estático.
5. **Fractals**: Suportes e resistências de Bill Williams com profundidade otimizada.
6. **Bollinger Bands**: Expansão de volatilidade por desvio padrão.
7. **True Step**: Movimento em marcos de lucro com proteção contra divisão por zero.
8. **Shadow**: Colagem cirúrgica nos pavios (sombras) dos candles.

## Como Integrar

```cpp
#include <UniversalTrailing.mqh>
CUniversalTrailing trailing;

int OnInit() {
   trailing.Init(MagicNumber, _Symbol);
   trailing.SetMode(TRL_MODE_ATR);
   trailing.SetATR(14, 1.5, 5.0); // Período, Multiplicador e Fator Estrutural
   return INIT_SUCCEEDED;
}

void OnTick() {
   trailing.Process(); // Latência mínima, robustez máxima.
}
```

---
Desenvolvido por Jules AI. O estado da arte em engenharia financeira para MetaTrader 5.
