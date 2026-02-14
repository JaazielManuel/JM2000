//+------------------------------------------------------------------+
//|                             JM2000 EA V1                         |
//|                                  Copyright © 2026, NeuralTrader  |
//|                                          https://neuraltrade.ai  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "2.2"
#property description "JM2000 EA V1 - Omni-Adaptive Master Integration (2026 Edition)"

#include <../Include/UniversalTrailing.mqh>

//--- Inputs Básicos
input int    StopLossPoints = 50;          // Stop Loss inicial (pontos)
input double Lots          = 0.01;         // Volume do lote base
input int    MagicNumber   = 12345;        // Magic Number
input int    TrailingStopPoints = 20;      // Distância do Trailing Stop (pontos)
input int    TrailingStepPoints = 10;      // Passo mínimo para mover SL (pontos)
input int    OffsetPoints = 10;            // Distância do preço atual para ordem pendente (pontos)
input int    UpdatePoints = 5;             // Distância mínima para atualizar ordem (pontos)

//--- Inputs Trailing Master (Mythical 2026)
input group "== TRAILING MASTER 2026 =="
input bool   InpUseAdvancedTrailing = true;      // Ativar Trailing Master?
input ENUM_TRAILING_MODE InpTrailingMode = TRL_MODE_ATR; // Modo de Trailing
input bool   InpOnlyInProfit = true;             // Trailing Estrutural (Apenas Lucro)
input bool   InpAdaptiveScaling = true;          // Auto-Escala (Sintéticos/Crypto)?
input bool   InpClusterMode = true;              // Modo Cluster (Unificar SL)?
input double InpMaxSpreadAllowed = 50;           // Spread Máximo para Trailing (pts)
input int    InpThrottleMS = 200;                // Throttle de Processamento (ms)

input group "== CONFIGURAÇÕES ADAPTATIVAS =="
input int    InpATRPeriod = 14;                  // Período ATR
input double InpATRMultiplier = 2.0;             // Multiplicador Volatilidade
input double InpATRStructuralFactor = 5.0;       // Fator Estrutural (Média Lenta)
input double InpPSARStep = 0.02;                 // PSAR Step
input double InpPSARMax = 0.2;                   // PSAR Max
input int    InpMAPeriod = 20;                   // Período Média Móvel
input int    InpHLCount = 3;                     // Velas para High/Low / Shadow
input double InpStepSizePts = 150;               // Tamanho do Degrau (True Step)
input double InpStepMinProfitPts = 50;           // Lucro Mínimo para Step (pts)

input group "== BREAKEVEN MASTER =="
input double InpBEActivationPts = 200;           // Ativação Breakeven (pts)
input double InpBELockProfitPts = 30;            // Lucro Travado no BE (pts)

//--- Inputs de Múltiplas Ordens
input int    InitialOrdersCount = 1;      // Número de ordens iniciais simultâneas (1-20)
input bool   UseUnifiedStops = true;       // Usar SL/TP unificado
input double SpacingPoints = 0;            // Espaçamento entre ordens (0 = mesmo preço)

//--- Inputs de Gerenciamento de Lote
input bool   UseDynamicLot = false;        // Ativar lote dinâmico
input double RiskPercent = 2.0;            // Percentual de risco TOTAL
input double MaxLotSize = 10.0;            // Tamanho máximo do lote
input double MarginSafetyPercent = 20.0;   // Margem livre a manter (%)

//--- Inputs de Controle
input int    MaxTotalOrders = 10;          // Número máximo de ordens abertas

//--- Inputs de Pirâmide
input bool   EnablePyramid = true;         // Ativar sistema de pirâmide
input int    PyramidLevels = 3;            // Número máximo de níveis
input int    PyramidDistance = 50;         // Distância entre níveis (pontos)
input double PyramidMultiplier = 1.5;      // Multiplicador do volume
input bool   PyramidTrailing = true;       // Trailing individual
input bool   PyramidOnlyInProfit = true;   // Adicionar somente em lucro
input double MinProfitForNextLevel = 1.2;  // Multiplicador de lucro mínimo
input bool   PyramidTrendFollowing = true; // Pirâmide a favor do movimento

//--- Inputs de Proteção
input double MaxDrawdownPercent = 5.0;     // DD% máximo para pausar
input bool   SafeModeOnErrors = true;      // Safe Mode por erros
input int    MaxConsecutiveErrors = 3;     // Número de erros para Safe Mode

//--- Inputs de Filtros
input bool   UseSpreadFilter = true;       // Filtrar spread anormal
input double MaxSpreadMultiplier = 2.0;    // Spread máximo (múltiplo)
input bool   UseTimeFilter = true;         // Filtrar horários
input int    AvoidLastMinutesFriday = 30;  // Minutos finais sexta
input int    AvoidFirstMinutesSunday = 10; // Minutos iniciais domingo

//--- Inputs de Performance
input bool   ShowChartInfo = true;         // Exibir informações
input bool   UseAdaptiveUpdate = true;     // UpdatePoints dinâmico

//--- Inputs de Cores do Gráfico
input color  CandleBullColor = clrGold;           // Cor das velas BUY (dourado)
input color  CandleBearColor = clrCrimson;        // Cor das velas SELL (vermelho)
input color  ChartBackground = clrBlack;          // Cor do fundo do gráfico
input color  ChartGrid = clrDimGray;              // Cor da grade
input color  ChartText = clrWhite;                // Cor do texto
input bool   ApplyChartColors = true;             // Aplicar cores ao gráfico

//--- Variáveis globais
ulong buyStopTickets[];
ulong sellStopTickets[];
double lastBuyPrice = 0;
double lastSellPrice = 0;
bool positionActive = false;
ENUM_POSITION_TYPE currentPositionType = WRONG_VALUE;

//--- Variáveis de controle do broker
int stopsLevel = 0;
int freezeLevel = 0;
int adjustedOffsetPoints = 0;
int adjustedStopLossPoints = 0;

//--- Cache
double cachedPoint = 0;
int cachedDigits = 0;
double cachedTickValue = 0;
double cachedTickSize = 0;
double cachedBid = 0;
double cachedAsk = 0;
double cachedSpread = 0;

//--- Estado
bool orderUpdateInProgress = false;
datetime lastOrderUpdateTime = 0;
int consecutiveErrors = 0;
bool safeModeActive = false;
double averageSpread = 0;
double maxEquityReached = 0;
double cachedATR = 0;
datetime lastATRUpdate = 0;

//--- Globais Trailing
CUniversalTrailing trailing;

//--- Pirâmide
struct PyramidLevel {
   ulong ticket;
   double entryPrice;
   double volume;
   double sl;
   datetime entryTime;
   double maxProfit;
};

PyramidLevel buyPyramid[];
PyramidLevel sellPyramid[];

//+------------------------------------------------------------------+
//| Helper: Remove element from array (MQL5 doesn't have ArrayRemove)|
//+------------------------------------------------------------------+
template<typename T>
void RemoveArrayElement(T &arr[], int index) {
   int size = ArraySize(arr);
   if(index < 0 || index >= size) return;

   for(int i = index; i < size - 1; i++) {
      arr[i] = arr[i + 1];
   }
   ArrayResize(arr, size - 1);
}

