//+------------------------------------------------------------------+
//|                                              MT_LiveExecutor.mq5 |
//|                                  Copyright 2026, Jules (Bolt ⚡) |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Jules (Bolt ⚡)"
#property link      "https://www.mql5.com"
#property version   "9.10"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

//--- Global Variables & Constants
input string InpPrompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Não operar 20 min antes ou depois de notícias de alto impacto. Máximo 3 trades simultâneos. Ao atingir +30 pontos, move stop para entrada +5 pontos.";

enum Signal {BUY=1, SELL=-1, NONE=0};

struct Rule {
   bool     active;
   int      tf;
   int      p1, p2, p3;
   double   d1, d2;
   string   s1;
   int      handle; // Indicator handle caching
   Signal   (*func)(Rule&);
};

//--- Execution State
Rule rules[30];
int nRules = 0;
int dynamicSafetyPoints = 0;
datetime lastSafetyUpdate = 0;
datetime lastBarTime = 0;
string currentPrompt = "";

//--- Price Cache
double cachedBid = 0;
double cachedAsk = 0;
double cachedSpread = 0;
int stopsLevel = 0;

//--- Strategy Parameters parsed from prompt
int p_frequency = 0; // minutes
int p_startHour = 0;
int p_stopPoints = 0;
int p_takePoints = 0;
double p_riskPercent = 0;
int p_newsVetoMins = 0;
int p_maxSimultaneous = 100;
int p_breakevenTrigger = 0;
int p_breakevenProfit = 0;

//--- Objects
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symInfo;
CAccountInfo accInfo;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!symInfo.Name(_Symbol)) return INIT_FAILED;
   trade.SetExpertMagicNumber(123456);

   EventSetTimer(60); // For dynamic safety decay

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   // Release all cached indicator handles
   for(int i=0; i<nRules; i++) {
      if(rules[i].handle != INVALID_HANDLE) {
         IndicatorRelease(rules[i].handle);
         rules[i].handle = INVALID_HANDLE;
      }
   }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check for prompt changes
   if(InpPrompt != currentPrompt) {
      InterpretaPrompt(InpPrompt);
      currentPrompt = InpPrompt;
   }

   UpdatePriceCache();

   // Logic for position management (trailing, breakeven)
   GerenciaPosicoes();

   // Logic for entry
   if(VerificaFiltros()) {
      Signal s = AvaliaTudo();
      if(s != NONE) {
         executaSignal(s);
      }
   }
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Decay dynamic safety points every 60s
   if(dynamicSafetyPoints > 0) {
      dynamicSafetyPoints--;
   }

   // Periodic performance check
   AIOptimizer();
}

//+------------------------------------------------------------------+
//| TradeTransaction function                                        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD) {
      // Synchronize SL for the cluster on new entry
      SynchronizeClusterSL(trans.symbol);
   }
}

