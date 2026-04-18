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

// ---------- ENUMS & STRUCTS ----------
enum Signal {BUY=1, SELL=-1, NONE=0};

struct Rule {
   bool     active;
   int      type;       // Rule type identifier
   int      tf;         // Timeframe
   int      p1_handle;  // Primary indicator handle
   int      p2_handle;  // Secondary indicator handle
   double   v1;         // Parameter 1 (e.g. period, threshold)
   double   v2;         // Parameter 2
   double   v3;         // Parameter 3
   Signal   intent;     // Fixed intent if applicable
};

// Rule Types
#define RT_MA_CROSS      1
#define RT_RSI_THRESH    2
#define RT_STOCH_CROSS   3
#define RT_BB_BOUNCE     4
#define RT_DAILY_BREAK   5
#define RT_DELTA_AGG     6
#define RT_VOL_CYCLE     7
#define RT_AMA           8
#define RT_BAR2_PAT      9
#define RT_RS_REL        10
#define RT_AI_PRED       11

// ---------- GLOBAL PARAMETERS ----------
Rule p_rules[30];
int  p_nRules = 0;

// Strategy Parameters
double p_riskPercent = 1.0;
int    p_stopPoints  = 300;
int    p_takePoints  = 500;
int    p_maxTrades   = 3;
int    p_beStart     = 0;
int    p_bePlus      = 0;
int    p_trailingStart = 0;
int    p_trailingStep  = 10;
bool   p_useMartingale = false;

// Time Filters
int      p_startTimeSeconds = 0; // Seconds from midnight
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

// State
datetime lastBarTime = 0;
long     EA_MAGIC = 123456;
CTrade   trade;

// ---------- HELPER FUNCTIONS ----------

double GetBufferValue(int handle, int buffer, int shift) {
   double val[1];
   if(CopyBuffer(handle, buffer, shift, 1, val) < 0) return 0;
   return val[0];
}

// 1.1 MÉDIAS & CRUZAMENTOS
Signal CruzamentoMA(Rule &r, int shift=1) {
   if(r.p2_handle != INVALID_HANDLE && r.p2_handle != 0) {
      // MA vs MA
      double f  = GetBufferValue(r.p1_handle, 0, shift);
      double s  = GetBufferValue(r.p2_handle, 0, shift);
      double fp = GetBufferValue(r.p1_handle, 0, shift+1);
      double sp = GetBufferValue(r.p2_handle, 0, shift+1);
      if(fp < sp && f > s) return BUY;
      if(fp > sp && f < s) return SELL;
   } else {
      // Price vs MA
      double ma  = GetBufferValue(r.p1_handle, 0, shift);
      double map = GetBufferValue(r.p1_handle, 0, shift+1);
      double c   = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
      double cp  = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift+1);
      if(cp < map && c > ma) return BUY;
      if(cp > map && c < ma) return SELL;
   }
   return NONE;
}

// 1.2 RSI
Signal RSIThreshold(Rule &r, int shift=1) {
   double v = GetBufferValue(r.p1_handle, 0, shift);
   double vp = GetBufferValue(r.p1_handle, 0, shift+1);

   if(r.intent == BUY) {
      if(vp < r.v1 && v > r.v1) return BUY;
   } else if(r.intent == SELL) {
      if(vp > r.v1 && v < r.v1) return SELL;
   } else {
      // Standard overbought/oversold logic if no specific intent is provided
      // Use heuristic thresholds if r.v1 (threshold) is not set for bidirectional
      double upper = (r.v1 > 50) ? r.v1 : 70;
      double lower = (r.v1 < 50 && r.v1 > 0) ? r.v1 : 30;
      if(v > upper) return SELL;
      if(v < lower) return BUY;
   }
   return NONE;
}

// 1.3 ESTOCÁSTICO
Signal StochCross(Rule &r, int shift=1) {
   double k1 = GetBufferValue(r.p1_handle, 0, shift);
   double d1 = GetBufferValue(r.p1_handle, 1, shift);
   double k2 = GetBufferValue(r.p1_handle, 0, shift+1);
   double d2 = GetBufferValue(r.p1_handle, 1, shift+1);
   if(k2 < d2 && k1 > d1) return BUY;
   if(k2 > d2 && k1 < d1) return SELL;
   return NONE;
}

