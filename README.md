# Universal Trailing Stop System (ELITE PRO)

Este é um sistema de Trailing Stop institucional para MQL5, desenvolvido para ser extremamente robusto, inteligente e adaptável a qualquer corretora (incluindo ECN e Deriv).

## Diferenciais da Versão Elite
- **Ajuste Dinâmico de Volatilidade (ATR)**: O multiplicador se adapta automaticamente em expansões de mercado, evitando stops prematuros.
- **Filtro de Spread**: Proteção contra spikes artificiais de spread que poderiam ativar o trailing inadequadamente.
- **Performance de Alta Frequência**: Sistema de *Throttling* integrado que reduz o consumo de CPU e chamadas redundantes a buffers de indicadores.
- **True Step Trailing**: Diferente do trailing comum, o modo Step agora move o Stop Loss em blocos fixos de lucro garantido.
- **Integridade Direcional**: Garantia matemática de que o Stop Loss nunca retrocederá e sempre respeitará a distância mínima de segurança.

## 8 Modos de Operação
1. **ATR**: Baseado na volatilidade quantitativa.
2. **PSAR**: Segue o indicador Parabolic SAR.
3. **Média Móvel**: Trailing por tendência.
4. **High/Low**: Baseado nas máximas/mínimas de velas anteriores.
5. **Fractals**: Suportes e resistências confirmados.
6. **Bollinger Bands**: Volatilidade por desvio padrão.
7. **True Step**: Movimento em degraus de lucro.
8. **Shadow**: Colagem agressiva na sombra da vela anterior.

## Como Usar

1. Copie `UniversalTrailing.mqh` para a pasta `Include`.
2. No seu EA:
   ```cpp
   #include <UniversalTrailing.mqh>
   CUniversalTrailing trailing;

   int OnInit() {
      trailing.Init(MagicNumber, _Symbol);
      trailing.SetMode(TRL_MODE_ATR);
      trailing.SetMaxSpread(50); // Proteção contra spread alto
      return INIT_SUCCEEDED;
   }

   void OnTick() {
      trailing.Process();
   }
   ```

---
Desenvolvido por Jules AI. Focado em robustez institucional e alta performance.
