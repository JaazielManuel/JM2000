# Universal Trailing Stop System (MASTER EDITION)

Este é o sistema de Trailing Stop mais avançado disponível para MQL5, projetado com arquitetura de grau institucional para máxima performance, segurança e adaptabilidade.

## Diferenciais da Versão Master
- **Arquitetura Multi-Instância**: O controle de *Throttling* é agora independente por instância da classe, permitindo o uso simultâneo em múltiplos símbolos e estratégias sem interferência.
- **Institutional ATR Scaling (Dual-Handle)**: Compara a volatilidade de curto prazo contra a média estrutural de longo prazo para um ajuste dinâmico de precisão quantitativa.
- **True Step Logic (Clean Math)**: Matemática refinada para travamento de lucros em blocos fixos, garantindo movimentos estruturais e elegantes do Stop Loss.
- **Micro-otimização Master**: Cache agressivo de propriedades de posição e otimização de busca de indicadores para latência mínima.
- **Spread & StopLevel Protection**: Filtro de spread institucional e gestão rigorosa de limites de corretora (ideal para Deriv e ativos de alta volatilidade).

## 8 Modos de Operação de Elite
1. **ATR**: Volatilidade adaptativa institucional.
2. **PSAR**: Tendência clássica por Parabolic SAR.
3. **Média Móvel**: Seguimento de tendência por MA.
4. **High/Low**: Proteção atrás de extremos de candles.
5. **Fractals**: Suportes e resistências estruturais de Bill Williams.
6. **Bollinger Bands**: Baseado em desvio padrão dinâmico.
7. **True Step**: Movimento em degraus de lucro matemático.
8. **Shadow**: Colagem agressiva nos pavios (sombras) da vela anterior.

## Como Integrar

```cpp
#include <UniversalTrailing.mqh>
CUniversalTrailing trailing;

int OnInit() {
   trailing.Init(MagicNumber, _Symbol);
   trailing.SetMode(TRL_MODE_ATR);
   trailing.SetATR(14, 1.5);
   return INIT_SUCCEEDED;
}

void OnTick() {
   trailing.Process();
}
```

---
Desenvolvido por Jules AI. O estado da arte em automação de proteção de capital no MQL5.