// 1.4 BOLLINGER BOUNCE
Signal BBounce(Rule &r, int shift=1) {
   double upper = GetBufferValue(r.p1_handle, 1, shift);
   double lower = GetBufferValue(r.p1_handle, 2, shift);
   double close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
   if(close < lower) return BUY;
   if(close > upper) return SELL;
   return NONE;
}

// 1.5 BREAKOUT DIÁRIO
Signal DailyBreak(Rule &r, int shift=1) {
   static datetime today = 0;
   static double hi = 0, lo = 0;
   datetime currentDay = iTime(_Symbol, PERIOD_D1, 0);
   if(currentDay != today) {
      today = currentDay;
      hi = iHigh(_Symbol, PERIOD_D1, 1);
      lo = iLow(_Symbol, PERIOD_D1, 1);
   }
   double close = iClose(_Symbol, PERIOD_M1, shift);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(close > hi + tickSize) return BUY;
   if(close < lo - tickSize) return SELL;
   return NONE;
}

// 1.6 MICROESTRUTURA: DELTA DE AGRESSÃO
Signal DeltaAggression(Rule &r) {
   MqlTick arr[];
   int seconds = (int)r.v1;
   int deltaTrigger = (int)r.v2;
   int n = CopyTicksRange(_Symbol, arr, COPY_TICKS_TRADE, TimeCurrent() - seconds, TimeCurrent());
   long buy = 0, sell = 0;
   for(int i = 0; i < n; i++) {
      if((arr[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++;
      else if((arr[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sell++;
   }
   long delta = buy - sell;
   if(delta > deltaTrigger) return BUY;
   if(delta < -deltaTrigger) return SELL;
   return NONE;
}

// 1.7 CICLO DE VOLUME
Signal VolumeCycle(Rule &r, int shift=1) {
   long vol[];
   int len = (int)r.v1;
   CopyVolume(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift, len, vol);
   int maxIdx = 0, minIdx = 0;
   for(int i=0; i<len; i++) {
      if(vol[i] > vol[maxIdx]) maxIdx = i;
      if(vol[i] < vol[minIdx]) minIdx = i;
   }
   if(vol[0] == vol[maxIdx]) return SELL;
   if(vol[0] == vol[minIdx]) return BUY;
   return NONE;
}

// 1.8 AMA
Signal AMASignal(Rule &r, int shift=1) {
   double ama  = GetBufferValue(r.p1_handle, 0, shift);
   double amap = GetBufferValue(r.p1_handle, 0, shift+1);
   if(amap < ama) return BUY;
   if(amap > ama) return SELL;
   return NONE;
}

// 1.9 BAR PATTERN
Signal Bar2Pattern(Rule &r, int shift=1) {
   double h0 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
   double l0 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
   double h1 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift+1);
   double l1 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift+1);
   bool bullish = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
   if(h0 < h1 && l0 > l1) return bullish ? BUY : SELL; // Inside Bar
   if(h0 > h1 && l0 < l1) return bullish ? SELL : BUY; // Outside Bar
   return NONE;
}

// 1.10 FORÇA RELATIVA
Signal RSRelative(Rule &r, int shift=1) {
   double r1 = GetBufferValue(r.p1_handle, 0, shift);
   double r2 = GetBufferValue(r.p2_handle, 0, shift);
   if(r1 > r2 + 5) return BUY;
   if(r1 < r2 - 5) return SELL;
   return NONE;
}

// 1.11 AI PRED
Signal AIPred(Rule &r, int shift=1) {
   // Heuristic: ATR + Candle size
   int atrHandle = iATR(_Symbol, PERIOD_CURRENT, 14);
   double atr[1]; CopyBuffer(atrHandle, 0, shift, 1, atr);
   double body = MathAbs(iClose(_Symbol, PERIOD_CURRENT, shift) - iOpen(_Symbol, PERIOD_CURRENT, shift));
   if(body > atr[0] * 1.5) {
      return (iClose(_Symbol, PERIOD_CURRENT, shift) > iOpen(_Symbol, PERIOD_CURRENT, shift)) ? BUY : SELL;
   }
   return NONE;
}

// ---------- NLP PARSER ----------

double ExtraiNumero(string txt, int &start) {
   string res = "";
   bool found = false;
   for(int i = start; i < StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.') {
         res += StringSubstr(txt, i, 1);
         found = true;
      } else if(found) {
         start = i;
         return StringToDouble(res);
      }
   }
   return found ? StringToDouble(res) : -1;
}

double ExtraiValorApos(string txt, string keyword) {
   int pos = StringFind(txt, keyword);
   if(pos < 0) return -1;
   int start = pos + StringLen(keyword);
   return ExtraiNumero(txt, start);
}

int PeriodoTexto(string txt) {
   string t = txt; StringToLower(t);
   if(StringFind(t, "30 minutos") >= 0 || StringFind(t, "m30") >= 0) return PERIOD_M30;
   if(StringFind(t, "15 minutos") >= 0 || StringFind(t, "m15") >= 0) return PERIOD_M15;
   if(StringFind(t, "5 minutos") >= 0 || StringFind(t, "m5") >= 0)  return PERIOD_M5;
   if(StringFind(t, "1 minuto") >= 0 || StringFind(t, "m1") >= 0)   return PERIOD_M1;
   if(StringFind(t, "h4") >= 0) return PERIOD_H4;
   if(StringFind(t, "h1") >= 0) return PERIOD_H1;
   if(StringFind(t, "d1") >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

void ResetStrategy() {
   for(int i=0; i<p_nRules; i++) {
      if(p_rules[i].p1_handle != INVALID_HANDLE && p_rules[i].p1_handle != 0) IndicatorRelease(p_rules[i].p1_handle);
      if(p_rules[i].p2_handle != INVALID_HANDLE && p_rules[i].p2_handle != 0) IndicatorRelease(p_rules[i].p2_handle);
   }
   p_nRules = 0;
   p_riskPercent = 1.0;
   p_stopPoints = 300;
   p_takePoints = 500;
   p_maxTrades = 3;
   p_beStart = 0; p_bePlus = 0;
   p_trailingStart = 0;
   p_startTimeSeconds = 0;
   p_useMartingale = false;
}

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   string p = prompt; StringToLower(p);

   // Global overrides
   double r = ExtraiValorApos(p, "risco de");
   if(r > 0) p_riskPercent = r;
   double s = ExtraiValorApos(p, "stop de");
   if(s > 0) p_stopPoints = (int)s;
   double t = ExtraiValorApos(p, "take de");
   if(t > 0) p_takePoints = (int)t;
   double m = ExtraiValorApos(p, "máximo");
   if(m > 0) p_maxTrades = (int)m;

   if(StringFind(p, "martingale") >= 0) p_useMartingale = true;

   // Break-even
   if(StringFind(p, "atingir +") >= 0) {
      p_beStart = (int)ExtraiValorApos(p, "atingir +");
      p_bePlus = (int)ExtraiValorApos(p, "entrada +");
   }

   // Time filter
   int hPos = StringFind(p, "depois das ");
   if(hPos >= 0) {
      int start = hPos + 12;
      double hh = ExtraiNumero(p, start);
      p_startTimeSeconds = (int)hh * 3600;
   }

   p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(p);

   // Split into segments
   string segments[];
   string temp = p;
   StringReplace(temp, " e ", "|");
   StringReplace(temp, ".", "|");
   StringReplace(temp, ",", "|");
   ushort sep = StringGetCharacter("|", 0);
   StringSplit(temp, sep, segments);

   Signal currentIntent = NONE;
   for(int i=0; i<ArraySize(segments); i++) {
      string seg = segments[i];
      if(StringFind(seg, "compra") >= 0) currentIntent = BUY;
      else if(StringFind(seg, "vende") >= 0) currentIntent = SELL;

      Rule rule; rule.active = true; rule.tf = p_frequency; rule.intent = currentIntent;
      rule.p1_handle = INVALID_HANDLE; rule.p2_handle = INVALID_HANDLE;

      if(StringFind(seg, " média ") >= 0 || StringFind(seg, " ma ") >= 0) {
         rule.type = RT_MA_CROSS;
         int start = 0;
         rule.v1 = ExtraiNumero(seg, start);
         if(rule.v1 <= 0) rule.v1 = 20; // default
         rule.v2 = ExtraiNumero(seg, start);
         rule.p1_handle = iMA(_Symbol, (ENUM_TIMEFRAMES)rule.tf, (int)rule.v1, 0, MODE_SMA, PRICE_CLOSE);
         if(rule.v2 > 0) rule.p2_handle = iMA(_Symbol, (ENUM_TIMEFRAMES)rule.tf, (int)rule.v2, 0, MODE_SMA, PRICE_CLOSE);
         p_rules[p_nRules++] = rule;
      }
      else if(StringFind(seg, "rsi") >= 0) {
         rule.type = RT_RSI_THRESH;
         int start = 0;
         double first = ExtraiNumero(seg, start);
         double second = ExtraiNumero(seg, start);
         int period = 14;
         double threshold = 50;

         if(second > 0) {
            period = (int)first;
            threshold = second;
         } else if(first > 0) {
            if(first < 30) period = (int)first;
            else threshold = first;
         }

         rule.v1 = threshold;
         rule.v2 = period;
         rule.p1_handle = iRSI(_Symbol, (ENUM_TIMEFRAMES)rule.tf, period, PRICE_CLOSE);
         p_rules[p_nRules++] = rule;
      }
      else if(StringFind(seg, "estocástico") >= 0 || StringFind(seg, "stoch") >= 0) {
         rule.type = RT_STOCH_CROSS;
         rule.p1_handle = iStochastic(_Symbol, (ENUM_TIMEFRAMES)rule.tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
         p_rules[p_nRules++] = rule;
      }
      else if(StringFind(seg, "bollinger") >= 0 || StringFind(seg, "bb") >= 0) {
         rule.type = RT_BB_BOUNCE;
         rule.p1_handle = iBands(_Symbol, (ENUM_TIMEFRAMES)rule.tf, 20, 0, 2.0, PRICE_CLOSE);
         p_rules[p_nRules++] = rule;
      }
      else if(StringFind(seg, "rompimento diário") >= 0) {
         rule.type = RT_DAILY_BREAK;
         p_rules[p_nRules++] = rule;
      }
      else if(StringFind(seg, "delta") >= 0) {
         rule.type = RT_DELTA_AGG;
         rule.v1 = 60; rule.v2 = 300;
         p_rules[p_nRules++] = rule;
      }
      else if(StringFind(seg, "previsão") >= 0 || StringFind(seg, "ai") >= 0) {
         rule.type = RT_AI_PRED;
         p_rules[p_nRules++] = rule;
      }
   }
}

// ---------- DECISION ENGINE ----------

Signal AvaliaRegra(Rule &r, int shift=1) {
   switch(r.type) {
      case RT_MA_CROSS:    return CruzamentoMA(r, shift);
      case RT_RSI_THRESH:  return RSIThreshold(r, shift);
      case RT_STOCH_CROSS: return StochCross(r, shift);
      case RT_BB_BOUNCE:   return BBounce(r, shift);
      case RT_DAILY_BREAK: return DailyBreak(r, shift);
      case RT_DELTA_AGG:   return DeltaAggression(r);
      case RT_VOL_CYCLE:   return VolumeCycle(r, shift);
      case RT_AMA:         return AMASignal(r, shift);
      case RT_BAR2_PAT:    return Bar2Pattern(r, shift);
      case RT_RS_REL:      return RSRelative(r, shift);
      case RT_AI_PRED:     return AIPred(r, shift);
   }
   return NONE;
}

Signal AvaliaTudo() {
   int buyLeg = 0, buyRules = 0;
   int sellLeg = 0, sellRules = 0;

   for(int i=0; i<p_nRules; i++) {
      Signal s = AvaliaRegra(p_rules[i], 1);
      if(p_rules[i].intent == BUY) { buyLeg += (s == BUY ? 1 : -1); buyRules++; }
      else if(p_rules[i].intent == SELL) { sellLeg += (s == SELL ? 1 : -1); sellRules++; }
      else {
         if(s == BUY) { buyLeg++; sellLeg--; }
         else if(s == SELL) { sellLeg++; buyLeg--; }
      }
   }

   if(buyRules > 0 && buyLeg == buyRules) return BUY;
   if(sellRules > 0 && sellLeg == sellRules) return SELL;
   return NONE;
}

// ---------- EXECUTION & RISK ----------

void GravaLog(string text) {
   int h = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE|FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      FileSeek(h, 0, SEEK_END);
      FileWrite(h, TimeToString(TimeCurrent()) + ": " + text);
      FileClose(h);
   }
   Print(text);
}

bool AguardaNoticias() {
   int h = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(h == INVALID_HANDLE) return false;
   string content = FileReadString(h);
   FileClose(h);
   if(content == "1") return true;
   datetime newsTime = StringToTime(content);
   if(newsTime > 0) {
      if(TimeCurrent() >= newsTime - 1200 && TimeCurrent() <= newsTime + 1200) return true;
   }
   return false;
}

double CalculaLote(double riscoPercent) {
   double capital = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = capital * (riscoPercent / 100.0);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(p_stopPoints <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double lot = riskAmount / (p_stopPoints * (tickValue / (tickSize / _Point)));

   // Martingale
   if(p_useMartingale) {
      HistorySelect(TimeCurrent()-86400, TimeCurrent());
      int total = HistoryDealsTotal();
      for(int i=total-1; i>=0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) lot *= 2.0;
            break;
         }
      }
   }

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot/step) * step;
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   return lot;
}

void EnviaOrdem(Signal s, string reason) {
   if(AguardaNoticias()) { GravaLog("Trade vetoed by news: " + reason); return; }
   if(PositionsTotal() >= p_maxTrades) return;

   double lote = CalculaLote(p_riskPercent);

   MqlTick lastTick; SymbolInfoTick(_Symbol, lastTick);
   double sl = 0, tp = 0;

   if(s == BUY) {
      sl = lastTick.ask - p_stopPoints * _Point;
      tp = lastTick.ask + p_takePoints * _Point;
      trade.SetExpertMagicNumber(EA_MAGIC);
      if(trade.Buy(lote, _Symbol, lastTick.ask, sl, tp, reason)) {
         GravaLog("BUY Order Sent: " + reason + " Lote: " + DoubleToString(lote, 2));
      } else {
         GravaLog("BUY Order Failed: " + IntegerToString(trade.ResultRetcode()) + " " + trade.ResultComment());
      }
   } else if(s == SELL) {
      sl = lastTick.bid + p_stopPoints * _Point;
      tp = lastTick.bid - p_takePoints * _Point;
      trade.SetExpertMagicNumber(EA_MAGIC);
      if(trade.Sell(lote, _Symbol, lastTick.bid, sl, tp, reason)) {
         GravaLog("SELL Order Sent: " + reason + " Lote: " + DoubleToString(lote, 2));
      } else {
         GravaLog("SELL Order Failed: " + IntegerToString(trade.ResultRetcode()) + " " + trade.ResultComment());
      }
   }
}

void GerenciaPosicoes() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double sl = PositionGetDouble(POSITION_SL);

         // Break-even
         if(p_beStart > 0) {
            double profitPoints = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? (currentPrice - openPrice)/_Point : (openPrice - currentPrice)/_Point;
            if(profitPoints >= p_beStart) {
               double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? openPrice + p_bePlus * _Point : openPrice - p_bePlus * _Point;
               if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && sl < newSL) || (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (sl > newSL || sl == 0))) {
                  trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
                  GravaLog("Break-even triggered for ticket " + IntegerToString(ticket));
               }
            }
         }

         // Trailing Stop
         if(p_trailingStart > 0) {
            double profitPoints = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? (currentPrice - openPrice)/_Point : (openPrice - currentPrice)/_Point;
            if(profitPoints >= p_trailingStart) {
               double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? currentPrice - p_trailingStart * _Point : currentPrice + p_trailingStart * _Point;
               if(MathAbs(newSL - sl) > p_trailingStep * _Point) {
                  trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
               }
            }
         }
      }
   }
}

