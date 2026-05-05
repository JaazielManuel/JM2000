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
#include <Trade\DealInfo.mqh>
#include <Trade\HistoryOrderInfo.mqh>

//--- Enums and Structs
enum ENUM_RULE_TYPE {
   RT_MA=1,          // Moving Average
   RT_RSI=2,         // RSI
   RT_STOCH=3,       // Stochastic
   RT_BB=4,          // Bollinger Bands
   RT_DAILYBREAK=5,  // Daily Breakout
   RT_DELTA=6,       // Delta Aggression
   RT_VOL=7,         // Volume Cycle
   RT_AMA=8,         // AMA
   RT_BAR2=9,        // 2-Bar Pattern
   RT_RS=10,         // Relative Strength
   RT_AI_PRED=11     // AI Prediction
};

enum ENUM_INTENT { INTENT_BUY, INTENT_SELL, INTENT_NONE };

struct Rule {
   bool            active;
   ENUM_RULE_TYPE  type;
   ENUM_INTENT     intent;
   ENUM_TIMEFRAMES timeframe;
   int             p1, p2, p3;   // Integer parameters (periods)
   double          d1, d2;       // Double parameters (thresholds, deviations)
   string          s1;           // String parameters (symbols)
   int             handle1, handle2;
};

//--- Global Variables
Rule        g_rules[20];
int         g_nRules = 0;
CTrade      g_trade;
int         EA_MAGIC = 123456;

//--- Strategy Parameters (Parsed from Prompt)
double      p_riskPercent = 1.0;
int         p_stopPoints = 0;
int         p_takePoints = 0;
int         p_beStart = 0;
int         p_bePlus = 0;
int         p_trailingStart = 0;
int         p_trailingStep = 10;
int         p_maxTrades = 3;
bool        p_useMartingale = false;
string      p_startTime = "00:00";
ENUM_TIMEFRAMES p_frequency = PERIOD_CURRENT;

//--- State Variables
datetime    g_lastBarTime = 0;
datetime    g_lastPromptFileTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(EA_MAGIC);
   EventSetTimer(1); // Check for updates and manage positions every second
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   ResetStrategy();
}

//+------------------------------------------------------------------+
//| Reset Strategy state                                             |
//+------------------------------------------------------------------+
void ResetStrategy()
{
   for(int i=0; i<20; i++) {
      if(g_rules[i].handle1 != INVALID_HANDLE && g_rules[i].handle1 != 0) IndicatorRelease(g_rules[i].handle1);
      if(g_rules[i].handle2 != INVALID_HANDLE && g_rules[i].handle2 != 0) IndicatorRelease(g_rules[i].handle2);
      g_rules[i].active = false;
   }
   g_nRules = 0;

   // Reset defaults
   p_riskPercent = 1.0;
   p_stopPoints = 0;
   p_takePoints = 0;
   p_beStart = 0;
   p_bePlus = 0;
   p_trailingStart = 0;
   p_maxTrades = 3;
   p_useMartingale = false;
   p_startTime = "00:00";
   p_frequency = PERIOD_CURRENT;
}

//+------------------------------------------------------------------+
//| Helper: Get Buffer Value                                         |
//+------------------------------------------------------------------+
double GetBufferValue(int handle, int buffer, int shift)
{
   double bufferArray[];
   ArraySetAsSeries(bufferArray, true);
   if(CopyBuffer(handle, buffer, shift, 1, bufferArray) > 0) return bufferArray[0];
   return 0;
}

//+------------------------------------------------------------------+
//| Utility: Extract Number from String                              |
//+------------------------------------------------------------------+
double ExtraiNumero(string text, int &startPos)
{
   string res = "";
   bool found = false;
   int len = StringLen(text);
   for(int i=startPos; i<len; i++) {
      ushort c = StringGetCharacter(text, i);
      if((c >= '0' && c <= '9') || c == '.') {
         res += ShortToString(c);
         found = true;
      } else if(found) {
         startPos = i;
         break;
      }
      if(i == len - 1) startPos = len;
   }
   return found ? StringToDouble(res) : 0;
}

