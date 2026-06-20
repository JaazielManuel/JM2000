//+------------------------------------------------------------------+
//|                                              MT_LiveExecutor.mq5 |
//|                                  Copyright 2024, Jules AI Agent |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Jules AI Agent"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

//=========================  MT5-KNOWLEDGE-CORE  =========================
// Procedural standards enforced: No object-oriented string methods.
// Uses static string functions (StringSubstr, StringReplace, etc.)
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

//--- Constants
#define EA_MAGIC 123456

//--- Enums
enum Signal { BUY = 1, SELL = -1, NONE = 0 };

//--- Structs
struct Rule {
   bool     active;
   int      type;       // 1: MA Cross, 2: RSI, 3: Stochastic, 4: BB, 5: Breakout, 6: Delta, 7: Volume, 8: AMA, 9: 2-Bar, 10: RS
   int      intent;     // 1: BUY, -1: SELL
   int      tf;
   int      p1, p2, p3;
   double   d1, d2;
   string   s1;
   int      handle;

   void Reset() {
      active = false;
      type = 0;
      intent = 0;
      tf = PERIOD_CURRENT;
      p1 = 0; p2 = 0; p3 = 0;
      d1 = 0; d2 = 0;
      s1 = "";
      handle = INVALID_HANDLE;
   }
};

//--- Global Variables
Rule buyRules[10];
Rule sellRules[10];
int nBuyRules = 0;
int nSellRules = 0;

// Strategy Parameters
double p_risk = 1.0;
int    p_slPoints = 300;
int    p_tpPoints = 500;
int    p_maxTrades = 3;
int    p_startHour = 0;
int    p_newsVeto = 20; // minutes
int    p_breakeven = 0;
int    p_breakevenPlus = 50;
int    p_trailingStop = 0;
int    p_trailingStep = 10;
bool   p_martingale = false;
bool   p_exitOpposite = false;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

// State
datetime lastBarTime = 0;
CTrade trade;

//--- Functions Prototypes
void InterpretaPrompt(string prompt);
void AddRule(string txt, int intent);
Signal AvaliaTudo();
Signal AvaliaRegra(Rule &r);
void EnviaOrdem(Signal s);
double CalculaLote(double risk);
void GerenciaPosicoes();
bool AguardaNoticias();
void ResetStrategy();
void CalculaStats();
void GravaLog(string texto);
double ExtraiNumero(string txt, int &cursor);
int PeriodoTexto(string nome);
double GetBufferValue(int handle, int buffer, int index);

//--- MQL5 Event Handlers
int OnInit() {
   trade.SetExpertMagicNumber(EA_MAGIC);
   EventSetTimer(5); // Timer for prompt monitoring and AI optimizer
   ResetStrategy();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   ResetStrategy();
   EventKillTimer();
}

void OnTick() {
   // Check bar frequency
   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar == lastBarTime) return;

   // Check hour filter
   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.hour < p_startHour) return;

   // Check news veto
   if(AguardaNoticias()) return;

   // Evaluate rules
   Signal s = AvaliaTudo();
   if(s != NONE) {
      if(PositionsTotal() < p_maxTrades) {
         EnviaOrdem(s);
         lastBarTime = currentBar;
      }
   }

   // Manage open positions (trailing, breakeven, exit by opposite)
   GerenciaPosicoes();
}

void OnTimer() {
   // Check for new prompt
   int file = FileOpen("prompt.txt", FILE_READ | FILE_COMMON);
   if(file != INVALID_HANDLE) {
      string prompt = FileReadString(file);
      FileClose(file);
      if(prompt != "") {
         InterpretaPrompt(prompt);
         FileDelete("prompt.txt", FILE_COMMON);
         GravaLog("Novo prompt carregado: " + prompt);
      }
   }

   // AIOptimizer placeholder
   static datetime lastOpt = 0;
   if(TimeCurrent() - lastOpt > 3600) {
      CalculaStats();
      lastOpt = TimeCurrent();
   }
}

