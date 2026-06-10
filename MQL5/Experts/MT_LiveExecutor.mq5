//+------------------------------------------------------------------+
//|                                              MT_LiveExecutor.mq5 |
//|                                  Copyright 2024, MT-LiveExecutor |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MT-LiveExecutor"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

//--- DEFINES
#define EA_MAGIC 123456
#define STATE_FILE "MT_LiveExecutor_State.csv"
#define LOG_FILE   "MT_LiveExecutor_Log.txt"
#define PROMPT_FILE "prompt.txt"
#define CALENDAR_FILE "calendar.txt"
#define NEWS_VETO_FILE "news_veto.txt"

//--- ENUMS
enum ENUM_SIGNAL { SIGNAL_BUY=1, SIGNAL_SELL=-1, SIGNAL_NONE=0 };

//--- STRUCTS
struct Rule {
   bool     active;
   int      type;    // 1:MA, 2:RSI, 3:Stoch, 4:BB, 5:DailyBreak, 6:Delta, 7:VolCycle, 8:AMA, 9:Bar2, 10:RelStr
   int      intent;  // SIGNAL_BUY or SIGNAL_SELL
   int      tf;
   int      p1, p2, p3;
   double   d1, d2;
   string   s1;
   int      handle1, handle2;

   void Reset() {
      active = false;
      type = 0;
      intent = 0;
      tf = PERIOD_CURRENT;
      p1 = 0; p2 = 0; p3 = 0;
      d1 = 0; d2 = 0;
      s1 = "";
      handle1 = INVALID_HANDLE;
      handle2 = INVALID_HANDLE;
   }
};

//--- GLOBALS
Rule      g_rules[50];
int       g_nRules = 0;
CTrade    g_trade;
string    g_lastPrompt = "";
datetime  g_lastBar = 0;
datetime  g_lastCSV = 0;
datetime  g_lastAI = 0;

// Strategy Parameters
double    p_risk = 1.0;
double    p_slPoints = 0;
double    p_tpPoints = 0;
int       p_maxTrades = 3;
double    p_trailingStop = 0;
double    p_trailingStep = 0;
double    p_breakeven = 0;
double    p_breakevenPlus = 0;
string    p_startTime = "00:00";
int       p_newsVeto = 20;
bool      p_martingale = false;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

