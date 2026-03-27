//+------------------------------------------------------------------+
//|                                              MT_LiveExecutor.mq5 |
//|                                  Copyright 2026, Jules (MT-Live) |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Jules"
#property link      "https://www.mql5.com"
#property version   "8.40"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

//--- Enums
enum Signal { BUY=1, SELL=-1, NONE=0 };

enum RuleType {
   RULE_NONE,
   RULE_MA_CROSS,
   RULE_RSI,
   RULE_STOCH,
   RULE_BB,
   RULE_DAILY_BREAK,
   RULE_AMA,
   RULE_BAR_PATTERN
};

//--- Structs
struct Rule {
   bool      active;
   RuleType  type;
   ENUM_TIMEFRAMES tf;
   int       p1, p2, p3;
   double    d1, d2;
   string    s1;
   int       p1_handle, p2_handle, p3_handle;
   bool      is_cross;
   Signal    direction;
   string    description;
};

//--- Constants
const long EA_MAGIC = 20260101;

//--- Global Variables - Trading Parameters
double   p_riskPercent           = 1.0;
int      p_slPoints              = 0;
int      p_tpPoints              = 0;
int      p_trailingStopPoints    = 0;
int      p_breakEvenPoints       = 0;
int      p_breakEvenProfitPoints = 0;
bool     p_martingale            = false;
bool     p_hedge                 = true;
bool     p_notifications         = false;
int      p_startTimeSeconds      = 0;
int      p_newsVetoMinutes       = 0;
int      p_maxTrades             = 100;
ENUM_TIMEFRAMES p_frequency      = PERIOD_CURRENT;

//--- Global Variables - State
Rule     rules[30];
int      nRules                  = 0;
int      dynamicSafetyPoints     = 0;
datetime lastBarTime             = 0;
datetime lastSafetyDecay        = 0;
datetime lastPromptUpdate        = 0;
string   currentPrompt           = "";

//--- MQL5 Classes
CTrade         trade;
CPositionInfo  posInfo;
CSymbolInfo    symbolInfo;
CAccountInfo   accountInfo;

//+------------------------------------------------------------------+
//| Lifecycle Handlers                                               |
//+------------------------------------------------------------------+

int OnInit() {
   symbolInfo.Name(_Symbol);
   trade.SetExpertMagicNumber(EA_MAGIC);

   string path = "MT_LiveExecutor_Prompt.txt";
   int handle = FileOpen(path, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      string prompt = FileReadString(handle);
      FileClose(handle);
      InterpretaPrompt(prompt);
   }

   EventSetTimer(60);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   ResetStrategy();
   EventKillTimer();
}

void OnTick() {
   GerenciaPosicoes();
   GravaCSV();

   if(AguardaNoticias()) return;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int currentSeconds = dt.hour * 3600 + dt.min * 60 + dt.sec;
   if(p_startTimeSeconds > 0 && currentSeconds < p_startTimeSeconds) return;

   if(TimeCurrent() - lastSafetyDecay >= 60) {
      if(dynamicSafetyPoints > 0) dynamicSafetyPoints--;
      lastSafetyDecay = TimeCurrent();
   }

   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar != lastBarTime) {
      Signal combined = AvaliaTudo();
      if(combined != NONE) EnviaOrdem(combined);
      lastBarTime = currentBar;
   }
}

