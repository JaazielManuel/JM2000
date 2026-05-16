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

// --- Definitions
#define EA_MAGIC 123456

// --- Enums
enum Signal {BUY=1, SELL=-1, NONE=0};

// --- Structs
struct Rule {
   int      type;       // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: DailyBreak, 6: Delta, 7: Vol, 8: AMA, 9: Bar2, 10: RS, 11: AI
   int      intent;     // BUY or SELL
   int      tf;         // Timeframe
   double   p1, p2, p3; // Parameters
   int      handle1;    // Indicator handle 1
   int      handle2;    // Indicator handle 2

   void Reset() {
      if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease(handle1);
      if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease(handle2);
      type = 0; intent = NONE; tf = PERIOD_CURRENT; p1 = 0; p2 = 0; p3 = 0;
      handle1 = INVALID_HANDLE; handle2 = INVALID_HANDLE;
   }
};

// --- Globals
CTrade         trade;
CPositionInfo  posInfo;
CSymbolInfo    symInfo;
MqlTradeRequest request;
MqlTradeResult  result;
Rule           rules[20];
int            nRules = 0;

double         p_riskPercent = 1.0;
int            p_stopPoints = 0;
int            p_takePoints = 0;
int            p_beStart = 0;
int            p_bePlus = 0;
int            p_trailingStop = 0;
int            p_trailingStep = 0;
int            p_maxTrades = 3;
string         p_startTime = "00:00";
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
bool           p_useMartingale = false;

datetime       lastPromptMod = 0;

// --- Utility Functions

double ExtraiNumero(string text, int &pos) {
   string res = "";
   bool found = false;
   int len = StringLen(text);
   for(int i = pos; i < len; i++) {
      ushort c = StringGetCharacter(text, i);
      if((c >= '0' && c <= '9') || c == '.') {
         res += ShortToString(c);
         found = true;
      } else if(found) {
         pos = i;
         return StringToDouble(res);
      }
   }
   pos = len;
   return (res == "") ? 0 : StringToDouble(res);
}

double ExtraiValorApos(string text, string keyword) {
   int p = StringFind(text, keyword);
   if(p < 0) return 0;
   int start = p + StringLen(keyword);
   return ExtraiNumero(text, start);
}

