//=========================  MT5-KNOWLEDGE-CORE  =========================
// MT-LiveExecutor: Natural Language Strategy Executor
//========================================================================

#property copyright "Copyright 2024, MT-LiveExecutor"
#property link      "https://github.com/MT-LiveExecutor"
#property version   "9.52"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// ---------- DEFINES & CONSTANTS ----------
#define EA_MAGIC 123456
#define MAX_RULES 20

// ---------- ENUMS ----------
enum ENUM_SIGNAL { SIGNAL_NONE=0, SIGNAL_BUY=1, SIGNAL_SELL=-1 };

// ---------- STRUCTS ----------
struct Rule {
   bool           active;
   int            type;       // 1:MA, 2:RSI, 3:Stoch, 4:BB, 5:DailyBreak, 6:Delta, 7:VolCycle, 8:AMA, 9:Bar2, 10:Relative
   int            p1, p2, p3;
   double         d1, d2;
   string         s1;
   int            tf;         // timeframe
   ENUM_SIGNAL    intent;     // BUY or SELL
   int            handle1;
   int            handle2;

   void Reset() {
      active = false; type = 0; p1 = 0; p2 = 0; p3 = 0; d1 = 0; d2 = 0; s1 = ""; tf = 0; intent = SIGNAL_NONE;
      if(handle1 != INVALID_HANDLE) { IndicatorRelease(handle1); handle1 = INVALID_HANDLE; }
      if(handle2 != INVALID_HANDLE) { IndicatorRelease(handle2); handle2 = INVALID_HANDLE; }
   }
};

// ---------- GLOBALS ----------
Rule rules[MAX_RULES];
int nRules = 0;

// Strategy Parameters
double p_risk = 1.0;
int    p_sl = 300;           // points
int    p_tp = 500;           // points
int    p_maxTrades = 3;
int    p_breakeven = 300;     // points to trigger
int    p_breakevenPlus = 50;  // points above entry
int    p_trailingStop = 0;    // points distance
int    p_trailingStep = 50;   // points step
bool   p_martingale = false;
int    p_startTime = 0;       // minutes from midnight
int    p_newsVeto = 20;       // minutes
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

// Global State
datetime lastBarTime = 0;
string currentPrompt = "";
CTrade trade;

// ---------- UTILITIES ----------

double GetBufferValue(int handle, int buffer, int shift) {
   double val[1];
   if(CopyBuffer(handle, buffer, shift, 1, val) < 0) return 0;
   return val[0];
}

