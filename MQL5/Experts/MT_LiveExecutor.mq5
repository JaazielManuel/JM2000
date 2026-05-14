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
#define MAX_RULES 20

//--- ENUMS
enum ENUM_INTENT { INTENT_NONE, INTENT_BUY, INTENT_SELL };
enum Signal { BUY=1, SELL=-1, NONE=0 };

//--- STRUCTS
struct Rule {
   int            type;       // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: DailyBreak, 6: Delta, 7: Vol, 8: AMA, 9: Bar2, 10: RS, 11: AI
   ENUM_INTENT    intent;
   ENUM_TIMEFRAMES timeframe;
   int            p1, p2, p3;
   double         d1, d2;
   string         s1;
   int            handle1;
   int            handle2;

   void Reset() {
      if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease(handle1);
      if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease(handle2);
      type = 0;
      intent = INTENT_NONE;
      timeframe = PERIOD_CURRENT;
      p1 = 0; p2 = 0; p3 = 0;
      d1 = 0.0; d2 = 0.0;
      s1 = "";
      handle1 = INVALID_HANDLE;
      handle2 = INVALID_HANDLE;
   }
};

//--- GLOBAL VARIABLES
CTrade          trade;
Rule            rules[MAX_RULES];
int             nRules = 0;

string          p_strategyPrompt = "";
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
double          p_riskPercent = 1.0;
int             p_stopPoints = 30;
int             p_takePoints = 50;
int             p_maxTrades = 3;
string          p_startTime = "10:00";
int             p_beStart = 0;
int             p_bePlus = 0;
int             p_trailingStop = 0;
int             p_trailingStep = 0;
bool            p_useMartingale = false;

datetime        lastPromptUpdate = 0;
datetime        lastBarTime = 0;
datetime        lastAICheck = 0;

//+------------------------------------------------------------------+
//--- MQL5 HANDLERS
//+------------------------------------------------------------------+
int OnInit() {
   EventSetTimer(1);
   if(FileIsExist("prompt.txt")) {
      int h = FileOpen("prompt.txt", FILE_READ | FILE_TXT | FILE_ANSI);
      if(h != INVALID_HANDLE) {
         p_strategyPrompt = FileReadString(h);
         InterpretaPrompt(p_strategyPrompt);
         lastPromptUpdate = (datetime)FileGetInteger("prompt.txt", FILE_MODIFY_DATE);
         FileClose(h);
      }
   }
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   EventKillTimer();
   ResetStrategy();
}

void OnTick() {
   GravaCSV();
   GerenciaPosicoes();

   if(!IsTimeAllowed()) return;
   if(AguardaNoticias()) return;

   datetime curBar = iTime(_Symbol, p_frequency, 0);
   if(curBar != lastBarTime) {
      Signal s = AvaliaTudo();
      if(s != NONE) {
         int openTrades = 0;
         for(int i=0; i<PositionsTotal(); i++) {
            ulong ticket = PositionGetTicket(i);
            if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) openTrades++;
         }
         if(openTrades < p_maxTrades) {
            EnviaOrdem((s == BUY ? INTENT_BUY : INTENT_SELL), p_riskPercent, "MT-LiveExecutor Signal");
            lastBarTime = curBar;
         }
      }
   }
}