void GravaCSV() {
   static datetime lastWrite = 0;
   if(TimeCurrent() - lastWrite < 5) return;
   lastWrite = TimeCurrent();

   int h = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      FileWrite(h, "Ticket", "Symbol", "Type", "Volume", "PriceOpen", "Time", "SL", "TP", "Profit", "Reason");
      for(int i = 0; i < PositionsTotal(); i++) {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
            FileWrite(h, ticket, _Symbol, PositionGetInteger(POSITION_TYPE), PositionGetDouble(POSITION_VOLUME),
                      PositionGetDouble(POSITION_PRICE_OPEN), PositionGetInteger(POSITION_TIME),
                      PositionGetDouble(POSITION_SL), PositionGetDouble(POSITION_TP), PositionGetDouble(POSITION_PROFIT), PositionGetString(POSITION_COMMENT));
         }
      }
      FileClose(h);
   }
}

// ---------- OPTIMIZATION & MAIN ----------

void CalculaEstatisticas() {
   HistorySelect(0, TimeCurrent());
   int total = HistoryDealsTotal();
   int wins = 0, losses = 0;
   double profit = 0;
   for(int i = 0; i < total; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
         double p = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         profit += p;
         if(p > 0) wins++; else if(p < 0) losses++;
      }
   }
   double winRate = (wins + losses > 0) ? (double)wins / (wins + losses) : 0;
   GravaLog("Stats: Profit=" + DoubleToString(profit, 2) + " WinRate=" + DoubleToString(winRate*100, 1) + "%");
}

