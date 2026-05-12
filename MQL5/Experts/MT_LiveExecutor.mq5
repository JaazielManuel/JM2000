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

//--- Enums
enum ENUM_SIGNAL { SIGNAL_NONE=0, SIGNAL_BUY=1, SIGNAL_SELL=-1 };

//--- Constants
#define EA_MAGIC 123456

//--- Global Variables (Strategy Parameters)
double   p_riskPercent  = 1.0;
int      p_stopPoints   = 0;
int      p_takePoints   = 0;
int      p_maxTrades    = 3;
string   p_startTime    = "00:00";
int      p_frequency    = PERIOD_M15;
int      p_beStart      = 0;
int      p_bePlus       = 0;
int      p_trailingStop = 0;
int      p_trailingStep = 0;
bool     p_useMartingale= false;

//--- State Variables
datetime last_prompt_mod = 0;
CTrade   trade;

//--- Rule Structure
struct Rule {
   int      type;       // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: DailyBreak, 6: Delta, 7: Vol, 8: AMA, 9: Bar2, 10: RS, 11: AI
   int      intent;     // SIGNAL_BUY or SIGNAL_SELL
   int      tf;         // Timeframe
   int      p1, p2, p3; // Integer parameters
   double   d1, d2;     // Double parameters
   string   s1;         // String parameter (e.g., benchmark symbol)
   int      handle1;    // Indicator handle 1
   int      handle2;    // Indicator handle 2