//+------------------------------------------------------------------+
//| Configura cores do gráfico programaticamente                     |
//+------------------------------------------------------------------+
void ApplyCustomChartColors() {
   if(!ApplyChartColors) return;

   long chartID = ChartID();

   // Configura cores principais das velas
   ChartSetInteger(chartID, CHART_COLOR_CANDLE_BULL, CandleBullColor);
   ChartSetInteger(chartID, CHART_COLOR_CANDLE_BEAR, CandleBearColor);
   ChartSetInteger(chartID, CHART_COLOR_BACKGROUND, ChartBackground);
   ChartSetInteger(chartID, CHART_COLOR_GRID, ChartGrid);
   ChartSetInteger(chartID, CHART_COLOR_FOREGROUND, ChartText);
   ChartSetInteger(chartID, CHART_COLOR_CHART_LINE, ChartText);
   ChartSetInteger(chartID, CHART_COLOR_CHART_UP, CandleBullColor);
   ChartSetInteger(chartID, CHART_COLOR_CHART_DOWN, CandleBearColor);
   ChartSetInteger(chartID, CHART_COLOR_VOLUME, clrDodgerBlue);

   // Configura também as bordas das velas
   ChartSetInteger(chartID, CHART_COLOR_BID, CandleBullColor);
   ChartSetInteger(chartID, CHART_COLOR_ASK, CandleBearColor);

   // Configura cores do Last
   ChartSetInteger(chartID, CHART_COLOR_LAST, clrYellow);

   // Ativa o modo de cores personalizadas
   ChartSetInteger(chartID, CHART_MODE, CHART_CANDLES);

   // Força o redesenho do gráfico
   ChartRedraw(chartID);

   if(ShowChartInfo) {
      Print("✓ Cores do gráfico configuradas:");
      Print("  - Velas BUY: ", ColorToString(CandleBullColor));
      Print("  - Velas SELL: ", ColorToString(CandleBearColor));
      Print("  - Fundo: ", ColorToString(ChartBackground));
   }
}

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit() {
   // Validação de inputs
   if(InitialOrdersCount < 1 || InitialOrdersCount > 20) {
      Print("ERRO: InitialOrdersCount deve estar entre 1 e 20");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(StopLossPoints < 5) {
      Print("ERRO: StopLossPoints muito baixo (mínimo 5)");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(TrailingStopPoints < 5) {
      Print("ERRO: TrailingStopPoints muito baixo (mínimo 5)");
      return(INIT_PARAMETERS_INCORRECT);
   }

   // Obtém níveis do broker
   stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   freezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);

   // Cache
   cachedPoint = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   cachedDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   cachedTickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   cachedTickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   // Ajusta offsets para respeitar stops_level
   adjustedOffsetPoints = MathMax(OffsetPoints, stopsLevel + 2);
   adjustedStopLossPoints = MathMax(StopLossPoints, stopsLevel + 2);

   // Inicializa arrays
   ArrayResize(buyPyramid, 0);
   ArrayResize(sellPyramid, 0);
   ArrayResize(buyStopTickets, 0);
   ArrayResize(sellStopTickets, 0);

   maxEquityReached = AccountInfoDouble(ACCOUNT_EQUITY);
   CalculateAverageSpread();

   // Aplica cores personalizadas ao gráfico
   ApplyCustomChartColors();

   // Inicialização Trailing Master (Ordem Cirúrgica)
   Print("Master Trailing: Inicializando engine...");
   trailing.Init(MagicNumber, _Symbol);
   trailing.SetThrottle(InpThrottleMS);
   trailing.SetMaxSpread(InpMaxSpreadAllowed);
   trailing.SetOnlyAboveEntry(InpOnlyInProfit);
   trailing.SetAdaptiveScaling(InpAdaptiveScaling);
   trailing.SetClusterMode(InpClusterMode);

   // Configurações Específicas (Surgical Setup)
   trailing.SetATR(InpATRPeriod, InpATRMultiplier, InpATRStructuralFactor);
   trailing.SetPSAR(InpPSARStep, InpPSARMax);
   trailing.SetMA(InpMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   trailing.SetHL(InpHLCount);
   trailing.SetBollinger(20, 2.0);
   trailing.SetFractals();
   trailing.SetStep(InpStepSizePts, InpStepMinProfitPts);
   trailing.SetBreakeven(InpBEActivationPts, InpBELockProfitPts);

   // Ativação Final do Modo
   trailing.SetMode(InpUseAdvancedTrailing ? InpTrailingMode : TRL_MODE_NONE);
   Print("Master Trailing: Engine configurada. Modo: ", EnumToString(InpTrailingMode), " Ativo: ", InpUseAdvancedTrailing);

   Print("═══════════════════════════════════════════════");
   Print("JM2000 EA V1 Inicializada");
   Print("Ordens Iniciais: ", InitialOrdersCount);
   Print("Stops Level: ", stopsLevel, " pts");
   Print("Freeze Level: ", freezeLevel, " pts");
   Print("Offset Ajustado: ", adjustedOffsetPoints, " pts");
   Print("SL Ajustado: ", adjustedStopLossPoints, " pts");
   Print("Cores: BUY=", ColorToString(CandleBullColor),
         " | SELL=", ColorToString(CandleBearColor));
   Print("═══════════════════════════════════════════════");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
   UpdatePriceCache();
   UpdateATRCache();
   MonitorDrawdownAndSafeMode();

   if(!IsMarketConditionSafe()) return;

   CheckActivePositions();
   UpdatePyramidArrays();

   // Trailing Master Integration
   if(InpUseAdvancedTrailing)
   {
      static uint last_call_print = 0;
      if(GetTickCount() - last_call_print > 5000) { Print("Master Trailing: Process Heartbeat (Positions: ", PositionsTotal(), ")"); last_call_print = GetTickCount(); }

      trailing.Process();
   }
   else
   {
      if(UseUnifiedStops && positionActive) {
         ApplyUnifiedTrailingStop();
      } else {
         ApplyTrailingStop();
      }
   }

   if(!positionActive) {
      ManageDynamicPendingOrders();
   } else {
      ManageOrdersWithActivePosition();
   }

   if(EnablePyramid && positionActive && !safeModeActive) {
      ManagePyramidSystem();
   }

   DisplayStatusInfo();
}

//+------------------------------------------------------------------+
//| Preço válido para pending SEMPRE relativo a Bid/Ask |
//+------------------------------------------------------------------+
double GetValidPendingPrice(bool isBuy, int additionalOffset = 0) {
   // NUNCA usar SYMBOL_LAST para pending orders
   int totalOffset = adjustedOffsetPoints + additionalOffset;
   double minDist = totalOffset * cachedPoint;

   if(isBuy) {
      // BUY_STOP: price > Ask + stops_level
      return NormalizeDouble(cachedAsk + minDist, cachedDigits);
   } else {
      // SELL_STOP: price < Bid - stops_level
      return NormalizeDouble(cachedBid - minDist, cachedDigits);
   }
}

//+------------------------------------------------------------------+
//| SL válido calculado APÓS preço final confirmado   |
//+------------------------------------------------------------------+
double CalculateValidSL(double orderPrice, bool isBuy) {
   // SL sempre calculado DEPOIS do preço estar confirmado
   int minSL = MathMax(stopsLevel + 2, adjustedStopLossPoints);
   double dist = minSL * cachedPoint;

   if(isBuy) {
      // BUY: SL ABAIXO do preço
      return NormalizeDouble(orderPrice - dist, cachedDigits);
   } else {
      // SELL: SL ACIMA do preço
      return NormalizeDouble(orderPrice + dist, cachedDigits);
   }
}

//+------------------------------------------------------------------+
//| Verifica se pode modificar ordem (freeze level)   |
//+------------------------------------------------------------------+
bool CanModifyOrder(ulong ticket) {
   if(!OrderSelect(ticket)) return false;
   if(freezeLevel <= 0) return true; // Sem freeze level

   double orderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
   long orderType = OrderGetInteger(ORDER_TYPE);

   // Referência correta baseada no tipo
   double refPrice = (orderType == ORDER_TYPE_BUY_STOP) ? cachedAsk : cachedBid;
   double distance = MathAbs(orderPrice - refPrice);

   // Margem de segurança de 2 pontos
   bool canModify = distance > (freezeLevel + 2) * cachedPoint;

   if(!canModify && ShowChartInfo) {
      Print("Ordem #", ticket, " em FREEZE LEVEL (dist: ", distance/cachedPoint, " pts)");
   }

   return canModify;
}

//+------------------------------------------------------------------+
//| Filling mode 100% compatível ECN                  |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillingMode() {
   // REGRA MT5 CRÍTICA:
   // PENDING ORDERS (BUY_STOP/SELL_STOP) → SEMPRE ORDER_FILLING_RETURN
   // Tentar usar IOC ou FOK em pending = INVALID_REQUEST

   return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| Filling mode para MARKET orders (fechar posições)                |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetMarketFilling() {
   int mode = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);

   // Preferência: IOC > FOK > RETURN
   if(mode == 2 || mode == 3) {  // IOC suportado
      return ORDER_FILLING_IOC;
   }

   if(mode == 1) {  // Apenas FOK
      return ORDER_FILLING_FOK;
   }

   // Padrão
   return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| Normaliza volume respeitando limites do broker                   |
//+------------------------------------------------------------------+
double NormalizeVolume(double volume) {
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   // Respeita limites
   volume = MathMax(volume, minLot);
   volume = MathMin(volume, maxLot);

   // Respeita step
   if(stepLot > 0) {
      volume = MathRound(volume / stepLot) * stepLot;
   }

   return NormalizeDouble(volume, 2);
}

//+------------------------------------------------------------------+
//| Atualiza cache de preços                                         |
//+------------------------------------------------------------------+
void UpdatePriceCache() {
   cachedBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   cachedAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   cachedSpread = (cachedAsk - cachedBid) / cachedPoint;
}

//+------------------------------------------------------------------+
//| Atualiza ATR                                                     |
//+------------------------------------------------------------------+
void UpdateATRCache() {
   datetime currentTime = TimeCurrent();
   if(currentTime - lastATRUpdate < 60) return;

   int atrHandle = iATR(_Symbol, PERIOD_M1, 14);
   if(atrHandle == INVALID_HANDLE) return;

   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);

   if(CopyBuffer(atrHandle, 0, 0, 1, atrBuffer) > 0) {
      cachedATR = atrBuffer[0];
      lastATRUpdate = currentTime;
   }

   IndicatorRelease(atrHandle);
}

//+------------------------------------------------------------------+
//| Calcula spread médio                                             |
//+------------------------------------------------------------------+
void CalculateAverageSpread() {
   static double spreadHistory[100];
   static int spreadIndex = 0;

   spreadHistory[spreadIndex] = cachedSpread;
   spreadIndex = (spreadIndex + 1) % 100;

   double sum = 0;
   int count = 0;

   for(int i = 0; i < 100; i++) {
      if(spreadHistory[i] > 0) {
         sum += spreadHistory[i];
         count++;
      }
   }

   if(count > 0) {
      averageSpread = sum / count;
   }
}

//+------------------------------------------------------------------+
//| Monitora drawdown e Safe Mode                                    |
//+------------------------------------------------------------------+
void MonitorDrawdownAndSafeMode() {
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(currentEquity > maxEquityReached) {
      maxEquityReached = currentEquity;
   }

   double drawdown = 0;
   if(maxEquityReached > 0) {
      drawdown = ((maxEquityReached - currentEquity) / maxEquityReached) * 100.0;
   }

   if(drawdown >= MaxDrawdownPercent) {
      if(!safeModeActive) {
         Print("SAFE MODE ATIVADO - Drawdown: ", DoubleToString(drawdown, 2), "%");
         safeModeActive = true;
      }
   } else {
      if(safeModeActive && drawdown < MaxDrawdownPercent * 0.7) {
         Print("SAFE MODE DESATIVADO");
         safeModeActive = false;
         consecutiveErrors = 0;
      }
   }

   if(SafeModeOnErrors && consecutiveErrors >= MaxConsecutiveErrors) {
      if(!safeModeActive) {
         Print("SAFE MODE ATIVADO - Erros: ", consecutiveErrors);
         safeModeActive = true;
      }
   }
}

//+------------------------------------------------------------------+
//| Verifica condições de mercado                                    |
//+------------------------------------------------------------------+
bool IsMarketConditionSafe() {
   if(UseSpreadFilter) {
      CalculateAverageSpread();
      if(averageSpread > 0 && cachedSpread > averageSpread * MaxSpreadMultiplier) {
         return false;
      }
   }

   if(UseTimeFilter) {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);

      if(dt.day_of_week == 5) {
         int minutesUntilClose = (24 * 60) - (dt.hour * 60 + dt.min);
         if(minutesUntilClose <= AvoidLastMinutesFriday) {
            return false;
         }
      }

      if(dt.day_of_week == 0) {
         int minutesSinceOpen = dt.hour * 60 + dt.min;
         if(minutesSinceOpen <= AvoidFirstMinutesSunday) {
            return false;
         }
      }
   }

   if(safeModeActive) return false;

   return true;
}