double ExtraiNumero(string text) { int start = 0; return ExtraiNumero(text, start); }

//+------------------------------------------------------------------+
//| Utility: Extract Value After Keyword                             |
//+------------------------------------------------------------------+
double ExtraiValorApos(string text, string keyword)
{
   int pos = StringFind(text, keyword);
   if(pos < 0) return 0;
   int start = pos + StringLen(keyword);
   return ExtraiNumero(text, start);
}

//+------------------------------------------------------------------+
//| Utility: Map Text to Period                                      |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES PeriodoTexto(string text)
{
   if(StringFind(text, "1 minuto") >= 0 || StringFind(text, "m1") >= 0) return PERIOD_M1;
   if(StringFind(text, "5 minuto") >= 0 || StringFind(text, "m5") >= 0) return PERIOD_M5;
   if(StringFind(text, "15 minuto") >= 0 || StringFind(text, "m15") >= 0) return PERIOD_M15;
   if(StringFind(text, "30 minuto") >= 0 || StringFind(text, "m30") >= 0) return PERIOD_M30;
   if(StringFind(text, "1 hora") >= 0 || StringFind(text, "h1") >= 0) return PERIOD_H1;
   if(StringFind(text, "4 hora") >= 0 || StringFind(text, "h4") >= 0) return PERIOD_H4;
   if(StringFind(text, "diário") >= 0 || StringFind(text, "d1") >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

//+------------------------------------------------------------------+
//| NLP Parser: InterpretaPrompt                                     |
//+------------------------------------------------------------------+
void InterpretaPrompt(string prompt)
{
   ResetStrategy();
   string work = prompt;
   StringToLower(work);

   //--- Global Strategy Parameters
   p_riskPercent = ExtraiValorApos(work, "risco de");
   if(p_riskPercent <= 0) p_riskPercent = 1.0;

   p_stopPoints = (int)ExtraiValorApos(work, "stop de");
   p_takePoints = (int)ExtraiValorApos(work, "take de");
   p_maxTrades = (int)ExtraiValorApos(work, "máximo");
   if(p_maxTrades <= 0) p_maxTrades = 3;

   if(StringFind(work, "martingale") >= 0) p_useMartingale = true;

   p_beStart = (int)ExtraiValorApos(work, "atingir +");
   p_bePlus = (int)ExtraiValorApos(work, "entrada +");

   p_trailingStart = (int)ExtraiValorApos(work, "trailing de");

   p_frequency = PeriodoTexto(work);

   //--- Identify Start Time
   int timePos = StringFind(work, "depois das");
   if(timePos >= 0) {
      int h = (int)ExtraiNumero(work, timePos);
      int m = 0;
      if(StringGetCharacter(work, timePos) == ':') {
         timePos++;
         m = (int)ExtraiNumero(work, timePos);
      }
      p_startTime = StringFormat("%02d:%02d", h, m);
   }

   //--- Split into segments
   StringReplace(work, " e ", "|");
   StringReplace(work, ".", "|");
   StringReplace(work, ",", "|");

   string segments[];
   int nSegments = StringSplit(work, '|', segments);

   ENUM_INTENT currentIntent = INTENT_NONE;
   int lastMA_p1 = 20;

   for(int i=0; i<nSegments && g_nRules < 20; i++) {
      string seg = segments[i];
      if(StringFind(seg, "compra") >= 0) currentIntent = INTENT_BUY;
      if(StringFind(seg, "vende") >= 0) currentIntent = INTENT_SELL;

      if(currentIntent == INTENT_NONE) continue;

      Rule r;
      ZeroMemory(r);
      r.handle1 = INVALID_HANDLE;
      r.handle2 = INVALID_HANDLE;
      r.active = false;
      r.intent = currentIntent;
      r.timeframe = PeriodoTexto(seg);
      if(r.timeframe == PERIOD_CURRENT) r.timeframe = p_frequency;

      //--- Moving Average Rule
      if(StringFind(seg, " média ") >= 0 || StringFind(seg, " ma ") >= 0 || StringFind(seg, " ma/") >= 0) {
         r.type = RT_MA;
         int cursor = 0;
         r.p1 = (int)ExtraiNumero(seg, cursor);
         if(r.p1 == 0) r.p1 = lastMA_p1;
         else lastMA_p1 = r.p1;

         r.p2 = (int)ExtraiNumero(seg, cursor); // Check for second period (crossover)

         if(r.p2 > 0) {
            r.handle1 = iMA(_Symbol, r.timeframe, r.p1, 0, MODE_EMA, PRICE_CLOSE);
            r.handle2 = iMA(_Symbol, r.timeframe, r.p2, 0, MODE_EMA, PRICE_CLOSE);
         } else {
            r.handle1 = iMA(_Symbol, r.timeframe, r.p1, 0, MODE_EMA, PRICE_CLOSE);
            r.handle2 = INVALID_HANDLE;
         }
         r.active = true;
      }

      //--- RSI Rule
      else if(StringFind(seg, "rsi") >= 0) {
         r.type = RT_RSI;
         int cursor = StringFind(seg, "rsi");
         cursor += 3;
         double n1 = ExtraiNumero(seg, cursor);
         double n2 = ExtraiNumero(seg, cursor);

         // Logic: if we have "RSI (14) acima de 55" -> n1=14, n2=55
         // if we have "RSI cair abaixo de 45" -> n1=45
         if(n1 > 0 && n2 > 0) { r.p1 = (int)n1; r.d1 = n2; }
         else if(n1 >= 40) { r.p1 = 14; r.d1 = n1; }
         else if(n1 > 0) { r.p1 = (int)n1; r.d1 = (currentIntent == INTENT_BUY) ? 30 : 70; }
         else { r.p1 = 14; r.d1 = (currentIntent == INTENT_BUY) ? 30 : 70; }

         r.handle1 = iRSI(_Symbol, r.timeframe, r.p1, PRICE_CLOSE);
         r.active = true;
      }

      //--- Bollinger Bands Rule
      else if(StringFind(seg, "bollinger") >= 0 || StringFind(seg, "bandas") >= 0) {
         r.type = RT_BB;
         r.p1 = 20; r.d1 = 2.0; // Defaults
         r.handle1 = iBands(_Symbol, r.timeframe, r.p1, 0, r.d1, PRICE_CLOSE);
         r.active = true;
      }

      //--- AI / Prediction Rule
      else if(StringFind(seg, "previsão") >= 0 || StringFind(seg, "ai") >= 0) {
         r.type = RT_AI_PRED;
         r.handle1 = iATR(_Symbol, r.timeframe, 14);
         r.active = true;
      }

      if(r.active) {
         g_rules[g_nRules] = r;
         g_nRules++;
      }
   }
}

//+------------------------------------------------------------------+
//| Manage Active Positions (Trailing, Breakeven)                    |
//+------------------------------------------------------------------+
void GerenciaPosicoes()
{
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC && PositionGetSymbol(i) == _Symbol) {
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double sl = PositionGetDouble(POSITION_SL);
         double tp = PositionGetDouble(POSITION_TP);

         //--- Break-even
         if(p_beStart > 0) {
            double profitPoints = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? (currentPrice - openPrice) / _Point : (openPrice - currentPrice) / _Point;
            if(profitPoints >= p_beStart) {
               double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? openPrice + p_bePlus * _Point : openPrice - p_bePlus * _Point;
               if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && (sl < newSL || sl == 0)) ||
                  (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (sl > newSL || sl == 0))) {
                  g_trade.PositionModify(ticket, newSL, tp);
               }
            }
         }

         //--- Trailing Stop
         if(p_trailingStart > 0) {
            double profitPoints = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? (currentPrice - openPrice) / _Point : (openPrice - currentPrice) / _Point;
            if(profitPoints >= p_trailingStart) {
               double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? currentPrice - p_trailingStart * _Point : currentPrice + p_trailingStart * _Point;
               if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && (newSL > sl + p_trailingStep * _Point)) ||
                  (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (newSL < sl - p_trailingStep * _Point || sl == 0))) {
                  g_trade.PositionModify(ticket, newSL, tp);
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| State Persistence: Save to CSV                                   |
//+------------------------------------------------------------------+
void GravaCSV()
{
   int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_ANSI);
   if(handle != INVALID_HANDLE) {
      FileWrite(handle, "Ticket", "Symbol", "Type", "Volume", "PriceOpen", "Time", "SL", "TP", "Profit", "Reason");
      for(int i=0; i<PositionsTotal(); i++) {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
            FileWrite(handle,
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
      FileClose(handle);
   }
}

//+------------------------------------------------------------------+
//| News Veto: AguardaNoticias                                       |
//+------------------------------------------------------------------+
bool AguardaNoticias()
{
   if(FileIsExist("news_veto.txt")) {
      int handle = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_ANSI);
      if(handle != INVALID_HANDLE) {
         string val = FileReadString(handle);
         FileClose(handle);
         if(val == "1" || val == "true") return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Timer: Check for prompt updates and manage                       |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Check for new prompt
   long lastMod = (long)FileGetInteger("prompt.txt", FILE_MODIFY_DATE);
   if(lastMod > (long)g_lastPromptFileTime) {
      int handle = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_ANSI);
      if(handle != INVALID_HANDLE) {
         string prompt = FileReadString(handle);
         FileClose(handle);
         InterpretaPrompt(prompt);
         g_lastPromptFileTime = (datetime)lastMod;
         Print("MT-LiveExecutor: Nova estratégia carregada.");
      }
   }

   GerenciaPosicoes();
   GravaCSV();
}

//+------------------------------------------------------------------+
//| OnTick: Signal Evaluation and Execution                          |
//+------------------------------------------------------------------+
void OnTick()
{
   // Frequency check
   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar == g_lastBarTime) return;
   g_lastBarTime = currentBar;

   // News veto
   if(AguardaNoticias()) return;

   // Time check
   if(p_startTime != "00:00") {
      string now = TimeToString(TimeCurrent(), TIME_MINUTES);
      if(now < p_startTime) return;
   }

   // Decision
   ENUM_INTENT signal = AvaliaTudo();
   if(signal != INTENT_NONE) {
      EnviaOrdem(signal, "Sinal Confluência");
   }
}

//+------------------------------------------------------------------+
//| Evaluates a single rule                                          |
//+------------------------------------------------------------------+
bool AvaliaRegra(Rule &r)
{
   if(!r.active) return false;

   switch(r.type) {
      case RT_MA:
         if(r.handle2 != INVALID_HANDLE) {
            double fast1 = GetBufferValue(r.handle1, 0, 1);
            double fast2 = GetBufferValue(r.handle1, 0, 2);
            double slow1 = GetBufferValue(r.handle2, 0, 1);
            double slow2 = GetBufferValue(r.handle2, 0, 2);
            if(r.intent == INTENT_BUY) return (fast2 < slow2 && fast1 > slow1);
            if(r.intent == INTENT_SELL) return (fast2 > slow2 && fast1 < slow1);
         } else {
            double ma1 = GetBufferValue(r.handle1, 0, 1);
            double ma2 = GetBufferValue(r.handle1, 0, 2);
            double close1 = iClose(_Symbol, r.timeframe, 1);
            double close2 = iClose(_Symbol, r.timeframe, 2);
            if(r.intent == INTENT_BUY) return (close2 < ma2 && close1 > ma1);
            if(r.intent == INTENT_SELL) return (close2 > ma2 && close1 < ma1);
         }
         break;

      case RT_RSI:
         double rsi1 = GetBufferValue(r.handle1, 0, 1);
         double rsi2 = GetBufferValue(r.handle1, 0, 2);
         if(r.intent == INTENT_BUY) return (rsi2 < r.d1 && rsi1 > r.d1);
         if(r.intent == INTENT_SELL) return (rsi2 > r.d1 && rsi1 < r.d1);
         break;

      case RT_BB:
         double upper = GetBufferValue(r.handle1, 1, 1);
         double lower = GetBufferValue(r.handle1, 2, 1);
         double closeBB = iClose(_Symbol, r.timeframe, 1);
         if(r.intent == INTENT_BUY) return (closeBB < lower);
         if(r.intent == INTENT_SELL) return (closeBB > upper);
         break;

      case RT_AI_PRED:
         double atr = GetBufferValue(r.handle1, 0, 1);
         double body = MathAbs(iClose(_Symbol, r.timeframe, 1) - iOpen(_Symbol, r.timeframe, 1));
         bool bullish = iClose(_Symbol, r.timeframe, 1) > iOpen(_Symbol, r.timeframe, 1);
         if(r.intent == INTENT_BUY) return (bullish && body > 1.5 * atr);
         if(r.intent == INTENT_SELL) return (!bullish && body > 1.5 * atr);
         break;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Confluence Decision Logic                                        |
//+------------------------------------------------------------------+
ENUM_INTENT AvaliaTudo()
{
   int buyConfirmations = 0;
   int sellConfirmations = 0;
   int buyRules = 0;
   int sellRules = 0;

   for(int i=0; i<g_nRules; i++) {
      if(g_rules[i].intent == INTENT_BUY) {
         buyRules++;
         if(AvaliaRegra(g_rules[i])) buyConfirmations++;
      } else if(g_rules[i].intent == INTENT_SELL) {
         sellRules++;
         if(AvaliaRegra(g_rules[i])) sellConfirmations++;
      }
   }

   if(buyRules > 0 && buyConfirmations == buyRules) return INTENT_BUY;
   if(sellRules > 0 && sellConfirmations == sellRules) return INTENT_SELL;

   return INTENT_NONE;
}

//+------------------------------------------------------------------+
//| Calculate Lot Volume based on risk and history                   |
//+------------------------------------------------------------------+
double CalculaLote(double riskPercent)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = equity * riskPercent / 100.0;

   //--- Martingale
   if(p_useMartingale) {
      if(HistorySelect(0, TimeCurrent())) {
         int total = HistoryDealsTotal();
         for(int i=total-1; i>=0; i--) {
            ulong ticket = HistoryDealGetTicket(i);
            if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol &&
               HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
               double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
               if(profit < 0) riskAmount *= 2.0;
               break;
            }
         }
      }
   }

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double stopPoints = (p_stopPoints > 0) ? p_stopPoints : 100;

   if(stopPoints == 0) return 0.01;

   double volume = riskAmount / (stopPoints * (tickValue / (tickSize / _Point)));
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   volume = MathFloor(volume / step) * step;

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(volume < minLot) volume = minLot;
   if(volume > maxLot) volume = maxLot;

   return NormalizeDouble(volume, 2);
}

//+------------------------------------------------------------------+
//| Execute Order                                                    |
//+------------------------------------------------------------------+
void EnviaOrdem(ENUM_INTENT type, string reason)
{
   if(type == INTENT_NONE) return;

   // Check max trades
   int count = 0;
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) count++;
   }
   if(count >= p_maxTrades) return;

   double lot = CalculaLote(p_riskPercent);
   double price = (type == INTENT_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0, tp = 0;

   if(type == INTENT_BUY) {
      if(p_stopPoints > 0) sl = price - p_stopPoints * _Point;
      if(p_takePoints > 0) tp = price + p_takePoints * _Point;
      if(g_trade.Buy(lot, _Symbol, price, sl, tp, reason)) {
         SendNotification("MT-LiveExecutor: BUY " + DoubleToString(lot, 2) + " " + _Symbol + " (" + reason + ")");
      }
   } else {
      if(p_stopPoints > 0) sl = price + p_stopPoints * _Point;
      if(p_takePoints > 0) tp = price - p_takePoints * _Point;
      if(g_trade.Sell(lot, _Symbol, price, sl, tp, reason)) {
         SendNotification("MT-LiveExecutor: SELL " + DoubleToString(lot, 2) + " " + _Symbol + " (" + reason + ")");
      }
   }
}