//--- NLP Parsing Logic
void InterpretaPrompt(string prompt) {
   ResetStrategy();
   StringToLower(prompt);
   StringReplace(prompt, "|", ".");
   StringReplace(prompt, "\n", ".");
   // Do not replace comma with dot yet, as dot is the segment separator

   string segments[];
   int nSegments = StringSplit(prompt, '.', segments);

   int currentIntent = 0; // 0: Global, 1: BUY, -1: SELL

   for(int i=0; i<nSegments; i++) {
      string seg = segments[i];
      StringReplace(seg, ",", "."); // normalize decimals within the segment
      StringTrimLeft(seg);
      StringTrimRight(seg);
      if(seg == "") continue;

      // Global parameters
      int cursor = 0;
      if(StringFind(seg, "risco") >= 0) p_risk = ExtraiNumero(seg, cursor);
      cursor = StringFind(seg, "stop");
      if(cursor >= 0) {
         cursor += 4;
         p_slPoints = (int)ExtraiNumero(seg, cursor);
      }
      cursor = StringFind(seg, "take"); if(cursor >= 0) p_tpPoints = (int)ExtraiNumero(seg, cursor);
      cursor = StringFind(seg, "máximo") >= 0 ? StringFind(seg, "máximo") : StringFind(seg, "max");
      if(cursor >= 0) p_maxTrades = (int)ExtraiNumero(seg, cursor);
      cursor = StringFind(seg, "após as");
      if(cursor >= 0) {
         cursor += 7;
         p_startHour = (int)ExtraiNumero(seg, cursor);
      }
      cursor = StringFind(seg, "notícias");
      if(cursor >= 0) {
         p_newsVeto = (int)ExtraiNumero(seg, cursor);
         if(p_newsVeto == 0) p_newsVeto = 20; // Default if not explicitly found in segment
      }
      cursor = StringFind(seg, "breakeven") >= 0 ? StringFind(seg, "breakeven") : StringFind(seg, "move stop para entrada");
      if(cursor >= 0) {
         p_breakeven = (int)ExtraiNumero(seg, cursor);
         if(p_breakeven == 0) p_breakeven = 30; // Default if not explicitly found in segment
      }
      cursor = StringFind(seg, "trailing") >= 0 ? StringFind(seg, "trailing") : StringFind(seg, "rastreio");
      if(cursor >= 0) p_trailingStop = (int)ExtraiNumero(seg, cursor);

      if(StringFind(seg, "martingale") >= 0) p_martingale = true;
      if(StringFind(seg, "saída por oposto") >= 0) p_exitOpposite = true;

      if(StringFind(seg, "cada") >= 0) p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(seg);

      // Intent shifts
      if(StringFind(seg, "compra") >= 0) { currentIntent = 1; }
      if(StringFind(seg, "vende") >= 0)  { currentIntent = -1; }

      // Indicators
      if(currentIntent != 0) {
         AddRule(seg, currentIntent);
      }
   }
}

void AddRule(string txt, int intent) {
   static int lastMA = 20;
   static int lastRSI = 14;

   Rule r; r.Reset();
   r.intent = intent;
   r.tf = PeriodoTexto(txt);
   r.active = true;

   int cursor = 0;

   // 1. MA Cross
   if(StringFind(txt, "média") >= 0 || StringFind(txt, "ma") >= 0) {
      cursor = StringFind(txt, "média") >= 0 ? StringFind(txt, "média") : StringFind(txt, "ma");
      r.type = 1;
      r.p1 = (int)ExtraiNumero(txt, cursor);
      if(r.p1 == 0) r.p1 = lastMA; else lastMA = r.p1;
      r.p2 = (int)ExtraiNumero(txt, cursor);
      if(r.p2 == 0) r.p2 = 21; // Default slow MA
      r.handle = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_EMA, PRICE_CLOSE);
      // second handle for cross would be r.p2, usually we need two handles or one with two buffers
      // for simplicity here we assume MA cross vs price or another MA
   }
   // 2. RSI
   if(StringFind(txt, "rsi") >= 0) {
      cursor = StringFind(txt, "rsi") + 3;
      r.type = 2;
      r.p1 = (int)ExtraiNumero(txt, cursor);
      if(r.p1 == 0) r.p1 = lastRSI; else lastRSI = r.p1;
      r.d1 = ExtraiNumero(txt, cursor); // Threshold
      r.handle = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
   }
   // 3. Stochastic
   if(StringFind(txt, "estocástico") >= 0 || StringFind(txt, "stoch") >= 0) {
      r.type = 3;
      r.p1 = 5; r.p2 = 3; r.p3 = 3;
      r.handle = iStochastic(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, r.p2, r.p3, MODE_SMA, STO_LOWHIGH);
   }
   // 4. Bollinger Bands
   if(StringFind(txt, "bollinger") >= 0 || StringFind(txt, "bandas") >= 0) {
      r.type = 4;
      r.p1 = 20; r.d1 = 2.0;
      r.handle = iBands(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, r.d1, PRICE_CLOSE);
   }
   // 5. Daily Breakout
   if(StringFind(txt, "breakout") >= 0) {
      r.type = 5;
   }
   // 6. Delta Aggression
   if(StringFind(txt, "delta") >= 0 || StringFind(txt, "agressão") >= 0) {
      r.type = 6;
      r.p1 = 60; // seconds
      r.p2 = 300; // trigger
   }
   // 7. Volume Cycle
   if(StringFind(txt, "volume") >= 0) {
      r.type = 7;
      r.p1 = 12;
   }
   // 8. AMA
   if(StringFind(txt, "ama") >= 0) {
      r.type = 8;
      r.p1 = 10; r.p2 = 2; r.p3 = 30;
      r.handle = iAMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, r.p2, r.p3, 0, PRICE_CLOSE);
   }
   // 9. 2-Bar Patterns
   if(StringFind(txt, "padrão") >= 0 || StringFind(txt, "candle") >= 0) {
      r.type = 9;
   }
   // 10. Relative Strength
   if(StringFind(txt, "força") >= 0 || StringFind(txt, "rs") >= 0) {
      r.type = 10;
      r.s1 = "US30";
   }

   if(r.type > 0) {
      if(intent == 1 && nBuyRules < 10) buyRules[nBuyRules++] = r;
      if(intent == -1 && nSellRules < 10) sellRules[nSellRules++] = r;
   }
}

