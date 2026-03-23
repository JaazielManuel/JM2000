//+------------------------------------------------------------------+
//|                                              MT_LiveExecutor.mq5 |
//|                                  Copyright 2026, MT-LiveExecutor |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MT-LiveExecutor"
#property link      "https://www.mql5.com"
#property version   "8.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// ---------- ENUMS & STRUCTS ----------
enum Signal {BUY=1, SELL=-1, NONE=0};

enum RuleType {
   RT_MA_CROSS,
   RT_RSI,
   RT_STOCH,
   RT_BB,
   RT_DAILY_BREAK,
   RT_DELTA,
   RT_VOL_CYCLE,
   RT_AMA,
   RT_BAR_PATTERN,
   RT_RS_RELATIVE
};

struct Rule {
   bool      active;
   RuleType  type;
   ENUM_TIMEFRAMES tf;
   int       p1, p2, p3;
   double    d1, d2;
   string    s1;
   int       p1_handle;
   int       p2_handle;
   int       p3_handle;
   bool      is_cross;
};

// ---------- GLOBAL VARIABLES ----------
Rule     rules[30];
int      nRules = 0;
CTrade   trade;
CPositionInfo posInfo;
CSymbolInfo symInfo;
CAccountInfo accInfo;

// Strategy parameters
double   p_riskPercent = 1.0;
int      p_stopPoints = 300;
int      p_takePoints = 500;
int      p_trailingStopPoints = 0;
int      p_breakEvenPoints = 0;
int      p_breakEvenLock = 50;
int      p_maxTrades = 3;
bool     p_hedge = false;
bool     p_martingale = false;
int      p_newsVetoBefore = 20;
int      p_newsVetoAfter = 20;
int      p_startTimeHour = 0;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

datetime lastBarTime = 0;
int      dynamicSafetyPoints = 0;
datetime lastSafetyDecay = 0;
int      atrHandle = INVALID_HANDLE;

// ---------- CORE FUNCTIONS PROTOTYPES ----------
void InterpretaPrompt(string prompt);
void AddRule(RuleType type, ENUM_TIMEFRAMES tf, int p1=0, int p2=0, int p3=0, double d1=0, double d2=0, string s1="", bool is_cross=false);
double ExtraiNumero(string txt, string chave);
ENUM_TIMEFRAMES PeriodoTexto(string nome);
Signal AvaliaTudo();
double CalculaLote(double riscoPercent);
void EnviaOrdem(Signal s);
double CalculateValidSL(ENUM_POSITION_TYPE type, double price, int points);
void GerenciaPosicoes();
void SynchronizeClusterSL(ENUM_POSITION_TYPE type, double newSL);
bool AguardaNoticias();
void GravaCSV();
void AIOptimizer();
void UpdatePriceCache();

// Indicator Checkers
Signal CheckMA(int idx);
Signal CheckRSI(int idx);
Signal CheckStoch(int idx);
Signal CheckBB(int idx);
Signal CheckDailyBreak(int idx);
Signal CheckDelta(int idx);
Signal CheckVolCycle(int idx);
Signal CheckAMA(int idx);
Signal CheckBarPattern(int idx);
Signal CheckRSRelative(int idx);