//--- Helper Functions for Parsing
int PeriodoTexto(string nome)
{
   StringToLower(nome);
   if(StringFind(nome, "m15") >= 0 || nome == "15") return PERIOD_M15;
   if(StringFind(nome, "m30") >= 0 || nome == "30") return PERIOD_M30;
   if(StringFind(nome, "m5")  >= 0 || nome == "5")  return PERIOD_M5;
   if(StringFind(nome, "m1")  >= 0 || nome == "1")  return PERIOD_M1;
   if(StringFind(nome, "h1")  >= 0 || nome == "60") return PERIOD_H1;
   if(StringFind(nome, "h4")  >= 0) return PERIOD_H4;
   if(StringFind(nome, "d1")  >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

double ExtraiNumero(string txt, string chave)
{
   int pos = StringFind(txt, chave);
   if(pos < 0) return 0;
   string sub = StringSubstr(txt, pos + StringLen(chave));
   return StringToDouble(sub);
}

//--- Helper placeholders (to be implemented in subsequent steps)
void InterpretaPrompt(string prompt)
{
   // 1. Cleanup old handles
   for(int i=0; i<nRules; i++) {
      if(rules[i].handle != INVALID_HANDLE) {
         IndicatorRelease(rules[i].handle);
         rules[i].handle = INVALID_HANDLE;
      }
   }
   ZeroMemory(rules);
   nRules = 0;
   lastBarTime = 0; // Reset bar tracking for new strategy

   string p = prompt;
   StringToLower(p);

   // 2. Global Strategy Parameters
   p_frequency = (int)ExtraiNumero(p, "cada ");
   p_startHour = (int)ExtraiNumero(p, "depois das ");
   p_stopPoints = (int)ExtraiNumero(p, "stop de ");
   p_takePoints = (int)ExtraiNumero(p, "take de ");
   p_riskPercent = ExtraiNumero(p, "risco de ");
   p_newsVetoMins = (int)ExtraiNumero(p, "não operar ");
   p_maxSimultaneous = (int)ExtraiNumero(p, "máximo ");
   if(p_maxSimultaneous == 0) p_maxSimultaneous = 100;

   // Breakeven logic
   p_breakevenTrigger = (int)ExtraiNumero(p, "atingir +");
   p_breakevenProfit = (int)ExtraiNumero(p, "entrada +");

   // 3. Signal Rule Detection (Multi-stage parsing)
   string parts[];
   int nParts = StringSplit(p, '.', parts);
   for(int i=0; i<nParts; i++) {
      AddRule(parts[i]);
   }

   PrintFormat("Bolt ⚡ Strategy Loaded: Freq=%d, Risk=%.2f%%, SL=%d, TP=%d, Max=%d",
               p_frequency, p_riskPercent, p_stopPoints, p_takePoints, p_maxSimultaneous);
}

//--- 1. MT5-KNOWLEDGE-CORE: Signals Implementation
Signal CruzamentoMA(Rule& r)
{
   if(r.handle == INVALID_HANDLE)
      r.handle = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_EMA, PRICE_CLOSE);

   double ma[2];
   if(CopyBuffer(r.handle, 0, 0, 2, ma) < 2) return NONE;

   double close[2];
   if(CopyClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0, 2, close) < 2) return NONE;

   // Price Cross Over MA
   if(close[1] <= ma[1] && close[0] > ma[0]) return BUY;
   if(close[1] >= ma[1] && close[0] < ma[0]) return SELL;

   return NONE;
}

Signal RSIThreshold(Rule& r)
{
   if(r.handle == INVALID_HANDLE)
      r.handle = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);

   double val[2];
   if(CopyBuffer(r.handle, 0, 0, 2, val) < 2) return NONE;

   // Check if thresholds are for trend-following or mean-reversion
   if(r.d1 > r.d2) { // e.g., Buy > 55, Sell < 45
      if(val[1] <= r.d1 && val[0] > r.d1) return BUY;
      if(val[1] >= r.d2 && val[0] < r.d2) return SELL;
   } else { // Mean Reversion
      if(val[0] < r.d1) return BUY;
      if(val[0] > r.d2) return SELL;
   }
   return NONE;
}

void AddRule(string txt)
{
   if(nRules >= 30) return;

   // MA Crossover / Price Crossover
   if(StringFind(txt, "média de") >= 0)
   {
      int per = (int)ExtraiNumero(txt, "média de ");
      rules[nRules].active = true;
      rules[nRules].tf = (p_frequency > 0) ? PeriodoTexto(IntegerToString(p_frequency)) : PERIOD_CURRENT;
      rules[nRules].p1 = per;
      rules[nRules].handle = INVALID_HANDLE;
      rules[nRules].func = &CruzamentoMA;
      nRules++;
   }

   // RSI
   if(StringFind(txt, "rsi") >= 0)
   {
      int per = (int)ExtraiNumero(txt, "rsi (");
      if(per == 0) per = 14;
      rules[nRules].active = true;
      rules[nRules].tf = (p_frequency > 0) ? PeriodoTexto(IntegerToString(p_frequency)) : PERIOD_CURRENT;
      rules[nRules].p1 = per;
      rules[nRules].d1 = ExtraiNumero(txt, "acima de ");
      rules[nRules].d2 = ExtraiNumero(txt, "abaixo de ");
      rules[nRules].handle = INVALID_HANDLE;
      rules[nRules].func = &RSIThreshold;
      nRules++;
   }
}

