//+------------------------------------------------------------------+
//|                 JM2000 EA V1                                     |
//|                                  Copyright © 2026, NeuralTrader  |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "1.0"
#property description "JM2000 EA V1 - Trailing Stop Otimizado"

#define EA_NAME "JM2000 EA V1"

//--- Enumeração para modos de trailing (DEVE estar ANTES dos inputs)
enum ENUM_TRAILING_MODE
{
   TRAILING_INDIVIDUAL,    // Individual (cada posição independente)
   TRAILING_BY_DIRECTION,  // Por direção (todas BUY juntas, todas SELL juntas)
   TRAILING_GLOBAL         // Global (todas as posições movem juntas)
};

input group "=== CONFIGURAÇÕES DE EXECUÇÃO ==="
input int    StopLossPoints      = 50;    // Stop Loss inicial (pontos)
input double Lots                = 0.01;  // Volume do lote (se lote dinâmico desligado)
input int    MagicNumber         = 12345; // Identificador único da EA (Magic Number)
input int    OffsetPoints        = 10;    // Distância para abrir ordens pendentes (pontos)
input int    UpdatePoints        = 5;     // Sensibilidade para mover as ordens (pontos)

input group "=== ESTRATÉGIA DE TRAILING STOP ==="
input ENUM_TRAILING_MODE TrailingMode = TRAILING_INDIVIDUAL; // Modo de funcionamento do Trailing
input int    TrailingStopPoints  = 20;    // Distância do Trailing Stop (pontos)
input int    TrailingStepPoints  = 10;    // Passo mínimo para mover o Stop Loss (pontos)
input int    BreakEvenPoints     = 30;    // Pontos de lucro para ativar BreakEven (0=desativado)
input int    BreakEvenPlusPoints = 5;     // Pontos de segurança acima da entrada no BreakEven
input bool   UsePartialClose     = false; // Fechar parte da posição ao atingir o BreakEven?
input double PartialClosePercent = 50.0;  // Porcentagem para fechar no BreakEven (ex: 50.0)

input group "=== CONFIGURAÇÕES DA GRADE (GRID) ==="
input int    InitialOrdersCount  = 3;     // Quantidade de ordens pendentes em cada lado
input double SpacingPoints       = 5;     // Espaço entre cada ordem da grade (pontos)

input group "=== GERENCIAMENTO DE RISCO ==="
input bool   UseDynamicLot          = false; // Usar cálculo de lote automático baseado no risco?
input double RiskPercent            = 2.0;   // Porcentagem de risco por operação
input double MaxLotSize             = 10.0;  // Tamanho máximo permitido para o lote
input double MarginSafetyPercent    = 20.0;  // Porcentagem de margem livre para manter de reserva

input group "=== LIMITES DE OPERAÇÃO ==="
input int    MaxPositions           = 0;     // Máximo de posições totais abertas (0 = ilimitado)
input int    MaxBuyPositions        = 0;     // Máximo de posições de COMPRA (0 = ilimitado)
input int    MaxSellPositions       = 0;     // Máximo de posições de VENDA (0 = ilimitado)
input bool   AllowHedging           = true;  // Permitir COMPRA e VENDA ao mesmo tempo?

input group "=== FILTROS E SEGURANÇA ==="
input double MaxDrawdownPercent     = 5.0;   // Limite de perda (Drawdown %) para pausar EA
input bool   SafeModeOnErrors       = true;  // Ativar Modo de Segurança se houver muitos erros?
input int    MaxConsecutiveErrors   = 3;     // Quantidade de erros para entrar em Modo de Segurança
input bool   UseSpreadFilter          = true;  // Bloquear operações com Spread muito alto?
input double MaxSpreadMultiplier      = 2.0;   // Multiplicador máximo do Spread médio
input bool   UseTimeFilter            = false; // Usar filtro de horário de negociação?
input int    AvoidLastMinutesFriday   = 30;    // Minutos antes de fechar a sexta para parar
input int    AvoidFirstMinutesSunday  = 10;    // Minutos após abrir o domingo para começar

input group "=== INTERFACE E PERFORMANCE ==="
input bool   ShowChartInfo      = true;   // Mostrar painel de informações no gráfico?
input bool   UseAdaptiveUpdate  = true;   // Ajustar sensibilidade automaticamente?
input int    RecreateDelaySeconds = 1;    // Tempo de espera para recriar ordens (segundos)
input int    ModificationCooldownMS = 500; // Intervalo mínimo entre modificações (ms)

input group "=== CUSTOMIZAÇÃO VISUAL ==="
input bool   ApplyChartColors   = true;       // Aplicar as cores abaixo ao gráfico?
input color  CandleBullColor    = clrGold;    // Cor das velas de Alta (COMPRA)
input color  CandleBearColor    = clrCrimson; // Cor das velas de Baixa (VENDA)
input color  ChartBackground    = clrBlack;   // Cor do fundo do gráfico
input color  ChartGrid          = clrDimGray; // Cor da grade do gráfico
input color  ChartText          = clrWhite;   // Cor das letras e textos

//--- Estrutura para gerenciar posições individuais
struct PositionTracker
{
   ulong    ticket;
   double   entryPrice;
   double   currentSL;
   double   volume;
   double   initialVolume;
   bool     isBuy;
   bool     breakEvenSet;
   bool     partialClosed;
   double   highestProfit;
   double   highestPrice;  // BUY: maior Bid alcançado / SELL: menor Ask alcançado
   datetime openTime;
};

//--- Variáveis globais
ulong buyStopTickets[];
ulong sellStopTickets[];
PositionTracker positions[];
datetime lastBuyOrderCreation  = 0;
datetime lastSellOrderCreation = 0;
datetime lastOrderUpdateTime   = 0;
ulong    lastBuyModifyTick     = 0;
ulong    lastSellModifyTick    = 0;

//--- Variáveis de controle do broker
int stopsLevel           = 0;
int freezeLevel          = 0;
int adjustedOffsetPoints = 0;
int adjustedStopLossPoints = 0;

//--- Cache Global (Symbol Info)
double cachedPoint      = 0;
int    cachedDigits     = 0;
double cachedTickValue  = 0;
double cachedTickSize   = 0;
double minVolume        = 0;
double maxVolume        = 0;
double stepVolume       = 0;