void OnTimer() {
   if(FileIsExist("prompt.txt")) {
      datetime mod = (datetime)FileGetInteger("prompt.txt", FILE_MODIFY_DATE);
      if(mod > lastPromptUpdate) {
         int h = FileOpen("prompt.txt", FILE_READ | FILE_TXT | FILE_ANSI);
         if(h != INVALID_HANDLE) {
            p_strategyPrompt = FileReadString(h);
            InterpretaPrompt(p_strategyPrompt);
            lastPromptUpdate = mod;
            FileClose(h);
            Print("Estratégia atualizada com novo prompt.");
            GravaLog("Estratégia atualizada.");
         }
      }
   }

   if(TimeCurrent() - lastAICheck >= 3600) {
      AIOptimizer();
      lastAICheck = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
//--- NLP PARSER
//+------------------------------------------------------------------+
void ResetStrategy() {
   for(int i=0; i<MAX_RULES; i++) rules[i].Reset();
   nRules = 0;
}

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   string work = prompt;
   StringToLower(work);

   double v;
   v = ExtraiValorApos(work, "risco de"); if(v > 0) p_riskPercent = v;
   v = ExtraiValorApos(work, "stop de"); if(v > 0) p_stopPoints = (int)v;
   v = ExtraiValorApos(work, "take de"); if(v > 0) p_takePoints = (int)v;
   v = ExtraiValorApos(work, "máximo"); if(v > 0) p_maxTrades = (int)v;

   if(StringFind(work, "martingale") >= 0) p_useMartingale = true;

   v = ExtraiValorApos(work, "atingir"); if(v > 0) p_beStart = (int)v;
   v = ExtraiValorApos(work, "entrada +"); if(v > 0) p_bePlus = (int)v;
   v = ExtraiValorApos(work, "trailing") ; if(v > 0) p_trailingStop = (int)v;

   int tPos = StringFind(work, "depois das");
   if(tPos >= 0) {
      int p = tPos + 10;
      while(p < StringLen(work) && !((StringGetCharacter(work, p) >= '0' && StringGetCharacter(work, p) <= '9'))) p++;
      string hStr = "";
      while(p < StringLen(work) && ((StringGetCharacter(work, p) >= '0' && StringGetCharacter(work, p) <= '9') || StringGetCharacter(work, p) == ':' || StringGetCharacter(work, p) == 'h')) {
         hStr += StringSubstr(work, p, 1);
         p++;
      }
      if(StringFind(hStr, "h") >= 0) hStr = StringReplace(hStr, "h", ":") > 0 ? hStr : hStr;
      if(StringLen(hStr) == 2) hStr += ":00";
      p_startTime = hStr;
   }

   p_frequency = PeriodoTexto(work);

   string segments[];
   string temp = work;
   StringReplace(temp, " e ", "|");
   StringReplace(temp, ".", "|");
   StringReplace(temp, ",", "|");
   ushort sep = StringGetCharacter("|", 0);
   StringSplit(temp, sep, segments);

   ENUM_INTENT currentIntent = INTENT_NONE;
   for(int i=0; i<ArraySize(segments); i++) {
      string seg = segments[i];
      if(StringFind(seg, "compra") >= 0) currentIntent = INTENT_BUY;
      else if(StringFind(seg, "vende") >= 0) currentIntent = INTENT_SELL;

      if(currentIntent == INTENT_NONE) continue;
      if(nRules >= MAX_RULES) break;

      Rule r;
      r.Reset();
      r.intent = currentIntent;
      r.timeframe = PeriodoTexto(seg);
      if(r.timeframe == PERIOD_CURRENT) r.timeframe = p_frequency;

      bool found = false;
      if(StringFind(seg, " ma ") >= 0 || StringFind(seg, "ma/") >= 0 || StringFind(seg, "média") >= 0) {
         r.type = 1;
         int p = 0;
         r.p1 = (int)ExtraiNumero(seg, p);
         r.p2 = (int)ExtraiNumero(seg, p);
         if(r.p1 > 0 && r.p2 > 0) {
            r.handle1 = iMA(_Symbol, r.timeframe, r.p1, 0, MODE_EMA, PRICE_CLOSE);
            r.handle2 = iMA(_Symbol, r.timeframe, r.p2, 0, MODE_EMA, PRICE_CLOSE);
         } else if(r.p1 > 0) {
            r.handle1 = iMA(_Symbol, r.timeframe, r.p1, 0, MODE_EMA, PRICE_CLOSE);
         }
         found = true;
      } else if(StringFind(seg, "rsi") >= 0) {
         r.type = 2;
         int p = 0;
         double n1 = ExtraiNumero(seg, p);
         double n2 = ExtraiNumero(seg, p);
         if(n2 > 0) { r.p1 = (int)n1; r.d1 = n2; }
         else if(n1 >= 40) { r.p1 = 14; r.d1 = n1; }
         else { r.p1 = 14; r.d1 = 50; }
         r.handle1 = iRSI(_Symbol, r.timeframe, r.p1, PRICE_CLOSE);
         found = true;
      } else if(StringFind(seg, "estocástico") >= 0 || StringFind(seg, "stoch") >= 0) {
         r.type = 3;
         r.handle1 = iStochastic(_Symbol, r.timeframe, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
         found = true;
      } else if(StringFind(seg, "bollinger") >= 0 || StringFind(seg, " bb ") >= 0) {
         r.type = 4;
         r.handle1 = iBands(_Symbol, r.timeframe, 20, 0, 2.0, PRICE_CLOSE);
         found = true;
      } else if(StringFind(seg, "rompimento diário") >= 0) {
         r.type = 5;
         found = true;
      } else if(StringFind(seg, "delta") >= 0) {
         r.type = 6;
         int p = 0;
         r.p1 = (int)ExtraiNumero(seg, p);
         r.p2 = (int)ExtraiNumero(seg, p);
         if(r.p1 == 0) r.p1 = 60;
         if(r.p2 == 0) r.p2 = 300;
         found = true;
      } else if(StringFind(seg, "volume") >= 0) {
         r.type = 7;
         found = true;
      } else if(StringFind(seg, "ama") >= 0 || StringFind(seg, "adaptativa") >= 0) {
         r.type = 8;
         r.handle1 = iAMA(_Symbol, r.timeframe, 10, 2, 30, 0, PRICE_CLOSE);
         found = true;
      } else if(StringFind(seg, "padrão barras") >= 0 || StringFind(seg, "bar2") >= 0) {
         r.type = 9;
         found = true;
      } else if(StringFind(seg, "força relativa") >= 0) {
         r.type = 10;
         found = true;
      } else if(StringFind(seg, "ia") >= 0 || StringFind(seg, "ai") >= 0 || StringFind(seg, "previsão") >= 0) {
         r.type = 11;
         r.handle1 = iATR(_Symbol, r.timeframe, 14);
         found = true;
      }

      if(found) {
         rules[nRules] = r;
         nRules++;
      }
   }
}

//+------------------------------------------------------------------+
//--- SIGNAL EVALUATION
//+------------------------------------------------------------------+
double GetBufferValue(int handle, int buffer, int shift) {
   double val[1];
   if(CopyBuffer(handle, buffer, shift, 1, val) < 0) return 0;
   return val[0];
}

bool AvaliaRegra(Rule &r) {
   if(r.type == 1) {
      if(r.handle2 != INVALID_HANDLE) {
         double f1 = GetBufferValue(r.handle1, 0, 1);
         double s1 = GetBufferValue(r.handle2, 0, 1);
         double f2 = GetBufferValue(r.handle1, 0, 2);
         double s2 = GetBufferValue(r.handle2, 0, 2);
         if(r.intent == INTENT_BUY) return (f2 < s2 && f1 > s1);
         if(r.intent == INTENT_SELL) return (f2 > s2 && f1 < s1);
      } else {
         double ma1 = GetBufferValue(r.handle1, 0, 1);
         double ma2 = GetBufferValue(r.handle1, 0, 2);
         double c1 = iClose(_Symbol, r.timeframe, 1);
         double c2 = iClose(_Symbol, r.timeframe, 2);
         if(r.intent == INTENT_BUY) return (c2 < ma2 && c1 > ma1);
         if(r.intent == INTENT_SELL) return (c2 > ma2 && c1 < ma1);
      }
   } else if(r.type == 2) {
      double rsi1 = GetBufferValue(r.handle1, 0, 1);
      double rsi2 = GetBufferValue(r.handle1, 0, 2);
      if(r.intent == INTENT_BUY) return (rsi2 < r.d1 && rsi1 > r.d1);
      if(r.intent == INTENT_SELL) return (rsi2 > r.d1 && rsi1 < r.d1);
   } else if(r.type == 3) {
      double k1 = GetBufferValue(r.handle1, 0, 1);
      double d1 = GetBufferValue(r.handle1, 1, 1);
      double k2 = GetBufferValue(r.handle1, 0, 2);
      double d2 = GetBufferValue(r.handle1, 1, 2);
      if(r.intent == INTENT_BUY) return (k2 < d2 && k1 > d1);
      if(r.intent == INTENT_SELL) return (k2 > d2 && k1 < d1);
   } else if(r.type == 4) {
      double up = GetBufferValue(r.handle1, 1, 1);
      double lo = GetBufferValue(r.handle1, 2, 1);
      double c1 = iClose(_Symbol, r.timeframe, 1);
      if(r.intent == INTENT_BUY) return (c1 < lo);
      if(r.intent == INTENT_SELL) return (c1 > up);
   } else if(r.type == 5) {
      double hi = iHigh(_Symbol, PERIOD_D1, 1);
      double lo = iLow(_Symbol, PERIOD_D1, 1);
      double c1 = iClose(_Symbol, r.timeframe, 1);
      if(r.intent == INTENT_BUY) return (c1 > hi);
      if(r.intent == INTENT_SELL) return (c1 < lo);
   } else if(r.type == 6) {
      MqlTick ticks[];
      int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, TimeCurrent() - r.p1, TimeCurrent());
      long buy = 0, sell = 0;
      for(int i=0; i<n; i++) if((ticks[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy += (long)ticks[i].volume; else sell += (long)ticks[i].volume;
      long delta = buy - sell;
      if(r.intent == INTENT_BUY) return (delta > r.p2);
      if(r.intent == INTENT_SELL) return (delta < -r.p2);
   } else if(r.type == 7) {
      long v1 = iVolume(_Symbol, r.timeframe, 1);
      long v2 = iVolume(_Symbol, r.timeframe, 2);
      return (v1 > v2 * 1.5);
   } else if(r.type == 8) {
      double ama1 = GetBufferValue(r.handle1, 0, 1);
      double ama2 = GetBufferValue(r.handle1, 0, 2);
      if(r.intent == INTENT_BUY) return (ama1 > ama2);
      if(r.intent == INTENT_SELL) return (ama1 < ama2);
   } else if(r.type == 9) {
      double h1 = iHigh(_Symbol, r.timeframe, 1);
      double l1 = iLow(_Symbol, r.timeframe, 1);
      double h2 = iHigh(_Symbol, r.timeframe, 2);
      double l2 = iLow(_Symbol, r.timeframe, 2);
      bool inside = (h1 < h2 && l1 > l2);
      bool outside = (h1 > h2 && l1 < l2);
      if(inside || outside) {
         double c1 = iClose(_Symbol, r.timeframe, 1);
         double o1 = iOpen(_Symbol, r.timeframe, 1);
         if(r.intent == INTENT_BUY) return (c1 > o1);
         if(r.intent == INTENT_SELL) return (c1 < o1);
      }
   } else if(r.type == 10) {
      double rsi1 = iRSI(_Symbol, r.timeframe, 14, PRICE_CLOSE, 1);
      double rsiBench = iRSI("US30", r.timeframe, 14, PRICE_CLOSE, 1);
      if(r.intent == INTENT_BUY) return (rsi1 > rsiBench + 5);
      if(r.intent == INTENT_SELL) return (rsi1 < rsiBench - 5);
   } else if(r.type == 11) {
      double atr = GetBufferValue(r.handle1, 0, 1);
      double body = MathAbs(iClose(_Symbol, r.timeframe, 1) - iOpen(_Symbol, r.timeframe, 1));
      if(body > atr * 1.5) {
         if(r.intent == INTENT_BUY) return (iClose(_Symbol, r.timeframe, 1) > iOpen(_Symbol, r.timeframe, 1));
         if(r.intent == INTENT_SELL) return (iClose(_Symbol, r.timeframe, 1) < iOpen(_Symbol, r.timeframe, 1));
      }
   }
   return false;
}

Signal AvaliaTudo() {
   int buyCount = 0, sellCount = 0;
   int buyRules = 0, sellRules = 0;
   for(int i=0; i<nRules; i++) {
      if(rules[i].intent == INTENT_BUY) { buyRules++; if(AvaliaRegra(rules[i])) buyCount++; }
      else if(rules[i].intent == INTENT_SELL) { sellRules++; if(AvaliaRegra(rules[i])) sellCount++; }
   }
   if(buyRules > 0 && buyCount == buyRules) return BUY;
   if(sellRules > 0 && sellCount == sellRules) return SELL;
   return NONE;
}

//+------------------------------------------------------------------+
//--- TRADE FUNCTIONS
//+------------------------------------------------------------------+
void EnviaOrdem(ENUM_INTENT intent, double risk, string reason) {
   if(intent == INTENT_NONE) return;
   double lote = CalculaLote(risk);
   double price = (intent == INTENT_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0, tp = 0;
   if(intent == INTENT_BUY) {
      if(p_stopPoints > 0) sl = price - p_stopPoints * _Point;
      if(p_takePoints > 0) tp = price + p_takePoints * _Point;
   } else {
      if(p_stopPoints > 0) sl = price + p_stopPoints * _Point;
      if(p_takePoints > 0) tp = price - p_takePoints * _Point;
   }
   double margin;
   if(!OrderCalcMargin((intent == INTENT_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL), _Symbol, lote, price, margin)) return;
   if(margin > AccountInfoDouble(ACCOUNT_FREEMARGIN)) return;
   bool success = false;
   for(int i=0; i<3; i++) {
      trade.SetExpertMagicNumber(EA_MAGIC);
      if(intent == INTENT_BUY) success = trade.Buy(lote, _Symbol, price, sl, tp, reason);
      else success = trade.Sell(lote, _Symbol, price, sl, tp, reason);
      if(success) { SendNotification("MT-LiveExecutor: Ordem executada - " + reason); break; }
      uint res = trade.ResultRetcode();
      if(res != TRADE_RETCODE_REQUOTES && res != TRADE_RETCODE_OFFQUOTES) break;
      price = (intent == INTENT_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   }
}

double CalculaLote(double riskPercent) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAbs = capital * riskPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lote = (p_stopPoints > 0) ? riskAbs / (p_stopPoints * (tickValue / (tickSize / _Point))) : SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(p_useMartingale) {
      HistorySelect(0, TimeCurrent());
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) lote *= 2.0;
            break;
         }
      }
   }
   double stepVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lote = MathFloor(lote / stepVol) * stepVol;
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lote < minVol) lote = minVol;
   if(lote > maxVol) lote = maxVol;
   return lote;
}

void GerenciaPosicoes() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) {
         if(PositionGetInteger(POSITION_MAGIC) != EA_MAGIC || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double curPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double sl = PositionGetDouble(POSITION_SL);
         int points = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? (int)((curPrice - openPrice) / _Point) : (int)((openPrice - curPrice) / _Point);
         if(p_beStart > 0 && points >= p_beStart) {
            double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? openPrice + p_bePlus * _Point : openPrice - p_bePlus * _Point;
            if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && (sl < newSL || sl == 0)) || (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (sl > newSL || sl == 0))) trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
         }
         if(p_trailingStop > 0 && points >= p_trailingStop) {
            double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? curPrice - p_trailingStop * _Point : curPrice + p_trailingStop * _Point;
            if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && (newSL > sl + p_trailingStep * _Point || sl == 0)) || (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (newSL < sl - p_trailingStep * _Point || sl == 0))) trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
         }
      }
   }
}