void OnTimer() {
   AIOptimizer();
   if(GlobalVariableCheck("MT_Executor_Prompt_Update")) {
      if(GlobalVariableGet("MT_Executor_Prompt_Update") > 0) {
         string path = "MT_LiveExecutor_Prompt.txt";
         int handle = FileOpen(path, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
         if(handle != INVALID_HANDLE) {
            string prompt = FileReadString(handle);
            FileClose(handle);
            InterpretaPrompt(prompt);
         }
         GlobalVariableSet("MT_Executor_Prompt_Update", 0);
      }
   }
}

//+------------------------------------------------------------------+
//| Decision Logic                                                   |
//+------------------------------------------------------------------+

Signal AvaliaTudo() {
   if(nRules == 0) return NONE;
   int buyVoters = 0; int sellVoters = 0;
   int buyWeight = 0; int sellWeight = 0;

   for(int i=0; i<nRules; i++) {
      if(!rules[i].active) continue;
      Signal s = NONE;
      switch(rules[i].type) {
         case RULE_MA_CROSS:  s = CheckMA(i, 1); break;
         case RULE_RSI:       s = CheckRSI(i, 1); break;
         case RULE_STOCH:     s = CheckStoch(i, 1); break;
         case RULE_BB:        s = CheckBB(i, 1); break;
         case RULE_AMA:       s = CheckAMA(i, 1); break;
         case RULE_DAILY_BREAK: s = CheckDailyBreak(1); break;
      }
      if(rules[i].direction == BUY) {
         buyWeight++; if(s == BUY) buyVoters++;
      } else if(rules[i].direction == SELL) {
         sellWeight++; if(s == SELL) sellVoters++;
      } else {
         buyWeight++; sellWeight++;
         if(s == BUY) buyVoters++; else if(s == SELL) sellVoters++;
      }
   }
   if(buyWeight > 0 && buyVoters == buyWeight) return BUY;
   if(sellWeight > 0 && sellVoters == sellWeight) return SELL;
   return NONE;
}

//+------------------------------------------------------------------+
//| NLP Parser                                                       |
//+------------------------------------------------------------------+

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   currentPrompt = prompt;
   lastBarTime = 0;
   int lastMA_p1 = 20, lastMA_p2 = 0;
   int lastRSI_p = 14;

   string segments[];
   string working = prompt;
   StringReplace(working, " e ", "|");
   StringReplace(working, " + ", "|");
   StringReplace(working, ", ", "|");
   StringReplace(working, ". ", "|");
   ushort sep = StringGetCharacter("|", 0);
   int n = StringSplit(working, sep, segments);

   for(int i=0; i<n; i++) {
      if(nRules >= 30) break;
      string s = segments[i]; StringToLower(s);
      ENUM_TIMEFRAMES tf = PeriodoTexto(s);
      Signal segDir = NONE;
      if(StringFind(s, "compra") >= 0) segDir = BUY;
      else if(StringFind(s, "vende") >= 0) segDir = SELL;

      if(StringFind(s, "a cada ") >= 0) p_frequency = MinutesToTimeframe((int)ExtractNumber(s, "a cada "));

      if(StringFind(s, "média") >= 0) {
         double dp1 = ExtractNumber(s, "média ");
         if(dp1 == 0) dp1 = ExtractNumber(s, "média de ");
         int p1 = (dp1 == 0) ? lastMA_p1 : (int)dp1; lastMA_p1 = p1;
         int p2 = (int)ExtractNumber(s, "/");
         if(p2 == 0) p2 = lastMA_p2; else lastMA_p2 = p2;
         rules[nRules].type = RULE_MA_CROSS;
         rules[nRules].tf = tf;
         rules[nRules].p1 = p1;
         rules[nRules].p1_handle = iMA(_Symbol, tf, p1, 0, MODE_EMA, PRICE_CLOSE);
         if(p2 > 0) {
            rules[nRules].p2 = p2;
            rules[nRules].p2_handle = iMA(_Symbol, tf, p2, 0, MODE_EMA, PRICE_CLOSE);
         }
         rules[nRules].direction = segDir; rules[nRules].active = true; nRules++;
      }

      if(StringFind(s, "rsi") >= 0) {
         int per = (int)ExtractNumber(s, "rsi (");
         if(per == 0) per = (int)ExtractNumber(s, "rsi ");
         if(per == 0) per = lastRSI_p; else lastRSI_p = per;
         rules[nRules].type = RULE_RSI;
         rules[nRules].tf = tf;
         rules[nRules].p1 = per;
         rules[nRules].p1_handle = iRSI(_Symbol, tf, per, PRICE_CLOSE);
         rules[nRules].is_cross = (StringFind(s, "subir") >= 0 || StringFind(s, "cair") >= 0 || StringFind(s, "cruzar") >= 0);
         double over = ExtractNumber(s, "acima de ");
         double under = ExtractNumber(s, "abaixo de ");
         if(segDir == BUY) { rules[nRules].d1 = (over > 0) ? over : 55; rules[nRules].d2 = (under > 0) ? under : 55; }
         else if(segDir == SELL) { rules[nRules].d1 = (over > 0) ? over : 45; rules[nRules].d2 = (under > 0) ? under : 45; }
         else { rules[nRules].d1 = (over > 0) ? over : 70; rules[nRules].d2 = (under > 0) ? under : 30; }
         rules[nRules].direction = segDir; rules[nRules].active = true; nRules++;
      }

      if(StringFind(s, "stop de ") >= 0) p_slPoints = (int)ExtractNumber(s, "stop de ");
      if(StringFind(s, "take de ") >= 0) p_tpPoints = (int)ExtractNumber(s, "take de ");
      if(StringFind(s, "risco de ") >= 0) p_riskPercent = ExtractNumber(s, "risco de ");
      if(StringFind(s, "depois das ") >= 0) {
         string tStr = ExtractTime(s, "depois das ");
         int h = (int)StringToInteger(StringSubstr(tStr, 0, 2));
         int m = (int)StringToInteger(StringSubstr(tStr, 3, 2));
         p_startTimeSeconds = h * 3600 + m * 60;
      }
      if(StringFind(s, "não operar ") >= 0) p_newsVetoMinutes = (int)ExtractNumber(s, "não operar ");
      if(StringFind(s, "máximo ") >= 0) p_maxTrades = (int)ExtractNumber(s, "máximo ");
      if(StringFind(s, "move stop") >= 0) {
         p_breakEvenPoints = (int)ExtractNumber(s, "atingir +");
         p_breakEvenProfitPoints = (int)ExtractNumber(s, "entrada +");
      }
      if(StringFind(s, "trailing stop") >= 0) p_trailingStopPoints = (int)ExtractNumber(s, "trailing stop ");
      if(StringFind(s, "martingale") >= 0) p_martingale = true;
      if(StringFind(s, "hedge") >= 0) p_hedge = true;
   }
}