//--- Cache Dinâmico (Tick Data)
double cachedBid        = 0;
double cachedAsk        = 0;
double cachedSpread     = 0;

//--- Estado
int      consecutiveErrors     = 0;
bool     safeModeActive        = false;
double   averageSpread         = 0;
double   spreadSum             = 0;
double   maxEquityReached      = 0;
double   cachedATR             = 0;
datetime lastATRUpdate         = 0;
int      handleATR             = INVALID_HANDLE;
int      countBuy              = 0;
int      countSell             = 0;
int      countTotal            = 0;

//--- Spread history
double   spreadHistory[100];
int      spreadIndex = 0;
bool     spreadHistoryReady = false;

//--- Protótipos de funções
void     UpdatePositionTracker();
void     SyncPendingOrders();
void     UpdatePriceCache();
void     UpdateATRCache();
void     CalculateAverageSpread();
void     MonitorDrawdownAndSafeMode();
bool     IsMarketConditionSafe();
void     ApplyOptimizedTrailing();
void     ManageContinuousPendingOrders();
void     DisplayStatusInfo();
double   CalculateDynamicLot();
bool     HasSufficientMargin(double volume);
double   NormalizeVolume(double volume);
void     HandleTradeError(uint retcode);
void     CountOpenPositions(int &buyCount, int &sellCount, int &totalCount);
bool     CanOpenMorePositions(bool isBuy);
int      GetAdaptiveUpdatePoints();
void     ManageBuyStops(double lotSize, int updateThreshold, datetime currentTime);
void     ManageSellStops(double lotSize, int updateThreshold, datetime currentTime);
bool     CreateBuyStops(double lotSize, int count);
bool     CreateSellStops(double lotSize, int count);
double   GetValidPendingPrice(bool isBuy, int additionalOffset = 0);
double   CalculateValidSL(double orderPrice, bool isBuy);
bool     CanModifyOrder(ulong ticket);
bool     CancelOrder(ulong ticket);
ENUM_ORDER_TYPE_FILLING GetMarketFilling();
bool     ClosePartialPosition(ulong ticket, double volume);
bool     ModifyPositionSL(ulong ticket, double newSL);
bool     ModifyPendingOrder(ulong ticket, double newPrice, double newSL);
void     ApplyIndividualTrailing();
void     ApplyDirectionalTrailing();
void     ApplyGlobalTrailing();

//+------------------------------------------------------------------+
//| Remove elemento do array                                         |
//+------------------------------------------------------------------+
template<typename T>
void RemoveArrayElement(T &arr[], int index)
{
   int size = ArraySize(arr);
   if(index < 0 || index >= size) return;
   if(index < size - 1)
      ArrayCopy(arr, arr, index, index + 1);
   ArrayResize(arr, size - 1);
}

//+------------------------------------------------------------------+
//| Configura cores do gráfico                                       |
//+------------------------------------------------------------------+
void ApplyCustomChartColors()
{
   if(!ApplyChartColors) return;
   long chartID = ChartID();
   ChartSetInteger(chartID, CHART_COLOR_CANDLE_BULL,  CandleBullColor);
   ChartSetInteger(chartID, CHART_COLOR_CANDLE_BEAR,  CandleBearColor);
   ChartSetInteger(chartID, CHART_COLOR_BACKGROUND,   ChartBackground);
   ChartSetInteger(chartID, CHART_COLOR_GRID,         ChartGrid);
   ChartSetInteger(chartID, CHART_COLOR_FOREGROUND,   ChartText);
   ChartSetInteger(chartID, CHART_COLOR_CHART_LINE,   ChartText);
   ChartSetInteger(chartID, CHART_COLOR_CHART_UP,     CandleBullColor);
   ChartSetInteger(chartID, CHART_COLOR_CHART_DOWN,   CandleBearColor);
   ChartSetInteger(chartID, CHART_COLOR_VOLUME,       clrDodgerBlue);
   ChartSetInteger(chartID, CHART_COLOR_BID,          CandleBullColor);
   ChartSetInteger(chartID, CHART_COLOR_ASK,          CandleBearColor);
   ChartSetInteger(chartID, CHART_COLOR_LAST,         clrYellow);
   ChartSetInteger(chartID, CHART_MODE,               CHART_CANDLES);
   ChartRedraw(chartID);
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   // Sincronização inicial
   UpdatePositionTracker();
   SyncPendingOrders();

   if(InitialOrdersCount < 1 || InitialOrdersCount > 20)
   {
      Print("ERRO: InitialOrdersCount deve estar entre 1 e 20");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(StopLossPoints < 5)
   {
      Print("ERRO: StopLossPoints muito baixo (mínimo 5)");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(TrailingStopPoints < 5)
   {
      Print("ERRO: TrailingStopPoints muito baixo (mínimo 5)");
      return INIT_PARAMETERS_INCORRECT;
   }

   // Cache de informações fixas do símbolo
   stopsLevel  = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   freezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);

   cachedPoint     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   cachedDigits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   cachedTickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   cachedTickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   minVolume       = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   maxVolume       = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   stepVolume      = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   adjustedOffsetPoints    = MathMax(OffsetPoints,    stopsLevel + 2);
   adjustedStopLossPoints  = MathMax(StopLossPoints,  stopsLevel + 2);

   ArrayResize(buyStopTickets,  0);
   ArrayResize(sellStopTickets, 0);
   ArrayResize(positions, 0);
   ArrayInitialize(spreadHistory, 0);

   maxEquityReached = AccountInfoDouble(ACCOUNT_EQUITY);

   // Inicializa indicador ATR de forma eficiente
   handleATR = iATR(_Symbol, PERIOD_M1, 14);
   if(handleATR == INVALID_HANDLE)
   {
      Print("ERRO: Falha ao criar handle do ATR");
      return INIT_FAILED;
   }

   UpdatePriceCache();
   CalculateAverageSpread();
   ApplyCustomChartColors();

   string trailingModeStr = "";
   switch(TrailingMode)
   {
      case TRAILING_INDIVIDUAL:   trailingModeStr = "INDIVIDUAL"; break;
      case TRAILING_BY_DIRECTION: trailingModeStr = "POR DIREÇÃO"; break;
      case TRAILING_GLOBAL:       trailingModeStr = "GLOBAL"; break;
   }

   Print("═══════════════════════════════════════════════");
   Print(EA_NAME, " - TRAILING OTIMIZADO");
   Print("═══════════════════════════════════════════════");
   Print("Trailing Mode: ",      trailingModeStr);
   Print("Trailing Stop: ",      TrailingStopPoints, " pts");
   Print("Trailing Step: ",      TrailingStepPoints, " pts");
   Print("BreakEven: ",          BreakEvenPoints, " pts");
   Print("Ordens por Lado: ",    InitialOrdersCount);
   Print("Espaçamento: ",        SpacingPoints, " pts");
   Print("Max Posições: ",       MaxPositions == 0 ? "ILIMITADO" : IntegerToString(MaxPositions));
   Print("Hedging: ",            AllowHedging ? "SIM" : "NÃO");
   Print("═══════════════════════════════════════════════");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   UpdatePriceCache();
   UpdateATRCache();
   MonitorDrawdownAndSafeMode();

   if(!IsMarketConditionSafe()) return;

   // ✅ Sistema de trailing otimizado
   ApplyOptimizedTrailing();

   // ✅ Sistema de captura contínua
   ManageContinuousPendingOrders();

   DisplayStatusInfo();
}

//+------------------------------------------------------------------+
//| Trade Transaction                                                |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   if(trans.type == TRADE_TRANSACTION_ORDER_ADD ||
      trans.type == TRADE_TRANSACTION_ORDER_DELETE ||
      trans.type == TRADE_TRANSACTION_DEAL_ADD ||
      trans.type == TRADE_TRANSACTION_HISTORY_ADD)
   {
      UpdatePositionTracker();
      SyncPendingOrders();
   }
}