int PeriodoTexto(string text) {
   string work = text;
   StringToLower(work);
   if(StringFind(work, "m1") >= 0 && StringFind(work, "m15") < 0) return PERIOD_M1;
   if(StringFind(work, "m5") >= 0 && StringFind(work, "m15") < 0) return PERIOD_M5;
   if(StringFind(work, "m15") >= 0) return PERIOD_M15;
   if(StringFind(work, "m30") >= 0) return PERIOD_M30;
   if(StringFind(work, "h1") >= 0) return PERIOD_H1;
   if(StringFind(work, "h4") >= 0) return PERIOD_H4;
   if(StringFind(work, "d1") >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

// --- Signal Evaluation

double GetBufferValue(int handle, int buffer, int shift) {
   double val[1];
   if(CopyBuffer(handle, buffer, shift, 1, val) < 0) return 0;
   return val[0];
}

bool AvaliaRegra(Rule &r) {
   if(r.type == 1) { // MA
      double ma1 = GetBufferValue(r.handle1, 0, 1);
      double ma2 = GetBufferValue(r.handle1, 0, 2);
      double close1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
      double close2 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
      if(r.intent == BUY) return (close2 < ma2 && close1 > ma1);
      if(r.intent == SELL) return (close2 > ma2 && close1 < ma1);
   }
   if(r.type == 2) { // RSI
      double rsi1 = GetBufferValue(r.handle1, 0, 1);
      double rsi2 = GetBufferValue(r.handle1, 0, 2);
      if(r.intent == BUY) return (rsi2 < r.p2 && rsi1 > r.p2);
      if(r.intent == SELL) return (rsi2 > r.p2 && rsi1 < r.p2);
   }
   if(r.type == 3) { // Stoch
      double k1 = GetBufferValue(r.handle1, 0, 1);
      double d1 = GetBufferValue(r.handle1, 1, 1);
      double k2 = GetBufferValue(r.handle1, 0, 2);
      double d2 = GetBufferValue(r.handle1, 1, 2);
      if(r.intent == BUY) return (k2 < d2 && k1 > d1);
      if(r.intent == SELL) return (k2 > d2 && k1 < d1);
   }
   if(r.type == 4) { // BB
      double close1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
      double upper1 = GetBufferValue(r.handle1, 1, 1);
      double lower1 = GetBufferValue(r.handle1, 2, 1);
      if(r.intent == BUY) return (close1 < lower1);
      if(r.intent == SELL) return (close1 > upper1);
   }
   if(r.type == 5) { // DailyBreak
      double hi = iHigh(_Symbol, PERIOD_D1, 1);
      double lo = iLow(_Symbol, PERIOD_D1, 1);
      double close1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
      if(r.intent == BUY) return (close1 > hi);
      if(r.intent == SELL) return (close1 < lo);
   }
   if(r.type == 6) { // Delta
      MqlTick ticks[];
      int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, TimeCurrent() - (int)r.p1, TimeCurrent());
      long buy = 0, sell = 0;
      for(int i=0; i<n; i++) if(ticks[i].flags&TICK_FLAG_BUY) buy += (long)ticks[i].volume; else sell += (long)ticks[i].volume;
      long delta = buy - sell;
      if(r.intent == BUY) return (delta > (long)r.p2);
      if(r.intent == SELL) return (delta < -(long)r.p2);
   }
   if(r.type == 7) { // Vol
      long v1 = iVolume(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
      long v2 = iVolume(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
      if(r.intent == BUY) return (v1 > v2 * 1.5);
      if(r.intent == SELL) return (v1 > v2 * 1.5);
   }
   if(r.type == 8) { // AMA
      double ama1 = GetBufferValue(r.handle1, 0, 1);
      double ama2 = GetBufferValue(r.handle1, 0, 2);
      if(r.intent == BUY) return (ama1 > ama2);
      if(r.intent == SELL) return (ama1 < ama2);
   }
   if(r.type == 9) { // Bar2
      double h0 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
      double l0 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
      double h1 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
      double l1 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
      bool inside = (h0 < h1 && l0 > l1);
      bool outside = (h0 > h1 && l0 < l1);
      double c0 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
      double o0 = iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
      if(inside) return (r.intent == BUY ? c0 > o0 : c0 < o0);
      if(outside) return (r.intent == BUY ? c0 < o0 : c0 > o0);
   }
   if(r.type == 11) { // AI Signal
      double atr = GetBufferValue(r.handle1, 0, 1);
      double c0 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
      double o0 = iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
      double body = MathAbs(c0 - o0);
      if(r.intent == BUY) return (c0 > o0 && body > 1.5 * atr);
      if(r.intent == SELL) return (c0 < o0 && body > 1.5 * atr);
   }
   return false;
}

Signal AvaliaTudo() {
   int buyVotes = 0, sellVotes = 0;
   int totalBuy = 0, totalSell = 0;

   for(int i=0; i<nRules; i++) {
      if(rules[i].intent == BUY) {
         totalBuy++;
         if(AvaliaRegra(rules[i])) buyVotes++;
      } else if(rules[i].intent == SELL) {
         totalSell++;
         if(AvaliaRegra(rules[i])) sellVotes++;
      }
   }

   if(totalBuy > 0 && buyVotes == totalBuy) return BUY;
   if(totalSell > 0 && sellVotes == totalSell) return SELL;
   return NONE;
}

// --- News & Filter

bool AguardaNoticias() {
   // Binary veto from news_veto.txt
   int h = FileOpen("news_veto.txt", FILE_READ|FILE_ANSI);
   if(h != INVALID_HANDLE) {
      string veto = FileReadString(h);
      FileClose(h);
      if(StringFind(veto, "1") >= 0 || StringFind(veto, "true") >= 0) return true;
   }

   // Advanced calendar check (simulated reading from calendar.txt)
   int hc = FileOpen("calendar.txt", FILE_READ|FILE_ANSI);
   if(hc != INVALID_HANDLE) {
      datetime now = TimeCurrent();
      while(!FileIsEnding(hc)) {
         string line = FileReadString(hc);
         datetime eventTime = (datetime)StringToTime(line);
         if(eventTime > 0) {
            if(now >= eventTime - 20*60 && now <= eventTime + 20*60) {
               FileClose(hc);
               return true;
            }
         }
      }
      FileClose(hc);
   }
   return false;
}

// --- Trade & Management

void GravaLog(string text) {
   int h = FileOpen("MT_LiveExecutor_Log.txt", FILE_READ|FILE_WRITE|FILE_ANSI|FILE_TXT);
   if(h != INVALID_HANDLE) {
      FileSeek(h, 0, SEEK_END);
      FileWrite(h, TimeToString(TimeCurrent()) + ": " + text);
      FileClose(h);
   }
   Print(text);
}

void CalculaStats(double &wr, double &dd, double &pf) {
   HistorySelect(0, TimeCurrent());
   int total = HistoryDealsTotal();
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double peak = balance, current = balance;
   double grossProfit = 0, grossLoss = 0;
   int wins = 0, losses = 0;

   for(int i=0; i<total; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
         double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         if(profit == 0) continue;
         current += profit;
         if(profit > 0) { wins++; grossProfit += profit; }
         else { losses++; grossLoss += MathAbs(profit); }
         if(current > peak) peak = current;
         double d = (peak - current) / peak;
         if(d > dd) dd = d;
      }
   }
   wr = (wins + losses > 0) ? (double)wins / (wins + losses) : 0;
   pf = (grossLoss > 0) ? grossProfit / grossLoss : grossProfit;
}

void GravaCSV() {
   int h = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(h == INVALID_HANDLE) return;
   FileWrite(h, "Ticket", "Symbol", "Type", "Volume", "PriceOpen", "Time", "SL", "TP", "Profit", "Reason");
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC) {
         FileWrite(h, posInfo.Ticket(), posInfo.Symbol(), posInfo.PositionType(), posInfo.Volume(),
                   posInfo.PriceOpen(), posInfo.Time(), posInfo.StopLoss(), posInfo.TakeProfit(),
                   posInfo.Profit(), posInfo.Comment());
      }
   }
   FileClose(h);
}