// Helper functions for indicators
double GetIndicatorValue(int handle, int buffer, int shift);

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   EventSetTimer(60);
   symInfo.Name(_Symbol);
   atrHandle = iATR(_Symbol, PERIOD_D1, 14);

   // Initial prompt load
   if(GlobalVariableCheck("MT_Executor_Prompt_Update"))
      GlobalVariableSet("MT_Executor_Prompt_Update", 0);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);

   for(int i=0; i<nRules; i++) {
      if(rules[i].p1_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p1_handle);
      if(rules[i].p2_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p2_handle);
      if(rules[i].p3_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p3_handle);
   }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   UpdatePriceCache();

   // Check news veto
   if(AguardaNoticias()) return;

   // Time filter
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.hour < p_startTimeHour) return;

   // Frequency check
   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar != lastBarTime)
   {
      Signal s = AvaliaTudo();
      if(s != NONE)
      {
         if(PositionsTotal() < p_maxTrades)
            EnviaOrdem(s);
      }
      lastBarTime = currentBar;
   }

   GerenciaPosicoes();

   // Dynamic safety decay
   if(TimeCurrent() - lastSafetyDecay > 60)
   {
      if(dynamicSafetyPoints > 0) dynamicSafetyPoints--;
      lastSafetyDecay = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
{
   AIOptimizer();

   // Check for prompt updates
   if(GlobalVariableGet("MT_Executor_Prompt_Update") > 0)
   {
      int handle = FileOpen("MT_LiveExecutor_Prompt.txt", FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
      if(handle != INVALID_HANDLE) {
         string prompt = "";
         while(!FileIsEnding(handle)) prompt += FileReadString(handle);
         FileClose(handle);

         if(prompt != "") {
            InterpretaPrompt(prompt);
            Print("Estratégia atualizada via prompt: ", prompt);
         }
      }
      GlobalVariableSet("MT_Executor_Prompt_Update", 0);
   }
}

void UpdatePriceCache()
{
   symInfo.Refresh();
}

//+------------------------------------------------------------------+
//| PROMPT PARSER                                                    |
//+------------------------------------------------------------------+
void InterpretaPrompt(string prompt)
{
   string pLower = prompt;
   StringToLower(pLower);

   // Reset global state for new strategy
   for(int i=0; i<nRules; i++) {
      if(rules[i].p1_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p1_handle);
      if(rules[i].p2_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p2_handle);
      if(rules[i].p3_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p3_handle);
      rules[i].active = false;
   }
   nRules = 0;
   lastBarTime = 0; // Force re-evaluation

   // 1. Operational Parameters
   p_riskPercent = ExtraiNumero(pLower, "risco de");
   if(p_riskPercent == 0) p_riskPercent = 1.0;

   p_stopPoints = (int)ExtraiNumero(pLower, "stop de");
   if(p_stopPoints == 0) p_stopPoints = 300;

   p_takePoints = (int)ExtraiNumero(pLower, "take de");
   if(p_takePoints == 0) p_takePoints = 500;

   p_trailingStopPoints = (int)ExtraiNumero(pLower, "trailing stop");
   p_breakEvenPoints = (int)ExtraiNumero(pLower, "atingir +");
   p_breakEvenLock = (int)ExtraiNumero(pLower, "entrada +");

   p_maxTrades = (int)ExtraiNumero(pLower, "máximo");
   if(p_maxTrades == 0) p_maxTrades = 3;

   p_startTimeHour = (int)ExtraiNumero(pLower, "depois das");

   p_newsVetoBefore = (int)ExtraiNumero(pLower, "operar"); // Simplified: "não operar X min antes..."
   if(p_newsVetoBefore == 0) p_newsVetoBefore = 20;
   p_newsVetoAfter = p_newsVetoBefore;

   if(StringFind(pLower, "cada ") >= 0) {
      int mins = (int)ExtraiNumero(pLower, "cada");
      if(mins == 1) p_frequency = PERIOD_M1;
      else if(mins <= 5) p_frequency = PERIOD_M5;
      else if(mins <= 15) p_frequency = PERIOD_M15;
      else if(mins <= 30) p_frequency = PERIOD_M30;
      else if(mins <= 60) p_frequency = PERIOD_H1;
      else p_frequency = PERIOD_M15;
   }

   p_hedge = (StringFind(pLower, "hedge") >= 0);
   p_martingale = (StringFind(pLower, "martingale") >= 0);

   // 2. Indicators Rules
   // Simplified segmentation by " e " or " + " or " . " or " , "
   string segments[];
   string sep = prompt;
   StringReplace(sep, " e ", "|");
   StringReplace(sep, " + ", "|");
   StringReplace(sep, ". ", "|");
   StringReplace(sep, ", ", "|");
   ushort u_sep = StringGetCharacter("|", 0);
   StringSplit(sep, u_sep, segments);

   for(int i=0; i<ArraySize(segments); i++) {
      string s = segments[i];
      StringToLower(s);

      // Moving Average Cross
      if(StringFind(s, "média") >= 0) {
         int per = (int)ExtraiNumero(s, "média de");
         if(per > 0) AddRule(RT_MA_CROSS, p_frequency, per, per*2); // default slow=2*fast if not specified
      }

      // RSI
      if(StringFind(s, "rsi") >= 0) {
         int per = (int)ExtraiNumero(s, "rsi (");
         if(per == 0) per = 14;
         double over = ExtraiNumero(s, "acima de");
         double under = ExtraiNumero(s, "abaixo de");
         bool is_cross = (StringFind(s, "subir") >= 0 || StringFind(s, "cair") >= 0);
         if(over == 0) over = 70;
         if(under == 0) under = 30;
         AddRule(RT_RSI, p_frequency, per, 0, 0, over, under, "", is_cross);
      }

      // Stochastic
      if(StringFind(s, "estocástico") >= 0 || StringFind(s, "stoch") >= 0) {
         AddRule(RT_STOCH, p_frequency, 5, 3, 3);
      }

      // Bollinger Bands
      if(StringFind(s, "bollinger") >= 0 || StringFind(s, "bb") >= 0) {
         AddRule(RT_BB, p_frequency, 20, 0, 0, 2.0);
      }
   }
}

void AddRule(RuleType type, ENUM_TIMEFRAMES tf, int p1=0, int p2=0, int p3=0, double d1=0, double d2=0, string s1="", bool is_cross=false)
{
   if(nRules >= 30) return;

   // Check if rule already exists to update it
   int idx = -1;
   for(int i=0; i<nRules; i++) {
      if(rules[i].type == type) { idx = i; break; }
   }

   if(idx == -1) {
      idx = nRules;
      nRules++;
   } else {
      // Release old handles
      if(rules[idx].p1_handle != INVALID_HANDLE) IndicatorRelease(rules[idx].p1_handle);
      if(rules[idx].p2_handle != INVALID_HANDLE) IndicatorRelease(rules[idx].p2_handle);
      if(rules[idx].p3_handle != INVALID_HANDLE) IndicatorRelease(rules[idx].p3_handle);
   }

   rules[idx].active = true;
   rules[idx].type = type;
   rules[idx].tf = tf;
   rules[idx].p1 = p1; rules[idx].p2 = p2; rules[idx].p3 = p3;
   rules[idx].d1 = d1; rules[idx].d2 = d2;
   rules[idx].s1 = s1;
   rules[idx].is_cross = is_cross;

   // Initialize handles
   rules[idx].p1_handle = INVALID_HANDLE;
   rules[idx].p2_handle = INVALID_HANDLE;
   rules[idx].p3_handle = INVALID_HANDLE;

   switch(type) {
      case RT_MA_CROSS:
         rules[idx].p1_handle = iMA(_Symbol, tf, p1, 0, MODE_EMA, PRICE_CLOSE);
         rules[idx].p2_handle = iMA(_Symbol, tf, p2, 0, MODE_EMA, PRICE_CLOSE);
         break;
      case RT_RSI:
         rules[idx].p1_handle = iRSI(_Symbol, tf, p1, PRICE_CLOSE);
         break;
      case RT_STOCH:
         rules[idx].p1_handle = iStochastic(_Symbol, tf, p1, p2, p3, MODE_SMA, STO_LOWHIGH);
         break;
      case RT_BB:
         rules[idx].p1_handle = iBands(_Symbol, tf, p1, 0, d1, PRICE_CLOSE);
         break;
      case RT_AMA:
         rules[idx].p1_handle = iAMA(_Symbol, tf, p1, p2, p3, 0, PRICE_CLOSE);
         break;
   }
}

double ExtraiNumero(string txt, string chave)
{
   int pos = StringFind(txt, chave);
   if(pos < 0) return 0;

   string sub = StringSubstr(txt, pos + StringLen(chave));
   string res = "";
   bool foundDigit = false;

   for(int i=0; i<StringLen(sub); i++) {
      ushort c = StringGetCharacter(sub, i);
      if((c >= '0' && c <= '9') || c == '.') {
         res += StringSubstr(sub, i, 1);
         foundDigit = true;
      } else if(foundDigit) {
         break;
      }
   }
   return StringToDouble(res);
}

ENUM_TIMEFRAMES PeriodoTexto(string nome)
{
   StringToLower(nome);
   if(StringFind(nome, "m1") >= 0) return PERIOD_M1;
   if(StringFind(nome, "m5") >= 0) return PERIOD_M5;
   if(StringFind(nome, "m15") >= 0) return PERIOD_M15;
   if(StringFind(nome, "m30") >= 0) return PERIOD_M30;
   if(StringFind(nome, "h1") >= 0) return PERIOD_H1;
   if(StringFind(nome, "d1") >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

//+------------------------------------------------------------------+
//| INDICATOR CHECKERS                                               |
//+------------------------------------------------------------------+
double GetIndicatorValue(int handle, int buffer, int shift)
{
   double val[];
   ArraySetAsSeries(val, true);
   if(CopyBuffer(handle, buffer, shift, 1, val) > 0) return val[0];
   return 0;
}

Signal CheckMA(int i)
{
   double f1 = GetIndicatorValue(rules[i].p1_handle, 0, 1);
   double s1 = GetIndicatorValue(rules[i].p2_handle, 0, 1);
   double f2 = GetIndicatorValue(rules[i].p1_handle, 0, 2);
   double s2 = GetIndicatorValue(rules[i].p2_handle, 0, 2);

   if(f2 < s2 && f1 > s1) return BUY;
   if(f2 > s2 && f1 < s1) return SELL;
   return NONE;
}

Signal CheckRSI(int i)
{
   double rsi1 = GetIndicatorValue(rules[i].p1_handle, 0, 1);
   double rsi2 = GetIndicatorValue(rules[i].p1_handle, 0, 2);

   if(rules[i].is_cross) {
      if(rsi2 < rules[i].d1 && rsi1 > rules[i].d1) return BUY; // Cross above (momentum)
      if(rsi2 > rules[i].d2 && rsi1 < rules[i].d2) return SELL; // Cross below (momentum)
   } else {
      if(rsi1 < rules[i].d2) return BUY;  // Reversion (oversold)
      if(rsi1 > rules[i].d1) return SELL; // Reversion (overbought)
   }
   return NONE;
}

Signal CheckStoch(int i)
{
   double k1 = GetIndicatorValue(rules[i].p1_handle, 0, 1);
   double d1 = GetIndicatorValue(rules[i].p1_handle, 1, 1);
   double k2 = GetIndicatorValue(rules[i].p1_handle, 0, 2);
   double d2 = GetIndicatorValue(rules[i].p1_handle, 1, 2);

   if(k2 < d2 && k1 > d1) return BUY;
   if(k2 > d2 && k1 < d1) return SELL;
   return NONE;
}

Signal CheckBB(int i)
{
   double mid = GetIndicatorValue(rules[i].p1_handle, 0, 1);
   double up  = GetIndicatorValue(rules[i].p1_handle, 1, 1);
   double low = GetIndicatorValue(rules[i].p1_handle, 2, 1);
   double close = iClose(_Symbol, rules[i].tf, 1);

   if(close < low) return BUY;
   if(close > up)  return SELL;
   return NONE;
}

Signal CheckDailyBreak(int i)
{
   double hi = iHigh(_Symbol, PERIOD_D1, 1);
   double lo = iLow(_Symbol, PERIOD_D1, 1);
   double close = iClose(_Symbol, PERIOD_M1, 0); // Real-time break

   if(close > hi) return BUY;
   if(close < lo) return SELL;
   return NONE;
}

Signal CheckDelta(int i)
{
   MqlTick ticks[];
   int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, TimeCurrent() - rules[i].p1, TimeCurrent());
   long buy=0, sell=0;
   for(int j=0; j<n; j++) {
      if((ticks[j].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++;
      else if((ticks[j].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sell++;
   }
   long delta = buy - sell;
   if(delta > rules[i].p2) return BUY;
   if(delta < -rules[i].p2) return SELL;
   return NONE;
}

Signal CheckVolCycle(int i)
{
   long vol[];
   ArraySetAsSeries(vol, true);
   CopyTickVolume(_Symbol, rules[i].tf, 1, rules[i].p1, vol);
   int maxIdx = ArrayMaximum(vol);
   int minIdx = ArrayMinimum(vol);
   if(maxIdx == 0) return SELL; // Highest volume on last candle
   if(minIdx == 0) return BUY;  // Lowest volume on last candle
   return NONE;
}

Signal CheckAMA(int i)
{
   double ama1 = GetIndicatorValue(rules[i].p1_handle, 0, 1);
   double ama2 = GetIndicatorValue(rules[i].p1_handle, 0, 2);
   if(ama1 > ama2) return BUY;
   if(ama1 < ama2) return SELL;
   return NONE;
}

Signal CheckBarPattern(int i)
{
   double h0 = iHigh(_Symbol, rules[i].tf, 1);
   double l0 = iLow(_Symbol, rules[i].tf, 1);
   double h1 = iHigh(_Symbol, rules[i].tf, 2);
   double l1 = iLow(_Symbol, rules[i].tf, 2);

   // Inside Bar
   if(h0 < h1 && l0 > l1) return (iClose(_Symbol, rules[i].tf, 1) > iOpen(_Symbol, rules[i].tf, 1)) ? BUY : SELL;
   // Outside Bar
   if(h0 > h1 && l0 < l1) return (iClose(_Symbol, rules[i].tf, 1) > iOpen(_Symbol, rules[i].tf, 1)) ? SELL : BUY;
   return NONE;
}

Signal CheckRSRelative(int i)
{
   double r1 = GetIndicatorValue(rules[i].p1_handle, 0, 1);
   double r2 = GetIndicatorValue(rules[i].p2_handle, 0, 1);
   if(r1 > r2 + 5) return BUY;
   if(r1 < r2 - 5) return SELL;
   return NONE;
}


Signal AvaliaTudo()
{
   if(nRules == 0) return NONE;
   Signal combined = NONE;
   bool first = true;

   for(int i=0; i<nRules; i++) {
      if(!rules[i].active) continue;
      Signal s = NONE;
      switch(rules[i].type) {
         case RT_MA_CROSS:    s = CheckMA(i); break;
         case RT_RSI:         s = CheckRSI(i); break;
         case RT_STOCH:       s = CheckStoch(i); break;
         case RT_BB:          s = CheckBB(i); break;
         case RT_DAILY_BREAK: s = CheckDailyBreak(i); break;
         case RT_DELTA:       s = CheckDelta(i); break;
         case RT_VOL_CYCLE:   s = CheckVolCycle(i); break;
         case RT_AMA:         s = CheckAMA(i); break;
         case RT_BAR_PATTERN: s = CheckBarPattern(i); break;
         case RT_RS_RELATIVE: s = CheckRSRelative(i); break;
      }

      if(first) {
         combined = s;
         first = false;
      } else {
         if(combined != s) return NONE; // AND logic: all must agree
      }
   }
   return combined;
}
double CalculaLote(double riscoPercent)
{
   double balance = accInfo.Balance();
   double riskMoney = balance * (riscoPercent / 100.0);

   if(p_martingale) {
      // Simple Martingale: check last trade result
      HistorySelect(TimeCurrent() - 86400, TimeCurrent());
      int total = HistoryDealsTotal();
      if(total > 0) {
         ulong ticket = HistoryDealGetTicket(total - 1);
         if(HistoryDealSelect(ticket)) {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            if(profit < 0) riskMoney *= 2.0;
         }
      }
   }

   double tickValue = symInfo.TickValue();
   double tickSize = symInfo.TickSize();
   double pointsToMoney = tickValue / (tickSize / _Point);
   double lotSize = riskMoney / (p_stopPoints * pointsToMoney);

   return NormalizeDouble(MathMax(symInfo.LotsMin(), MathMin(symInfo.LotsMax(), lotSize)), 2);
}

void EnviaOrdem(Signal s)
{
   double price = (s == BUY) ? symInfo.Ask() : symInfo.Bid();

   // Hedge logic: Close opposite if p_hedge is false
   if(!p_hedge) {
      for(int i = PositionsTotal() - 1; i >= 0; i--) {
         if(posInfo.SelectByIndex(i)) {
            if(posInfo.Symbol() == _Symbol) {
               if((s == BUY && posInfo.PositionType() == POSITION_TYPE_SELL) ||
                  (s == SELL && posInfo.PositionType() == POSITION_TYPE_BUY)) {
                  trade.PositionClose(posInfo.Ticket());
               }
            }
         }
      }
   }

   double sl = CalculateValidSL((s == BUY ? POSITION_TYPE_BUY : POSITION_TYPE_SELL), price, p_stopPoints);
   double tp = (s == BUY) ? price + p_takePoints * _Point : price - p_takePoints * _Point;
   double volume = CalculaLote(p_riskPercent);

   if(s == BUY) trade.Buy(volume, _Symbol, price, sl, tp, "MT-LiveExecutor BUY");
   else trade.Sell(volume, _Symbol, price, sl, tp, "MT-LiveExecutor SELL");

   if(trade.ResultRetcode() != TRADE_RETCODE_DONE) {
      dynamicSafetyPoints = MathMin(100, dynamicSafetyPoints + 5);
   }
}

double CalculateValidSL(ENUM_POSITION_TYPE type, double price, int points)
{
   double brokerMin = (symInfo.StopsLevel() + dynamicSafetyPoints + 1) * _Point;
   double requestedDist = points * _Point;
   double safeDist = MathMax(requestedDist, brokerMin);

   if(type == POSITION_TYPE_BUY) return price - safeDist;
   return price + safeDist;
}

void GerenciaPosicoes()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(posInfo.SelectByIndex(i)) {
         if(posInfo.Symbol() != _Symbol) continue;

         double currentPrice = (posInfo.PositionType() == POSITION_TYPE_BUY) ? symInfo.Bid() : symInfo.Ask();
         double openPrice = posInfo.PriceOpen();
         double currentSL = posInfo.StopLoss();
         int profitPoints = (posInfo.PositionType() == POSITION_TYPE_BUY)
            ? (int)((currentPrice - openPrice) / _Point)
            : (int)((openPrice - currentPrice) / _Point);

         // Break-even
         if(p_breakEvenPoints > 0 && profitPoints >= p_breakEvenPoints) {
            double beSL = (posInfo.PositionType() == POSITION_TYPE_BUY)
               ? openPrice + p_breakEvenLock * _Point
               : openPrice - p_breakEvenLock * _Point;

            bool shouldUpdate = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (currentSL < beSL) : (currentSL > beSL || currentSL == 0);
            if(shouldUpdate) {
               trade.PositionModify(posInfo.Ticket(), beSL, posInfo.TakeProfit());
            }
         }

         // Trailing Stop
         if(p_trailingStopPoints > 0 && profitPoints >= p_trailingStopPoints) {
            double trailSL = (posInfo.PositionType() == POSITION_TYPE_BUY)
               ? currentPrice - p_trailingStopPoints * _Point
               : currentPrice + p_trailingStopPoints * _Point;

            bool shouldUpdate = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (currentSL < trailSL) : (currentSL > trailSL || currentSL == 0);
            if(shouldUpdate) {
               trade.PositionModify(posInfo.Ticket(), trailSL, posInfo.TakeProfit());
            }
         }
      }
   }
}

void SynchronizeClusterSL(ENUM_POSITION_TYPE type, double newSL)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(posInfo.SelectByIndex(i)) {
         if(posInfo.Symbol() == _Symbol && posInfo.PositionType() == type) {
            trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
         }
      }
   }
}

void OnTradeTransaction(const MqlTradeTransaction& trans, const MqlTradeRequest& request, const MqlTradeResult& result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD) {
      if(HistoryDealSelect(trans.deal)) {
         long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_IN) {
            // New position entered, sync SL if needed
            if(PositionSelectByTicket(HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID))) {
               SynchronizeClusterSL(posInfo.PositionType(), posInfo.StopLoss());
               GravaCSV();
            }
         }
      }
   }
}
bool AguardaNoticias()
{
   int handle = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      string content = FileReadString(handle);
      FileClose(handle);
      if(content == "1") return true;
   }
   return false;
}