void UpdatePriceCache() {
   MqlTick tick;
   if(SymbolInfoTick(_Symbol, tick)) {
      cachedBid = tick.bid;
      cachedAsk = tick.ask;
      cachedSpread = (tick.ask - tick.bid) / _Point;
      stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   }
}
//--- Normalization Helpers
double NS(double price) { return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)); }
double NV(double volume) {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double v = MathFloor(volume/step)*step;
   double minV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   return MathMax(minV, MathMin(maxV, v));
}

bool VerificaFiltros()
{
   // 1. Time restriction
   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.hour < p_startHour) return false;

   // 2. Frequency restriction (only once per bar)
   datetime currentBar = iTime(_Symbol, (ENUM_TIMEFRAMES)PeriodoTexto(IntegerToString(p_frequency)), 0);
   if(currentBar == lastBarTime) return false;

   // 3. News restriction
   if(p_newsVetoMins > 0 && AguardaNoticias()) return false;

   // 4. Maximum simultaneous trades
   if(PositionsTotal() >= p_maxSimultaneous) return false;

   return true;
}

Signal AvaliaTudo()
{
   if(nRules == 0) return NONE;
   int voto = 0;
   for(int i=0; i<nRules; i++) {
      if(rules[i].active) {
         Signal s = rules[i].func(rules[i]);
         if(s == BUY) voto++;
         if(s == SELL) voto--;
      }
   }

   if(voto == nRules) return BUY; // Unanimous Buy
   if(voto == -nRules) return SELL; // Unanimous Sell

   return NONE;
}

void executaSignal(Signal s)
{
   if(s == NONE) return;

   double lote = CalculaLote(p_riskPercent);
   double sl = 0, tp = 0;
   double price = (s == BUY) ? cachedAsk : cachedBid;

   int safetyBuffer = stopsLevel + dynamicSafetyPoints + 2;

   if(s == BUY) {
      if(p_stopPoints > 0) sl = NS(price - MathMax(p_stopPoints, safetyBuffer) * _Point);
      if(p_takePoints > 0) tp = NS(price + p_takePoints * _Point);
      if(trade.Buy(lote, _Symbol, price, sl, tp)) {
         lastBarTime = iTime(_Symbol, (ENUM_TIMEFRAMES)PeriodoTexto(IntegerToString(p_frequency)), 0);
         GravaLog(StringFormat("COMPRA EXECUTADA: Lote=%.2f, SL=%.5f, TP=%.5f", lote, sl, tp));
      }
   } else {
      if(p_stopPoints > 0) sl = NS(price + MathMax(p_stopPoints, safetyBuffer) * _Point);
      if(p_takePoints > 0) tp = NS(price - p_takePoints * _Point);
      if(trade.Sell(lote, _Symbol, price, sl, tp)) {
         lastBarTime = iTime(_Symbol, (ENUM_TIMEFRAMES)PeriodoTexto(IntegerToString(p_frequency)), 0);
         GravaLog(StringFormat("VENDA EXECUTADA: Lote=%.2f, SL=%.5f, TP=%.5f", lote, sl, tp));
      }
   }
}