//+------------------------------------------------------------------+
//| UpdatePoints adaptativo                                          |
//+------------------------------------------------------------------+
int GetAdaptiveUpdatePoints() {
   if(!UseAdaptiveUpdate) return UpdatePoints;

   double atrPoints = 0;
   if(cachedATR > 0 && cachedPoint > 0) {
      atrPoints = cachedATR / cachedPoint * 0.2;
   }

   double spreadPoints = cachedSpread * 1.5;

   int adaptive = (int)MathMax(atrPoints, spreadPoints);
   adaptive = MathMax(adaptive, UpdatePoints);

   return adaptive;
}

//+------------------------------------------------------------------+
//| Verifica posições ativas                                         |
//+------------------------------------------------------------------+
void CheckActivePositions() {
   int buyCount = 0;
   int sellCount = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
            long type = PositionGetInteger(POSITION_TYPE);
            if(type == POSITION_TYPE_BUY) {
               buyCount++;
               currentPositionType = POSITION_TYPE_BUY;
            } else if(type == POSITION_TYPE_SELL) {
               sellCount++;
               currentPositionType = POSITION_TYPE_SELL;
            }
         }
      }
   }

   positionActive = (buyCount > 0 || sellCount > 0);

   if(buyCount > 0 && sellCount > 0) {
      CloseOppositePositions();
   }
}