//+------------------------------------------------------------------+
//--- LOGGING & PERSISTENCE
//+------------------------------------------------------------------+
void GravaLog(string texto) {
   int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE | FILE_READ | FILE_TXT | FILE_ANSI);
   if(handle != INVALID_HANDLE) { FileSeek(handle, 0, SEEK_END); FileWrite(handle, TimeToString(TimeCurrent()) + ": " + texto); FileClose(handle); }
}

void GravaCSV() {
   int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV | FILE_ANSI);
   if(handle != INVALID_HANDLE) {
      FileWrite(handle, "Ticket", "Symbol", "Type", "Volume", "PriceOpen", "Time", "SL", "TP", "Profit", "Reason");
      for(int i = 0; i < PositionsTotal(); i++) {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC)
            FileWrite(handle, ticket, PositionGetString(POSITION_SYMBOL), PositionGetInteger(POSITION_TYPE), PositionGetDouble(POSITION_VOLUME), PositionGetDouble(POSITION_PRICE_OPEN), TimeToString(PositionGetInteger(POSITION_TIME)), PositionGetDouble(POSITION_SL), PositionGetDouble(POSITION_TP), PositionGetDouble(POSITION_PROFIT), PositionGetString(POSITION_COMMENT));
      }
      FileClose(handle);
   }
}