//+------------------------------------------------------------------+
//| ✅ Sincroniza ordens pendentes                                   |
//+------------------------------------------------------------------+
void SyncPendingOrders()
{
   for(int i = ArraySize(buyStopTickets) - 1; i >= 0; i--)
      if(!OrderSelect(buyStopTickets[i]))
         RemoveArrayElement(buyStopTickets, i);

   for(int i = ArraySize(sellStopTickets) - 1; i >= 0; i--)
      if(!OrderSelect(sellStopTickets[i]))
         RemoveArrayElement(sellStopTickets, i);
}

//+------------------------------------------------------------------+
//| Seleciona uma ordem pendente ativa pelo ticket                   |
//+------------------------------------------------------------------+
bool OrderSelect(ulong ticket)
{
   if(ticket <= 0) return false;
   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong t = OrderGetTicket(i);
      if(t == ticket) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| ✅ Atualiza tracker de posições                                  |
//+------------------------------------------------------------------+
void UpdatePositionTracker()
{
   // Remove posições que foram fechadas
   for(int i = ArraySize(positions) - 1; i >= 0; i--)
   {
      if(!PositionSelectByTicket(positions[i].ticket))
      {
         if(ShowChartInfo)
            Print("📍 Posição #", positions[i].ticket, " fechada");
         RemoveArrayElement(positions, i);
      }
   }

   // Adiciona novas posições
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      // Verifica se já está no tracker
      bool found = false;
      for(int j = 0, sz_track = ArraySize(positions); j < sz_track; j++)
      {
         if(positions[j].ticket == ticket)
         {
            // Atualiza dados que podem ter mudado
            positions[j].currentSL = PositionGetDouble(POSITION_SL);
            positions[j].volume    = PositionGetDouble(POSITION_VOLUME);
            found = true;
            break;
         }
      }

      // Adiciona se for nova
      if(!found)
      {
         int sz = ArraySize(positions);
         if(ArrayResize(positions, sz + 1) > 0)
         {
            positions[sz].ticket         = ticket;
            positions[sz].entryPrice     = PositionGetDouble(POSITION_PRICE_OPEN);
            positions[sz].currentSL      = PositionGetDouble(POSITION_SL);
            positions[sz].volume         = PositionGetDouble(POSITION_VOLUME);
            positions[sz].initialVolume  = PositionGetDouble(POSITION_VOLUME);
            positions[sz].isBuy          = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
            positions[sz].breakEvenSet   = false;
            positions[sz].partialClosed  = false;
            positions[sz].highestProfit  = 0;
            positions[sz].highestPrice   = positions[sz].isBuy ? cachedBid : cachedAsk;
            positions[sz].openTime       = (datetime)PositionGetInteger(POSITION_TIME);

            if(ShowChartInfo)
               Print("📍 Nova posição #", ticket, " | ",
                     positions[sz].isBuy ? "BUY" : "SELL",
                     " | ", positions[sz].volume, " lots");
         }
      }
   }

   // Atualiza contadores globais
   countBuy = 0; countSell = 0;
   countTotal = ArraySize(positions);
   for(int i=0; i<countTotal; i++)
   {
      if(positions[i].isBuy) countBuy++; else countSell++;
   }
}

//+------------------------------------------------------------------+
//| ✅ Sistema de trailing otimizado                                 |
//+------------------------------------------------------------------+
void ApplyOptimizedTrailing()
{
   switch(TrailingMode)
   {
      case TRAILING_INDIVIDUAL:
         ApplyIndividualTrailing();
         break;

      case TRAILING_BY_DIRECTION:
         ApplyDirectionalTrailing();
         break;

      case TRAILING_GLOBAL:
         ApplyGlobalTrailing();
         break;
   }
}