//+------------------------------------------------------------------+
//| Utilities                                                        |
//+------------------------------------------------------------------+

double ExtractNumber(string txt, string key) {
   int pos = StringFind(txt, key);
   if(pos < 0) return 0;
   string sub = StringSubstr(txt, pos + StringLen(key));
   string res = "";
   for(int i=0; i<StringLen(sub); i++) {
      ushort c = StringGetCharacter(sub, i);
      if((c >= '0' && c <= '9') || c == '.') res += CharToString((char)c);
      else if(res != "" && (c < '0' || c > '9') && c != '.') break;
   }
   return StringToDouble(res);
}

string ExtractTime(string txt, string key) {
   int pos = StringFind(txt, key);
   if(pos < 0) return "00:00";
   string sub = StringSubstr(txt, pos + StringLen(key));
   string res = "";
   for(int i=0; i<StringLen(sub); i++) {
      ushort c = StringGetCharacter(sub, i);
      if(c == ' ') { if(res != "") break; else continue; }
      res += CharToString((char)c);
   }
   StringReplace(res, "h", ":00");
   if(StringLen(res) < 5 && StringFind(res, ":") < 0) res += ":00";
   if(StringLen(res) == 4 && StringFind(res, ":") == 1) res = "0" + res;
   return res;
}

ENUM_TIMEFRAMES PeriodoTexto(string nome) {
   if(StringFind(nome, "m15") >= 0) return PERIOD_M15;
   if(StringFind(nome, "m30") >= 0) return PERIOD_M30;
   if(StringFind(nome, "m1") >= 0)  return PERIOD_M1;
   if(StringFind(nome, "m5") >= 0)  return PERIOD_M5;
   if(StringFind(nome, "h1") >= 0)  return PERIOD_H1;
   if(StringFind(nome, "d1") >= 0)  return PERIOD_D1;
   return PERIOD_CURRENT;
}