void GravaCSV()
{
   int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(handle != INVALID_HANDLE) {
      FileWrite(handle, "Ticket", "Symbol", "Type", "OpenPrice", "SL", "TP", "Time", "Magic");
      for(int i=0; i<PositionsTotal(); i++) {
         if(posInfo.SelectByIndex(i)) {
            FileWrite(handle,
               posInfo.Ticket(),
               posInfo.Symbol(),
               posInfo.PositionType(),
               posInfo.PriceOpen(),
               posInfo.StopLoss(),
               posInfo.TakeProfit(),
               posInfo.Time(),
               posInfo.Magic());
         }
      }
      FileClose(handle);
   }
}

void AIOptimizer()
{
   if(!HistorySelect(0, TimeCurrent())) return;

   int totalDeals = HistoryDealsTotal();
   int wins = 0, losses = 0;
   double profit = 0, loss = 0;

   for(int i=0; i<totalDeals; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealSelect(ticket)) {
         if(HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT) {
            double res = HistoryDealGetDouble(ticket, DEAL_PROFIT) + HistoryDealGetDouble(ticket, DEAL_COMMISSION) + HistoryDealGetDouble(ticket, DEAL_SWAP);
            if(res > 0) { wins++; profit += res; }
            else if(res < 0) { losses++; loss -= res; }
         }
      }
   }

   double winRate = (wins + losses > 0) ? (double)wins / (wins + losses) : 0;
   double profitFactor = (loss > 0) ? profit / loss : profit;

   // Heuristic adjustment: if WinRate < 40%, reduce risk
   if(wins + losses > 10 && winRate < 0.4) {
      p_riskPercent = MathMax(0.5, p_riskPercent * 0.9);
   }

   // Volatility adjustment using ATR
   double atr[];
   ArraySetAsSeries(atr, true);
   if(atrHandle != INVALID_HANDLE && CopyBuffer(atrHandle, 0, 0, 1, atr) > 0) {
      double currentAtr = atr[0];
      // If ATR is high (volatile), widen SL
      if(currentAtr > 100 * _Point) {
         p_stopPoints = (int)MathMax(p_stopPoints, currentAtr / _Point);
      }
   }
}
