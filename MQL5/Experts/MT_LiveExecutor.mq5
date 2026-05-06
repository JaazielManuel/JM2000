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

//--- CONSTANTS
#define MAX_RULES 20
#define EA_MAGIC 123456

//--- ENUMS
enum ENUM_SIGNAL { SIGNAL_NONE=0, SIGNAL_BUY=1, SIGNAL_SELL=-1 };
enum ENUM_RULE_TYPE {
   RT_MA=1, RT_RSI=2, RT_STOCH=3, RT_BB=4, RT_DAILYBREAK=5,
   RT_DELTA=6, RT_VOL=7, RT_AMA=8, RT_BAR2=9, RT_RS=10, RT_AI=11
};

//--- STRUCTS
struct Rule {
   int type;
   ENUM_SIGNAL intent;
   ENUM_TIMEFRAMES tf;
   int handle1;
   int handle2;
   double p1, p2, p3;
   string s1;

   void Reset() {
      if(handle1 != INVALID_HANDLE && handle1 != 0) {
         IndicatorRelease(handle1);
         handle1 = INVALID_HANDLE;
      }
      if(handle2 != INVALID_HANDLE && handle2 != 0) {
         IndicatorRelease(handle2);
         handle2 = INVALID_HANDLE;
      }
      type = 0;
      intent = SIGNAL_NONE;
      s1 = "";
      p1 = 0; p2 = 0; p3 = 0;
   }
};

//--- GLOBALS
Rule g_rules[MAX_RULES];
int g_nRules = 0;
CTrade g_trade;
CPositionInfo g_pos;

// Strategy Parameters
double p_riskPercent = 1.0;
int p_stopPoints = 300;
int p_takePoints = 500;
int p_maxTrades = 3;
int p_beStart = 0;
int p_bePlus = 0;
int p_trailingStop = 0;
int p_trailingStep = 10;
string p_startTime = "00:00";
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
bool p_useMartingale = false;

datetime g_lastPromptUpdate = 0;
datetime g_lastBar = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
   g_trade.SetExpertMagicNumber(EA_MAGIC);
   EventSetTimer(1);
   for(int i=0; i<MAX_RULES; i++) {
      g_rules[i].handle1 = INVALID_HANDLE;
      g_rules[i].handle2 = INVALID_HANDLE;
   }
   ResetStrategy();
   CheckPromptUpdate();
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   EventKillTimer();
   ResetStrategy();
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
   GerenciaPosicoes();
   GravaCSV();

   // Frequency check
   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar == g_lastBar) return;
   g_lastBar = currentBar;

   // News veto check
   if(AguardaNoticias()) return;

   // Time window check
   if(!CheckTimeWindow()) return;

   // Max trades check
   if(CountOpenPositions() >= p_maxTrades) return;

   ENUM_SIGNAL signal = AvaliaTudo();
   if(signal != SIGNAL_NONE) {
      EnviaOrdem(signal);
   }
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer() {
   CheckPromptUpdate();
   AIOptimizer();
}

//+------------------------------------------------------------------+
//| Reset Strategy                                                   |
//+------------------------------------------------------------------+
void ResetStrategy() {
   for(int i=0; i<MAX_RULES; i++) g_rules[i].Reset();
   g_nRules = 0;

   // Revert defaults
   p_riskPercent = 1.0;
   p_stopPoints = 300;
   p_takePoints = 500;
   p_maxTrades = 3;
   p_beStart = 0;
   p_bePlus = 0;
   p_trailingStop = 0;
   p_startTime = "00:00";
   p_frequency = PERIOD_M15;
   p_useMartingale = false;
}