bool AguardaNoticias() {
   if(FileIsExist("news_veto.txt")) {
      int h = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_ANSI);
      if(h != INVALID_HANDLE) { string content = FileReadString(h); FileClose(h); if(content == "1" || content == "true") return true; }
   }
   if(FileIsExist("calendar.txt")) {
      int h = FileOpen("calendar.txt", FILE_READ | FILE_CSV | FILE_ANSI);
      if(h != INVALID_HANDLE) {
         datetime now = TimeCurrent();
         while(!FileIsEnding(h)) {
            datetime eventTime = StringToTime(FileReadString(h));
            if(eventTime > 0 && now >= eventTime - 1200 && now <= eventTime + 1200) { FileClose(h); return true; }
         }
         FileClose(h);
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//--- OPTIMIZER
//+------------------------------------------------------------------+
void AIOptimizer() {
   HistorySelect(TimeCurrent() - 36000, TimeCurrent());
   int wins = 0, count = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0 && count < 10; i--) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
         if(HistoryDealGetDouble(ticket, DEAL_PROFIT) > 0) wins++;
         count++;
      }
   }
   if(count >= 5 && (double)wins / count < 0.4) p_riskPercent *= 0.9;
}

//+------------------------------------------------------------------+
//--- UTILS
//+------------------------------------------------------------------+
double ExtraiValorApos(string texto, string chave) {
   int pos = StringFind(texto, chave);
   if(pos < 0) return -1;
   pos += StringLen(chave);
   while(pos < StringLen(texto) && (StringGetCharacter(texto, pos) == ' ' || StringGetCharacter(texto, pos) == ':')) pos++;
   string valStr = "";
   while(pos < StringLen(texto) && ((StringGetCharacter(texto, pos) >= '0' && StringGetCharacter(texto, pos) <= '9') || StringGetCharacter(texto, pos) == '.')) { valStr += StringSubstr(texto, pos, 1); pos++; }
   return StringToDouble(valStr);
}