double CalculaLote(double riskPercent) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = capital * riskPercent / 100.0;
   if(p_useMartingale) {
      HistorySelect(0, TimeCurrent());
      for(int i=HistoryDealsTotal()-1; i>=0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) riskAmount *= 2.0;
            break;
         }
      }
   }
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(p_stopPoints == 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lot = riskAmount / (p_stopPoints * (tickValue / (tickSize / _Point)));
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot/step) * step;
   return MathMax(lot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
}

bool IsTimeAllowed() {
   MqlDateTime dt;
   TimeCurrent(dt);
   string now = StringFormat("%02d:%02d", dt.hour, dt.min);
   return (now >= p_startTime);
}

void EnviaOrdem(int type, string reason) {
   if(!IsTimeAllowed()) return;
   if(AguardaNoticias()) return;
   int count = 0;
   for(int i=PositionsTotal()-1; i>=0; i--) if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC) count++;
   if(count >= p_maxTrades) return;

   double lot = CalculaLote(p_riskPercent);
   double price = (type == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0, tp = 0;
   if(p_stopPoints > 0) sl = (type == BUY) ? price - p_stopPoints * _Point : price + p_stopPoints * _Point;
   if(p_takePoints > 0) tp = (type == BUY) ? price + p_takePoints * _Point : price - p_takePoints * _Point;

   bool success = false;
   for(int i=0; i<3; i++) {
      if(type == BUY) {
         if(trade.Buy(lot, _Symbol, price, sl, tp, reason)) { success = true; break; }
      } else {
         if(trade.Sell(lot, _Symbol, price, sl, tp, reason)) { success = true; break; }
      }
      int err = (int)trade.ResultRetcode();
      if(err != TRADE_RETCODE_REQUOTES && err != TRADE_RETCODE_OFFQUOTES) break;
      price = (type == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   }

   if(success) {
      string msg = StringFormat("Trade Executed: %s at %f, lot %f", (type == BUY ? "BUY" : "SELL"), price, lot);
      GravaLog(msg);
      SendNotification(msg);
      SendMail("MT_LiveExecutor Alert", msg);
   } else {
      GravaLog("Trade Failed: " + trade.ResultComment());
   }
   GravaCSV();
}

void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC) {
         double price = (posInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double points = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (price - posInfo.PriceOpen()) : (posInfo.PriceOpen() - price);
         points /= _Point;

         // Breakeven
         if(p_beStart > 0 && points >= p_beStart && posInfo.StopLoss() != (posInfo.PriceOpen() + p_bePlus * _Point * (posInfo.PositionType()==POSITION_TYPE_BUY?1:-1))) {
            trade.PositionModify(posInfo.Ticket(), posInfo.PriceOpen() + p_bePlus * _Point * (posInfo.PositionType()==POSITION_TYPE_BUY?1:-1), posInfo.TakeProfit());
         }

         // Trailing
         if(p_trailingStop > 0 && points >= p_trailingStop) {
            double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? price - p_trailingStop * _Point : price + p_trailingStop * _Point;
            if(posInfo.PositionType() == POSITION_TYPE_BUY) {
               if(posInfo.StopLoss() < newSL - p_trailingStep * _Point) trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
            } else {
               if(posInfo.StopLoss() > newSL + p_trailingStep * _Point || posInfo.StopLoss() == 0) trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
            }
         }
      }
   }
}