double ExtraiNumero(string txt, int &cursor) {
   string res = "";
   bool found = false;
   for(int i = cursor; i < StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.') {
         res += CharToString((char)c);
         found = true;
      } else if(found) {
         cursor = i;
         break;
      }
   }
   return StringToDouble(res);
}

int PeriodoTexto(string nome) {
   if(StringFind(nome, "m15") >= 0) return PERIOD_M15;
   if(StringFind(nome, "m1") >= 0)  return PERIOD_M1;
   if(StringFind(nome, "m5") >= 0)  return PERIOD_M5;
   if(StringFind(nome, "h1") >= 0)  return PERIOD_H1;
   if(StringFind(nome, "d1") >= 0)  return PERIOD_D1;
   if(StringFind(nome, "minutos") >= 0 || StringFind(nome, "min") >= 0) {
      int c = 0;
      int val = (int)ExtraiNumero(nome, c);
      if(val == 1) return PERIOD_M1;
      if(val == 5) return PERIOD_M5;
      if(val == 15) return PERIOD_M15;
      if(val == 30) return PERIOD_M30;
   }
   return PERIOD_CURRENT;
}

//--- Signal Engine Logic
Signal AvaliaTudo() {
   int buyVotos = 0;
   int sellVotos = 0;

   for(int i=0; i<nBuyRules; i++) {
      if(buyRules[i].active && AvaliaRegra(buyRules[i]) == BUY) buyVotos++;
   }
   for(int i=0; i<nSellRules; i++) {
      if(sellRules[i].active && AvaliaRegra(sellRules[i]) == SELL) sellVotos++;
   }

   if(nBuyRules > 0 && buyVotos == nBuyRules) return BUY;
   if(nSellRules > 0 && sellVotos == nSellRules) return SELL;

   return NONE;
}