//+------------------------------------------------------------------+
//| Conta total de ordens                                            |
//+------------------------------------------------------------------+
int GetTotalOpenOrdersAndPositions() {
   int total = 0;

   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket)) {
         if(OrderGetInteger(ORDER_MAGIC) == MagicNumber) {
            total++;
         }
      }
   }

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
            total++;
         }
      }
   }

   return total;
}

//+------------------------------------------------------------------+
//| Verifica se pode abrir mais ordens                               |
//+------------------------------------------------------------------+
bool CanOpenMoreOrders() {
   if(MaxTotalOrders == 0) return true;

   int currentTotal = GetTotalOpenOrdersAndPositions();
   return (currentTotal < MaxTotalOrders);
}

//+------------------------------------------------------------------+
//| Calcula lote dinâmico                                            |
//+------------------------------------------------------------------+
double CalculateDynamicLot(int pyramidLevel = 0) {
   if(!UseDynamicLot) {
      if(pyramidLevel > 0 && EnablePyramid) {
         return NormalizeVolume(Lots * MathPow(PyramidMultiplier, pyramidLevel));
      }
      return Lots;
   }

   double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double accountEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);

   double baseValue = MathMin(accountBalance, accountEquity);

   double effectiveRisk = RiskPercent;
   if(EnablePyramid && PyramidLevels > 0) {
      effectiveRisk = RiskPercent / PyramidLevels;
   }

   double riskAmount = baseValue * (effectiveRisk / 100.0);

   double pointValue = 0;
   if(cachedTickSize > 0) {
      pointValue = (cachedTickValue / cachedTickSize) * cachedPoint;
   } else {
      pointValue = cachedPoint * 10;
   }

   if(pointValue <= 0) return Lots;

   double calculatedLot = 0;
   if(adjustedStopLossPoints > 0) {
      calculatedLot = riskAmount / (adjustedStopLossPoints * pointValue);
   } else {
      calculatedLot = Lots;
   }

   if(pyramidLevel > 0 && EnablePyramid) {
      calculatedLot *= MathPow(PyramidMultiplier, pyramidLevel);
   }

   calculatedLot = MathMin(calculatedLot, MaxLotSize);

   double requiredMargin = 0;
   if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, calculatedLot, cachedAsk, requiredMargin)) {
      double safeMargin = freeMargin * ((100.0 - MarginSafetyPercent) / 100.0);

      if(requiredMargin > safeMargin) {
         double marginRatio = safeMargin / requiredMargin;
         calculatedLot *= marginRatio;
      }
   }

   return NormalizeVolume(calculatedLot);
}

//+------------------------------------------------------------------+
//| Verifica margem suficiente                                       |
//+------------------------------------------------------------------+
bool HasSufficientMargin(double volume) {
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double requiredMargin = 0;

   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, volume, cachedAsk, requiredMargin)) {
      return false;
   }

   double safeMargin = freeMargin * ((100.0 - MarginSafetyPercent) / 100.0);

   return (requiredMargin <= safeMargin);
}

//+------------------------------------------------------------------+
//| Bloqueia updates no mesmo tick                    |
//+------------------------------------------------------------------+
void ManageDynamicPendingOrders() {
   if(!CanOpenMoreOrders()) return;
   if(orderUpdateInProgress) return;

   // Não modifica pendings no mesmo segundo
   datetime currentTime = TimeCurrent();
   if(currentTime - lastOrderUpdateTime < 2) {
      return;
   }

   double tradeLot = CalculateDynamicLot(0);

   if(UseDynamicLot && !HasSufficientMargin(tradeLot * InitialOrdersCount)) {
      if(ShowChartInfo) {
         Print("Margem insuficiente para ", InitialOrdersCount, " ordens");
      }
      return;
   }

   // Usa função corrigida para preços
   double buyStopPrice = GetValidPendingPrice(true, 0);
   double sellStopPrice = GetValidPendingPrice(false, 0);

   // SL calculado APÓS preço confirmado
   double buyStopSL = CalculateValidSL(buyStopPrice, true);
   double sellStopSL = CalculateValidSL(sellStopPrice, false);

   int adaptiveUpdate = GetAdaptiveUpdatePoints();

   //--- BUY STOPS
   int currentBuyOrders = ArraySize(buyStopTickets);

   if(currentBuyOrders == 0) {
      CreateMultipleBuyStops(buyStopPrice, buyStopSL, tradeLot, InitialOrdersCount);
      lastOrderUpdateTime = currentTime;
   } else {
      UpdateBuyStopOrders(buyStopPrice, buyStopSL, tradeLot, adaptiveUpdate);
   }

   //--- SELL STOPS
   int currentSellOrders = ArraySize(sellStopTickets);

   if(currentSellOrders == 0) {
      CreateMultipleSellStops(sellStopPrice, sellStopSL, tradeLot, InitialOrdersCount);
      lastOrderUpdateTime = currentTime;
   } else {
      UpdateSellStopOrders(sellStopPrice, sellStopSL, tradeLot, adaptiveUpdate);
   }
}