   void Reset() {
      if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease(handle1);
      if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease(handle2);
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

Rule rules[20];
int  nRules = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(EA_MAGIC);
   EventSetTimer(1); // Check prompt every second
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   EventKillTimer();
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
   GravaCSV();
   GerenciaPosicoes();

   static datetime lastBar = 0;
   datetime currentBar = iTime(_Symbol, (ENUM_TIMEFRAMES)p_frequency, 0);

   if(currentBar != lastBar) {
      if(IsTimeAllowed()) {
         ENUM_SIGNAL sig = AvaliaTudo();
         if(sig != SIGNAL_NONE) {
            string reason = "Signal from prompt";
            EnviaOrdem(sig, p_riskPercent, reason);
         }
      }
      lastBar = currentBar;
   }
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer() {
   // 1. Check for prompt update
   string filename = "prompt.txt";
   datetime mod = (datetime)FileGetInteger(filename, FILE_MODIFY_DATE, false);
   if(mod > last_prompt_mod) {
      ResetStrategy();
      int handle = FileOpen(filename, FILE_READ | FILE_TXT | FILE_ANSI);
      if(handle != INVALID_HANDLE) {
         string prompt = FileReadString(handle);
         FileClose(handle);
         InterpretaPrompt(prompt);
         last_prompt_mod = mod;
      }
   }

   // 2. AI Optimizer (Hourly)
   static datetime lastAI = 0;
   if(TimeCurrent() - lastAI > 3600) {
      AIOptimizer();
      lastAI = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
//| Utilities                                                        |
//+------------------------------------------------------------------+
int PeriodoTexto(string text) {
   string work = text;
   StringToLower(work);
   if(StringFind(work, "m15") >= 0) return PERIOD_M15;
   if(StringFind(work, "m1") >= 0)  return PERIOD_M1;
   if(StringFind(work, "m5") >= 0)  return PERIOD_M5;
   if(StringFind(work, "h1") >= 0)  return PERIOD_H1;
   if(StringFind(work, "d1") >= 0)  return PERIOD_D1;
   if(StringFind(work, "minutos") >= 0 || StringFind(work, "min") >= 0) {
      if(StringFind(work, "15") >= 0) return PERIOD_M15;
      if(StringFind(work, "5") >= 0)  return PERIOD_M5;
      if(StringFind(work, "1") >= 0)  return PERIOD_M1;
   }
   return PERIOD_CURRENT;
}

double ExtraiValorApos(string text, string keyword) {
   string work = text;
   StringToLower(work);
   int pos = StringFind(work, keyword);
   if(pos < 0) return -1;

   string sub = StringSubstr(text, pos + StringLen(keyword));
   return StringToDouble(sub);
}

bool IsTimeAllowed() {
   if(p_startTime == "" || p_startTime == "00:00") return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string now = StringFormat("%02d:%02d", dt.hour, dt.min);
   return (now >= p_startTime);
}

void ResetStrategy() {
   for(int i=0; i<20; i++) rules[i].Reset();
   nRules = 0;
   // Reset global params to defaults if needed
}

double ExtraiNumero(string text, int &pos) {
   string work = text;
   int len = StringLen(work);
   string res = "";
   bool found = false;

   while(pos < len) {
      ushort c = StringGetCharacter(work, pos);
      if((c >= '0' && c <= '9') || c == '.') {
         res += ShortToString(c);
         found = true;
      } else if(found) {
         break;
      }
      pos++;
   }
   return StringToDouble(res);
}

void InterpretaPrompt(string prompt) {
   string work = prompt;
   StringToLower(work);

   // 1. Global Parameters
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

   int p = StringFind(work, "depois das");
   if(p >= 0) {
      p_startTime = StringSubstr(prompt, p + 11, 5);
   } else if((p = StringFind(work, "início")) >= 0) {
      p_startTime = StringSubstr(prompt, p + 7, 5);
   }

   // Strategy timeframe
   p_frequency = PeriodoTexto(work);

   // Breakeven & Trailing
   val = ExtraiValorApos(work, "atingir +");
   if(val > 0) p_beStart = (int)val;
   val = ExtraiValorApos(work, "entrada +");
   if(val > 0) p_bePlus = (int)val;

   if(StringFind(work, "trailing") >= 0) {
      p_trailingStop = (int)ExtraiValorApos(work, "trailing");
      p_trailingStep = 10; // Default
   }

   // 2. Rules
   string segments[];
   string sep = "|";
   string tempPrompt = prompt;
   StringReplace(tempPrompt, " e ", sep);
   StringReplace(tempPrompt, ".", sep);
   StringReplace(tempPrompt, ",", sep);
   ushort u_sep = StringGetCharacter(sep, 0);
   int nSeg = StringSplit(tempPrompt, u_sep, segments);

   int currentIntent = SIGNAL_NONE;
   for(int i=0; i<nSeg && nRules < 20; i++) {
      string seg = segments[i];
      StringToLower(seg);

      if(StringFind(seg, "compra") >= 0) currentIntent = SIGNAL_BUY;
      else if(StringFind(seg, "vende") >= 0) currentIntent = SIGNAL_SELL;

      if(currentIntent == SIGNAL_NONE) continue;

      Rule r;
      r.Reset();
      r.intent = currentIntent;
      r.tf = PeriodoTexto(seg);
      if(r.tf == PERIOD_CURRENT) r.tf = p_frequency;

      bool ruleFound = false;

      // Moving Average
      if(StringFind(seg, " ma ") >= 0 || StringFind(seg, " ma/") >= 0 || StringFind(seg, "média") >= 0) {
         r.type = 1;
         int cursor = 0;
         r.p1 = (int)ExtraiNumero(seg, cursor);
         r.p2 = (int)ExtraiNumero(seg, cursor);
         if(r.p1 == 0) r.p1 = 20;
         r.handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_SMA, PRICE_CLOSE);
         if(r.p2 > 0) r.handle2 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p2, 0, MODE_SMA, PRICE_CLOSE);
         ruleFound = true;
      }
      // RSI
      else if(StringFind(seg, "rsi") >= 0) {
         r.type = 2;
         int cursor = 0;
         double n1 = ExtraiNumero(seg, cursor);
         double n2 = ExtraiNumero(seg, cursor);
         if(n2 == 0) {
            r.p1 = 14; r.d1 = n1;
         } else {
            r.p1 = (int)n1; r.d1 = n2;
         }
         if(r.d1 == 0) r.d1 = (currentIntent == SIGNAL_BUY) ? 30 : 70;
         r.handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
         ruleFound = true;
      }
      // Stochastic
      else if(StringFind(seg, "estocástico") >= 0 || StringFind(seg, "stoch") >= 0) {
         r.type = 3;
         r.handle1 = iStochastic(_Symbol, (ENUM_TIMEFRAMES)r.tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
         ruleFound = true;
      }
      // Bollinger Bands
      else if(StringFind(seg, "bollinger") >= 0 || StringFind(seg, " bb ") >= 0) {
         r.type = 4;
         r.handle1 = iBands(_Symbol, (ENUM_TIMEFRAMES)r.tf, 20, 0, 2.0, PRICE_CLOSE);
         ruleFound = true;
      }
      // AI Signal
      else if(StringFind(seg, "ia") >= 0 || StringFind(seg, "previsão") >= 0) {
         r.type = 11;
         r.handle1 = iATR(_Symbol, (ENUM_TIMEFRAMES)r.tf, 14);
         ruleFound = true;
      }

      if(ruleFound) {
         rules[nRules] = r;
         nRules++;
      }
   }
}

ENUM_SIGNAL AvaliaTudo() {
   int buyCount = 0;
   int sellCount = 0;
   int totalBuyRules = 0;
   int totalSellRules = 0;

   for(int i=0; i<nRules; i++) {
      ENUM_SIGNAL res = AvaliaRegra(rules[i]);
      if(rules[i].intent == SIGNAL_BUY) {
         totalBuyRules++;
         if(res == SIGNAL_BUY) buyCount++;
      } else if(rules[i].intent == SIGNAL_SELL) {
         totalSellRules++;
         if(res == SIGNAL_SELL) sellCount++;
      }
   }

   if(totalBuyRules > 0 && buyCount == totalBuyRules) return SIGNAL_BUY;
   if(totalSellRules > 0 && sellCount == totalSellRules) return SIGNAL_SELL;

   return SIGNAL_NONE;
}

double GetBufferValue(int handle, int buffer, int shift) {
   double val[1];
   if(CopyBuffer(handle, buffer, shift, 1, val) > 0) return val[0];
   return 0;
}

ENUM_SIGNAL AvaliaRegra(Rule &r) {
   if(r.handle1 == INVALID_HANDLE) return SIGNAL_NONE;

   // 1. MA
   if(r.type == 1) {
      double ma1 = GetBufferValue(r.handle1, 0, 1);
      double ma1_p = GetBufferValue(r.handle1, 0, 2);

      if(r.handle2 == INVALID_HANDLE) { // Price vs MA
         double close1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         double close2 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
         if(close2 < ma1_p && close1 > ma1) return SIGNAL_BUY;
         if(close2 > ma1_p && close1 < ma1) return SIGNAL_SELL;
      } else { // MA vs MA
         double ma2 = GetBufferValue(r.handle2, 0, 1);
         double ma2_p = GetBufferValue(r.handle2, 0, 2);
         if(ma1_p < ma2_p && ma1 > ma2) return SIGNAL_BUY;
         if(ma1_p > ma2_p && ma1 < ma2) return SIGNAL_SELL;
      }
   }
   // 2. RSI
   else if(r.type == 2) {
      double rsi1 = GetBufferValue(r.handle1, 0, 1);
      double rsi2 = GetBufferValue(r.handle1, 0, 2);
      if(rsi2 < r.d1 && rsi1 > r.d1) return SIGNAL_BUY;
      if(rsi2 > r.d1 && rsi1 < r.d1) return SIGNAL_SELL;
   }
   // 3. Stoch
   else if(r.type == 3) {
      double k1 = GetBufferValue(r.handle1, 0, 1);
      double d1 = GetBufferValue(r.handle1, 1, 1);
      double k2 = GetBufferValue(r.handle1, 0, 2);
      double d2 = GetBufferValue(r.handle1, 1, 2);
      if(k2 < d2 && k1 > d1) return SIGNAL_BUY;
      if(k2 > d2 && k1 < d1) return SIGNAL_SELL;
   }
   // 4. BB
   else if(r.type == 4) {
      double close1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
      double upper = GetBufferValue(r.handle1, 1, 1);
      double lower = GetBufferValue(r.handle1, 2, 1);
      if(close1 < lower) return SIGNAL_BUY;
      if(close1 > upper) return SIGNAL_SELL;
   }
   // 11. AI
   else if(r.type == 11) {
      return AISignal(r);
   }

   return SIGNAL_NONE;
}

ENUM_SIGNAL AISignal(Rule &r) {
   double atr = GetBufferValue(r.handle1, 0, 1);
   double body = MathAbs(iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1) - iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1));
   bool bullish = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);