double ExtraiNumero(string texto, int &startPos) {
   while(startPos < StringLen(texto) && !((StringGetCharacter(texto, startPos) >= '0' && StringGetCharacter(texto, startPos) <= '9') || StringGetCharacter(texto, startPos) == '.')) startPos++;
   string valStr = "";
   while(startPos < StringLen(texto) && ((StringGetCharacter(texto, startPos) >= '0' && StringGetCharacter(texto, startPos) <= '9') || StringGetCharacter(texto, startPos) == '.')) { valStr += StringSubstr(texto, startPos, 1); startPos++; }
   return StringToDouble(valStr);
}

ENUM_TIMEFRAMES PeriodoTexto(string texto) {
   if(StringFind(texto, "m15") >= 0) return PERIOD_M15;
   if(StringFind(texto, "m1") >= 0 && StringFind(texto, "m15") < 0) return PERIOD_M1;
   if(StringFind(texto, "m5") >= 0 && StringFind(texto, "m15") < 0) return PERIOD_M5;
   if(StringFind(texto, "h1") >= 0) return PERIOD_H1;
   if(StringFind(texto, "d1") >= 0) return PERIOD_D1;
   if(StringFind(texto, "minutos") >= 0 || StringFind(texto, "min") >= 0) {
      int p = 0; int val = (int)ExtraiNumero(texto, p);
      if(val == 1) return PERIOD_M1; if(val == 5) return PERIOD_M5; if(val == 15) return PERIOD_M15; if(val == 30) return PERIOD_M30; if(val == 60) return PERIOD_H1;
   }
   return PERIOD_CURRENT;
}

bool IsTimeAllowed() { return (TimeToString(TimeCurrent(), TIME_MINUTES) >= p_startTime); }