//+------------------------------------------------------------------+
//| Check for prompt.txt updates                                     |
//+------------------------------------------------------------------+
void CheckPromptUpdate() {
   string filename = "prompt.txt";
   datetime lastMod = (datetime)FileGetInteger(filename, FILE_MODIFY_DATE, false);

   if(lastMod > g_lastPromptUpdate) {
      g_lastPromptUpdate = lastMod;
      int handle = FileOpen(filename, FILE_READ|FILE_TXT|FILE_ANSI);
      if(handle != INVALID_HANDLE) {
         string prompt = "";
         while(!FileIsEnding(handle)) prompt += FileReadString(handle);
         FileClose(handle);

         if(prompt != "") {
            ResetStrategy();
            InterpretaPrompt(prompt);
            Print("Estratégia atualizada via prompt.txt");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| NLP Engine                                                       |
//+------------------------------------------------------------------+
void InterpretaPrompt(string prompt) {
   string work = prompt;
   StringToLower(work);

   // Global parameters
   double val = ExtraiValorApos(work, "risco");
   if(val > 0) p_riskPercent = val;

   val = ExtraiValorApos(work, "stop");
   if(val > 0) p_stopPoints = (int)val;

   val = ExtraiValorApos(work, "take");
   if(val > 0) p_takePoints = (int)val;

   val = ExtraiValorApos(work, "máximo");
   if(val > 0) p_maxTrades = (int)val;

   if(StringFind(work, "martingale") >= 0) p_useMartingale = true;

   // Frequency
   if(StringFind(work, "1 minuto") >= 0 || StringFind(work, "m1") >= 0) p_frequency = PERIOD_M1;
   else if(StringFind(work, "5 minutos") >= 0 || StringFind(work, "m5") >= 0) p_frequency = PERIOD_M5;
   else if(StringFind(work, "15 minutos") >= 0 || StringFind(work, "m15") >= 0) p_frequency = PERIOD_M15;
   else if(StringFind(work, "1 hora") >= 0 || StringFind(work, "h1") >= 0) p_frequency = PERIOD_H1;

   // Breakeven
   if(StringFind(work, "atingir") >= 0 && StringFind(work, "move stop") >= 0) {
      int pos = StringFind(work, "atingir");
      p_beStart = (int)ExtraiNumero(work, pos);
      pos = StringFind(work, "entrada");
      if(pos >= 0) p_bePlus = (int)ExtraiNumero(work, pos);
   }

   // Trailing Stop
   int trailPos = StringFind(work, "trailing");
   if(trailPos >= 0) {
      p_trailingStop = (int)ExtraiNumero(work, trailPos);
   }

   // Start Time
   if(StringFind(work, "depois das") >= 0 || StringFind(work, "início") >= 0 || StringFind(work, "começar") >= 0) {
      int tPos = StringFind(work, ":");
      if(tPos > 2) p_startTime = StringSubstr(work, tPos-2, 5);
   }

   // Split by segments
   string segments[];
   string sep = "|";
   string norm = work;
   StringReplace(norm, " e ", sep);
   StringReplace(norm, ".", sep);
   StringReplace(norm, ",", sep);
   ushort u_sep = StringGetCharacter(sep, 0);
   int nSeg = StringSplit(norm, u_sep, segments);

   ENUM_SIGNAL currentIntent = SIGNAL_NONE;

   for(int i=0; i<nSeg && g_nRules < MAX_RULES; i++) {
      string seg = segments[i];
      if(StringFind(seg, "compra") >= 0) currentIntent = SIGNAL_BUY;
      else if(StringFind(seg, "vende") >= 0) currentIntent = SIGNAL_SELL;

      if(currentIntent == SIGNAL_NONE) continue;

      Rule r;
      ZeroMemory(r);
      r.intent = currentIntent;
      r.tf = p_frequency; // Default
      r.handle1 = INVALID_HANDLE;
      r.handle2 = INVALID_HANDLE;

      bool added = false;

      // MA Rule
      if(StringFind(seg, " média ") >= 0 || StringFind(seg, " ma ") >= 0 || StringFind(seg, " ma/") >= 0) {
         r.type = RT_MA;
         int pos = 0;
         r.p1 = ExtraiNumero(seg, pos);
         r.p2 = ExtraiNumero(seg, pos); // second MA if exists

         if(r.p2 > 0) {
            r.handle1 = iMA(_Symbol, r.tf, (int)r.p1, 0, MODE_EMA, PRICE_CLOSE);
            r.handle2 = iMA(_Symbol, r.tf, (int)r.p2, 0, MODE_EMA, PRICE_CLOSE);
         } else {
            r.handle1 = iMA(_Symbol, r.tf, (int)r.p1, 0, MODE_EMA, PRICE_CLOSE);
         }
         added = true;
      }
      // RSI Rule
      else if(StringFind(seg, "rsi") >= 0) {
         r.type = RT_RSI;
         int pos = 0;
         double n1 = ExtraiNumero(seg, pos);
         double n2 = ExtraiNumero(seg, pos);
         if(n2 > 0) { r.p1 = n1; r.p2 = n2; } // period, threshold
         else if(n1 >= 40) { r.p1 = 14; r.p2 = n1; } // threshold only
         else { r.p1 = n1; r.p2 = (r.intent == SIGNAL_BUY) ? 55 : 45; } // period only, default thresholds

         r.handle1 = iRSI(_Symbol, r.tf, (int)r.p1, PRICE_CLOSE);
         added = true;
      }
      // Bollinger Rule
      else if(StringFind(seg, "bollinger") >= 0 || StringFind(seg, " bb ") >= 0) {
         r.type = RT_BB;
         r.handle1 = iBands(_Symbol, r.tf, 20, 0, 2.0, PRICE_CLOSE);
         added = true;
      }
      // Stoch Rule
      else if(StringFind(seg, "estocástico") >= 0 || StringFind(seg, "stoch") >= 0) {
         r.type = RT_STOCH;
         int pos = 0;
         r.p1 = ExtraiNumero(seg, pos); // K
         r.p2 = ExtraiNumero(seg, pos); // D
         r.p3 = ExtraiNumero(seg, pos); // slowing
         if(r.p1 <= 0) r.p1 = 5;
         if(r.p2 <= 0) r.p2 = 3;
         if(r.p3 <= 0) r.p3 = 3;
         r.handle1 = iStochastic(_Symbol, r.tf, (int)r.p1, (int)r.p2, (int)r.p3, MODE_SMA, STO_LOWHIGH);
         added = true;
      }
      // Delta Rule
      else if(StringFind(seg, "delta") >= 0) {
         r.type = RT_DELTA;
         int pos = 0;
         r.p1 = ExtraiNumero(seg, pos); // seconds
         r.p2 = ExtraiNumero(seg, pos); // trigger
         if(r.p1 <= 0) r.p1 = 60;
         if(r.p2 <= 0) r.p2 = 300;
         added = true;
      }
      // Volume Rule
      else if(StringFind(seg, "volume") >= 0) {
         r.type = RT_VOL;
         int pos = 0;
         r.p1 = ExtraiNumero(seg, pos); // len
         if(r.p1 <= 0) r.p1 = 12;
         added = true;
      }
      // AMA Rule
      else if(StringFind(seg, "ama") >= 0 || StringFind(seg, "adaptativa") >= 0) {
         r.type = RT_AMA;
         int pos = 0;
         r.p1 = ExtraiNumero(seg, pos); // len
         r.p2 = ExtraiNumero(seg, pos); // fast
         r.p3 = ExtraiNumero(seg, pos); // slow
         if(r.p1 <= 0) r.p1 = 10;
         if(r.p2 <= 0) r.p2 = 2;
         if(r.p3 <= 0) r.p3 = 30;
         r.handle1 = iAMA(_Symbol, r.tf, (int)r.p1, (int)r.p2, (int)r.p3, 0, PRICE_CLOSE);
         added = true;
      }
      // Bar2Pattern Rule
      else if(StringFind(seg, "padrão barras") >= 0 || StringFind(seg, "inside") >= 0 || StringFind(seg, "outside") >= 0) {
         r.type = RT_BAR2;
         added = true;
      }
      // RS Rule
      else if(StringFind(seg, "força relativa") >= 0 || StringFind(seg, " rs ") >= 0) {
         r.type = RT_RS;
         r.s1 = "US30"; // default benchmark
         // Attempt to extract symbol name if it follows "rs "
         int rsPos = StringFind(seg, " rs ");
         if(rsPos >= 0) {
            int start = rsPos + 4;
            int end = StringFind(seg, " ", start);
            if(end > start) r.s1 = StringSubstr(seg, start, end - start);
         }
         r.p1 = 14; // default len
         r.handle1 = iRSI(_Symbol, r.tf, (int)r.p1, PRICE_CLOSE);
         r.handle2 = iRSI(r.s1, r.tf, (int)r.p1, PRICE_CLOSE);
         added = true;
      }
      // Daily Breakout
      else if(StringFind(seg, "rompimento diário") >= 0) {
         r.type = RT_DAILYBREAK;
         added = true;
      }
      // AI Signal
      else if(StringFind(seg, "previsão") >= 0 || StringFind(seg, "ai") >= 0) {
         r.type = RT_AI;
         r.handle1 = iATR(_Symbol, r.tf, 14);
         added = true;
      }

      if(added) {
         g_rules[g_nRules] = r;
         g_nRules++;
      }
   }
}

//+------------------------------------------------------------------+
//| Evaluate all rules                                               |
//+------------------------------------------------------------------+
ENUM_SIGNAL AvaliaTudo() {
   int buyVotes = 0;
   int sellVotes = 0;
   int buyRules = 0;
   int sellRules = 0;

   for(int i=0; i<g_nRules; i++) {
      ENUM_SIGNAL res = AvaliaRegra(g_rules[i]);
      if(g_rules[i].intent == SIGNAL_BUY) {
         buyRules++;
         if(res == SIGNAL_BUY) buyVotes++;
      } else if(g_rules[i].intent == SIGNAL_SELL) {
         sellRules++;
         if(res == SIGNAL_SELL) sellVotes++;
      }
   }

   if(buyRules > 0 && buyVotes == buyRules) return SIGNAL_BUY;
   if(sellRules > 0 && sellVotes == sellRules) return SIGNAL_SELL;

   return SIGNAL_NONE;
}

//+------------------------------------------------------------------+
//| Evaluate single rule                                             |
//+------------------------------------------------------------------+
ENUM_SIGNAL AvaliaRegra(Rule &r) {
   switch(r.type) {
      case RT_MA:
         if(r.handle2 != INVALID_HANDLE) {
            // MA crossover
            double fast1 = GetBufferValue(r.handle1, 0, 1);
            double fast2 = GetBufferValue(r.handle1, 0, 2);
            double slow1 = GetBufferValue(r.handle2, 0, 1);
            double slow2 = GetBufferValue(r.handle2, 0, 2);
            if(fast2 < slow2 && fast1 > slow1) return SIGNAL_BUY;
            if(fast2 > slow2 && fast1 < slow1) return SIGNAL_SELL;
         } else {
            // Price vs MA
            double ma1 = GetBufferValue(r.handle1, 0, 1);
            double ma2 = GetBufferValue(r.handle1, 0, 2);
            double close1 = iClose(_Symbol, r.tf, 1);
            double close2 = iClose(_Symbol, r.tf, 2);
            if(close2 < ma2 && close1 > ma1) return SIGNAL_BUY;
            if(close2 > ma2 && close1 < ma1) return SIGNAL_SELL;
         }
         break;

      case RT_RSI:
         double rsi1 = GetBufferValue(r.handle1, 0, 1);
         double rsi2 = GetBufferValue(r.handle1, 0, 2);
         if(rsi2 < r.p2 && rsi1 > r.p2) return SIGNAL_BUY;
         if(rsi2 > r.p2 && rsi1 < r.p2) return SIGNAL_SELL;
         break;

      case RT_BB:
         double close = iClose(_Symbol, r.tf, 1);
         double upper = GetBufferValue(r.handle1, 1, 1); // Upper
         double lower = GetBufferValue(r.handle1, 2, 1); // Lower
         if(close < lower) return SIGNAL_BUY;
         if(close > upper) return SIGNAL_SELL;
         break;

      case RT_DAILYBREAK:
         double hi = iHigh(_Symbol, PERIOD_D1, 1);
         double lo = iLow(_Symbol, PERIOD_D1, 1);
         double cur = iClose(_Symbol, PERIOD_CURRENT, 0);
         if(cur > hi) return SIGNAL_BUY;
         if(cur < lo) return SIGNAL_SELL;
         break;

      case RT_STOCH:
         double k1 = GetBufferValue(r.handle1, 0, 1);
         double k2 = GetBufferValue(r.handle1, 0, 2);
         double d1 = GetBufferValue(r.handle1, 1, 1);
         double d2 = GetBufferValue(r.handle1, 1, 2);
         if(k2 < d2 && k1 > d1) return SIGNAL_BUY;
         if(k2 > d2 && k1 < d1) return SIGNAL_SELL;
         break;

      case RT_DELTA:
      {
         MqlTick arr[];
         int n = CopyTicksRange(_Symbol, arr, COPY_TICKS_TRADE, TimeCurrent()-(int)r.p1, TimeCurrent());
         long buy = 0, sell = 0;
         for(int i=0; i<n; i++) if(arr[i].flags&TICK_FLAG_BUY) buy++; else if(arr[i].flags&TICK_FLAG_SELL) sell++;
         long delta = buy - sell;
         if(delta > (long)r.p2) return SIGNAL_BUY;
         if(delta < -(long)r.p2) return SIGNAL_SELL;
         break;
      }

      case RT_VOL:
      {
         double vol[];
         ArraySetAsSeries(vol, true);
         if(CopyVolume(_Symbol, r.tf, 1, (int)r.p1, vol) > 0) {
            int maxIdx = ArrayMaximum(vol);
            int minIdx = ArrayMinimum(vol);
            if(maxIdx == 0) return SIGNAL_SELL;
            if(minIdx == 0) return SIGNAL_BUY;
         }
         break;
      }

      case RT_AMA:
         double ama1 = GetBufferValue(r.handle1, 0, 1);
         double ama2 = GetBufferValue(r.handle1, 0, 2);
         if(ama2 < ama1) return SIGNAL_BUY;
         if(ama2 > ama1) return SIGNAL_SELL;
         break;

      case RT_BAR2:
         double h0 = iHigh(_Symbol, r.tf, 1);
         double l0 = iLow(_Symbol, r.tf, 1);
         double h1 = iHigh(_Symbol, r.tf, 2);
         double l1 = iLow(_Symbol, r.tf, 2);
         // Inside bar
         if(h0 < h1 && l0 > l1) return (iClose(_Symbol, r.tf, 1) > iOpen(_Symbol, r.tf, 1)) ? SIGNAL_BUY : SIGNAL_SELL;
         // Outside bar
         if(h0 > h1 && l0 < l1) return (iClose(_Symbol, r.tf, 1) > iOpen(_Symbol, r.tf, 1)) ? SIGNAL_SELL : SIGNAL_BUY;
         break;

      case RT_RS:
         double rs1 = GetBufferValue(r.handle1, 0, 1);
         double rs2 = GetBufferValue(r.handle2, 0, 1);
         if(rs1 > rs2 + 5) return SIGNAL_BUY;
         if(rs1 < rs2 - 5) return SIGNAL_SELL;
         break;

      case RT_AI:
         double atr = GetBufferValue(r.handle1, 0, 1);
         double body = MathAbs(iClose(_Symbol, r.tf, 1) - iOpen(_Symbol, r.tf, 1));
         if(body > 1.5 * atr) {
            if(iClose(_Symbol, r.tf, 1) > iOpen(_Symbol, r.tf, 1)) return SIGNAL_BUY;
            else return SIGNAL_SELL;
         }
         break;
   }
   return SIGNAL_NONE;
}

//+------------------------------------------------------------------+
//| Send Order                                                       |
//+------------------------------------------------------------------+
void EnviaOrdem(ENUM_SIGNAL type) {
   double lot = CalculaLote(p_riskPercent);
   int retry = 0;
   bool res = false;

   while(retry < 3 && !res) {
      double price = (type == SIGNAL_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl = 0, tp = 0;
      if(type == SIGNAL_BUY) {
         sl = (p_stopPoints > 0) ? price - p_stopPoints * _Point : 0;
         tp = (p_takePoints > 0) ? price + p_takePoints * _Point : 0;
      } else {
         sl = (p_stopPoints > 0) ? price + p_stopPoints * _Point : 0;
         tp = (p_takePoints > 0) ? price - p_takePoints * _Point : 0;
      }

      // Margin check
      double marginReq = 0;
      ENUM_ORDER_TYPE orderType = (type == SIGNAL_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      if(!OrderCalcMargin(orderType, _Symbol, lot, price, marginReq)) {
         Print("Erro ao calcular margem: ", GetLastError());
         break;
      }
      double freeMargin = AccountInfoDouble(ACCOUNT_FREEMARGIN);
      if(marginReq > freeMargin) {
         PrintFormat("Margem insuficiente! Requerida: %.2f, Disponível: %.2f", marginReq, freeMargin);
         break;
      }

      string comment = "MT-LiveExecutor Signal";
      g_trade.SetDeviationInPoints(30); // 30 points slippage

      if(type == SIGNAL_BUY) res = g_trade.Buy(lot, _Symbol, price, sl, tp, comment);
      else res = g_trade.Sell(lot, _Symbol, price, sl, tp, comment);

      if(res) {
         SendNotification("Trade executado: " + EnumToString(type));
         GravaLog("Trade executado: " + EnumToString(type) + " Lot: " + DoubleToString(lot, 2));
      } else {
         uint code = g_trade.ResultRetcode();
         if(code == TRADE_RETCODE_REQUOTES || code == TRADE_RETCODE_PRICE_OFF) {
            retry++;
            Sleep(100);
            Print("Requote/Offquote detectado. Tentativa ", retry);
         } else {
            Print("Erro ao enviar ordem: ", code, " - ", g_trade.ResultComment());
            break;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate Lot Size                                               |
//+------------------------------------------------------------------+
double CalculaLote(double risk) {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * risk / 100.0;

   if(p_useMartingale) {
      // Check last deal
      HistorySelect(TimeCurrent()-86400*7, TimeCurrent());
      for(int i=HistoryDealsTotal()-1; i>=0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            if(profit < 0) riskMoney *= 2.0;
            break;
         }
      }
   }

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(p_stopPoints == 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double lot = riskMoney / (p_stopPoints * (tickValue / (tickSize / _Point)));
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / stepLot) * stepLot;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Manage Positions                                                 |
//+------------------------------------------------------------------+
void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(g_pos.SelectByIndex(i)) {
         if(g_pos.Symbol() == _Symbol && g_pos.Magic() == EA_MAGIC) {
            double priceCurrent = (g_pos.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double profitPoints = (g_pos.PositionType() == POSITION_TYPE_BUY) ? (priceCurrent - g_pos.PriceOpen())/_Point : (g_pos.PriceOpen() - priceCurrent)/_Point;

            // Breakeven
            if(p_beStart > 0 && profitPoints >= p_beStart) {
               double newSL = (g_pos.PositionType() == POSITION_TYPE_BUY) ? g_pos.PriceOpen() + p_bePlus * _Point : g_pos.PriceOpen() - p_bePlus * _Point;
               if(g_pos.PositionType() == POSITION_TYPE_BUY) {
                  if(g_pos.StopLoss() < newSL) g_trade.PositionModify(g_pos.Ticket(), newSL, g_pos.TakeProfit());
               } else {
                  if(g_pos.StopLoss() > newSL || g_pos.StopLoss() == 0) g_trade.PositionModify(g_pos.Ticket(), newSL, g_pos.TakeProfit());
               }
            }

            // Trailing Stop
            if(p_trailingStop > 0 && profitPoints >= p_trailingStop) {
               double newSL = (g_pos.PositionType() == POSITION_TYPE_BUY) ? priceCurrent - p_trailingStop * _Point : priceCurrent + p_trailingStop * _Point;
               if(g_pos.PositionType() == POSITION_TYPE_BUY) {
                  if(newSL > g_pos.StopLoss() + p_trailingStep * _Point) g_trade.PositionModify(g_pos.Ticket(), newSL, g_pos.TakeProfit());
               } else {
                  if(newSL < g_pos.StopLoss() - p_trailingStep * _Point || g_pos.StopLoss() == 0) g_trade.PositionModify(g_pos.Ticket(), newSL, g_pos.TakeProfit());
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| News Veto Check                                                  |
//+------------------------------------------------------------------+
bool AguardaNoticias() {
   if(FileIsExist("news_veto.txt")) {
      int handle = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_ANSI);
      if(handle != INVALID_HANDLE) {
         string content = FileReadString(handle);
         FileClose(handle);
         if(StringFind(content, "VETO=1") >= 0) return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| AI Optimizer                                                     |
//+------------------------------------------------------------------+
void AIOptimizer() {
   static datetime lastRun = 0;
   if(TimeCurrent() - lastRun < 3600) return;
   lastRun = TimeCurrent();

   HistorySelect(TimeCurrent()-86400*30, TimeCurrent());
   int total = HistoryDealsTotal();
   int wins = 0;
   int trades = 0;

   for(int i=total-1; i>=0 && trades < 10; i--) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
         trades++;
         if(HistoryDealGetDouble(ticket, DEAL_PROFIT) > 0) wins++;
      }
   }

   if(trades >= 5) {
      double wr = (double)wins / trades;
      if(wr < 0.40) {
         p_riskPercent *= 0.8;
         GravaLog("AI: Winrate baixo (" + DoubleToString(wr*100, 1) + "%). Risco reduzido para " + DoubleToString(p_riskPercent, 2));
      }
   }
}

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
double ExtraiValorApos(string texto, string palavra) {
   int pos = StringFind(texto, palavra);
   if(pos < 0) return -1;
   pos += StringLen(palavra);
   return ExtraiNumero(texto, pos);
}

double ExtraiNumero(string text, int &pos) {
   string res = "";
   bool found = false;
   for(int i=pos; i<StringLen(text); i++) {
      ushort c = StringGetCharacter(text, i);
      if((c >= '0' && c <= '9') || c == '.') {
         res += ShortToString(c);
         found = true;
      } else if(found) {
         pos = i;
         break;
      }
   }
   return StringToDouble(res);
}

double GetBufferValue(int handle, int buffer, int index) {
   double val[];
   ArraySetAsSeries(val, true);
   if(CopyBuffer(handle, buffer, index, 1, val) > 0) return val[0];
   return 0;
}

bool CheckTimeWindow() {
   MqlDateTime dt;
   TimeCurrent(dt);
   int targetH = (int)StringToInteger(StringSubstr(p_startTime, 0, 2));
   int targetM = (int)StringToInteger(StringSubstr(p_startTime, 3, 2));
   if(dt.hour > targetH) return true;
   if(dt.hour == targetH && dt.min >= targetM) return true;
   return false;
}

int CountOpenPositions() {
   int count = 0;
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(g_pos.SelectByIndex(i)) {
         if(g_pos.Magic() == EA_MAGIC) count++;
      }
   }
   return count;
}

void GravaLog(string texto) {
   int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE|FILE_READ|FILE_TXT|FILE_ANSI);
   if(handle != INVALID_HANDLE) {
      FileSeek(handle, 0, SEEK_END);
      FileWriteString(handle, TimeToString(TimeCurrent()) + ": " + texto + "\n");
      FileClose(handle);
   }
}

void GravaCSV() {
   int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(handle != INVALID_HANDLE) {
      FileWrite(handle, "Ticket", "Symbol", "Type", "Volume", "PriceOpen", "Time", "SL", "TP", "Profit", "Reason");
      for(int i=0; i<PositionsTotal(); i++) {
         if(g_pos.SelectByIndex(i)) {
            if(g_pos.Magic() == EA_MAGIC) {
               FileWrite(handle, g_pos.Ticket(), g_pos.Symbol(), g_pos.PositionType(), g_pos.Volume(),
                         g_pos.PriceOpen(), g_pos.Time(), g_pos.StopLoss(), g_pos.TakeProfit(),
                         g_pos.Profit(), g_pos.Comment());
            }
         }
      }
      FileClose(handle);
   }
}