// --- NLP Parser

void InterpretaPrompt(string prompt) {
   string work = prompt;
   StringToLower(work);

   // Reset Strategy
   for(int i = 0; i < 20; i++) rules[i].Reset();
   nRules = 0;

   // Global parameters
   double val;
   val = ExtraiValorApos(work, "risco de");
   if(val > 0) p_riskPercent = val;

   val = ExtraiValorApos(work, "stop de");
   if(val > 0) p_stopPoints = (int)val;

   val = ExtraiValorApos(work, "take de");
   if(val > 0) p_takePoints = (int)val;

   val = ExtraiValorApos(work, "máximo");
   if(val > 0) p_maxTrades = (int)val;

   if(StringFind(work, "martingale") >= 0) p_useMartingale = true;
   else p_useMartingale = false;

   // Timeframe global
   p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(work);
   if(p_frequency == PERIOD_CURRENT) p_frequency = PERIOD_M15;

   // Start Time
   int pTime = StringFind(work, "depois das");
   if(pTime < 0) pTime = StringFind(work, "início");
   if(pTime < 0) pTime = StringFind(work, "começar");
   if(pTime >= 0) {
      int start = pTime + 10;
      int h = (int)ExtraiNumero(work, start);
      int m = 0;
      if(StringGetCharacter(work, start) == ':') {
         start++;
         m = (int)ExtraiNumero(work, start);
      }
      p_startTime = StringFormat("%02d:%02d", h, m);
   }

   // Breakeven & Trailing
   p_beStart = (int)ExtraiValorApos(work, "atingir +");
   p_bePlus = (int)ExtraiValorApos(work, "entrada +");
   p_trailingStop = (int)ExtraiValorApos(work, "trailing stop de");
   if(p_trailingStop == 0) p_trailingStop = (int)ExtraiValorApos(work, "trailing de");
   p_trailingStep = 10; // Default step

   // Rules Parsing
   int currentIntent = NONE;
   string segments[];
   int nSeg = StringSplit(work, '.', segments);
   if(nSeg <= 1) nSeg = StringSplit(work, ';', segments);

   for(int i=0; i<nSeg && nRules < 20; i++) {
      string seg = segments[i];
      if(StringFind(seg, "compra") >= 0) currentIntent = BUY;
      else if(StringFind(seg, "vende") >= 0) currentIntent = SELL;

      if(currentIntent == NONE) continue;

      // MA
      if(StringFind(seg, " ma ") >= 0 || StringFind(seg, " ma/") >= 0 || StringFind(seg, "média") >= 0) {
         rules[nRules].type = 1;
         rules[nRules].intent = currentIntent;
         rules[nRules].tf = PeriodoTexto(seg);
         if(rules[nRules].tf == PERIOD_CURRENT) rules[nRules].tf = (int)p_frequency;
         int pos = 0;
         rules[nRules].p1 = ExtraiNumero(seg, pos);
         if(rules[nRules].p1 == 0) rules[nRules].p1 = 20;
         rules[nRules].handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, (int)rules[nRules].p1, 0, MODE_SMA, PRICE_CLOSE);
         nRules++;
      }

      // RSI
      if(StringFind(seg, "rsi") >= 0 && nRules < 20) {
         rules[nRules].type = 2;
         rules[nRules].intent = currentIntent;
         rules[nRules].tf = PeriodoTexto(seg);
         if(rules[nRules].tf == PERIOD_CURRENT) rules[nRules].tf = (int)p_frequency;
         int pos = StringFind(seg, "rsi") + 3;
         double n1 = ExtraiNumero(seg, pos);
         double n2 = ExtraiNumero(seg, pos);
         if(n2 == 0) {
            if(n1 >= 40) { rules[nRules].p1 = 14; rules[nRules].p2 = n1; }
            else { rules[nRules].p1 = n1; rules[nRules].p2 = (currentIntent == BUY) ? 30 : 70; }
         } else {
            rules[nRules].p1 = n1; rules[nRules].p2 = n2;
         }
         rules[nRules].handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, (int)rules[nRules].p1, PRICE_CLOSE);
         nRules++;
      }

      // Bollinger Bands
      if(StringFind(seg, "bollinger") >= 0 && nRules < 20) {
         rules[nRules].type = 4;
         rules[nRules].intent = currentIntent;
         rules[nRules].tf = PeriodoTexto(seg);
         if(rules[nRules].tf == PERIOD_CURRENT) rules[nRules].tf = (int)p_frequency;
         rules[nRules].p1 = 20; rules[nRules].p2 = 2.0; // Defaults
         rules[nRules].handle1 = iBands(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, 20, 0, 2.0, PRICE_CLOSE);
         nRules++;
      }

      // Stochastic
      if((StringFind(seg, "stoch") >= 0 || StringFind(seg, "estocástico") >= 0) && nRules < 20) {
         rules[nRules].type = 3;
         rules[nRules].intent = currentIntent;
         rules[nRules].tf = PeriodoTexto(seg);
         if(rules[nRules].tf == PERIOD_CURRENT) rules[nRules].tf = (int)p_frequency;
         rules[nRules].handle1 = iStochastic(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
         nRules++;
      }

      // DailyBreak
      if(StringFind(seg, "máxima") >= 0 || StringFind(seg, "mínima") >= 0 || StringFind(seg, "diário") >= 0) {
         rules[nRules].type = 5;
         rules[nRules].intent = currentIntent;
         rules[nRules].tf = (int)p_frequency;
         nRules++;
      }

      // Delta
      if(StringFind(seg, "delta") >= 0 || StringFind(seg, "agressão") >= 0) {
         rules[nRules].type = 6;
         rules[nRules].intent = currentIntent;
         rules[nRules].p1 = 60; // 60s default
         rules[nRules].p2 = 300; // 300 delta default
         nRules++;
      }

      // Volume
      if(StringFind(seg, "volume") >= 0) {
         rules[nRules].type = 7;
         rules[nRules].intent = currentIntent;
         rules[nRules].tf = (int)p_frequency;
         nRules++;
      }

      // AMA
      if(StringFind(seg, "ama") >= 0) {
         rules[nRules].type = 8;
         rules[nRules].intent = currentIntent;
         rules[nRules].tf = (int)p_frequency;
         rules[nRules].handle1 = iAMA(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, 10, 2, 30, 0, PRICE_CLOSE);
         nRules++;
      }

      // Bar2 Patterns
      if(StringFind(seg, "padrão") >= 0 || StringFind(seg, "inside") >= 0 || StringFind(seg, "outside") >= 0) {
         rules[nRules].type = 9;
         rules[nRules].intent = currentIntent;
         rules[nRules].tf = (int)p_frequency;
         nRules++;
      }

      // AI Logic
      if(StringFind(seg, "ia") >= 0 || StringFind(seg, "inteligência") >= 0 || StringFind(seg, "previsão") >= 0) {
         rules[nRules].type = 11;
         rules[nRules].intent = currentIntent;
         rules[nRules].tf = (int)p_frequency;
         rules[nRules].handle1 = iATR(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, 14);
         nRules++;
      }
   }
}

