# Universal Trailing Stop System (INSTITUTIONAL+)

Este é um sistema de Trailing Stop definitivo para MQL5, desenhado para traders profissionais e desenvolvedores que buscam a máxima performance e robustez em qualquer ativo (Forex, Índices, Criptos e Sintéticos da Deriv).

## Diferenciais da Versão Institutional+
- **Ajuste Dinâmico de Volatilidade (ATR)**: Multiplicador inteligente que expande e contrai com o mercado.
- **Filtro de Spread**: Evita ativações falsas em momentos de baixa liquidez ou spikes de notícias.
- **Micro-otimizações de Elite**: Cache de tipos, otimização de buffers de indicadores (Fractals) e redução de chamadas API redundantes.
- **Trailing Stop Estrutural**: Opção para permitir o movimento do Stop apenas quando a posição já está em lucro (Break-even estrutural).
- **High-Frequency Throttling**: Processamento controlado em milissegundos para evitar sobrecarga de CPU.
- **True Step Trailing**: Trava o lucro em blocos fixos (milestones) de preço.
- **Proteção Deriv/ECN**: Validação dupla de `StopLevel` e `FreezeLevel` com margem de segurança de 1 point.

## 8 Modos de Operação
1. **ATR**: Volatilidade adaptativa quantitativa.
2. **PSAR**: Tendência clássica por Parabolic SAR.
3. **Média Móvel**: Seguimento de tendência por MA.
4. **High/Low**: Proteção atrás de máximas e mínimas de candles recentes.
5. **Fractals**: Suportes e resistências confirmados por Bill Williams.
6. **Bollinger Bands**: Baseado em desvio padrão e volatilidade.
7. **True Step**: Movimento em degraus estruturais de lucro.
8. **Shadow**: Colagem agressiva na "sombra" (pavios) da vela anterior.

## Como Integrar em 3 Passos

1. Copie `UniversalTrailing.mqh` para sua pasta `Include`.
2. Inclua e declare no seu EA:
   ```cpp
   #include <UniversalTrailing.mqh>
   CUniversalTrailing trailing;
   ```
3. Inicialize e Processe:
   ```cpp
   // No OnInit
   trailing.Init(MagicNumber, _Symbol);
   trailing.SetMode(TRL_MODE_ATR);

   // No OnTick
   trailing.Process();
   ```

---
Desenvolvido por Jules AI. Focado em engenharia de software de alta performance para o mercado financeiro.