// Indicator Functions
ENUM_SIGNAL SignalMA(Rule &r, int shift) {
   double fnow = GetBufferValue(r.handle1, 0, shift);
   double fprev = GetBufferValue(r.handle1, 0, shift+1);
   double snow = GetBufferValue(r.handle2, 0, shift);
   double sprev = GetBufferValue(r.handle2, 0, shift+1);
   if(fprev <= sprev && fnow > snow) return SIGNAL_BUY;
   if(fprev >= sprev && fnow < snow) return SIGNAL_SELL;
   return SIGNAL_NONE;
}
ENUM_SIGNAL SignalRSI(Rule &r, int shift) {
   double v = GetBufferValue(r.handle1, 0, shift);
   if(v > r.d1) return SIGNAL_SELL;
   if(v < r.d2) return SIGNAL_BUY;
   return SIGNAL_NONE;
}
ENUM_SIGNAL SignalStoch(Rule &r, int shift) {
   double k1 = GetBufferValue(r.handle1, 0, shift);
   double d1 = GetBufferValue(r.handle1, 1, shift);
   double k2 = GetBufferValue(r.handle1, 0, shift+1);
   double d2 = GetBufferValue(r.handle1, 1, shift+1);
   if(k2 <= d2 && k1 > d1) return SIGNAL_BUY;
   if(k2 >= d2 && k1 < d1) return SIGNAL_SELL;
   return SIGNAL_NONE;
}
ENUM_SIGNAL SignalBB(Rule &r, int shift) {
   double up = GetBufferValue(r.handle1, 1, shift);
   double lo = GetBufferValue(r.handle1, 2, shift);
   double close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
   if(close < lo) return SIGNAL_BUY;
   if(close > up) return SIGNAL_SELL;
   return SIGNAL_NONE;
}
ENUM_SIGNAL SignalDailyBreak(Rule &r, int shift) {
   double hi = iHigh(_Symbol, PERIOD_D1, 1);
   double lo = iLow(_Symbol, PERIOD_D1, 1);
   double close = iClose(_Symbol, PERIOD_M1, shift);
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(close > hi + tick) return SIGNAL_BUY;
   if(close < lo - tick) return SIGNAL_SELL;
   return SIGNAL_NONE;
}
ENUM_SIGNAL SignalDelta(Rule &r, int shift) {
   MqlTick arr[];
   int n = CopyTicksRange(_Symbol, arr, COPY_TICKS_TRADE, TimeCurrent() - r.p1, TimeCurrent());
   long buy = 0, sell = 0;
   for(int i=0; i<n; i++) {
      if((arr[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++;
      else if((arr[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sell++;
   }
   long delta = buy - sell;
   if(delta > r.p2) return SIGNAL_BUY;
   if(delta < -r.p2) return SIGNAL_SELL;
   return SIGNAL_NONE;
}
ENUM_SIGNAL SignalVolumeCycle(Rule &r, int shift) {
   long vol[]; ArraySetAsSeries(vol, true);
   CopyVolume(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift, r.p1, vol);
   int maxIdx = ArrayMaximum(vol);
   int minIdx = ArrayMinimum(vol);
   if(maxIdx == 0) return SIGNAL_SELL;
   if(minIdx == 0) return SIGNAL_BUY;
   return SIGNAL_NONE;
}
ENUM_SIGNAL SignalAMA(Rule &r, int shift) {
   double now = GetBufferValue(r.handle1, 0, shift);
   double prev = GetBufferValue(r.handle1, 0, shift+1);
   if(now > prev) return SIGNAL_BUY;
   if(now < prev) return SIGNAL_SELL;
   return SIGNAL_NONE;
}
ENUM_SIGNAL SignalBar2(Rule &r, int shift) {
   double h0 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
   double l0 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
   double h1 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift+1);
   double l1 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift+1);
   double c0 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
   double o0 = iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
   if(h0 < h1 && l0 > l1) return (c0 > o0) ? SIGNAL_BUY : SIGNAL_SELL;
   if(h0 > h1 && l0 < l1) return (c0 > o0) ? SIGNAL_SELL : SIGNAL_BUY;
   return SIGNAL_NONE;
}
ENUM_SIGNAL SignalRelative(Rule &r, int shift) {
   double r1 = GetBufferValue(r.handle1, 0, shift);
   double r2 = GetBufferValue(r.handle2, 0, shift);
   if(r1 > r2 + 5) return SIGNAL_BUY;
   if(r1 < r2 - 5) return SIGNAL_SELL;
   return SIGNAL_NONE;
}

// ---------- NLP PARSER ----------

double ExtraiNumero(string txt, int &cursor) {
   string s = "";
   bool found = false;
   int start = cursor;
   for(int i=start; i<StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.' || c == ',') {
         if(c == ',') s += "."; else s += CharToString((uchar)c);
         found = true;
      } else if(found) {
         cursor = i;
         break;
      }
      if(i == StringLen(txt)-1) cursor = i+1;
   }
   return StringToDouble(s);
}

int PeriodoTexto(string txt) {
   string t = txt;
   StringToLower(t);
   if(StringFind(t, "m1") >= 0 && StringFind(t, "m15") < 0) return PERIOD_M1;
   if(StringFind(t, "m5") >= 0) return PERIOD_M5;
   if(StringFind(t, "m15") >= 0) return PERIOD_M15;
   if(StringFind(t, "m30") >= 0) return PERIOD_M30;
   if(StringFind(t, "h1") >= 0) return PERIOD_H1;
   if(StringFind(t, "h4") >= 0) return PERIOD_H4;
   if(StringFind(t, "d1") >= 0) return PERIOD_D1;
   return (int)p_frequency;
}

void AddRule(string txt, ENUM_SIGNAL intent) {
   if(nRules >= MAX_RULES) return;
   string t = txt;
   StringToLower(t);
   int tf = PeriodoTexto(t);
   static int lastMA = 20;
   static int lastRSI = 14;

   if(StringFind(t, "média") >= 0 || StringFind(t, "ma") >= 0) {
      int c = StringFind(t, "média"); if(c < 0) c = StringFind(t, "ma");
      int p = (int)ExtraiNumero(t, c); if(p == 0) p = lastMA; else lastMA = p;
      rules[nRules].Reset(); rules[nRules].active = true; rules[nRules].type = 1;
      rules[nRules].p1 = 9; rules[nRules].p2 = p; rules[nRules].tf = tf; rules[nRules].intent = intent;
      rules[nRules].handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)tf, 9, 0, MODE_EMA, PRICE_CLOSE);
      rules[nRules].handle2 = iMA(_Symbol, (ENUM_TIMEFRAMES)tf, p, 0, MODE_EMA, PRICE_CLOSE);
      if(rules[nRules].handle1 != INVALID_HANDLE && rules[nRules].handle2 != INVALID_HANDLE) nRules++;
   } else if(StringFind(t, "rsi") >= 0) {
      int c = StringFind(t, "rsi") + 3;
      int p = (int)ExtraiNumero(t, c); if(p == 0) p = lastRSI; else lastRSI = p;
      double over = 70, under = 30;
      double n1 = ExtraiNumero(t, c); double n2 = ExtraiNumero(t, c);
      if(n1 > 0) { if(n1 > 50) { over = n1; if(n2 > 0) under = n2; } else { under = n1; if(n2 > 0) over = n2; } }
      rules[nRules].Reset(); rules[nRules].active = true; rules[nRules].type = 2;
      rules[nRules].p1 = p; rules[nRules].d1 = over; rules[nRules].d2 = under; rules[nRules].tf = tf; rules[nRules].intent = intent;
      rules[nRules].handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)tf, p, PRICE_CLOSE);
      if(rules[nRules].handle1 != INVALID_HANDLE) nRules++;
   }
}