   if(body > 1.5 * atr) {
      return bullish ? SIGNAL_BUY : SIGNAL_SELL;
   }
   return SIGNAL_NONE;
}

void EnviaOrdem(ENUM_SIGNAL type, double risk, string reason) {
   if(AguardaNoticias()) {
      GravaLog("Trade vetoed by news filter.");
      return;
   }

   int openTrades = 0;
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(PositionSelectByTicket(PositionGetTicket(i))) {
         if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) openTrades++;
      }
   }
   if(openTrades >= p_maxTrades) return;

   double lot = CalculaLote(risk);
   double price = (type == SIGNAL_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0, tp = 0;

   if(type == SIGNAL_BUY) {
      if(p_stopPoints > 0) sl = price - p_stopPoints * _Point;
      if(p_takePoints > 0) tp = price + p_takePoints * _Point;
      for(int i=0; i<3; i++) {
         if(trade.Buy(lot, _Symbol, price, sl, tp, reason)) {
            SendNotification("MT-LiveExecutor: BUY " + _Symbol + " " + DoubleToString(lot, 2));
            break;
         }
      }
   } else {
      if(p_stopPoints > 0) sl = price + p_stopPoints * _Point;
      if(p_takePoints > 0) tp = price - p_takePoints * _Point;
      for(int i=0; i<3; i++) {
         if(trade.Sell(lot, _Symbol, price, sl, tp, reason)) {
            SendNotification("MT-LiveExecutor: SELL " + _Symbol + " " + DoubleToString(lot, 2));
            break;
         }
      }
   }
}