Signal AvaliaRegra(Rule &r) {
   if(!r.active) return NONE;

   switch(r.type) {
      case 1: // MA Cross
      {
         double ma0 = GetBufferValue(r.handle, 0, 0);
         double ma1 = GetBufferValue(r.handle, 0, 1);
         double close0 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
         double close1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         if(r.intent == 1 && close1 < ma1 && close0 > ma0) return BUY;
         if(r.intent == -1 && close1 > ma1 && close0 < ma0) return SELL;
         break;
      }
      case 2: // RSI
      {
         double rsi = GetBufferValue(r.handle, 0, 0);
         if(r.intent == 1 && rsi > r.d1) return BUY;
         if(r.intent == -1 && rsi < r.d1) return SELL;
         break;
      }
      case 3: // Stochastic
      {
         double k = GetBufferValue(r.handle, 0, 0);
         double d = GetBufferValue(r.handle, 1, 0);
         if(r.intent == 1 && k > d) return BUY;
         if(r.intent == -1 && k < d) return SELL;
         break;
      }
      case 4: // Bollinger Bands
      {
         double lower = GetBufferValue(r.handle, 2, 0);
         double upper = GetBufferValue(r.handle, 1, 0);
         double close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
         if(r.intent == 1 && close < lower) return BUY;
         if(r.intent == -1 && close > upper) return SELL;
         break;
      }
      case 5: // Daily Breakout
      {
         double hi = iHigh(_Symbol, PERIOD_D1, 1);
         double lo = iLow(_Symbol, PERIOD_D1, 1);
         double close = iClose(_Symbol, PERIOD_M1, 0);
         if(r.intent == 1 && close > hi) return BUY;
         if(r.intent == -1 && close < lo) return SELL;
         break;
      }
      case 6: // Delta Aggression
      {
         MqlTick ticks[];
         int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, TimeCurrent()-r.p1, TimeCurrent());
         long buy=0, sell=0;
         for(int i=0; i<n; i++) if((ticks[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++; else sell++;
         long delta = buy - sell;
         if(r.intent == 1 && delta > r.p2) return BUY;
         if(r.intent == -1 && delta < -r.p2) return SELL;
         break;
      }
      case 7: // Volume Cycle
      {
         double vol[]; ArraySetAsSeries(vol, true);
         CopyVolume(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0, r.p1, vol);
         int maxIdx = ArrayMaximum(vol);
         int minIdx = ArrayMinimum(vol);
         if(r.intent == 1 && minIdx == 0) return BUY;
         if(r.intent == -1 && maxIdx == 0) return SELL;
         break;
      }
      case 8: // AMA
      {
         double ama0 = GetBufferValue(r.handle, 0, 0);
         double ama1 = GetBufferValue(r.handle, 0, 1);
         if(r.intent == 1 && ama0 > ama1) return BUY;
         if(r.intent == -1 && ama0 < ama1) return SELL;
         break;
      }
      case 9: // 2-Bar Pattern
      {
         double h0 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
         double l0 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
         double h1 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         double l1 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         bool inside = (h0 < h1 && l0 > l1);
         bool outside = (h0 > h1 && l0 < l1);
         if(inside || outside) {
            bool bullish = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
            if(r.intent == 1 && bullish) return BUY;
            if(r.intent == -1 && !bullish) return SELL;
         }
         break;
      }
      case 10: // Relative Strength
      {
         double r1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, 14, PRICE_CLOSE, 0);
         double r2 = iRSI(r.s1, (ENUM_TIMEFRAMES)r.tf, 14, PRICE_CLOSE, 0);
         if(r.intent == 1 && r1 > r2 + 5) return BUY;
         if(r.intent == -1 && r1 < r2 - 5) return SELL;
         break;
      }
   }
   return NONE;
}
void EnviaOrdem(Signal s) {
   if(s == NONE) return;

   double lote = CalculaLote(p_risk);
   double sl = 0, tp = 0;
   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   string msg = "";
   if(s == BUY) {
      sl = (p_slPoints > 0) ? price - p_slPoints * _Point : 0;
      tp = (p_tpPoints > 0) ? price + p_tpPoints * _Point : 0;
      if(trade.Buy(lote, _Symbol, price, sl, tp)) {
         msg = "Compra executada: " + DoubleToString(lote, 2) + " SL: " + DoubleToString(sl, _Digits) + " TP: " + DoubleToString(tp, _Digits);
         GravaLog(msg);
      } else {
         msg = "Erro na compra: " + IntegerToString(trade.ResultRetcode());
         GravaLog(msg);
      }
   } else {
      sl = (p_slPoints > 0) ? price + p_slPoints * _Point : 0;
      tp = (p_tpPoints > 0) ? price - p_tpPoints * _Point : 0;
      if(trade.Sell(lote, _Symbol, price, sl, tp)) {
         msg = "Venda executada: " + DoubleToString(lote, 2) + " SL: " + DoubleToString(sl, _Digits) + " TP: " + DoubleToString(tp, _Digits);
         GravaLog(msg);
      } else {
         msg = "Erro na venda: " + IntegerToString(trade.ResultRetcode());
         GravaLog(msg);
      }
   }
}

double CalculaLote(double riskPercent) {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAbs = balance * riskPercent / 100.0;
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(p_slPoints == 0 || tickVal == 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double lot = riskAbs / (p_slPoints * _Point * (tickVal / tickSize));

   // Martingale
   if(p_martingale) {
      HistorySelect(TimeCurrent() - 86400, TimeCurrent());
      int total = HistoryDealsTotal();
      if(total > 0) {
         ulong ticket = HistoryDealGetTicket(total - 1);
         if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            if(profit < 0) lot *= 2;
         }
      }
   }

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / step) * step;
   lot = MathMax(lot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
   lot = MathMin(lot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX));

   return lot;
}

