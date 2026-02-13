//+------------------------------------------------------------------+
//|                 JM2000 EA V1 - TRAILING OTIMIZADO                |
//|                                  Copyright © 2026, NeuralTrader  |
//|                                          https://neuraltrade.ai  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "1.04"
#property description "JM2000 EA - Trailing Otimizado Multi-Posições"

//--- Enumeração para modos de trailing (DEVE estar ANTES dos inputs)
enum ENUM_TRAILING_MODE
{
   TRAILING_INDIVIDUAL,    // Individual (cada posição independente)
   TRAILING_BY_DIRECTION,  // Por direção (todas BUY juntas, todas SELL juntas)
   TRAILING_GLOBAL         // Global (todas as posições movem juntas)
};

//--- Inputs Básicos
input int    StopLossPoints      = 50;    // Stop Loss inicial (pontos)
input double Lots                = 0.01;  // Volume do lote base
input int    MagicNumber         = 12345; // Magic Number
input int    OffsetPoints        = 10;    // Distância do preço atual para ordem pendente (pontos)
input int    UpdatePoints        = 5;     // Distância mínima para atualizar ordem (pontos)

//--- Inputs de Trailing Stop
input ENUM_TRAILING_MODE TrailingMode = TRAILING_INDIVIDUAL; // Modo de Trailing
input int    TrailingStopPoints  = 20;    // Distância do Trailing Stop (pontos)
input int    TrailingStepPoints  = 10;    // Passo mínimo para mover SL (pontos)
input int    BreakEvenPoints     = 30;    // Pontos de lucro para BreakEven (0=desativado)
input int    BreakEvenPlusPoints = 5;     // Pontos além do BreakEven
input bool   UsePartialClose     = false; // Fechar parcialmente no BreakEven
input double PartialClosePercent = 50.0;  // % do volume a fechar (50 = metade)

//--- Inputs de Múltiplas Ordens
input int    InitialOrdersCount  = 3;     // Número de ordens pendentes por lado (1-20)
input double SpacingPoints       = 5;     // Espaçamento entre ordens (0 = mesmo preço)

//--- Inputs de Gerenciamento de Lote
input bool   UseDynamicLot          = false; // Ativar lote dinâmico
input double RiskPercent            = 2.0;   // Percentual de risco TOTAL
input double MaxLotSize             = 10.0;  // Tamanho máximo do lote
input double MarginSafetyPercent    = 20.0;  // Margem livre a manter (%)

//--- Inputs de Controle de Posições
input int    MaxPositions           = 0;     // Máximo de posições simultâneas (0 = ilimitado)
input int    MaxBuyPositions        = 0;     // Máximo de posições BUY (0 = ilimitado)
input int    MaxSellPositions       = 0;     // Máximo de posições SELL (0 = ilimitado)
input bool   AllowHedging           = true;  // Permitir BUY e SELL simultâneos

//--- Inputs de Proteção
input double MaxDrawdownPercent     = 5.0;   // DD% máximo para pausar
input bool   SafeModeOnErrors       = true;  // Safe Mode por erros
input int    MaxConsecutiveErrors   = 3;     // Número de erros para Safe Mode

//--- Inputs de Filtros
input bool   UseSpreadFilter          = true;  // Filtrar spread anormal
input double MaxSpreadMultiplier      = 2.0;   // Spread máximo (múltiplo)
input bool   UseTimeFilter            = false; // Filtrar horários
input int    AvoidLastMinutesFriday   = 30;    // Minutos finais sexta
input int    AvoidFirstMinutesSunday  = 10;    // Minutos iniciais domingo

//--- Inputs de Performance
input bool   ShowChartInfo      = true;   // Exibir informações
input bool   UseAdaptiveUpdate  = true;   // UpdatePoints dinâmico
input int    RecreateDelaySeconds = 1;    // Delay para recriar ordens (segundos)

//--- Inputs de Cores do Gráfico
input color  CandleBullColor    = clrGold;    // Cor das velas BUY (dourado)
input color  CandleBearColor    = clrCrimson; // Cor das velas SELL (vermelho)
input color  ChartBackground    = clrBlack;   // Cor do fundo do gráfico
input color  ChartGrid          = clrDimGray; // Cor da grade
input color  ChartText          = clrWhite;   // Cor do texto
input bool   ApplyChartColors   = true;       // Aplicar cores ao gráfico

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

//--- Variáveis de controle do broker
int stopsLevel           = 0;
int freezeLevel          = 0;
int adjustedOffsetPoints = 0;
int adjustedStopLossPoints = 0;

//--- Cache
double cachedPoint    = 0;
int    cachedDigits   = 0;
double cachedTickValue = 0;
double cachedTickSize  = 0;
double cachedBid      = 0;
double cachedAsk      = 0;
double cachedSpread   = 0;