//--- Prototypes
void InterpretaPrompt(string prompt);
void AvaliaTudo();
void GerenciaPosicoes();
void GravaCSV();
void GravaLog(string txt);
void ResetStrategy();
void AIOptimizer();
bool AguardaNoticias();
double CalculaLote(double riscoPercent, double slPoints);
void EnviaOrdem(int signal, string reason);
double GetBufferValue(int handle, int buffer, int index);
int AvaliaRegra(Rule &r);
bool IsTimeAllowed();
void CalculaStats();

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(EA_MAGIC);
   EventSetTimer(1);
   ResetStrategy();
   GravaLog("MT-LiveExecutor Iniciado.");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   ResetStrategy();
   GravaLog("MT-LiveExecutor Finalizado.");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   GerenciaPosicoes();

   if(TimeCurrent() - g_lastCSV >= 5) {
      GravaCSV();
      g_lastCSV = TimeCurrent();
   }

   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar != g_lastBar) {
      AvaliaTudo();
      g_lastBar = currentBar;
   }
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Check for prompt updates
   int h = FileOpen(PROMPT_FILE, FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      string prompt = FileReadString(h);
      FileClose(h);
      if(prompt != g_lastPrompt && prompt != "") {
         g_lastPrompt = prompt;
         InterpretaPrompt(prompt);
      }
   }

   if(TimeCurrent() - g_lastAI >= 3600) {
      AIOptimizer();
      g_lastAI = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
//| Reset Strategy                                                   |
//+------------------------------------------------------------------+
void ResetStrategy() {
   for(int i=0; i<50; i++) {
      if(g_rules[i].handle1 != INVALID_HANDLE && g_rules[i].handle1 != 0) IndicatorRelease(g_rules[i].handle1);
      if(g_rules[i].handle2 != INVALID_HANDLE && g_rules[i].handle2 != 0) IndicatorRelease(g_rules[i].handle2);
      g_rules[i].Reset();
   }
   g_nRules = 0;
}

//+------------------------------------------------------------------+
//| Logger                                                           |
//+------------------------------------------------------------------+
void GravaLog(string txt) {
   int h = FileOpen(LOG_FILE, FILE_WRITE|FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      FileSeek(h, 0, SEEK_END);
      FileWrite(h, TimeToString(TimeCurrent()) + ": " + txt);
      FileClose(h);
   }
}

//+------------------------------------------------------------------+
//| State Persistence                                                |
//+------------------------------------------------------------------+
void GravaCSV() {
   int h = FileOpen(STATE_FILE, FILE_WRITE|FILE_CSV|FILE_COMMON|FILE_ANSI, ';');
   if(h != INVALID_HANDLE) {
      FileWrite(h, "Ticket", "Symbol", "Type", "Price", "SL", "TP", "Profit");
      for(int i = 0; i < PositionsTotal(); i++) {
         if(PositionSelectByTicket(PositionGetTicket(i))) {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
               FileWrite(h, PositionGetInteger(POSITION_TICKET),
                           PositionGetString(POSITION_SYMBOL),
                           PositionGetInteger(POSITION_TYPE),
                           PositionGetDouble(POSITION_PRICE_OPEN),
                           PositionGetDouble(POSITION_SL),
                           PositionGetDouble(POSITION_TP),
                           PositionGetDouble(POSITION_PROFIT));
            }
         }
      }
      FileClose(h);
   }
}

//+------------------------------------------------------------------+
//| Utilities for Indicator values                                   |
//+------------------------------------------------------------------+
double GetBufferValue(int handle, int buffer, int index) {
   double val[1];
   if(CopyBuffer(handle, buffer, index, 1, val) < 0) return 0;
   return val[0];
}