//+------------------------------------------------------------------+
//| Cria múltiplas BUY Stops com validação completa    |
//+------------------------------------------------------------------+
bool CreateMultipleBuyStops(double basePrice, double baseSL, double lotSize, int count) {
   if(count < 1) return false;

   ArrayResize(buyStopTickets, 0);

   MqlTradeRequest requests[];
   ArrayResize(requests, count);

   int validRequests = 0;

   // Fase 1: PREPARA todas as requisições
   for(int i = 0; i < count; i++) {
      // Preço com espaçamento (sempre válido)
      double orderPrice = GetValidPendingPrice(true, (int)(i * SpacingPoints));

      // SL recalculado para cada preço
      double orderSL = CalculateValidSL(orderPrice, true);

      // Validação final
      if(orderPrice <= cachedAsk) {
         if(ShowChartInfo) Print("BUY #", i+1, " preço inválido - pulando");
         continue;
      }

      if(orderSL >= orderPrice) {
         if(ShowChartInfo) Print("BUY #", i+1, " SL invertido - pulando");
         continue;
      }

      // Zera memória ANTES de preencher
      ZeroMemory(requests[validRequests]);

      requests[validRequests].action = TRADE_ACTION_PENDING;
      requests[validRequests].symbol = _Symbol;
      requests[validRequests].volume = lotSize;
      requests[validRequests].type = ORDER_TYPE_BUY_STOP;
      requests[validRequests].price = orderPrice;
      requests[validRequests].sl = orderSL;
      requests[validRequests].tp = 0.0;
      requests[validRequests].magic = MagicNumber;
      requests[validRequests].type_filling = ORDER_FILLING_RETURN;  // PENDING = RETURN (HARDCODED)
      requests[validRequests].type_time = ORDER_TIME_GTC;           // OBRIGATÓRIO para ECN
      requests[validRequests].deviation = 0;                        // NÃO usar em pending

      validRequests++;
   }

   if(validRequests == 0) {
      if(ShowChartInfo) Print("Nenhuma ordem BUY válida");
      return false;
   }

   // Fase 2: ENVIA todas rapidamente
   int successCount = 0;

   if(ShowChartInfo) {
      Print("Enviando ", validRequests, " BUY Stops...");
   }

   for(int i = 0; i < validRequests; i++) {
      MqlTradeResult result = {};

      // VALIDAÇÃO FINAL: Atualiza preços e verifica novamente
      UpdatePriceCache();
      double finalPrice = requests[i].price;
      double finalSL = requests[i].sl;

      // Verifica se preço ainda é válido (Ask pode ter mudado)
      if(finalPrice <= cachedAsk) {
         if(ShowChartInfo) {
            Print("BUY #", i+1, " REJEITADA: preço ", finalPrice,
                  " <= Ask ", cachedAsk, " - recalculando...");
         }

         // Recalcula com preço atual
         finalPrice = GetValidPendingPrice(true, (int)(i * SpacingPoints));
         finalSL = CalculateValidSL(finalPrice, true);

         requests[i].price = finalPrice;
         requests[i].sl = finalSL;
      }

      if(ShowChartInfo) {
         Print("BUY #", i+1, ": Price=", finalPrice, " Ask=", cachedAsk,
               " SL=", finalSL, " Dist=", (finalPrice - cachedAsk)/cachedPoint, " pts");
      }

      // Valida retcode corretamente
      if(OrderSend(requests[i], result) &&
         (result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)) {

         int size = ArraySize(buyStopTickets);
         ArrayResize(buyStopTickets, size + 1);
         buyStopTickets[size] = result.order;
         successCount++;
         consecutiveErrors = 0;
      } else {
         if(ShowChartInfo) {
            Print("BUY #", i+1, " falhou: ", result.retcode, " - ", result.comment);
         }
         HandleTradeError(result.retcode);
      }

      // Micro-delay apenas se rate limit
      if(result.retcode == TRADE_RETCODE_LIMIT_ORDERS || result.retcode == TRADE_RETCODE_REQUOTE) {
         Sleep(10);
      }
   }

   if(successCount > 0) {
      lastBuyPrice = basePrice;
      Print(successCount, "/", validRequests, " BUY Stops criadas");
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Cria múltiplas SELL Stops com validação completa   |
//+------------------------------------------------------------------+
bool CreateMultipleSellStops(double basePrice, double baseSL, double lotSize, int count) {
   if(count < 1) return false;

   ArrayResize(sellStopTickets, 0);

   MqlTradeRequest requests[];
   ArrayResize(requests, count);

   int validRequests = 0;

   for(int i = 0; i < count; i++) {
      double orderPrice = GetValidPendingPrice(false, (int)(i * SpacingPoints));
      double orderSL = CalculateValidSL(orderPrice, false);

      if(orderPrice >= cachedBid) {
         if(ShowChartInfo) Print("SELL #", i+1, " preço inválido - pulando");
         continue;
      }

      if(orderSL <= orderPrice) {
         if(ShowChartInfo) Print("SELL #", i+1, " SL invertido - pulando");
         continue;
      }

      // Zera memória ANTES de preencher
      ZeroMemory(requests[validRequests]);

      requests[validRequests].action = TRADE_ACTION_PENDING;
      requests[validRequests].symbol = _Symbol;
      requests[validRequests].volume = lotSize;
      requests[validRequests].type = ORDER_TYPE_SELL_STOP;
      requests[validRequests].price = orderPrice;
      requests[validRequests].sl = orderSL;
      requests[validRequests].tp = 0.0;
      requests[validRequests].magic = MagicNumber;
      requests[validRequests].type_filling = ORDER_FILLING_RETURN;  // PENDING = RETURN (HARDCODED)
      requests[validRequests].type_time = ORDER_TIME_GTC;           // OBRIGATÓRIO para ECN
      requests[validRequests].deviation = 0;                        // NÃO usar em pending

      validRequests++;
   }

   if(validRequests == 0) {
      if(ShowChartInfo) Print("Nenhuma ordem SELL válida");
      return false;
   }

   int successCount = 0;

   if(ShowChartInfo) {
      Print("Enviando ", validRequests, " SELL Stops...");
   }

   for(int i = 0; i < validRequests; i++) {
      MqlTradeResult result = {};

      // VALIDAÇÃO FINAL: Atualiza preços e verifica novamente
      UpdatePriceCache();
      double finalPrice = requests[i].price;
      double finalSL = requests[i].sl;

      // Verifica se preço ainda é válido (Bid pode ter mudado)
      if(finalPrice >= cachedBid) {
         if(ShowChartInfo) {
            Print("SELL #", i+1, " REJEITADA: preço ", finalPrice,
                  " >= Bid ", cachedBid, " - recalculando...");
         }

         // Recalcula com preço atual
         finalPrice = GetValidPendingPrice(false, (int)(i * SpacingPoints));
         finalSL = CalculateValidSL(finalPrice, false);

         requests[i].price = finalPrice;
         requests[i].sl = finalSL;
      }

      if(ShowChartInfo) {
         Print("SELL #", i+1, ": Price=", finalPrice, " Bid=", cachedBid,
               " SL=", finalSL, " Dist=", (cachedBid - finalPrice)/cachedPoint, " pts");
      }

      if(OrderSend(requests[i], result) &&
         (result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)) {

         int size = ArraySize(sellStopTickets);
         ArrayResize(sellStopTickets, size + 1);
         sellStopTickets[size] = result.order;
         successCount++;
         consecutiveErrors = 0;
      } else {
         if(ShowChartInfo) {
            Print("SELL #", i+1, " falhou: ", result.retcode, " - ", result.comment);
         }
         HandleTradeError(result.retcode);
      }

      if(result.retcode == TRADE_RETCODE_LIMIT_ORDERS || result.retcode == TRADE_RETCODE_REQUOTE) {
         Sleep(10);
      }
   }

   if(successCount > 0) {
      lastSellPrice = basePrice;
      Print(successCount, "/", validRequests, " SELL Stops criadas");
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Atualiza BUY stops (com proteção freeze) - FIXED   |
//+------------------------------------------------------------------+
void UpdateBuyStopOrders(double newPrice, double newSL, double lotSize, int updateThreshold) {
   // Remove tickets inválidos - FIXED: usando função helper
   for(int i = ArraySize(buyStopTickets) - 1; i >= 0; i--) {
      if(!OrderSelect(buyStopTickets[i])) {
         RemoveArrayElement(buyStopTickets, i);
      }
   }

   int currentCount = ArraySize(buyStopTickets);

   if(currentCount == 0) {
      ArrayResize(buyStopTickets, 0);
      return;
   }

   if(currentCount > 0 && OrderSelect(buyStopTickets[0])) {
      double firstPrice = OrderGetDouble(ORDER_PRICE_OPEN);
      double diffPoints = MathAbs(newPrice - firstPrice) / cachedPoint;

      if(diffPoints >= updateThreshold) {
         // Só cancela se NÃO estiver em freeze
         bool canCancel = false;
         for(int i = 0; i < currentCount; i++) {
            if(CanModifyOrder(buyStopTickets[i])) {
               canCancel = true;
               break;
            }
         }

         if(canCancel) {
            for(int i = 0; i < currentCount; i++) {
               if(CanModifyOrder(buyStopTickets[i])) {
                  CancelOrder(buyStopTickets[i]);
               }
            }
            ArrayResize(buyStopTickets, 0);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Atualiza SELL stops (com proteção freeze) - FIXED  |
//+------------------------------------------------------------------+
void UpdateSellStopOrders(double newPrice, double newSL, double lotSize, int updateThreshold) {
   // FIXED: usando função helper
   for(int i = ArraySize(sellStopTickets) - 1; i >= 0; i--) {
      if(!OrderSelect(sellStopTickets[i])) {
         RemoveArrayElement(sellStopTickets, i);
      }
   }

   int currentCount = ArraySize(sellStopTickets);

   if(currentCount == 0) {
      ArrayResize(sellStopTickets, 0);
      return;
   }

   if(currentCount > 0 && OrderSelect(sellStopTickets[0])) {
      double firstPrice = OrderGetDouble(ORDER_PRICE_OPEN);
      double diffPoints = MathAbs(newPrice - firstPrice) / cachedPoint;

      if(diffPoints >= updateThreshold) {
         bool canCancel = false;
         for(int i = 0; i < currentCount; i++) {
            if(CanModifyOrder(sellStopTickets[i])) {
               canCancel = true;
               break;
            }
         }

         if(canCancel) {
            for(int i = 0; i < currentCount; i++) {
               if(CanModifyOrder(sellStopTickets[i])) {
                  CancelOrder(sellStopTickets[i]);
               }
            }
            ArrayResize(sellStopTickets, 0);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Tratamento de erros                                              |
//+------------------------------------------------------------------+
void HandleTradeError(uint retcode) {
   consecutiveErrors++;

   switch(retcode) {
      case TRADE_RETCODE_REQUOTE:
         if(ShowChartInfo) Print("Requote");
         break;
      case TRADE_RETCODE_REJECT:
         if(ShowChartInfo) Print("Rejeitada");
         break;
      case TRADE_RETCODE_PRICE_CHANGED:
         if(ShowChartInfo) Print("Preço mudou");
         break;
      case TRADE_RETCODE_INVALID_STOPS:
         if(ShowChartInfo) Print("Stops inválidos");
         break;
      case TRADE_RETCODE_FROZEN:
         if(ShowChartInfo) Print("Freeze level");
         break;
      case TRADE_RETCODE_INVALID_PRICE:
         if(ShowChartInfo) Print("Preço inválido");
         break;
      default:
         if(ShowChartInfo) Print("Erro: ", retcode);
   }
}

//+------------------------------------------------------------------+
//| Gerencia ordens com posição ativa                                |
//+------------------------------------------------------------------+
void ManageOrdersWithActivePosition() {
   if(currentPositionType == POSITION_TYPE_BUY) {
      for(int i = 0; i < ArraySize(sellStopTickets); i++) {
         if(CanModifyOrder(sellStopTickets[i])) {
            CancelOrder(sellStopTickets[i]);
         }
      }
      ArrayResize(sellStopTickets, 0);
      RemoveAllSellPendingOrders();

   } else if(currentPositionType == POSITION_TYPE_SELL) {
      for(int i = 0; i < ArraySize(buyStopTickets); i++) {
         if(CanModifyOrder(buyStopTickets[i])) {
            CancelOrder(buyStopTickets[i]);
         }
      }
      ArrayResize(buyStopTickets, 0);
      RemoveAllBuyPendingOrders();
   }
}

//+------------------------------------------------------------------+
//| Remove ordens BUY pendentes                                      |
//+------------------------------------------------------------------+
void RemoveAllBuyPendingOrders() {
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket)) {
         if(OrderGetInteger(ORDER_MAGIC) == MagicNumber) {
            long type = OrderGetInteger(ORDER_TYPE);
            if(type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_LIMIT) {
               if(CanModifyOrder(ticket)) {
                  CancelOrder(ticket);
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Remove ordens SELL pendentes                                     |
//+------------------------------------------------------------------+
void RemoveAllSellPendingOrders() {
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket)) {
         if(OrderGetInteger(ORDER_MAGIC) == MagicNumber) {
            long type = OrderGetInteger(ORDER_TYPE);
            if(type == ORDER_TYPE_SELL_STOP || type == ORDER_TYPE_SELL_LIMIT) {
               if(CanModifyOrder(ticket)) {
                  CancelOrder(ticket);
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Fecha posições opostas                                           |
//+------------------------------------------------------------------+
void CloseOppositePositions() {
   int buyCount = 0;
   int sellCount = 0;
   datetime latestBuyTime = 0;
   datetime latestSellTime = 0;
   ulong latestBuyTicket = 0;
   ulong latestSellTicket = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
            long type = PositionGetInteger(POSITION_TYPE);
            datetime time = (datetime)PositionGetInteger(POSITION_TIME);

            if(type == POSITION_TYPE_BUY) {
               buyCount++;
               if(time > latestBuyTime) {
                  latestBuyTime = time;
                  latestBuyTicket = ticket;
               }
            } else if(type == POSITION_TYPE_SELL) {
               sellCount++;
               if(time > latestSellTime) {
                  latestSellTime = time;
                  latestSellTicket = ticket;
               }
            }
         }
      }
   }

   if(buyCount > 0 && sellCount > 0) {
      if(latestBuyTime > latestSellTime) {
         ClosePosition(latestBuyTicket);
      } else {
         ClosePosition(latestSellTicket);
      }
   }
}

//+------------------------------------------------------------------+
//| Fecha posição                                                    |
//+------------------------------------------------------------------+
void ClosePosition(ulong ticket) {
   if(!PositionSelectByTicket(ticket)) return;

   long type = PositionGetInteger(POSITION_TYPE);
   double volume = PositionGetDouble(POSITION_VOLUME);

   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   request.action = TRADE_ACTION_DEAL;
   request.position = ticket;
   request.symbol = _Symbol;
   request.volume = volume;
   request.deviation = 10;
   request.magic = MagicNumber;
   request.type_filling = GetMarketFilling();  // MARKET usa GetMarketFilling()

   if(type == POSITION_TYPE_BUY) {
      request.type = ORDER_TYPE_SELL;
      request.price = cachedBid;
   } else {
      request.type = ORDER_TYPE_BUY;
      request.price = cachedAsk;
   }

   if(!OrderSend(request, result)) {
      if(ShowChartInfo) {
         Print("Erro ao fechar #", ticket, ": ", result.retcode);
      }
   }
}

//+------------------------------------------------------------------+
//| Cancela ordem                                                    |
//+------------------------------------------------------------------+
bool CancelOrder(ulong ticket) {
   if(ticket == 0) return false;

   // Verifica freeze level antes
   if(!CanModifyOrder(ticket)) return false;

   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   request.action = TRADE_ACTION_REMOVE;
   request.order = ticket;

   if(OrderSend(request, result) &&
      (result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)) {
      consecutiveErrors = 0;
      return true;
   } else {
      HandleTradeError(result.retcode);
      if(!OrderSelect(ticket)) {
         return true;
      }
      return false;
   }
}

//+------------------------------------------------------------------+
//| Atualiza arrays de pirâmide                                      |
//+------------------------------------------------------------------+
void UpdatePyramidArrays() {
   ArrayResize(buyPyramid, 0);
   ArrayResize(sellPyramid, 0);

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      long type = PositionGetInteger(POSITION_TYPE);
      PyramidLevel level;

      level.ticket = ticket;
      level.entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      level.volume = PositionGetDouble(POSITION_VOLUME);
      level.sl = PositionGetDouble(POSITION_SL);
      level.entryTime = (datetime)PositionGetInteger(POSITION_TIME);

      double currentProfit = PositionGetDouble(POSITION_PROFIT);
      level.maxProfit = MathMax(level.maxProfit, currentProfit);

      if(type == POSITION_TYPE_BUY) {
         int size = ArraySize(buyPyramid);
         ArrayResize(buyPyramid, size + 1);
         buyPyramid[size] = level;
      } else if(type == POSITION_TYPE_SELL) {
         int size = ArraySize(sellPyramid);
         ArrayResize(sellPyramid, size + 1);
         sellPyramid[size] = level;
      }
   }
}

//+------------------------------------------------------------------+
//| Gerencia pirâmide                                                |
//+------------------------------------------------------------------+
void ManagePyramidSystem() {
   if(!positionActive) return;

   ManagePyramidLevels();

   // Se Trailing Master estiver ativo, ele já cuida de todas as posições
   if(!InpUseAdvancedTrailing && PyramidTrailing && !UseUnifiedStops) {
      ApplyPyramidTrailing();
   }
}

//+------------------------------------------------------------------+
//| Gerencia níveis de pirâmide                                      |
//+------------------------------------------------------------------+
void ManagePyramidLevels() {
   if(currentPositionType == POSITION_TYPE_BUY) {
      int currentLevels = ArraySize(buyPyramid);

      if(currentLevels >= PyramidLevels) return;
      if(!CanOpenMoreOrders()) return;

      if(currentLevels == 0) return;

      PyramidLevel lastLevel = buyPyramid[currentLevels - 1];

      if(PyramidOnlyInProfit) {
         if(!PositionSelectByTicket(lastLevel.ticket)) return;
         double currentProfit = PositionGetDouble(POSITION_PROFIT);
         if(currentProfit <= 0) return;

         double requiredProfit = lastLevel.volume * PyramidDistance * cachedPoint * MinProfitForNextLevel;
         if(currentProfit < requiredProfit) return;
      }

      double currentPrice = cachedBid;
      double distanceFromLast = (currentPrice - lastLevel.entryPrice) / cachedPoint;

      if(distanceFromLast < PyramidDistance) return;

      if(PyramidTrendFollowing) {
         if(currentPrice <= lastLevel.entryPrice) return;
      }

      double newVolume = CalculateDynamicLot(currentLevels);

      if(!HasSufficientMargin(newVolume)) return;

      double entryPrice = GetValidPendingPrice(true, 0);
      double slPrice = CalculateValidSL(entryPrice, true);

      MqlTradeRequest request = {};
      MqlTradeResult result = {};

      // Zera memória ANTES de preencher
      ZeroMemory(request);

      request.action = TRADE_ACTION_PENDING;
      request.symbol = _Symbol;
      request.volume = newVolume;
      request.type = ORDER_TYPE_BUY_STOP;
      request.price = entryPrice;
      request.sl = slPrice;
      request.tp = 0.0;
      request.magic = MagicNumber;
      request.type_filling = ORDER_FILLING_RETURN;  // PENDING = RETURN
      request.type_time = ORDER_TIME_GTC;           // OBRIGATÓRIO para ECN
      request.deviation = 0;                        // NÃO usar em pending

      if(OrderSend(request, result) &&
         (result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)) {
         Print("Pirâmide BUY nível ", currentLevels + 1, " | Vol: ", newVolume);
      }
   } else if(currentPositionType == POSITION_TYPE_SELL) {
      int currentLevels = ArraySize(sellPyramid);

      if(currentLevels >= PyramidLevels) return;
      if(!CanOpenMoreOrders()) return;

      if(currentLevels == 0) return;

      PyramidLevel lastLevel = sellPyramid[currentLevels - 1];

      if(PyramidOnlyInProfit) {
         if(!PositionSelectByTicket(lastLevel.ticket)) return;
         double currentProfit = PositionGetDouble(POSITION_PROFIT);
         if(currentProfit <= 0) return;

         double requiredProfit = lastLevel.volume * PyramidDistance * cachedPoint * MinProfitForNextLevel;
         if(currentProfit < requiredProfit) return;
      }

      double currentPrice = cachedAsk;
      double distanceFromLast = (lastLevel.entryPrice - currentPrice) / cachedPoint;

      if(distanceFromLast < PyramidDistance) return;

      if(PyramidTrendFollowing) {
         if(currentPrice >= lastLevel.entryPrice) return;
      }

      double newVolume = CalculateDynamicLot(currentLevels);

      if(!HasSufficientMargin(newVolume)) return;

      double entryPrice = GetValidPendingPrice(false, 0);
      double slPrice = CalculateValidSL(entryPrice, false);

      MqlTradeRequest request = {};
      MqlTradeResult result = {};

      // Zera memória ANTES de preencher
      ZeroMemory(request);

      request.action = TRADE_ACTION_PENDING;
      request.symbol = _Symbol;
      request.volume = newVolume;
      request.type = ORDER_TYPE_SELL_STOP;
      request.price = entryPrice;
      request.sl = slPrice;
      request.tp = 0.0;
      request.magic = MagicNumber;
      request.type_filling = ORDER_FILLING_RETURN;  // PENDING = RETURN
      request.type_time = ORDER_TIME_GTC;           // OBRIGATÓRIO para ECN
      request.deviation = 0;                        // NÃO usar em pending

      if(OrderSend(request, result) &&
         (result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)) {
         Print("Pirâmide SELL nível ", currentLevels + 1, " | Vol: ", newVolume);
      }
   }
}

//+------------------------------------------------------------------+
//| Trailing unificado                                               |
//+------------------------------------------------------------------+
void ApplyUnifiedTrailingStop() {
   if(!positionActive) return;

   double avgEntry = 0;
   double totalVolume = 0;
   double minProfit = DBL_MAX;

   PyramidLevel levels[];

   if(currentPositionType == POSITION_TYPE_BUY) {
      ArrayCopy(levels, buyPyramid);
   } else if(currentPositionType == POSITION_TYPE_SELL) {
      ArrayCopy(levels, sellPyramid);
   } else {
      return;
   }

   int levelCount = ArraySize(levels);
   if(levelCount == 0) return;

   for(int i = 0; i < levelCount; i++) {
      avgEntry += levels[i].entryPrice * levels[i].volume;
      totalVolume += levels[i].volume;

      if(PositionSelectByTicket(levels[i].ticket)) {
         double profit = PositionGetDouble(POSITION_PROFIT);
         if(profit < minProfit) minProfit = profit;
      }
   }

   if(totalVolume <= 0) return;
   avgEntry /= totalVolume;

   if(minProfit <= 0) return;

   double newSL = 0;

   if(currentPositionType == POSITION_TYPE_BUY) {
      double trailDistance = TrailingStopPoints * cachedPoint;
      newSL = NormalizeDouble(cachedBid - trailDistance, cachedDigits);

      if(newSL <= avgEntry) return;

      for(int i = 0; i < levelCount; i++) {
         if(PositionSelectByTicket(levels[i].ticket)) {
            double currentSL = PositionGetDouble(POSITION_SL);

            if(newSL > currentSL + (TrailingStepPoints * cachedPoint)) {
               ModifyPositionSL(levels[i].ticket, newSL);
            }
         }
      }
   } else {
      double trailDistance = TrailingStopPoints * cachedPoint;
      newSL = NormalizeDouble(cachedAsk + trailDistance, cachedDigits);

      if(newSL >= avgEntry) return;

      for(int i = 0; i < levelCount; i++) {
         if(PositionSelectByTicket(levels[i].ticket)) {
            double currentSL = PositionGetDouble(POSITION_SL);

            if(currentSL == 0 || newSL < currentSL - (TrailingStepPoints * cachedPoint)) {
               ModifyPositionSL(levels[i].ticket, newSL);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Trailing individual                                              |
//+------------------------------------------------------------------+
void ApplyTrailingStop() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
            long type = PositionGetInteger(POSITION_TYPE);
            bool isBuy = (type == POSITION_TYPE_BUY);

            ApplyIndividualTrailing(ticket, isBuy);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Trailing de pirâmide                                             |
//+------------------------------------------------------------------+
void ApplyPyramidTrailing() {
   for(int i = 0; i < ArraySize(buyPyramid); i++) {
      ApplyIndividualTrailing(buyPyramid[i].ticket, true);
   }

   for(int i = 0; i < ArraySize(sellPyramid); i++) {
      ApplyIndividualTrailing(sellPyramid[i].ticket, false);
   }
}

//+------------------------------------------------------------------+
//| Trailing individual por ticket                                   |
//+------------------------------------------------------------------+
void ApplyIndividualTrailing(ulong ticket, bool isBuy) {
   if(!PositionSelectByTicket(ticket)) return;

   double currentSL = PositionGetDouble(POSITION_SL);
   double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);

   double trailDistance = TrailingStopPoints * cachedPoint;
   double stepDistance = TrailingStepPoints * cachedPoint;

   double newSL = 0;

   if(isBuy) {
      newSL = NormalizeDouble(cachedBid - trailDistance, cachedDigits);

      if(newSL <= entryPrice) return;

      if(currentSL == 0 || newSL > currentSL + stepDistance) {
         ModifyPositionSL(ticket, newSL);
      }
   } else {
      newSL = NormalizeDouble(cachedAsk + trailDistance, cachedDigits);

      if(newSL >= entryPrice) return;

      if(currentSL == 0 || newSL < currentSL - stepDistance) {
         ModifyPositionSL(ticket, newSL);
      }
   }
}

//+------------------------------------------------------------------+
//| Modifica SL                                                      |
//+------------------------------------------------------------------+
void ModifyPositionSL(ulong ticket, double newSL) {
   MqlTradeRequest request = {};
   MqlTradeResult result = {};

   request.action = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.symbol = _Symbol;
   request.sl = newSL;
   request.tp = 0.0;

   if(OrderSend(request, result) &&
      (result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)) {
      consecutiveErrors = 0;
   } else {
      HandleTradeError(result.retcode);
   }
}

//+------------------------------------------------------------------+
//| Verifica se trading é permitido                                 |
//+------------------------------------------------------------------+
bool IsTradeAllowed() {
   ENUM_SYMBOL_TRADE_MODE tradeMode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED) return false;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;

   double checkLot = CalculateDynamicLot(0);

   double margin;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, checkLot, cachedAsk, margin))
      return false;

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double safeMargin = freeMargin * ((100.0 - MarginSafetyPercent) / 100.0);

   return (margin <= safeMargin);
}

//+------------------------------------------------------------------+
//| Exibe informações                                                |
//+------------------------------------------------------------------+
void DisplayStatusInfo() {
   if(!ShowChartInfo) return;

   static int displayCounter = 0;
   displayCounter++;

   if(displayCounter >= 1000) {
      displayCounter = 0;

      string info = "";

      if(safeModeActive) {
         info = "SAFE MODE";
      } else if(positionActive) {
         int levels = 0;
         double totalProfit = 0;

         if(currentPositionType == POSITION_TYPE_BUY) {
            levels = ArraySize(buyPyramid);
            for(int i = 0; i < levels; i++) {
               if(PositionSelectByTicket(buyPyramid[i].ticket)) {
                  totalProfit += PositionGetDouble(POSITION_PROFIT);
               }
            }
            info = "BUY " + IntegerToString(levels) + "x | $" + DoubleToString(totalProfit, 2);
         } else {
            levels = ArraySize(sellPyramid);
            for(int i = 0; i < levels; i++) {
               if(PositionSelectByTicket(sellPyramid[i].ticket)) {
                  totalProfit += PositionGetDouble(POSITION_PROFIT);
               }
            }
            info = "SELL " + IntegerToString(levels) + "x | $" + DoubleToString(totalProfit, 2);
         }

         if(UseUnifiedStops) {
            info += " [UNIFIED]";
         }
      } else {
         info = "AGUARDANDO";
         if(InitialOrdersCount > 1) {
            info += " [" + IntegerToString(InitialOrdersCount) + " ordens]";
         }
      }

      if(MaxTotalOrders > 0) {
         int totalOrders = GetTotalOpenOrdersAndPositions();
         info += " | " + IntegerToString(totalOrders) + "/" + IntegerToString(MaxTotalOrders);
      }

      info += " | SP: " + DoubleToString(cachedSpread, 1);

      Comment(info);
   }
}

//+------------------------------------------------------------------+
//| Desinicialização                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   Comment("");

   int totalCanceled = 0;

   for(int i = 0; i < ArraySize(buyStopTickets); i++) {
      if(CanModifyOrder(buyStopTickets[i])) {
         if(CancelOrder(buyStopTickets[i])) {
            totalCanceled++;
         }
      }
   }

   for(int i = 0; i < ArraySize(sellStopTickets); i++) {
      if(CanModifyOrder(sellStopTickets[i])) {
         if(CancelOrder(sellStopTickets[i])) {
            totalCanceled++;
         }
      }
   }

   Print("═══════════════════════════════════════════════");
   Print("JM2000 EA V1 Finalizada");
   Print("Ordens canceladas: ", totalCanceled);
   Print("═══════════════════════════════════════════════");
}