//--- Estado
int      consecutiveErrors     = 0;
bool     safeModeActive        = false;
double   averageSpread         = 0;
double   maxEquityReached      = 0;
double   cachedATR             = 0;
datetime lastATRUpdate         = 0;
int      atrHandle             = INVALID_HANDLE;

//--- Spread history
double   spreadHistory[100];
int      spreadIndex = 0;
bool     spreadHistoryReady = false;

//+------------------------------------------------------------------+
//| Remove elemento do array                                         |
//+------------------------------------------------------------------+
template<typename T>
void RemoveArrayElement(T &arr[], int index)
{
   int size = ArraySize(arr);
   if(index < 0 || index >= size) return;
   for(int i = index; i < size - 1; i++)
      arr[i] = arr[i + 1];
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

   stopsLevel  = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   freezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);

   cachedPoint     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   cachedDigits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   cachedTickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   cachedTickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   adjustedOffsetPoints    = MathMax(OffsetPoints,    stopsLevel + 2);
   adjustedStopLossPoints  = MathMax(StopLossPoints,  stopsLevel + 2);

   ArrayResize(buyStopTickets,  0);
   ArrayResize(sellStopTickets, 0);
   ArrayResize(positions, 0);
   ArrayInitialize(spreadHistory, 0);

   maxEquityReached = AccountInfoDouble(ACCOUNT_EQUITY);

   UpdatePriceCache();
   CalculateAverageSpread();
   ApplyCustomChartColors();

   atrHandle = iATR(_Symbol, PERIOD_M1, 14);
   if(atrHandle == INVALID_HANDLE)
   {
      Print("ERRO: Falha ao criar handle do ATR");
      return INIT_FAILED;
   }

   string trailingModeStr = "";
   switch(TrailingMode)
   {
      case TRAILING_INDIVIDUAL:   trailingModeStr = "INDIVIDUAL"; break;
      case TRAILING_BY_DIRECTION: trailingModeStr = "POR DIREÇÃO"; break;
      case TRAILING_GLOBAL:       trailingModeStr = "GLOBAL"; break;
   }

   Print("═══════════════════════════════════════════════");
   Print("JM2000 EA - TRAILING OTIMIZADO");
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

   // ✅ Atualiza tracker de posições
   UpdatePositionTracker();

   // ✅ Sistema de trailing otimizado
   ApplyOptimizedTrailing();

   // ✅ Sistema de captura contínua
   ManageContinuousPendingOrders();

   DisplayStatusInfo();
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
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      // Verifica se já está no tracker
      bool found = false;
      for(int j = 0; j < ArraySize(positions); j++)
      {
         if(positions[j].ticket == ticket)
         {
            found = true;
            break;
         }
      }

      // Adiciona se for nova
      if(!found)
      {
         int sz = ArraySize(positions);
         ArrayResize(positions, sz + 1);

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
   // Agrupa posições por direção
   double buyMaxPrice  = 0;
   double sellMinPrice = DBL_MAX;
   int    buyCount     = 0;
   int    sellCount    = 0;

   for(int i = 0; i < ArraySize(positions); i++)
   {
      if(positions[i].isBuy)
      {
         if(cachedBid > buyMaxPrice)
            buyMaxPrice = cachedBid;
         buyCount++;
      }
      else
      {
         if(cachedAsk < sellMinPrice)
            sellMinPrice = cachedAsk;
         sellCount++;
      }
   }

   double trailDist = TrailingStopPoints * cachedPoint;
   double stepDist  = TrailingStepPoints * cachedPoint;

   // Trailing para todas as posições BUY
   if(buyCount > 0)
   {
      double newBuySL = NormalizeDouble(buyMaxPrice - trailDist, cachedDigits);

      for(int i = 0; i < ArraySize(positions); i++)
      {
         if(!positions[i].isBuy) continue;
         if(!PositionSelectByTicket(positions[i].ticket)) continue;

         if(newBuySL > positions[i].entryPrice &&
            (positions[i].currentSL == 0 || newBuySL > positions[i].currentSL + stepDist))
         {
            if(ModifyPositionSL(positions[i].ticket, newBuySL))
            {
               positions[i].currentSL = newBuySL;
            }
         }
      }
   }

   // Trailing para todas as posições SELL
   if(sellCount > 0)
   {
      double newSellSL = NormalizeDouble(sellMinPrice + trailDist, cachedDigits);

      for(int i = 0; i < ArraySize(positions); i++)
      {
         if(positions[i].isBuy) continue;
         if(!PositionSelectByTicket(positions[i].ticket)) continue;

         if(newSellSL < positions[i].entryPrice &&
            (positions[i].currentSL == 0 || newSellSL < positions[i].currentSL - stepDist))
         {
            if(ModifyPositionSL(positions[i].ticket, newSellSL))
            {
               positions[i].currentSL = newSellSL;
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| ✅ Trailing Global - todas posições movem juntas                 |
//+------------------------------------------------------------------+
void ApplyGlobalTrailing()
{
   if(ArraySize(positions) == 0) return;

   // Calcula preço médio ponderado
   double totalBuyVolume  = 0;
   double totalSellVolume = 0;
   double buyWeightedPrice  = 0;
   double sellWeightedPrice = 0;

   for(int i = 0; i < ArraySize(positions); i++)
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

   double trailDist = TrailingStopPoints * cachedPoint;
   double stepDist  = TrailingStepPoints * cachedPoint;

   // Trailing unificado para BUYs
   if(totalBuyVolume > 0)
   {
      double avgBuyEntry = buyWeightedPrice / totalBuyVolume;
      double newBuySL = NormalizeDouble(cachedBid - trailDist, cachedDigits);

      if(newBuySL > avgBuyEntry)
      {
         for(int i = 0; i < ArraySize(positions); i++)
         {
            if(!positions[i].isBuy) continue;
            if(positions[i].currentSL == 0 || newBuySL > positions[i].currentSL + stepDist)
            {
               if(ModifyPositionSL(positions[i].ticket, newBuySL))
                  positions[i].currentSL = newBuySL;
            }
         }
      }
   }

   // Trailing unificado para SELLs
   if(totalSellVolume > 0)
   {
      double avgSellEntry = sellWeightedPrice / totalSellVolume;
      double newSellSL = NormalizeDouble(cachedAsk + trailDist, cachedDigits);

      if(newSellSL < avgSellEntry)
      {
         for(int i = 0; i < ArraySize(positions); i++)
         {
            if(positions[i].isBuy) continue;
            if(positions[i].currentSL == 0 || newSellSL < positions[i].currentSL - stepDist)
            {
               if(ModifyPositionSL(positions[i].ticket, newSellSL))
                  positions[i].currentSL = newSellSL;
            }
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

   if(atrHandle == INVALID_HANDLE) return;

   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);
   if(CopyBuffer(atrHandle, 0, 0, 1, atrBuffer) > 0)
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

   spreadHistory[spreadIndex] = cachedSpread;
   spreadIndex = (spreadIndex + 1) % 100;
   if(spreadIndex == 0) spreadHistoryReady = true;

   int limit  = spreadHistoryReady ? 100 : spreadIndex;
   double sum = 0;
   for(int i = 0; i < limit; i++)
      sum += spreadHistory[i];

   if(limit > 0) averageSpread = sum / limit;
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
      TimeToStruct(TimeCurrent(), dt);
      if(dt.day_of_week == 5)
      {
         int minutesUntilClose = (24 * 60) - (dt.hour * 60 + dt.min);
         if(minutesUntilClose <= AvoidLastMinutesFriday) return false;
      }
      if(dt.day_of_week == 0)
      {
         int minutesSinceOpen = dt.hour * 60 + dt.min;
         if(minutesSinceOpen <= AvoidFirstMinutesSunday) return false;
      }
   }

   return true;
}

//+------------------------------------------------------------------+
//| Conta posições abertas                                           |
//+------------------------------------------------------------------+
void CountOpenPositions(int &buyCount, int &sellCount, int &totalCount)
{
   buyCount = 0;
   sellCount = 0;
   totalCount = 0;

   for(int i = 0; i < ArraySize(positions); i++)
   {
      if(positions[i].isBuy)
         buyCount++;
      else
         sellCount++;
      totalCount++;
   }
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

   double atrPoints    = (cachedATR > 0 && cachedPoint > 0) ? (cachedATR / cachedPoint * 0.2) : 0;
   double spreadPoints = cachedSpread * 1.5;
   int    adaptive     = (int)MathMax(atrPoints, spreadPoints);
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
   for(int i = ArraySize(buyStopTickets) - 1; i >= 0; i--)
   {
      if(!OrderSelect(buyStopTickets[i]))
         RemoveArrayElement(buyStopTickets, i);
   }

   int currentCount = ArraySize(buyStopTickets);

   if(currentCount < InitialOrdersCount)
   {
      if(currentTime - lastBuyOrderCreation >= RecreateDelaySeconds)
      {
         if(CanOpenMorePositions(true))
         {
            CreateBuyStops(lotSize, InitialOrdersCount - currentCount);
            lastBuyOrderCreation = currentTime;
            return;
         }
      }
      return;
   }

   if(currentCount > 0)
   {
      if(!OrderSelect(buyStopTickets[0])) return;

      double currentOrderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
      double newPrice = GetValidPendingPrice(true, 0);
      double diffPoints = MathAbs(newPrice - currentOrderPrice) / cachedPoint;

      if(diffPoints >= updateThreshold)
      {
         for(int i = currentCount - 1; i >= 0; i--)
         {
            if(CanModifyOrder(buyStopTickets[i]))
            {
               CancelOrder(buyStopTickets[i]);
               RemoveArrayElement(buyStopTickets, i);
            }
         }

         if(ArraySize(buyStopTickets) == 0)
         {
            CreateBuyStops(lotSize, InitialOrdersCount);
            lastBuyOrderCreation = currentTime;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Gerencia SELL Stops                                              |
//+------------------------------------------------------------------+
void ManageSellStops(double lotSize, int updateThreshold, datetime currentTime)
{
   for(int i = ArraySize(sellStopTickets) - 1; i >= 0; i--)
   {
      if(!OrderSelect(sellStopTickets[i]))
         RemoveArrayElement(sellStopTickets, i);
   }

   int currentCount = ArraySize(sellStopTickets);

   if(currentCount < InitialOrdersCount)
   {
      if(currentTime - lastSellOrderCreation >= RecreateDelaySeconds)
      {
         if(CanOpenMorePositions(false))
         {
            CreateSellStops(lotSize, InitialOrdersCount - currentCount);
            lastSellOrderCreation = currentTime;
            return;
         }
      }
      return;
   }

   if(currentCount > 0)
   {
      if(!OrderSelect(sellStopTickets[0])) return;

      double currentOrderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
      double newPrice = GetValidPendingPrice(false, 0);
      double diffPoints = MathAbs(newPrice - currentOrderPrice) / cachedPoint;

      if(diffPoints >= updateThreshold)
      {
         for(int i = currentCount - 1; i >= 0; i--)
         {
            if(CanModifyOrder(sellStopTickets[i]))
            {
               CancelOrder(sellStopTickets[i]);
               RemoveArrayElement(sellStopTickets, i);
            }
         }

         if(ArraySize(sellStopTickets) == 0)
         {
            CreateSellStops(lotSize, InitialOrdersCount);
            lastSellOrderCreation = currentTime;
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
      UpdatePriceCache();

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
      UpdatePriceCache();

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
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   volume = MathMax(volume, minLot);
   volume = MathMin(volume, maxLot);
   if(stepLot > 0)
      volume = MathRound(volume / stepLot) * stepLot;

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

   int buyCount, sellCount, totalCount;
   CountOpenPositions(buyCount, sellCount, totalCount);

   double totalProfit = 0;
   for(int i = 0; i < ArraySize(positions); i++)
   {
      if(PositionSelectByTicket(positions[i].ticket))
         totalProfit += PositionGetDouble(POSITION_PROFIT);
   }

   string modeStr = "";
   switch(TrailingMode)
   {
      case TRAILING_INDIVIDUAL:   modeStr = "IND"; break;
      case TRAILING_BY_DIRECTION: modeStr = "DIR"; break;
      case TRAILING_GLOBAL:       modeStr = "GLB"; break;
   }

   string info = "";

   if(safeModeActive)
   {
      info = "🛑 SAFE MODE";
   }
   else
   {
      info = "🔄 TRAILING " + modeStr + "\n";

      info += "📊 Posições: ";
      if(totalCount == 0)
         info += "0";
      else
         info += IntegerToString(buyCount) + "B/" +
                 IntegerToString(sellCount) + "S | $" +
                 DoubleToString(totalProfit, 2);

      int buyPending  = ArraySize(buyStopTickets);
      int sellPending = ArraySize(sellStopTickets);
      info += "\n📋 Pendentes: " + IntegerToString(buyPending) + "B/" +
              IntegerToString(sellPending) + "S";

      info += "\n📡 SP: " + DoubleToString(cachedSpread, 1);
   }

   Comment(info);
}

//+------------------------------------------------------------------+
//| Desinicialização                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);

   Comment("");

   int totalCanceled = 0;

   for(int i = ArraySize(buyStopTickets) - 1; i >= 0; i--)
      if(CancelOrder(buyStopTickets[i]))
         totalCanceled++;

   for(int i = ArraySize(sellStopTickets) - 1; i >= 0; i--)
      if(CancelOrder(sellStopTickets[i]))
         totalCanceled++;

   Print("═══════════════════════════════════════════════");
   Print("JM2000 EA - Trailing Otimizado Finalizado");
   Print("Ordens Canceladas: ", totalCanceled);
   Print("═══════════════════════════════════════════════");
}