double CalculaLote(double riskPercent) {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (riskPercent / 100.0);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   double lot = 0.1;
   if(p_stopPoints > 0) {
      lot = riskAmount / (p_stopPoints * (tickValue / (tickSize / _Point)));
   }

   if(p_useMartingale) {
      HistorySelect(TimeCurrent() - 86400, TimeCurrent());
      for(int i=HistoryDealsTotal()-1; i>=0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) lot *= 2.0;
            break;
         }
      }
   }

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / stepLot) * stepLot;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return lot;
}

void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) {
         if(PositionGetInteger(POSITION_MAGIC) != EA_MAGIC) continue;

         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double currentSL = PositionGetDouble(POSITION_SL);
         int distPoints = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? (int)((currentPrice - openPrice) / _Point) : (int)((openPrice - currentPrice) / _Point);

         // Breakeven
         if(p_beStart > 0 && distPoints >= p_beStart) {
            double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? openPrice + p_bePlus * _Point : openPrice - p_bePlus * _Point;
            if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && (currentSL < newSL || currentSL == 0)) ||
               (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (currentSL > newSL || currentSL == 0))) {
               trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
            }
         }

         // Trailing Stop
         if(p_trailingStop > 0 && distPoints >= p_trailingStop) {
            double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? currentPrice - p_trailingStop * _Point : currentPrice + p_trailingStop * _Point;
            if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && newSL > currentSL + p_trailingStep * _Point) ||
               (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (newSL < currentSL - p_trailingStep * _Point || currentSL == 0))) {
               trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
            }
         }
      }
   }
}

bool AguardaNoticias() {
   if(FileIsExist("news_veto.txt")) {
      int h = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_ANSI);
      if(h != INVALID_HANDLE) {
         string val = FileReadString(h);
         FileClose(h);
         if(val == "1") return true;
      }
   }
   return false;
}

void AIOptimizer() {
   HistorySelect(TimeCurrent() - 86400, TimeCurrent());
   int total = 0, wins = 0;
   int count = 0;
   for(int i=HistoryDealsTotal()-1; i>=0 && count < 10; i--) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
         if(HistoryDealGetDouble(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT) {
            total++;
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) > 0) wins++;
            count++;
         }
      }
   }
   if(total > 0) {
      double wr = (double)wins / total;
      if(wr < 0.4) p_riskPercent *= 0.9;
   }
}

void GravaCSV() {
   int h = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV | FILE_ANSI);
   if(h != INVALID_HANDLE) {
      FileWrite(h, "Ticket", "Symbol", "Type", "Volume", "PriceOpen", "Time", "SL", "TP", "Profit", "Reason");
      for(int i=PositionsTotal()-1; i>=0; i--) {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelectByTicket(ticket)) {
            if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
               FileWrite(h,
                  ticket,
                  PositionGetString(POSITION_SYMBOL),
                  PositionGetInteger(POSITION_TYPE),
                  PositionGetDouble(POSITION_VOLUME),
                  PositionGetDouble(POSITION_PRICE_OPEN),
                  PositionGetInteger(POSITION_TIME),
                  PositionGetDouble(POSITION_SL),
                  PositionGetDouble(POSITION_TP),
                  PositionGetDouble(POSITION_PROFIT),
                  PositionGetString(POSITION_COMMENT)
               );
            }
         }
      }
      FileClose(h);
   }
}

void GravaLog(string text) {
   int h = FileOpen("MT_LiveExecutor_Log.txt", FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h != INVALID_HANDLE) {
      FileSeek(h, 0, SEEK_END);
      FileWriteString(h, TimeToString(TimeCurrent()) + ": " + text + "\r\n");
      FileClose(h);
   }
   Print(text);
}