//+------------------------------------------------------------------+
//| Signal evaluation for a single rule                              |
//+------------------------------------------------------------------+
int AvaliaRegra(Rule &r) {
   if(!r.active) return 0;

   switch(r.type) {
      case 1: { // MA Cross
         double f1 = GetBufferValue(r.handle1, 0, 1);
         double s1 = GetBufferValue(r.handle2, 0, 1);
         double f2 = GetBufferValue(r.handle1, 0, 2);
         double s2 = GetBufferValue(r.handle2, 0, 2);
         if(f2 <= s2 && f1 > s1) return SIGNAL_BUY;
         if(f2 >= s2 && f1 < s1) return SIGNAL_SELL;
         break;
      }
      case 2: { // RSI
         double v1 = GetBufferValue(r.handle1, 0, 1);
         double v2 = GetBufferValue(r.handle1, 0, 2);
         if(r.intent == SIGNAL_BUY && v2 <= r.d1 && v1 > r.d1) return SIGNAL_BUY;
         if(r.intent == SIGNAL_SELL && v2 >= r.d1 && v1 < r.d1) return SIGNAL_SELL;
         break;
      }
      case 3: { // Stoch
         double k1 = GetBufferValue(r.handle1, 0, 1);
         double d1 = GetBufferValue(r.handle1, 1, 1);
         double k2 = GetBufferValue(r.handle1, 0, 2);
         double d2 = GetBufferValue(r.handle1, 1, 2);
         if(k2 <= d2 && k1 > d1) return SIGNAL_BUY;
         if(k2 >= d2 && k1 < d1) return SIGNAL_SELL;
         break;
      }
      case 4: { // Bollinger Bands
         double close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         double upper = GetBufferValue(r.handle1, 1, 1);
         double lower = GetBufferValue(r.handle1, 2, 1);
         if(close < lower) return SIGNAL_BUY;
         if(close > upper) return SIGNAL_SELL;
         break;
      }
      case 5: { // Daily Breakout
         double close = iClose(_Symbol, PERIOD_M1, 1);
         double high = iHigh(_Symbol, PERIOD_D1, 1);
         double low = iLow(_Symbol, PERIOD_D1, 1);
         if(close > high) return SIGNAL_BUY;
         if(close < low) return SIGNAL_SELL;
         break;
      }
      case 6: { // Delta Aggression
         MqlTick ticks[];
         int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, (TimeCurrent()-60)*1000, TimeCurrent()*1000);
         long buy=0, sell=0;
         for(int i=0; i<n; i++) if((ticks[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++; else sell++;
         long delta = buy - sell;
         if(delta > r.p1) return SIGNAL_BUY;
         if(delta < -r.p1) return SIGNAL_SELL;
         break;
      }
      case 7: { // Volume Cycle
         long vol[]; ArraySetAsSeries(vol, true);
         CopyVolume(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0, r.p1, vol);
         int maxIdx = ArrayMaximum(vol);
         int minIdx = ArrayMinimum(vol);
         if(minIdx == 0) return SIGNAL_BUY;
         if(maxIdx == 0) return SIGNAL_SELL;
         break;
      }
      case 8: { // AMA
         double v1 = GetBufferValue(r.handle1, 0, 1);
         double v2 = GetBufferValue(r.handle1, 0, 2);
         if(v1 > v2) return SIGNAL_BUY;
         if(v1 < v2) return SIGNAL_SELL;
         break;
      }
      case 9: { // 2-Bar Patterns
         double h0 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         double l0 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         double h1 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
         double l1 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
         bool inside = (h0 < h1 && l0 > l1);
         bool outside = (h0 > h1 && l0 < l1);
         if(inside || outside) {
            return (iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1)) ? SIGNAL_BUY : SIGNAL_SELL;
         }
         break;
      }
      case 10: { // Relative Strength
         double rsi1 = GetBufferValue(r.handle1, 0, 1);
         double rsi2 = GetBufferValue(r.handle2, 0, 1);
         if(rsi1 > rsi2 + 5) return SIGNAL_BUY;
         if(rsi1 < rsi2 - 5) return SIGNAL_SELL;
         break;
      }
   }
   return SIGNAL_NONE;
}

//+------------------------------------------------------------------+
//| Decision Engine                                                  |
//+------------------------------------------------------------------+
void AvaliaTudo() {
   if(AguardaNoticias()) return;
   if(!IsTimeAllowed()) return;

   int buyRules = 0, sellRules = 0;
   int buyVotos = 0, sellVotos = 0;

   for(int i=0; i<g_nRules; i++) {
      if(!g_rules[i].active) continue;
      int res = AvaliaRegra(g_rules[i]);

      if(g_rules[i].intent == SIGNAL_BUY) {
         buyRules++;
         if(res == SIGNAL_BUY) buyVotos++;
      } else if(g_rules[i].intent == SIGNAL_SELL) {
         sellRules++;
         if(res == SIGNAL_SELL) sellVotos++;
      }
   }

   if(buyRules > 0 && buyVotos == buyRules) EnviaOrdem(SIGNAL_BUY, "Confluencia de Compra");
   else if(sellRules > 0 && sellVotos == sellRules) EnviaOrdem(SIGNAL_SELL, "Confluencia de Venda");
}

//+------------------------------------------------------------------+
//| News Veto check                                                  |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Time Window Check                                                |
//+------------------------------------------------------------------+
bool IsTimeAllowed() {
   datetime now = TimeCurrent();
   string currentTime = TimeToString(now, TIME_MINUTES);
   if(currentTime < p_startTime) return false;
   return true;
}

//+------------------------------------------------------------------+
//| Performance Stats                                                |
//+------------------------------------------------------------------+
void CalculaStats() {
   HistorySelect(0, TimeCurrent());
   int total = HistoryDealsTotal();
   int wins = 0, losses = 0;
   double profit = 0, loss = 0;

   for(int i=0; i<total; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
         double res = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         if(res > 0) { wins++; profit += res; }
         if(res < 0) { losses++; loss += MathAbs(res); }
      }
   }

   double winRate = (wins + losses > 0) ? (double)wins / (wins + losses) * 100 : 0;
   double pf = (loss > 0) ? profit / loss : profit;

   GravaLog("Stats: Trades: " + IntegerToString(wins+losses) + " WinRate: " + DoubleToString(winRate, 2) + "% PF: " + DoubleToString(pf, 2));
}