ENUM_TIMEFRAMES MinutesToTimeframe(int min) {
   if(min <= 1) return PERIOD_M1;
   if(min <= 5) return PERIOD_M5;
   if(min <= 15) return PERIOD_M15;
   if(min <= 30) return PERIOD_M30;
   if(min <= 60) return PERIOD_H1;
   if(min <= 240) return PERIOD_H4;
   return PERIOD_D1;
}

//+------------------------------------------------------------------+
//| Technical Indicators                                             |
//+------------------------------------------------------------------+

Signal CheckMA(int index, int shift=1) {
   if(rules[index].p1_handle == INVALID_HANDLE) return NONE;
   double ma1[], ma2[];
   ArraySetAsSeries(ma1, true); ArraySetAsSeries(ma2, true);
   if(CopyBuffer(rules[index].p1_handle, 0, shift, 2, ma1) <= 1) return NONE;
   if(rules[index].p2_handle != INVALID_HANDLE) {
      if(CopyBuffer(rules[index].p2_handle, 0, shift, 2, ma2) <= 1) return NONE;
      if(ma1[1] < ma2[1] && ma1[0] > ma2[0]) return BUY;
      if(ma1[1] > ma2[1] && ma1[0] < ma2[0]) return SELL;
   } else {
      double close1 = iClose(_Symbol, rules[index].tf, shift);
      double close2 = iClose(_Symbol, rules[index].tf, shift+1);
      if(close2 < ma1[1] && close1 > ma1[0]) return BUY;
      if(close2 > ma1[1] && close1 < ma1[0]) return SELL;
   }
   return NONE;
}

Signal CheckRSI(int index, int shift=1) {
   if(rules[index].p1_handle == INVALID_HANDLE) return NONE;
   double rsi[]; ArraySetAsSeries(rsi, true);
   if(CopyBuffer(rules[index].p1_handle, 0, shift, 2, rsi) <= 1) return NONE;
   if(rules[index].is_cross) {
      if(rsi[1] < rules[index].d1 && rsi[0] >= rules[index].d1) return BUY;
      if(rsi[1] > rules[index].d2 && rsi[0] <= rules[index].d2) return SELL;
   } else {
      if(rsi[0] < rules[index].d2) return BUY;
      if(rsi[0] > rules[index].d1) return SELL;
   }
   return NONE;
}

Signal CheckStoch(int index, int shift=1) {
   if(rules[index].p1_handle == INVALID_HANDLE) return NONE;
   double k[], d[];
   ArraySetAsSeries(k, true); ArraySetAsSeries(d, true);
   CopyBuffer(rules[index].p1_handle, 0, shift, 2, k);
   CopyBuffer(rules[index].p1_handle, 1, shift, 2, d);
   if(k[1] < d[1] && k[0] > d[0]) return BUY;
   if(k[1] > d[1] && k[0] < d[0]) return SELL;
   return NONE;
}

Signal CheckBB(int index, int shift=1) {
   if(rules[index].p1_handle == INVALID_HANDLE) return NONE;
   double up[], lo[];
   ArraySetAsSeries(up, true); ArraySetAsSeries(lo, true);
   CopyBuffer(rules[index].p1_handle, 1, shift, 1, up);
   CopyBuffer(rules[index].p1_handle, 2, shift, 1, lo);
   double close = iClose(_Symbol, rules[index].tf, shift);
   if(close < lo[0]) return BUY;
   if(close > up[0]) return SELL;
   return NONE;
}

Signal CheckDailyBreak(int shift=1) {
   double hi = iHigh(_Symbol, PERIOD_D1, 1);
   double lo = iLow(_Symbol, PERIOD_D1, 1);
   double close = iClose(_Symbol, PERIOD_CURRENT, shift);
   if(close > hi) return BUY;
   if(close < lo) return SELL;
   return NONE;
}