//+------------------------------------------------------------------+
//| ✅ Trailing Individual - cada posição independente               |
//+------------------------------------------------------------------+
void ApplyIndividualTrailing()
{
   for(int i = 0; i < ArraySize(positions); i++)
   {
      if(!PositionSelectByTicket(positions[i].ticket)) continue;

      double currentPrice = positions[i].isBuy ? cachedBid : cachedAsk;
      double currentProfit = PositionGetDouble(POSITION_PROFIT);

      // Atualiza maior preço alcançado
      if(positions[i].isBuy)
      {
         if(currentPrice > positions[i].highestPrice)
            positions[i].highestPrice = currentPrice;
      }
      else
      {
         if(currentPrice < positions[i].highestPrice)
            positions[i].highestPrice = currentPrice;
      }

      // Atualiza maior lucro
      if(currentProfit > positions[i].highestProfit)
         positions[i].highestProfit = currentProfit;

      // 1️⃣ BreakEven
      if(BreakEvenPoints > 0 && !positions[i].breakEvenSet)
      {
         double profitPoints = positions[i].isBuy
            ? (currentPrice - positions[i].entryPrice) / cachedPoint
            : (positions[i].entryPrice - currentPrice) / cachedPoint;

         if(profitPoints >= BreakEvenPoints)
         {
            double newSL = positions[i].entryPrice +
                          (positions[i].isBuy ? 1 : -1) * BreakEvenPlusPoints * cachedPoint;
            newSL = NormalizeDouble(newSL, cachedDigits);

            if(ModifyPositionSL(positions[i].ticket, newSL))
            {
               positions[i].breakEvenSet = true;
               positions[i].currentSL = newSL;

               if(ShowChartInfo)
                  Print("⚖️ BreakEven #", positions[i].ticket,
                        " @ ", DoubleToString(newSL, cachedDigits));

               // Fechamento parcial
               if(UsePartialClose && !positions[i].partialClosed && PartialClosePercent > 0)
               {
                  double closeVolume = NormalizeVolume(positions[i].volume * PartialClosePercent / 100.0);
                  if(closeVolume >= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
                  {
                     if(ClosePartialPosition(positions[i].ticket, closeVolume))
                     {
                        positions[i].partialClosed = true;
                        positions[i].volume -= closeVolume;

                        if(ShowChartInfo)
                           Print("📉 Fechamento parcial #", positions[i].ticket,
                                 " | ", closeVolume, " lots");
                     }
                  }
               }
            }
         }
      }

      // 2️⃣ Trailing Stop
      double trailDist = TrailingStopPoints * cachedPoint;
      double stepDist  = TrailingStepPoints * cachedPoint;
      double newSL     = 0;

      if(positions[i].isBuy)
      {
         newSL = NormalizeDouble(currentPrice - trailDist, cachedDigits);

         // Só move se estiver em lucro e respeitar o step
         if(newSL > positions[i].entryPrice &&
            (positions[i].currentSL == 0 || newSL > positions[i].currentSL + stepDist))
         {
            if(ModifyPositionSL(positions[i].ticket, newSL))
            {
               positions[i].currentSL = newSL;

               if(ShowChartInfo)
                  Print("📈 Trailing BUY #", positions[i].ticket,
                        " | SL: ", DoubleToString(newSL, cachedDigits));
            }
         }
      }
      else // SELL
      {
         newSL = NormalizeDouble(currentPrice + trailDist, cachedDigits);

         if(newSL < positions[i].entryPrice &&
            (positions[i].currentSL == 0 || newSL < positions[i].currentSL - stepDist))
         {
            if(ModifyPositionSL(positions[i].ticket, newSL))
            {
               positions[i].currentSL = newSL;

               if(ShowChartInfo)
                  Print("📉 Trailing SELL #", positions[i].ticket,
                        " | SL: ", DoubleToString(newSL, cachedDigits));
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| ✅ Trailing Por Direção - BUYs juntos, SELLs juntos              |
//+------------------------------------------------------------------+
void ApplyDirectionalTrailing()
{
   int sz = ArraySize(positions);
   if(sz == 0) return;

   double buyMaxPrice  = 0;
   double sellMinPrice = DBL_MAX;

   for(int i = 0; i < sz; i++)
   {
      if(positions[i].isBuy)
      {
         if(cachedBid > buyMaxPrice) buyMaxPrice = cachedBid;
      }
      else
      {
         if(cachedAsk < sellMinPrice) sellMinPrice = cachedAsk;
      }
   }

   const double trailDist = TrailingStopPoints * cachedPoint;
   const double stepDist  = TrailingStepPoints * cachedPoint;
   const double newBuySL  = (buyMaxPrice > 0) ? NormalizeDouble(buyMaxPrice - trailDist, cachedDigits) : 0;
   const double newSellSL = (sellMinPrice < DBL_MAX) ? NormalizeDouble(sellMinPrice + trailDist, cachedDigits) : 0;

   for(int i = 0; i < sz; i++)
   {
      if(positions[i].isBuy)
      {
         if(newBuySL > positions[i].entryPrice && (positions[i].currentSL == 0 || newBuySL > positions[i].currentSL + stepDist))
         {
            if(ModifyPositionSL(positions[i].ticket, newBuySL)) positions[i].currentSL = newBuySL;
         }
      }
      else
      {
         if(newSellSL < positions[i].entryPrice && (positions[i].currentSL == 0 || newSellSL < positions[i].currentSL - stepDist))
         {
            if(ModifyPositionSL(positions[i].ticket, newSellSL)) positions[i].currentSL = newSellSL;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| ✅ Trailing Global - todas posições movem juntas                 |
//+------------------------------------------------------------------+
void ApplyGlobalTrailing()
{
   int sz = ArraySize(positions);
   if(sz == 0) return;

   double totalBuyVolume  = 0, totalSellVolume = 0;
   double buyWeightedPrice = 0, sellWeightedPrice = 0;

   for(int i = 0; i < sz; i++)
   {
      if(positions[i].isBuy)
      {
         buyWeightedPrice += positions[i].entryPrice * positions[i].volume;
         totalBuyVolume   += positions[i].volume;
      }
      else
      {
         sellWeightedPrice += positions[i].entryPrice * positions[i].volume;
         totalSellVolume   += positions[i].volume;
      }
   }

   const double trailDist = TrailingStopPoints * cachedPoint;
   const double stepDist  = TrailingStepPoints * cachedPoint;
   const double avgBuyEntry = (totalBuyVolume > 0) ? buyWeightedPrice / totalBuyVolume : 0;
   const double avgSellEntry = (totalSellVolume > 0) ? sellWeightedPrice / totalSellVolume : 0;
   const double newBuySL = NormalizeDouble(cachedBid - trailDist, cachedDigits);
   const double newSellSL = NormalizeDouble(cachedAsk + trailDist, cachedDigits);

   for(int i = 0; i < sz; i++)
   {
      if(positions[i].isBuy)
      {
         if(totalBuyVolume > 0 && newBuySL > avgBuyEntry && (positions[i].currentSL == 0 || newBuySL > positions[i].currentSL + stepDist))
         {
            if(ModifyPositionSL(positions[i].ticket, newBuySL)) positions[i].currentSL = newBuySL;
         }
      }
      else
      {
         if(totalSellVolume > 0 && newSellSL < avgSellEntry && (positions[i].currentSL == 0 || newSellSL < positions[i].currentSL - stepDist))
         {
            if(ModifyPositionSL(positions[i].ticket, newSellSL)) positions[i].currentSL = newSellSL;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Fecha parcialmente uma posição                                   |
//+------------------------------------------------------------------+
bool ClosePartialPosition(ulong ticket, double volume)
{
   if(!PositionSelectByTicket(ticket)) return false;

   string symbol = PositionGetString(POSITION_SYMBOL);
   long   type   = PositionGetInteger(POSITION_TYPE);

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};

   req.action        = TRADE_ACTION_DEAL;
   req.position      = ticket;
   req.symbol        = symbol;
   req.volume        = volume;
   req.deviation     = 10;
   req.magic         = MagicNumber;
   req.comment       = EA_NAME;
   req.type_filling  = GetMarketFilling();

   if(type == POSITION_TYPE_BUY)
   {
      req.type  = ORDER_TYPE_SELL;
      req.price = cachedBid;
   }
   else
   {
      req.type  = ORDER_TYPE_BUY;
      req.price = cachedAsk;
   }

   if(OrderSend(req, res) &&
      (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED))
   {
      consecutiveErrors = 0;
      return true;
   }

   HandleTradeError(res.retcode);
   return false;
}

//+------------------------------------------------------------------+
//| Modifica SL de uma posição                                       |
//+------------------------------------------------------------------+
bool ModifyPositionSL(ulong ticket, double newSL)
{
   if(!PositionSelectByTicket(ticket)) return false;

   double currentSL = PositionGetDouble(POSITION_SL);

   // Evita modificações desnecessárias
   if(MathAbs(newSL - currentSL) < cachedPoint * 0.5) return false;

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};

   req.action   = TRADE_ACTION_SLTP;
   req.position = ticket;
   req.symbol   = _Symbol;
   req.sl       = newSL;
   req.tp       = 0.0;
   req.comment  = EA_NAME;

   if(OrderSend(req, res) &&
      (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED))
   {
      consecutiveErrors = 0;
      return true;
   }

   HandleTradeError(res.retcode);
   return false;
}

//+------------------------------------------------------------------+
//| Modifica preço e SL de uma ordem pendente                        |
//+------------------------------------------------------------------+
bool ModifyPendingOrder(ulong ticket, double newPrice, double newSL)
{
   if(!OrderSelect(ticket)) return false;

   double currentPrice = OrderGetDouble(ORDER_PRICE_OPEN);
   double currentSL    = OrderGetDouble(ORDER_SL);

   // Verifica se houve mudança significativa para evitar spam de modificações
   if(MathAbs(newPrice - currentPrice) < cachedPoint * 0.1 &&
      MathAbs(newSL - currentSL) < cachedPoint * 0.1)
      return false;

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};

   req.action = TRADE_ACTION_MODIFY;
   req.order  = ticket;
   req.price  = newPrice;
   req.sl     = newSL;
   req.tp     = 0.0;
   req.type_time = ORDER_TIME_GTC;
   req.comment = EA_NAME;

   if(OrderSend(req, res) &&
      (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED))
   {
      consecutiveErrors = 0;
      return true;
   }

   HandleTradeError(res.retcode);
   return false;
}

//+------------------------------------------------------------------+
//| Atualiza cache de preços                                         |
//+------------------------------------------------------------------+
void UpdatePriceCache()
{
   cachedBid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   cachedAsk    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   cachedSpread = (cachedAsk - cachedBid) / cachedPoint;
}

//+------------------------------------------------------------------+
//| Atualiza ATR                                                     |
//+------------------------------------------------------------------+
void UpdateATRCache()
{
   datetime currentTime = TimeCurrent();
   if(currentTime - lastATRUpdate < 60) return;

   if(handleATR == INVALID_HANDLE) return;

   double atrBuffer[1];
   if(CopyBuffer(handleATR, 0, 0, 1, atrBuffer) > 0)
   {
      cachedATR    = atrBuffer[0];
      lastATRUpdate = currentTime;
   }
}

//+------------------------------------------------------------------+
//| Calcula spread médio                                             |
//+------------------------------------------------------------------+
void CalculateAverageSpread()
{
   if(cachedSpread <= 0) return;

   // O(1) update of average
   spreadSum -= spreadHistory[spreadIndex];
   spreadHistory[spreadIndex] = cachedSpread;
   spreadSum += cachedSpread;

   spreadIndex = (spreadIndex + 1) % 100;
   if(!spreadHistoryReady && spreadIndex == 0) spreadHistoryReady = true;

   int limit = spreadHistoryReady ? 100 : spreadIndex;
   if(limit > 0) averageSpread = spreadSum / limit;
}

//+------------------------------------------------------------------+
//| Monitora drawdown e Safe Mode                                    |
//+------------------------------------------------------------------+
void MonitorDrawdownAndSafeMode()
{
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(currentEquity > maxEquityReached)
      maxEquityReached = currentEquity;

   double drawdown = 0;
   if(maxEquityReached > 0)
      drawdown = ((maxEquityReached - currentEquity) / maxEquityReached) * 100.0;

   if(!safeModeActive && drawdown >= MaxDrawdownPercent)
   {
      Print("🛑 SAFE MODE ON - DD: ", DoubleToString(drawdown, 2), "%");
      safeModeActive = true;
   }
   else if(safeModeActive && drawdown < MaxDrawdownPercent * 0.7)
   {
      Print("✅ SAFE MODE OFF");
      safeModeActive     = false;
      consecutiveErrors  = 0;
   }

   if(SafeModeOnErrors && consecutiveErrors >= MaxConsecutiveErrors && !safeModeActive)
   {
      Print("🛑 SAFE MODE ON - Erros: ", consecutiveErrors);
      safeModeActive = true;
   }
}

//+------------------------------------------------------------------+
//| Verifica condições de mercado                                    |
//+------------------------------------------------------------------+
bool IsMarketConditionSafe()
{
   if(safeModeActive) return false;

   if(UseSpreadFilter)
   {
      CalculateAverageSpread();
      if(averageSpread > 0 && cachedSpread > averageSpread * MaxSpreadMultiplier)
         return false;
   }

   if(UseTimeFilter)
   {
      MqlDateTime dt;
      datetime now = TimeCurrent();
      TimeToStruct(now, dt);
      if(dt.day_of_week == 5) // Friday
      {
         if((dt.hour * 60 + dt.min) >= (1440 - AvoidLastMinutesFriday)) return false;
      }
      else if(dt.day_of_week == 0) // Sunday
      {
         if((dt.hour * 60 + dt.min) <= AvoidFirstMinutesSunday) return false;
      }
   }

   return true;
}

//+------------------------------------------------------------------+
//| Conta posições abertas                                           |
//+------------------------------------------------------------------+
void CountOpenPositions(int &buyCount, int &sellCount, int &totalCount)
{
   buyCount = countBuy;
   sellCount = countSell;
   totalCount = countTotal;
}

//+------------------------------------------------------------------+
//| Verifica se pode abrir mais posições                             |
//+------------------------------------------------------------------+
bool CanOpenMorePositions(bool isBuy)
{
   int buyCount, sellCount, totalCount;
   CountOpenPositions(buyCount, sellCount, totalCount);

   if(MaxPositions > 0 && totalCount >= MaxPositions)
      return false;

   if(isBuy && MaxBuyPositions > 0 && buyCount >= MaxBuyPositions)
      return false;

   if(!isBuy && MaxSellPositions > 0 && sellCount >= MaxSellPositions)
      return false;

   if(!AllowHedging)
   {
      if(isBuy && sellCount > 0) return false;
      if(!isBuy && buyCount > 0) return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| UpdatePoints adaptativo                                          |
//+------------------------------------------------------------------+
int GetAdaptiveUpdatePoints()
{
   if(!UseAdaptiveUpdate) return UpdatePoints;

   // Elasticidade inteligente: combina volatilidade (ATR) e custo operacional (Spread)
   // Multiplicador de 0.3 no ATR permite capturar movimentos estruturais ignorando ruído
   double atrFactor    = (cachedATR > 0 && cachedPoint > 0) ? (cachedATR / cachedPoint * 0.3) : 0;
   // Spread x 2.0 garante que não moveremos ordens por uma distância menor que o custo de transação
   double spreadFactor = cachedSpread * 2.0;

   int adaptive = (int)MathCeil(MathMax(atrFactor, spreadFactor));

   // Retorna o maior entre o calculado e o fixo definido pelo usuário
   return MathMax(adaptive, UpdatePoints);
}

//+------------------------------------------------------------------+
//| Sistema de captura contínua                                      |
//+------------------------------------------------------------------+
void ManageContinuousPendingOrders()
{
   datetime currentTime = TimeCurrent();

   if(currentTime - lastOrderUpdateTime < 1) return;

   double tradeLot = CalculateDynamicLot();

   if(UseDynamicLot && !HasSufficientMargin(tradeLot * InitialOrdersCount))
      return;

   int adaptiveUpdate = GetAdaptiveUpdatePoints();

   ManageBuyStops(tradeLot, adaptiveUpdate, currentTime);
   ManageSellStops(tradeLot, adaptiveUpdate, currentTime);

   lastOrderUpdateTime = currentTime;
}

//+------------------------------------------------------------------+
//| Gerencia BUY Stops                                               |
//+------------------------------------------------------------------+
void ManageBuyStops(double lotSize, int updateThreshold, datetime currentTime)
{
   int currentCount = ArraySize(buyStopTickets);
   ulong currentTick = GetTickCount64();

   // 1. Manter Frequência: Adiciona ordens se faltarem
   if(currentCount < InitialOrdersCount)
   {
      if(currentTime - lastBuyOrderCreation >= RecreateDelaySeconds)
      {
         if(CanOpenMorePositions(true))
         {
            CreateBuyStops(lotSize, InitialOrdersCount - currentCount);
            lastBuyOrderCreation = currentTime;
         }
      }
      // Se acabamos de criar, aguardamos o próximo ciclo para permitir modificações
      return;
   }

   // 2. Movimentação Inteligente: Modifica em vez de cancelar
   if(currentCount > 0 && (currentTick - lastBuyModifyTick) >= ModificationCooldownMS)
   {
      if(!OrderSelect(buyStopTickets[0]))
      {
         SyncPendingOrders();
         return;
      }

      double currentOrderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
      double idealLeadPrice    = GetValidPendingPrice(true, 0);

      // Lógica Assertiva: Buy Stop só acompanha se o preço CAIR (entrada mais barata)
      if(idealLeadPrice < currentOrderPrice - updateThreshold * cachedPoint)
      {
         bool allModified = true;
         for(int i = 0; i < currentCount; i++)
         {
            double newPrice = GetValidPendingPrice(true, (int)(i * SpacingPoints));
            double newSL    = CalculateValidSL(newPrice, true);

            if(!ModifyPendingOrder(buyStopTickets[i], newPrice, newSL))
               allModified = false;
         }

         if(allModified)
         {
            lastBuyModifyTick = currentTick;
            if(ShowChartInfo) Print("🔄 Grade BUY otimizada para baixo (Preço melhor)");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Gerencia SELL Stops                                              |
//+------------------------------------------------------------------+
void ManageSellStops(double lotSize, int updateThreshold, datetime currentTime)
{
   int currentCount = ArraySize(sellStopTickets);
   ulong currentTick = GetTickCount64();

   // 1. Manter Frequência: Adiciona ordens se faltarem
   if(currentCount < InitialOrdersCount)
   {
      if(currentTime - lastSellOrderCreation >= RecreateDelaySeconds)
      {
         if(CanOpenMorePositions(false))
         {
            CreateSellStops(lotSize, InitialOrdersCount - currentCount);
            lastSellOrderCreation = currentTime;
         }
      }
      return;
   }

   // 2. Movimentação Inteligente: Modifica em vez de cancelar
   if(currentCount > 0 && (currentTick - lastSellModifyTick) >= ModificationCooldownMS)
   {
      if(!OrderSelect(sellStopTickets[0]))
      {
         SyncPendingOrders();
         return;
      }

      double currentOrderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
      double idealLeadPrice    = GetValidPendingPrice(false, 0);

      // Lógica Assertiva: Sell Stop só acompanha se o preço SUBIR (entrada mais cara)
      if(idealLeadPrice > currentOrderPrice + updateThreshold * cachedPoint)
      {
         bool allModified = true;
         for(int i = 0; i < currentCount; i++)
         {
            double newPrice = GetValidPendingPrice(false, (int)(i * SpacingPoints));
            double newSL    = CalculateValidSL(newPrice, false);

            if(!ModifyPendingOrder(sellStopTickets[i], newPrice, newSL))
               allModified = false;
         }

         if(allModified)
         {
            lastSellModifyTick = currentTick;
            if(ShowChartInfo) Print("🔄 Grade SELL otimizada para cima (Preço melhor)");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Cria BUY Stops                                                   |
//+------------------------------------------------------------------+
bool CreateBuyStops(double lotSize, int count)
{
   if(count < 1) return false;

   int successCount = 0;
   int startIndex = ArraySize(buyStopTickets);

   for(int i = 0; i < count; i++)
   {
      double orderPrice = GetValidPendingPrice(true, (int)((startIndex + i) * SpacingPoints));
      double orderSL    = CalculateValidSL(orderPrice, true);

      if(orderPrice <= cachedAsk) continue;
      if(orderSL <= 0 || orderSL >= orderPrice) continue;

      MqlTradeRequest req = {};
      MqlTradeResult  res = {};

      req.action        = TRADE_ACTION_PENDING;
      req.symbol        = _Symbol;
      req.volume        = lotSize;
      req.type          = ORDER_TYPE_BUY_STOP;
      req.price         = orderPrice;
      req.sl            = orderSL;
      req.tp            = 0.0;
      req.magic         = MagicNumber;
      req.comment       = EA_NAME;
      req.type_filling  = ORDER_FILLING_RETURN;
      req.type_time     = ORDER_TIME_GTC;
      req.deviation     = 0;

      if(OrderSend(req, res) &&
         (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED))
      {
         int sz = ArraySize(buyStopTickets);
         ArrayResize(buyStopTickets, sz + 1);
         buyStopTickets[sz] = res.order;
         successCount++;
         consecutiveErrors = 0;

         if(ShowChartInfo) Print("➕ Buy Stop #", res.order, " adicionada à grade (Pos: ", sz, ")");
      }
      else
      {
         HandleTradeError(res.retcode);
         if(res.retcode == TRADE_RETCODE_LIMIT_ORDERS ||
            res.retcode == TRADE_RETCODE_REQUOTE)
            Sleep(10);
      }
   }

   return (successCount > 0);
}

//+------------------------------------------------------------------+
//| Cria SELL Stops                                                  |
//+------------------------------------------------------------------+
bool CreateSellStops(double lotSize, int count)
{
   if(count < 1) return false;

   int successCount = 0;
   int startIndex = ArraySize(sellStopTickets);

   for(int i = 0; i < count; i++)
   {
      double orderPrice = GetValidPendingPrice(false, (int)((startIndex + i) * SpacingPoints));
      double orderSL    = CalculateValidSL(orderPrice, false);

      if(orderPrice >= cachedBid) continue;
      if(orderSL <= orderPrice || orderSL <= 0) continue;

      MqlTradeRequest req = {};
      MqlTradeResult  res = {};

      req.action        = TRADE_ACTION_PENDING;
      req.symbol        = _Symbol;
      req.volume        = lotSize;
      req.type          = ORDER_TYPE_SELL_STOP;
      req.price         = orderPrice;
      req.sl            = orderSL;
      req.tp            = 0.0;
      req.magic         = MagicNumber;
      req.comment       = EA_NAME;
      req.type_filling  = ORDER_FILLING_RETURN;
      req.type_time     = ORDER_TIME_GTC;
      req.deviation     = 0;

      if(OrderSend(req, res) &&
         (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED))
      {
         int sz = ArraySize(sellStopTickets);
         ArrayResize(sellStopTickets, sz + 1);
         sellStopTickets[sz] = res.order;
         successCount++;
         consecutiveErrors = 0;

         if(ShowChartInfo) Print("➕ Sell Stop #", res.order, " adicionada à grade (Pos: ", sz, ")");
      }
      else
      {
         HandleTradeError(res.retcode);
         if(res.retcode == TRADE_RETCODE_LIMIT_ORDERS ||
            res.retcode == TRADE_RETCODE_REQUOTE)
            Sleep(10);
      }
   }

   return (successCount > 0);
}

//+------------------------------------------------------------------+
//| Preço válido para pending                                        |
//+------------------------------------------------------------------+
double GetValidPendingPrice(bool isBuy, int additionalOffset = 0)
{
   int    totalOffset = adjustedOffsetPoints + additionalOffset;
   double minDist     = totalOffset * cachedPoint;

   if(isBuy)
      return NormalizeDouble(cachedAsk + minDist, cachedDigits);
   else
      return NormalizeDouble(cachedBid - minDist, cachedDigits);
}

//+------------------------------------------------------------------+
//| SL válido                                                         |
//+------------------------------------------------------------------+
double CalculateValidSL(double orderPrice, bool isBuy)
{
   int    minSL = MathMax(stopsLevel + 2, adjustedStopLossPoints);
   double dist  = minSL * cachedPoint;

   if(isBuy)
      return NormalizeDouble(orderPrice - dist, cachedDigits);
   else
      return NormalizeDouble(orderPrice + dist, cachedDigits);
}

//+------------------------------------------------------------------+
//| Verifica freeze level                                            |
//+------------------------------------------------------------------+
bool CanModifyOrder(ulong ticket)
{
   if(!OrderSelect(ticket)) return false;
   if(freezeLevel <= 0)     return true;

   double orderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
   long   orderType  = OrderGetInteger(ORDER_TYPE);
   double refPrice   = (orderType == ORDER_TYPE_BUY_STOP) ? cachedAsk : cachedBid;
   double distance   = MathAbs(orderPrice - refPrice);

   return (distance > (freezeLevel + 2) * cachedPoint);
}

//+------------------------------------------------------------------+
//| Cancela ordem                                                    |
//+------------------------------------------------------------------+
bool CancelOrder(ulong ticket)
{
   if(ticket == 0) return false;
   if(!CanModifyOrder(ticket)) return false;

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};

   req.action = TRADE_ACTION_REMOVE;
   req.order  = ticket;
   req.comment = EA_NAME;

   if(OrderSend(req, res) &&
      (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED))
   {
      consecutiveErrors = 0;
      return true;
   }

   HandleTradeError(res.retcode);
   if(!OrderSelect(ticket)) return true;
   return false;
}

//+------------------------------------------------------------------+
//| Filling mode                                                     |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetMarketFilling()
{
   int mode = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if(mode == 2 || mode == 3) return ORDER_FILLING_IOC;
   if(mode == 1)               return ORDER_FILLING_FOK;
   return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| Calcula lote dinâmico                                            |
//+------------------------------------------------------------------+
double CalculateDynamicLot()
{
   if(!UseDynamicLot) return Lots;

   double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double accountEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double freeMargin     = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double baseValue      = MathMin(accountBalance, accountEquity);

   double riskAmount    = baseValue * (RiskPercent / 100.0);
   double pointValue    = (cachedTickSize > 0)
                          ? (cachedTickValue / cachedTickSize) * cachedPoint
                          : cachedPoint * 10;

   if(pointValue <= 0) return Lots;

   double calculatedLot = (adjustedStopLossPoints > 0)
                          ? riskAmount / (adjustedStopLossPoints * pointValue)
                          : Lots;

   calculatedLot = MathMin(calculatedLot, MaxLotSize);

   double requiredMargin = 0;
   if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, calculatedLot, cachedAsk, requiredMargin))
   {
      double safeMargin = freeMargin * ((100.0 - MarginSafetyPercent) / 100.0);
      if(requiredMargin > safeMargin && requiredMargin > 0)
         calculatedLot *= (safeMargin / requiredMargin);
   }

   return NormalizeVolume(calculatedLot);
}

//+------------------------------------------------------------------+
//| Verifica margem                                                  |
//+------------------------------------------------------------------+
bool HasSufficientMargin(double volume)
{
   double freeMargin     = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double requiredMargin = 0;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, volume, cachedAsk, requiredMargin))
      return false;
   double safeMargin = freeMargin * ((100.0 - MarginSafetyPercent) / 100.0);
   return (requiredMargin <= safeMargin);
}

//+------------------------------------------------------------------+
//| Normaliza volume                                                 |
//+------------------------------------------------------------------+
double NormalizeVolume(double volume)
{
   volume = MathMax(volume, minVolume);
   volume = MathMin(volume, maxVolume);
   if(stepVolume > 0)
      volume = MathRound(volume / stepVolume) * stepVolume;

   return NormalizeDouble(volume, 2);
}

//+------------------------------------------------------------------+
//| Tratamento de erros                                              |
//+------------------------------------------------------------------+
void HandleTradeError(uint retcode)
{
   consecutiveErrors++;

   if(!ShowChartInfo) return;
   switch(retcode)
   {
      case TRADE_RETCODE_REQUOTE:       break;
      case TRADE_RETCODE_PRICE_CHANGED: break;
      case TRADE_RETCODE_REJECT:        Print("❌ Ordem rejeitada");          break;
      case TRADE_RETCODE_INVALID_STOPS: Print("❌ Stops inválidos");          break;
      case TRADE_RETCODE_FROZEN:        Print("❌ Freeze level");             break;
      case TRADE_RETCODE_INVALID_PRICE: Print("❌ Preço inválido");           break;
      case TRADE_RETCODE_NO_MONEY:      Print("❌ Margem insuficiente");      break;
      case TRADE_RETCODE_LIMIT_ORDERS:  Print("❌ Limite de ordens");         break;
   }
}

//+------------------------------------------------------------------+
//| Display                                                          |
//+------------------------------------------------------------------+
void DisplayStatusInfo()
{
   if(!ShowChartInfo) return;

   static int displayCounter = 0;
   if(++displayCounter < 100) return;
   displayCounter = 0;

   double totalProfit = 0;
   for(int i = 0; i < countTotal; i++)
   {
      if(PositionSelectByTicket(positions[i].ticket))
         totalProfit += PositionGetDouble(POSITION_PROFIT);
   }

   string info = EA_NAME + "\n";
   info += (safeModeActive) ? "🛑 MODO DE SEGURANÇA ATIVO" : "🔄 TRAILING ATIVO ";

   if(!safeModeActive)
   {
      switch(TrailingMode)
      {
         case TRAILING_INDIVIDUAL:   info += "IND"; break;
         case TRAILING_BY_DIRECTION: info += "DIR"; break;
         case TRAILING_GLOBAL:       info += "GLB"; break;
      }

      StringAdd(info, "\n📊 Posições: ");
      if(countTotal == 0) StringAdd(info, "0");
      else StringAdd(info, StringFormat("%dB/%dS | $%.2f", countBuy, countSell, totalProfit));

      StringAdd(info, StringFormat("\n📋 Pendentes: %dB/%dS", ArraySize(buyStopTickets), ArraySize(sellStopTickets)));
      StringAdd(info, StringFormat("\n📡 SP: %.1f", cachedSpread));
   }

   Comment(info);

}

//+------------------------------------------------------------------+
//| Desinicialização                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(handleATR != INVALID_HANDLE)
      IndicatorRelease(handleATR);

   Comment("");

   int totalCanceled = 0;

   for(int i = ArraySize(buyStopTickets) - 1; i >= 0; i--)
      if(CancelOrder(buyStopTickets[i]))
         totalCanceled++;

   for(int i = ArraySize(sellStopTickets) - 1; i >= 0; i--)
      if(CancelOrder(sellStopTickets[i]))
         totalCanceled++;

   Print("═══════════════════════════════════════════════");
   Print(EA_NAME, " - Trailing Otimizado Finalizado");
   Print("Ordens Canceladas: ", totalCanceled);
   Print("═══════════════════════════════════════════════");
}