bool AguardaNoticias() {
   // 1. Direct Veto
   int h = FileOpen(NEWS_VETO_FILE, FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      string veto = FileReadString(h);
      FileClose(h);
      if(veto == "1") return true;
   }

   // 2. Calendar check
   h = FileOpen(CALENDAR_FILE, FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      while(!FileIsEnding(h)) {
         string line = FileReadString(h);
         string parts[];
         if(StringSplit(line, ';', parts) >= 4) {
            datetime newsTime = StringToTime(parts[0]);
            if(MathAbs(TimeCurrent() - newsTime) < p_newsVeto * 60) {
               if(StringFind(parts[2], "High") >= 0 || StringFind(parts[2], "Alto") >= 0) {
                  FileClose(h);
                  return true;
               }
            }
         }
      }
      FileClose(h);
   }
   return false;
}

//+------------------------------------------------------------------+
//| Risk Management: Lote                                             |
//+------------------------------------------------------------------+
double CalculaLote(double riscoPercent, double slPoints) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = capital * (riscoPercent / 100.0);

   if(p_martingale) {
      HistorySelect(TimeCurrent()-86400, TimeCurrent());
      int total = HistoryDealsTotal();
      if(total > 0) {
         ulong ticket = HistoryDealGetTicket(total-1);
         if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) riskAmount *= 2;
      }
   }

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(slPoints <= 0) slPoints = 300; // default 30p

   double lot = riskAmount / (slPoints * _Point * (tickValue / tickSize));

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / stepLot) * stepLot;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return lot;
}

//+------------------------------------------------------------------+
//| Trade Execution                                                  |
//+------------------------------------------------------------------+
void EnviaOrdem(int signal, string reason) {
   if(PositionsTotal() >= p_maxTrades) return;

   double lot = CalculaLote(p_risk, p_slPoints);
   double sl = 0, tp = 0;
   double price = 0;

   if(signal == SIGNAL_BUY) {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(p_slPoints > 0) sl = price - p_slPoints * _Point;
      if(p_tpPoints > 0) tp = price + p_tpPoints * _Point;
      if(g_trade.Buy(lot, _Symbol, price, sl, tp, reason)) {
         GravaLog("COMPRA executada: " + reason + " Lote: " + DoubleToString(lot, 2));
         SendNotification("MT-LiveExecutor: Compra " + _Symbol);
      }
   } else if(signal == SIGNAL_SELL) {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(p_slPoints > 0) sl = price + p_slPoints * _Point;
      if(p_tpPoints > 0) tp = price - p_tpPoints * _Point;
      if(g_trade.Sell(lot, _Symbol, price, sl, tp, reason)) {
         GravaLog("VENDA executada: " + reason + " Lote: " + DoubleToString(lot, 2));
         SendNotification("MT-LiveExecutor: Venda " + _Symbol);
      }
   }
}