Signal CheckAMA(int index, int shift=1) {
   if(rules[index].p1_handle == INVALID_HANDLE) return NONE;
   double ama[]; ArraySetAsSeries(ama, true);
   CopyBuffer(rules[index].p1_handle, 0, shift, 2, ama);
   if(ama[1] < ama[0]) return BUY;
   if(ama[1] > ama[0]) return SELL;
   return NONE;
}

//+------------------------------------------------------------------+
//| Trade Execution                                                  |
//+------------------------------------------------------------------+

void EnviaOrdem(Signal s) {
   if(s == NONE) return;
   if(!p_hedge) {
      for(int i=PositionsTotal()-1; i>=0; i--) {
         if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == EA_MAGIC) {
            if((s == BUY && posInfo.PositionType() == POSITION_TYPE_SELL) || (s == SELL && posInfo.PositionType() == POSITION_TYPE_BUY))
               trade.PositionClose(posInfo.Ticket());
         }
      }
   }
   int count = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
      if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == EA_MAGIC) count++;
   if(count >= p_maxTrades) return;
   double lot = CalculaLote(p_riskPercent);
   double price = (s == BUY) ? symbolInfo.Ask() : symbolInfo.Bid();
   int safety = (int)symbolInfo.StopsLevel() + dynamicSafetyPoints + 1;
   double sl = 0, tp = 0;
   if(p_slPoints > 0) sl = (s == BUY) ? price - MathMax(p_slPoints, safety) * _Point : price + MathMax(p_slPoints, safety) * _Point;
   if(p_tpPoints > 0) tp = (s == BUY) ? price + p_tpPoints * _Point : price - p_tpPoints * _Point;
   if(s == BUY) trade.Buy(lot, _Symbol, price, sl, tp, "MT-Live: BUY");
   else trade.Sell(lot, _Symbol, price, sl, tp, "MT-Live: SELL");
   if(trade.ResultRetcode() != TRADE_RETCODE_DONE) dynamicSafetyPoints = MathMin(dynamicSafetyPoints + 5, 100);
}

double CalculaLote(double risco) {
   double equity = accountInfo.Equity();
   double riskAbs = equity * (risco / 100.0);
   if(p_martingale) {
      if(HistorySelect(TimeCurrent() - 86400, TimeCurrent())) {
         int total = HistoryDealsTotal();
         for(int i=total-1; i>=0; i--) {
            ulong t = HistoryDealGetTicket(i);
            if(HistoryDealGetString(t, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(t, DEAL_ENTRY) == DEAL_ENTRY_OUT) {
               if(HistoryDealGetDouble(t, DEAL_PROFIT) < 0) riskAbs *= 2.0;
               break;
            }
         }
      }
   }
   double slDist = (p_slPoints > 0) ? p_slPoints : 500;
   double vol = riskAbs / (slDist * (symbolInfo.TickValue() / (symbolInfo.TickSize() / _Point)));
   return NormalizeDouble(MathMax(symbolInfo.LotsMin(), MathMin(symbolInfo.LotsMax(), vol)), 2);
}

//+------------------------------------------------------------------+
//| Management & Stats                                               |
//+------------------------------------------------------------------+

void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == EA_MAGIC) {
         double price = (posInfo.PositionType() == POSITION_TYPE_BUY) ? symbolInfo.Bid() : symbolInfo.Ask();
         double open = posInfo.PriceOpen();
         int points = (int)(MathAbs(price - open) / _Point);
         double sl = posInfo.StopLoss();
         bool mod = false;
         if(p_breakEvenPoints > 0 && points >= p_breakEvenPoints) {
            double be = (posInfo.PositionType() == POSITION_TYPE_BUY) ? open + p_breakEvenProfitPoints * _Point : open - p_breakEvenProfitPoints * _Point;
            if(sl == 0 || (posInfo.PositionType() == POSITION_TYPE_BUY && be > sl) || (posInfo.PositionType() == POSITION_TYPE_SELL && (be < sl || sl == 0))) { sl = be; mod = true; }
         }
         if(p_trailingStopPoints > 0 && points >= p_trailingStopPoints) {
            double ts = (posInfo.PositionType() == POSITION_TYPE_BUY) ? price - p_trailingStopPoints * _Point : price + p_trailingStopPoints * _Point;
            if(sl == 0 || (posInfo.PositionType() == POSITION_TYPE_BUY && ts > sl) || (posInfo.PositionType() == POSITION_TYPE_SELL && (ts < sl || sl == 0))) { sl = ts; mod = true; }
         }
         if(mod) trade.PositionModify(posInfo.Ticket(), sl, posInfo.TakeProfit());
      }
   }
}