void InterpretaPrompt(string prompt) {
   for(int i=0; i<MAX_RULES; i++) rules[i].Reset();
   nRules = 0; currentPrompt = prompt;
   string p = prompt; StringReplace(p, " e ", "."); StringReplace(p, ";", ".");
   string segments[]; int n = StringSplit(p, '.', segments);
   ENUM_SIGNAL currentIntent = SIGNAL_NONE;
   for(int i=0; i<n; i++) {
      string s = segments[i]; StringTrimLeft(s); StringTrimRight(s); string sl = s; StringToLower(sl);
      if(StringFind(sl, "compra") >= 0) currentIntent = SIGNAL_BUY;
      if(StringFind(sl, "vende") >= 0) currentIntent = SIGNAL_SELL;
      int c = 0;
      if(StringFind(sl, "risco") >= 0) { c = StringFind(sl, "risco") + 5; p_risk = ExtraiNumero(sl, c); }
      if(StringFind(sl, "stop") >= 0 && StringFind(sl, "move") < 0) { c = StringFind(sl, "stop") + 4; p_sl = (int)ExtraiNumero(sl, c); }
      if(StringFind(sl, "take") >= 0) { c = StringFind(sl, "take") + 4; p_tp = (int)ExtraiNumero(sl, c); }
      if(StringFind(sl, "máximo") >= 0) { c = StringFind(sl, "máximo") + 6; p_maxTrades = (int)ExtraiNumero(sl, c); }
      if(StringFind(sl, "martingale") >= 0) p_martingale = true;
      if(StringFind(sl, "depois das") >= 0 || StringFind(sl, "início") >= 0) {
         c = StringFind(sl, " h"); if(c < 0) c = StringFind(sl, "h");
         if(c > 0) { int hCursor = c-2; if(hCursor < 0) hCursor = 0; p_startTime = (int)ExtraiNumero(sl, hCursor) * 60; }
      }
      if(StringFind(sl, "notícias") >= 0) { c = StringFind(sl, "notícias") - 3; if(c < 0) c = 0; double v = ExtraiNumero(sl, c); if(v > 0) p_newsVeto = (int)v; }
      if(StringFind(sl, "move stop") >= 0 || StringFind(sl, "breakeven") >= 0) {
         c = StringFind(sl, "atingir") + 7; p_breakeven = (int)ExtraiNumero(sl, c); p_breakevenPlus = (int)ExtraiNumero(sl, c);
      }
      if(StringFind(sl, "trailing") >= 0 || StringFind(sl, "rastreio") >= 0) {
         c = StringFind(sl, "trailing") + 8; p_trailingStop = (int)ExtraiNumero(sl, c);
      }
      if(currentIntent != SIGNAL_NONE) AddRule(s, currentIntent);
   }
}