//+------------------------------------------------------------------+
//| Position Management (Trailing, Breakeven)                        |
//+------------------------------------------------------------------+
void GerenciaPosicoes() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(PositionSelectByTicket(PositionGetTicket(i))) {
         string symbol = PositionGetString(POSITION_SYMBOL);
         if(symbol != _Symbol) continue;

         ulong ticket = PositionGetInteger(POSITION_TICKET);
         if(PositionGetInteger(POSITION_MAGIC) != EA_MAGIC) continue;

         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double currentSL = PositionGetDouble(POSITION_SL);

         double profitPoints = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? (currentPrice - openPrice)/_Point : (openPrice - currentPrice)/_Point;

         // Breakeven
         if(p_breakeven > 0 && profitPoints >= p_breakeven) {
            double targetSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? openPrice + p_breakevenPlus * _Point : openPrice - p_breakevenPlus * _Point;
            if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && (currentSL < targetSL || currentSL == 0)) ||
               (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (currentSL > targetSL || currentSL == 0))) {
               g_trade.PositionModify(ticket, targetSL, PositionGetDouble(POSITION_TP));
               GravaLog("Breakeven ativado para ticket " + IntegerToString(ticket));
            }
         }

         // Trailing Stop
         if(p_trailingStop > 0 && profitPoints >= p_trailingStop) {
            double targetSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? currentPrice - p_trailingStop * _Point : currentPrice + p_trailingStop * _Point;
            if(MathAbs(targetSL - currentSL) >= p_trailingStep * _Point) {
                if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && targetSL > currentSL) ||
                   (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (targetSL < currentSL || currentSL == 0))) {
                   g_trade.PositionModify(ticket, targetSL, PositionGetDouble(POSITION_TP));
                }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| NLP Helper: Extract numbers from string                          |
//+------------------------------------------------------------------+
double ExtraiNumero(string txt, int &cursor) {
   string res = "";
   bool found = false;
   for(int i = cursor; i < StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.' || c == ',') {
         if(c == ',') c = '.';
         res += ShortToString(c);
         found = true;
      } else if(found) {
         cursor = i;
         break;
      }
   }
   if(!found) return 0;
   return StringToDouble(res);
}