bool AguardaNoticias() {
   if(p_newsVetoMinutes == 0) return false;
   int handle = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      string s = FileReadString(handle); FileClose(handle);
      if(s == "1") return true;
   }
   MqlCalendarValue values[];
   datetime from = TimeCurrent() - p_newsVetoMinutes * 60;
   datetime to = TimeCurrent() + p_newsVetoMinutes * 60;
   if(CalendarValueHistory(values, from, to)) {
      for(int i=0; i<ArraySize(values); i++) {
         MqlCalendarEvent event;
         if(CalendarEventById(values[i].event_id, event)) {
            if(event.importance == CALENDAR_IMPORTANCE_HIGH) return true;
         }
      }
   }
   return false;
}

void AIOptimizer() {
   if(!HistorySelect(0, TimeCurrent())) return;
   double p = 0, l = 0; int w = 0, lo = 0;
   for(int i=0; i<HistoryDealsTotal(); i++) {
      ulong t = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC) {
         double res = HistoryDealGetDouble(t, DEAL_PROFIT);
         if(res > 0) { p += res; w++; } else if(res < 0) { l += MathAbs(res); lo++; }
      }
   }
   if(w + lo > 5) PrintFormat("AI Stats: WinRate %.1f%%, PF %.2f", (double)w/(w+lo)*100.0, (l>0)?p/l:p);
}

void GravaCSV() {
   int h = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON);
   if(h != INVALID_HANDLE) {
      for(int i=0; i<PositionsTotal(); i++)
         if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC)
            FileWrite(h, posInfo.Ticket(), posInfo.Symbol(), posInfo.PriceOpen(), posInfo.StopLoss());
      FileClose(h);
   }
}

//+------------------------------------------------------------------+
//| MQL5 Wrappers                                                    |
//+------------------------------------------------------------------+
datetime iTime(string s, ENUM_TIMEFRAMES t, int i) { datetime d[1]; return (CopyTime(s,t,i,1,d)>0)?d[0]:0; }
double iClose(string s, ENUM_TIMEFRAMES t, int i) { double d[1]; return (CopyClose(s,t,i,1,d)>0)?d[0]:0; }
double iHigh(string s, ENUM_TIMEFRAMES t, int i) { double d[1]; return (CopyHigh(s,t,i,1,d)>0)?d[0]:0; }
double iLow(string s, ENUM_TIMEFRAMES t, int i) { double d[1]; return (CopyLow(s,t,i,1,d)>0)?d[0]:0; }
double iOpen(string s, ENUM_TIMEFRAMES t, int i) { double d[1]; return (CopyOpen(s,t,i,1,d)>0)?d[0]:0; }

void ResetStrategy() {
   for(int i=0; i<30; i++) {
      if(rules[i].p1_handle != INVALID_HANDLE && rules[i].p1_handle != 0) IndicatorRelease(rules[i].p1_handle);
      if(rules[i].p2_handle != INVALID_HANDLE && rules[i].p2_handle != 0) IndicatorRelease(rules[i].p2_handle);
      rules[i].active = false; rules[i].type = RULE_NONE;
      rules[i].p1_handle = INVALID_HANDLE; rules[i].p2_handle = INVALID_HANDLE;
   }
   nRules = 0; p_slPoints = 0; p_tpPoints = 0; p_martingale = false; p_hedge = true; p_startTimeSeconds = 0;
}