double CalculaLote(double riscoPercent)
{
   if(riscoPercent <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riscoAbs = capital * (riscoPercent / 100.0);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   int stopPts = (p_stopPoints > 0) ? p_stopPoints : 100; // Default if no SL
   double stopCost = (stopPts * _Point) * (tickValue / tickSize);

   if(stopCost <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   return NV(riscoAbs / stopCost);
}
void GerenciaPosicoes()
{
   if(p_breakevenTrigger <= 0) return;

   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(posInfo.SelectByTicket(ticket)) {
         if(posInfo.Symbol() != _Symbol) continue;

         double entry = posInfo.PriceOpen();
         double sl = posInfo.StopLoss();
         double currentPrice = (posInfo.PositionType() == POSITION_TYPE_BUY) ? cachedBid : cachedAsk;
         double profitPoints = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (currentPrice - entry)/_Point : (entry - currentPrice)/_Point;

         // Breakeven logic
         if(profitPoints >= p_breakevenTrigger) {
            double targetSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? entry + p_breakevenProfit*_Point : entry - p_breakevenProfit*_Point;

            // Only move if it improves protection
            bool shouldMove = false;
            if(posInfo.PositionType() == POSITION_TYPE_BUY && (sl < targetSL || sl == 0)) shouldMove = true;
            if(posInfo.PositionType() == POSITION_TYPE_SELL && (sl > targetSL || sl == 0)) shouldMove = true;

            if(shouldMove) {
               trade.PositionModify(ticket, NS(targetSL), posInfo.TakeProfit());
               GravaLog(StringFormat("BREAKEVEN ATIVADO: Ticket=%d em %.5f", ticket, targetSL));
            }
         }
      }
   }
}

void SynchronizeClusterSL(string symbol)
{
   if(symbol != _Symbol || p_stopPoints <= 0) return;

   double bestBuySL = 0;
   double bestSellSL = 0;

   // Find best SL in cluster
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(posInfo.SelectByTicket(ticket)) {
         if(posInfo.Symbol() != _Symbol) continue;
         double sl = posInfo.StopLoss();
         if(posInfo.PositionType() == POSITION_TYPE_BUY) {
            if(sl > bestBuySL) bestBuySL = sl;
         } else {
            if(bestSellSL == 0 || sl < bestSellSL) bestSellSL = sl;
         }
      }
   }

   // Sync all to the best SL
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(posInfo.SelectByTicket(ticket)) {
         if(posInfo.Symbol() != _Symbol) continue;
         double sl = posInfo.StopLoss();
         if(posInfo.PositionType() == POSITION_TYPE_BUY && bestBuySL > 0 && sl < bestBuySL) {
            trade.PositionModify(ticket, NS(bestBuySL), posInfo.TakeProfit());
         }
         if(posInfo.PositionType() == POSITION_TYPE_SELL && bestSellSL > 0 && (sl > bestSellSL || sl == 0)) {
            trade.PositionModify(ticket, NS(bestSellSL), posInfo.TakeProfit());
         }
      }
   }
}

bool AguardaNoticias()
{
   MqlCalendarValue values[];
   datetime from = TimeCurrent() - p_newsVetoMins * 60;
   datetime to = TimeCurrent() + p_newsVetoMins * 60;

   if(CalendarValueHistory(values, from, to, NULL, NULL) > 0) {
      for(int i=0; i<ArraySize(values); i++) {
         MqlCalendarEvent event;
         if(CalendarEventById(values[i].event_id, event)) {
            if(event.importance == CALENDAR_IMPORTANCE_HIGH) return true;
         }
      }
   }
   return false;
}
void AIOptimizer()
{
   if(!HistorySelect(0, TimeCurrent())) return;

   int total = HistoryDealsTotal();
   int wins = 0, losses = 0;
   double profit = 0, loss = 0;

   for(int i=0; i<total; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;

      double p = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      if(p > 0) { wins++; profit += p; }
      if(p < 0) { losses++; loss -= p; }
   }

   double winRate = (wins+losses > 0) ? (double)wins/(wins+losses)*100.0 : 0;
   double pf = (loss > 0) ? profit/loss : profit;

   PrintFormat("Bolt ⚡ AI Optimization: WinRate=%.1f%%, ProfitFactor=%.2f", winRate, pf);

   // Suggest risk adjustment based on performance
   if(winRate > 60 && pf > 2.0) {
      Print("Bolt ⚡ AI Suggestion: Strategy performing well. Consider increasing risk by 0.5%.");
   } else if(winRate < 40 && wins+losses > 10) {
      Print("Bolt ⚡ AI Suggestion: High loss rate. Consider tightening Stop Loss or reducing risk.");
   }
}

void GravaLog(string texto)
{
   Print("Bolt ⚡: ", texto);

   int handle = FileOpen("MT_LiveExecutor_Log.csv", FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      FileSeek(handle, 0, SEEK_END);
      FileWrite(handle, TimeToString(TimeCurrent()), _Symbol, texto);
      FileClose(handle);
   }
}