void GerenciaPosicoes() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
         double sl = PositionGetDouble(POSITION_SL);
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

         // Breakeven
         if(p_breakeven > 0) {
            if(type == POSITION_TYPE_BUY && currentPrice > openPrice + p_breakeven * _Point) {
               double newSL = openPrice + p_breakevenPlus * _Point;
               if(sl < newSL) trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
            }
            if(type == POSITION_TYPE_SELL && currentPrice < openPrice - p_breakeven * _Point) {
               double newSL = openPrice - p_breakevenPlus * _Point;
               if(sl == 0 || sl > newSL) trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
            }
         }

         // Trailing Stop
         if(p_trailingStop > 0) {
            if(type == POSITION_TYPE_BUY && currentPrice > openPrice + p_trailingStop * _Point) {
               double newSL = currentPrice - p_trailingStop * _Point;
               if(newSL > sl + p_trailingStep * _Point) trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
            }
            if(type == POSITION_TYPE_SELL && currentPrice < openPrice - p_trailingStop * _Point) {
               double newSL = currentPrice + p_trailingStop * _Point;
               if(sl == 0 || newSL < sl - p_trailingStep * _Point) trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
            }
         }

         // Exit by Opposite Signal
         if(p_exitOpposite) {
            Signal s = AvaliaTudo();
            if((type == POSITION_TYPE_BUY && s == SELL) || (type == POSITION_TYPE_SELL && s == BUY)) {
               trade.PositionClose(ticket);
            }
         }
      }
   }
}
bool AguardaNoticias() {
   // Binary news veto
   int file = FileOpen("news_veto.txt", FILE_READ | FILE_COMMON);
   if(file != INVALID_HANDLE) {
      string veto = FileReadString(file);
      FileClose(file);
      if(veto == "1" || veto == "true") return true;
   }

   // Calendar.txt scan
   file = FileOpen("calendar.txt", FILE_READ | FILE_COMMON);
   if(file != INVALID_HANDLE) {
      datetime now = TimeCurrent();
      while(!FileIsEnding(file)) {
         string line = FileReadString(file);
         // Format: YYYY.MM.DD HH:MM;Symbol;Impact;Title
         if(StringFind(line, "High") >= 0 || StringFind(line, "Alto") >= 0) {
            string parts[];
            StringSplit(line, ';', parts);
            if(ArraySize(parts) > 0) {
               datetime eventTime = StringToTime(parts[0]);
               if(MathAbs(now - eventTime) < p_newsVeto * 60) {
                  FileClose(file);
                  return true;
               }
            }
         }
      }
      FileClose(file);
   }

   return false;
}

void ResetStrategy() {
   for(int i=0; i<nBuyRules; i++) {
      if(buyRules[i].handle != INVALID_HANDLE) IndicatorRelease(buyRules[i].handle);
      buyRules[i].Reset();
   }
   for(int i=0; i<nSellRules; i++) {
      if(sellRules[i].handle != INVALID_HANDLE) IndicatorRelease(sellRules[i].handle);
      sellRules[i].Reset();
   }
   nBuyRules = 0;
   nSellRules = 0;
   p_risk = 1.0;
   p_slPoints = 300;
   p_tpPoints = 500;
   p_maxTrades = 3;
   p_startHour = 0;
   p_newsVeto = 20;
   p_breakeven = 0;
   p_trailingStop = 0;
   p_martingale = false;
   p_exitOpposite = false;
   p_frequency = PERIOD_M15;
}

void CalculaStats() {
   HistorySelect(0, TimeCurrent());
   int total = HistoryDealsTotal();
   int wins = 0, losses = 0;
   double profit = 0, drawdown = 0, maxBalance = 0;
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   for(int i=0; i<total; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
         double p = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         profit += p;
         if(p > 0) wins++; else if(p < 0) losses++;

         double balanceAtTime = currentBalance - profit; // Simplified
         if(balanceAtTime > maxBalance) maxBalance = balanceAtTime;
         double dd = maxBalance - balanceAtTime;
         if(dd > drawdown) drawdown = dd;
      }
   }

   double winRate = (wins + losses > 0) ? (double)wins / (wins + losses) * 100.0 : 0;
   Print("Stats: WinRate: ", DoubleToString(winRate, 2), "% | Drawdown: ", DoubleToString(drawdown, 2), " | Profit: ", DoubleToString(profit, 2));
}

void GravaLog(string texto) {
   Print(texto);
   SendNotification(texto);
   int file = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_READ | FILE_COMMON | FILE_CSV);
   if(file != INVALID_HANDLE) {
      FileSeek(file, 0, SEEK_END);
      FileWrite(file, TimeToString(TimeCurrent()), texto);
      FileClose(file);
   }
}
double GetBufferValue(int handle, int buffer, int index) {
   if(handle == INVALID_HANDLE) return 0.0;
   double val[];
   ArraySetAsSeries(val, true);
   if(CopyBuffer(handle, buffer, index, 1, val) > 0) return val[0];
   return 0.0;
}