void AIOptimizer() {
   HistorySelect(TimeCurrent() - 3600*24*30, TimeCurrent());
   int total = HistoryDealsTotal();
   int count = 0, wins = 0;
   for(int i=total-1; i>=0 && count < 10; i--) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
         double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         if(profit != 0) {
            count++;
            if(profit > 0) wins++;
         }
      }
   }
   if(count >= 5) {
      double wr = (double)wins / count;
      if(wr < 0.4) p_riskPercent *= 0.8;
   }
}

int OnInit() {
   EventSetTimer(1);
   trade.SetExpertMagicNumber(EA_MAGIC);
   symInfo.Name(_Symbol);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   EventKillTimer();
   for(int i = 0; i < 20; i++) rules[i].Reset();
}

void OnTimer() {
   static datetime lastAI = 0;
   if(TimeCurrent() - lastAI >= 3600) {
      AIOptimizer();
      lastAI = TimeCurrent();
   }

   datetime mod = (datetime)FileGetInteger("prompt.txt", FILE_MODIFY_DATE);
   if(mod > lastPromptMod) {
      int h = FileOpen("prompt.txt", FILE_READ|FILE_ANSI);
      if(h != INVALID_HANDLE) {
         string prompt = FileReadString(h);
         FileClose(h);
         InterpretaPrompt(prompt);
         lastPromptMod = mod;
      }
   }
}

void OnTick() {
   static datetime lastCSV = 0;
   if(TimeCurrent() - lastCSV >= 5) { // Update state every 5 seconds
      GravaCSV();
      lastCSV = TimeCurrent();
   }

   GerenciaPosicoes();

   static datetime lastBar = 0;
   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar != lastBar) {
      Signal s = AvaliaTudo();
      if(s == BUY) EnviaOrdem(BUY, "Signal BUY");
      else if(s == SELL) EnviaOrdem(SELL, "Signal SELL");
      lastBar = currentBar;
   }
}