// ---------- SIGNAL ENGINE ----------

ENUM_SIGNAL AvaliaRegra(Rule &r) {
   switch(r.type) {
      case 1: return SignalMA(r, 0); case 2: return SignalRSI(r, 0); case 3: return SignalStoch(r, 0);
      case 4: return SignalBB(r, 0); case 5: return SignalDailyBreak(r, 0); case 6: return SignalDelta(r, 0);
      case 7: return SignalVolumeCycle(r, 0); case 8: return SignalAMA(r, 0); case 9: return SignalBar2(r, 0);
      case 10: return SignalRelative(r, 0);
   }
   return SIGNAL_NONE;
}

ENUM_SIGNAL AvaliaTudo() {
   int buyV = 0, sellV = 0, buyR = 0, sellR = 0;
   for(int i=0; i<nRules; i++) {
      if(!rules[i].active) continue; ENUM_SIGNAL res = AvaliaRegra(rules[i]);
      if(rules[i].intent == SIGNAL_BUY) { buyR++; if(res == SIGNAL_BUY) buyV++; }
      else if(rules[i].intent == SIGNAL_SELL) { sellR++; if(res == SIGNAL_SELL) sellV++; }
   }
   if(buyR > 0 && buyV == buyR) return SIGNAL_BUY;
   if(sellR > 0 && sellV == sellR) return SIGNAL_SELL;
   return SIGNAL_NONE;
}

// ---------- TRADE EXECUTION ----------

void GravaLog(string texto);

double CalculaLote(double riscoP) {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double rVal = balance * (riscoP / 100.0);
   if(p_martingale) {
      HistorySelect(0, TimeCurrent());
      for(int i=HistoryDealsTotal()-1; i>=0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) rVal *= 2.0;
            break;
         }
      }
   }
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lot = rVal / ((p_sl > 0 ? p_sl : 300) * _Point * (tv / ts));
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / stepL) * stepL;
   if(lot < minL) lot = minL; if(lot > maxL) lot = maxL;
   return lot;
}

void EnviaOrdem(ENUM_SIGNAL s, string reason) {
   if(s == SIGNAL_NONE || PositionsTotal() >= p_maxTrades) return;
   double lot = CalculaLote(p_risk); double sl = 0, tp = 0, price = 0;
   if(s == SIGNAL_BUY) {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK); if(p_sl > 0) sl = price - p_sl * _Point; if(p_tp > 0) tp = price + p_tp * _Point;
      if(trade.Buy(lot, _Symbol, price, sl, tp, reason)) GravaLog("BUY: " + reason);
   } else {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID); if(p_sl > 0) sl = price + p_sl * _Point; if(p_tp > 0) tp = price - p_tp * _Point;
      if(trade.Sell(lot, _Symbol, price, sl, tp, reason)) GravaLog("SELL: " + reason);
   }
}