void AIOptimizer() {
   static datetime lastOpt = 0;
   if(TimeCurrent() - lastOpt < 3600) return;
   lastOpt = TimeCurrent();

   HistorySelect(TimeCurrent() - 86400 * 7, TimeCurrent());
   int total = 0, wins = 0;
   for(int i=HistoryDealsTotal()-1; i>=0 && total < 20; i--) {
      ulong t = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC) {
         total++;
         if(HistoryDealGetDouble(t, DEAL_PROFIT) > 0) wins++;
      }
   }
   double wr = (total > 0) ? (double)wins/total : 0.5;
   if(wr < 0.4 && total >= 10) p_riskPercent *= 0.8;
   else if(wr > 0.6 && total >= 10) p_riskPercent = MathMin(2.0, p_riskPercent * 1.2);

   GravaLog("AI Optimizer ran. New risk: " + DoubleToString(p_riskPercent, 2));
}

int OnInit() {
   EventSetTimer(1);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   EventKillTimer();
}

void OnTimer() {
   static datetime lastPromptCheck = 0;
   if(TimeCurrent() - lastPromptCheck >= 5) {
      lastPromptCheck = TimeCurrent();
      int h = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON);
      if(h != INVALID_HANDLE) {
         string prompt = FileReadString(h);
         FileClose(h);
         static string lastPrompt = "";
         if(prompt != lastPrompt && prompt != "") {
            lastPrompt = prompt;
            InterpretaPrompt(prompt);
            GravaLog("New Strategy Loaded: " + prompt);
         }
      }
   }

   AIOptimizer();
}

void OnTick() {
   // Time filter
   MqlDateTime dt; TimeCurrent(dt);
   int secondsToday = dt.hour * 3600 + dt.min * 60 + dt.sec;
   if(secondsToday < p_startTimeSeconds) return;

   // Frequency check
   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar != lastBarTime) {
      lastBarTime = currentBar;
      Signal s = AvaliaTudo();
      if(s != NONE) {
         EnviaOrdem(s, "Signal Match");
      }
   }

   GerenciaPosicoes();
   GravaCSV();
}