//+------------------------------------------------------------------+
//| NLP Helper: Get timeframe from text                              |
//+------------------------------------------------------------------+
int PeriodoTexto(string txt) {
   string t = txt;
   StringLower(t);
   // Order matters to avoid m1 matching m15
   if(StringFind(t, "m15") >= 0) return PERIOD_M15;
   if(StringFind(t, "m1") >= 0 && StringFind(t, "m15") < 0) return PERIOD_M1;
   if(StringFind(t, "m5") >= 0) return PERIOD_M5;
   if(StringFind(t, "h1") >= 0) return PERIOD_H1;
   if(StringFind(t, "d1") >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

//+------------------------------------------------------------------+
//| Add a rule to the engine                                         |
//+------------------------------------------------------------------+
void AddRule(string txt, int intent) {
   if(g_nRules >= 50) return;
   Rule &r = g_rules[g_nRules];
   r.Reset();
   r.intent = intent;
   r.tf = PeriodoTexto(txt);

   string t = txt;
   StringLower(t);

   static int lastMA = 20;
   static int lastRSI = 14;

   if(StringFind(t, "média") >= 0 || StringFind(t, "media") >= 0) {
      r.type = 1;
      int cur = StringFind(t, "média");
      if(cur < 0) cur = StringFind(t, "media");
      double p = ExtraiNumero(t, cur);
      if(p > 0) lastMA = (int)p;
      r.p1 = lastMA;
      r.handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_EMA, PRICE_CLOSE);
      r.handle2 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1, 0, MODE_SMA, PRICE_CLOSE); // Price proxy
      r.active = true;
   }
   else if(StringFind(t, "rsi") >= 0) {
      r.type = 2;
      int cur = StringFind(t, "rsi") + 3;
      double p = ExtraiNumero(t, cur);
      if(p > 0) lastRSI = (int)p;
      r.p1 = lastRSI;
      r.d1 = ExtraiNumero(t, cur); // threshold
      r.handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
      r.active = true;
   }
   else if(StringFind(t, "estocástico") >= 0) {
      r.type = 3;
      r.handle1 = iStochastic(_Symbol, (ENUM_TIMEFRAMES)r.tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
      r.active = true;
   }
   else if(StringFind(t, "bollinger") >= 0) {
      r.type = 4;
      r.handle1 = iBands(_Symbol, (ENUM_TIMEFRAMES)r.tf, 20, 0, 2.0, PRICE_CLOSE);
      r.active = true;
   }

   if(r.active) {
      if(r.handle1 == INVALID_HANDLE) {
         GravaLog("Erro ao criar handle para regra " + IntegerToString(g_nRules));
         r.active = false;
      } else {
         g_nRules++;
      }
   }
}

//+------------------------------------------------------------------+
//| Main Parser                                                      |
//+------------------------------------------------------------------+
void InterpretaPrompt(string prompt) {
   GravaLog("Interpretando: " + prompt);
   ResetStrategy();

   string work = prompt;
   StringReplace(work, " e ", ".");
   StringReplace(work, " + ", ".");

   string segments[];
   int n = StringSplit(work, '.', segments);

   int currentIntent = SIGNAL_BUY;

   for(int i=0; i<n; i++) {
      string s = segments[i];
      StringTrimLeft(s); StringTrimRight(s);
      string sl = s; StringLower(sl);

      if(StringFind(sl, "compra") >= 0) currentIntent = SIGNAL_BUY;
      if(StringFind(sl, "venda") >= 0 || StringFind(sl, "vende") >= 0) currentIntent = SIGNAL_SELL;

      // Global Params
      int cur = 0;
      if(StringFind(sl, "stop de") >= 0) { cur = StringFind(sl, "stop de") + 7; p_slPoints = ExtraiNumero(sl, cur); }
      if(StringFind(sl, "take de") >= 0) { cur = StringFind(sl, "take de") + 7; p_tpPoints = ExtraiNumero(sl, cur); }
      if(StringFind(sl, "risco de") >= 0) { cur = StringFind(sl, "risco de") + 8; p_risk = ExtraiNumero(sl, cur); }
      if(StringFind(sl, "máximo") >= 0) { cur = StringFind(sl, "máximo") + 6; p_maxTrades = (int)ExtraiNumero(sl, cur); }
      if(StringFind(sl, "notícias") >= 0) { cur = StringFind(sl, "notícias") - 3; p_newsVeto = (int)ExtraiNumero(sl, cur); if(p_newsVeto==0) p_newsVeto=20; }

      if(StringFind(sl, "move stop para entrada") >= 0) {
         cur = StringFind(sl, "atingir") + 7;
         p_breakeven = ExtraiNumero(sl, cur);
         cur = StringFind(sl, "entrada +") + 9;
         p_breakevenPlus = ExtraiNumero(sl, cur);
      }

      if(StringFind(sl, "depois das") >= 0) {
         cur = StringFind(sl, "depois das") + 10;
         while(cur < StringLen(sl) && (StringGetCharacter(sl, cur) == ' ')) cur++;
         p_startTime = StringSubstr(sl, cur, 5);
         if(StringFind(p_startTime, "h") >= 0) {
            int hPos = StringFind(p_startTime, "h");
            string hour = StringSubstr(p_startTime, 0, hPos);
            if(StringLen(hour) == 1) hour = "0" + hour;
            p_startTime = hour + ":00";
         }
      }

      // Add Rules
      AddRule(s, currentIntent);
   }

   // Timeframe frequency
   p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(prompt);

   GravaLog("Estratégia carregada. Regras: " + IntegerToString(g_nRules));
}

//+------------------------------------------------------------------+
//| AI Optimizer Placeholder                                         |
//+------------------------------------------------------------------+
void AIOptimizer() {
   GravaLog("AIOptimizer executado.");
}