void GerenciaPosicoes() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t) && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
         double op = PositionGetDouble(POSITION_PRICE_OPEN); double sl = PositionGetDouble(POSITION_SL);
         double pr = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(p_breakeven > 0) {
            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
               if(pr - op >= p_breakeven * _Point) { double nSL = op + p_breakevenPlus * _Point; if(sl < nSL) trade.PositionModify(t, nSL, PositionGetDouble(POSITION_TP)); }
            } else {
               if(op - pr >= p_breakeven * _Point) { double nSL = op - p_breakevenPlus * _Point; if(sl == 0 || sl > nSL) trade.PositionModify(t, nSL, PositionGetDouble(POSITION_TP)); }
            }
         }
         if(p_trailingStop > 0) {
            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
               if(pr - op > p_trailingStop * _Point) { double nSL = pr - p_trailingStop * _Point; if(nSL > sl + p_trailingStep * _Point) trade.PositionModify(t, nSL, PositionGetDouble(POSITION_TP)); }
            } else {
               if(op - pr > p_trailingStop * _Point) { double nSL = pr + p_trailingStop * _Point; if(sl == 0 || nSL < sl - p_trailingStep * _Point) trade.PositionModify(t, nSL, PositionGetDouble(POSITION_TP)); }
            }
         }
      }
   }
}

// ---------- EVENT HANDLERS ----------

bool AguardaNoticias();

int OnInit() {
   trade.SetExpertMagicNumber(EA_MAGIC); EventSetTimer(1);
   string prompt = "média 20 e rsi 14 stop 300 take 500";
   InterpretaPrompt(prompt); return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { EventKillTimer(); }

void OnTimer() {
   // Periodic tasks (Stats, etc.)
}

void OnTick() {
   GerenciaPosicoes();
   static datetime lastP = 0;
   if(TimeCurrent() - lastP > 2) {
      int h = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON);
      if(h != INVALID_HANDLE) { string p = FileReadString(h); FileClose(h); if(p != "" && p != currentPrompt) InterpretaPrompt(p); }
      lastP = TimeCurrent();
   }
   datetime curB = iTime(_Symbol, p_frequency, 0);
   if(curB != lastBarTime) {
      lastBarTime = curB; MqlDateTime dt; TimeCurrent(dt);
      if(dt.hour * 60 + dt.min < p_startTime) return;
      if(AguardaNoticias()) return;
      ENUM_SIGNAL sig = AvaliaTudo(); if(sig != SIGNAL_NONE) EnviaOrdem(sig, "NLP Trigger");
   }
}

// ---------- UTILITIES ----------

void GravaLog(string texto) {
   int h = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE|FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) { FileSeek(h, 0, SEEK_END); FileWrite(h, TimeToString(TimeCurrent()) + ": " + texto); FileClose(h); }
}

bool AguardaNoticias() {
   int h = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) { string c = FileReadString(h); FileClose(h); if(StringFind(c, "1") >= 0) return true; }
   int hc = FileOpen("calendar.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(hc != INVALID_HANDLE) {
      while(!FileIsEnding(hc)) {
         string l = FileReadString(hc);
         if(StringFind(l, "High") >= 0 || StringFind(l, "Alto") >= 0) {
            int semi = StringFind(l, ";"); if(semi > 0) {
               datetime nt = StringToTime(StringSubstr(l, 0, semi));
               if(MathAbs(TimeCurrent() - nt) < p_newsVeto * 60) { FileClose(hc); return true; }
            }
         }
      }
      FileClose(hc);
   }
   return false;
}

void CalculaStats() {
   HistorySelect(0, TimeCurrent()); double profit = 0; int wins = 0, losses = 0;
   for(int i=0; i<HistoryDealsTotal(); i++) {
      ulong t = HistoryDealGetTicket(i);
      if(HistoryDealGetString(t, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC) {
         double p = HistoryDealGetDouble(t, DEAL_PROFIT); profit += p;
         if(p > 0) wins++; else if(p < 0) losses++;
      }
   }
   GravaLog("Stats: Profit=" + DoubleToString(profit, 2) + " Wins=" + (string)wins + " Losses=" + (string)losses);
}
