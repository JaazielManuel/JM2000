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
enum ENUM_SIGNAL { SIGNAL_NONE=0, SIGNAL_BUY=1, SIGNAL_SELL=-1 };

//--- STRUCTS
struct Rule {
   bool active;
   int type;         // 1: MA Cross, 2: RSI, 3: Stochastic, 4: BB, 5: Breakout, 6: Delta, 7: Volume, 8: AMA, 9: Pattern, 10: Relative
   int handle1;
   int handle2;
   int p1, p2, p3;   // Periods/Params
   double d1, d2;    // Levels/Thresholds
   ENUM_SIGNAL intent;

   void Reset() {
      active = false;
      if(handle1 != INVALID_HANDLE) IndicatorRelease(handle1);
      if(handle2 != INVALID_HANDLE) IndicatorRelease(handle2);
      handle1 = INVALID_HANDLE;
      handle2 = INVALID_HANDLE;
      type = 0;
   }
};

//--- GLOBALS
Rule g_rules[MAX_RULES];
int g_nRules = 0;
CTrade g_trade;
CPositionInfo g_pos;

// Strategy Parameters
double p_risk = 1.0;
double p_sl = 0;
double p_tp = 0;
int p_maxTrades = 3;
int p_breakeven = 0;
int p_breakevenPlus = 0;
int p_trailingStop = 0;
int p_trailingStep = 0;
bool p_martingale = false;
int p_newsVeto = 20; // minutes
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
int p_startHour = 0;
datetime g_lastExecution = 0;
string g_lastPrompt = "";

//--- UTILITIES
double ExtraiNumero(string txt, int &cursor) {
   string s = "";
   bool found = false;
   for(int i = cursor; i < StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.' || c == ',') {
         if(c == ',') s += "."; else s += StringSubstr(txt, i, 1);
         found = true;
      } else if(found) {
         cursor = i;
         return StringToDouble(s);
      }
   }
   cursor = StringLen(txt);
   return StringToDouble(s);
}

ENUM_TIMEFRAMES PeriodoTexto(string txt) {
   string t = txt;
   StringToLower(t);
   if(StringFind(t, "m15") >= 0) return PERIOD_M15;
   if(StringFind(t, "m1") >= 0)  return PERIOD_M1;
   if(StringFind(t, "m5") >= 0)  return PERIOD_M5;
   if(StringFind(t, "h1") >= 0)  return PERIOD_H1;
   if(StringFind(t, "d1") >= 0)  return PERIOD_D1;
   return PERIOD_CURRENT;
}

double GetBufferValue(int handle, int buffer, int shift) {
   double arr[];
   ArraySetAsSeries(arr, true);
   if(CopyBuffer(handle, buffer, shift, 1, arr) > 0) return arr[0];
   return 0;
}

//--- LOGGING & PERSISTENCE
void GravaLog(string msg) {
   PrintFormat("[MT-LiveExecutor] %s", msg);
}

void GravaCSV() {
   int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_COMMON, ';');
   if(handle != INVALID_HANDLE) {
      FileWrite(handle, "Ticket", "Symbol", "Type", "Lots", "PriceOpen", "SL", "TP", "Profit");
      for(int i = 0; i < PositionsTotal(); i++) {
         if(g_pos.SelectByIndex(i)) {
            if(g_pos.Magic() == EA_MAGIC) {
               FileWrite(handle, g_pos.Ticket(), g_pos.Symbol(), g_pos.PositionType(), g_pos.Volume(), g_pos.PriceOpen(), g_pos.StopLoss(), g_pos.TakeProfit(), g_pos.Profit());
            }
         }
      }
      FileClose(handle);
   }
}

//--- NEWS FILTER
bool AguardaNoticias() {
   // Check news_veto.txt
   int hVeto = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(hVeto != INVALID_HANDLE) {
      string content = FileReadString(hVeto);
      FileClose(hVeto);
      if(StringFind(content, "1") >= 0) return true;
   }

   // Check calendar.txt
   int hCal = FileOpen("calendar.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(hCal != INVALID_HANDLE) {
      datetime now = TimeCurrent();
      while(!FileIsEnding(hCal)) {
         string line = FileReadString(hCal);
         // Format: YYYY.MM.DD HH:MM;Symbol;Impact;Title
         int semi1 = StringFind(line, ";");
         if(semi1 < 10) continue;
         string dateStr = StringSubstr(line, 0, semi1);
         datetime newsTime = StringToTime(dateStr);
         if(MathAbs(now - newsTime) < p_newsVeto * 60) {
            if(StringFind(line, "High") >= 0 || StringFind(line, "Alto") >= 0) {
               FileClose(hCal);
               return true;
            }
         }
      }
      FileClose(hCal);
   }
   return false;
}

//--- SIGNAL ENGINE
int AvaliaRegra(int index) {
   Rule r = g_rules[index];
   if(!r.active) return 0;

   switch(r.type) {
      case 1: { // MA Cross
         double f0 = GetBufferValue(r.handle1, 0, 0);
         double s0 = GetBufferValue(r.handle2, 0, 0);
         double f1 = GetBufferValue(r.handle1, 0, 1);
         double s1 = GetBufferValue(r.handle2, 0, 1);
         if(f1 <= s1 && f0 > s0) return (r.intent == SIGNAL_BUY ? 1 : 0);
         if(f1 >= s1 && f0 < s0) return (r.intent == SIGNAL_SELL ? 1 : 0);
         break;
      }
      case 2: { // RSI
         double val = GetBufferValue(r.handle1, 0, 0);
         if(r.intent == SIGNAL_BUY && val < r.d2) return 1;
         if(r.intent == SIGNAL_SELL && val > r.d1) return 1;
         // Special logic for prompt: "rsi acima de 55"
         if(r.intent == SIGNAL_BUY && r.d1 > 0 && val > r.d1) return 1;
         if(r.intent == SIGNAL_SELL && r.d2 > 0 && val < r.d2) return 1;
         break;
      }
      case 3: { // Stochastic
         double k0 = GetBufferValue(r.handle1, 0, 0);
         double d0 = GetBufferValue(r.handle1, 1, 0);
         double k1 = GetBufferValue(r.handle1, 0, 1);
         double d1 = GetBufferValue(r.handle1, 1, 1);
         if(k1 <= d1 && k0 > d0) return (r.intent == SIGNAL_BUY ? 1 : 0);
         if(k1 >= d1 && k0 < d0) return (r.intent == SIGNAL_SELL ? 1 : 0);
         break;
      }
      case 4: { // BB
         double close = iClose(_Symbol, PERIOD_CURRENT, 0);
         double upper = GetBufferValue(r.handle1, 1, 0);
         double lower = GetBufferValue(r.handle1, 2, 0);
         if(close < lower) return (r.intent == SIGNAL_BUY ? 1 : 0);
         if(close > upper) return (r.intent == SIGNAL_SELL ? 1 : 0);
         break;
      }
      case 5: { // Daily Breakout
         double hi = iHigh(_Symbol, PERIOD_D1, 1);
         double lo = iLow(_Symbol, PERIOD_D1, 1);
         double close = iClose(_Symbol, PERIOD_CURRENT, 0);
         if(close > hi) return (r.intent == SIGNAL_BUY ? 1 : 0);
         if(close < lo) return (r.intent == SIGNAL_SELL ? 1 : 0);
         break;
      }
      case 6: { // Delta Aggression
         MqlTick arr[];
         int n = CopyTicksRange(_Symbol, arr, COPY_TICKS_TRADE, TimeCurrent() - r.p1, TimeCurrent());
         long buy = 0, sell = 0;
         for(int i = 0; i < n; i++) if((arr[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++; else if((arr[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sell++;
         long delta = buy - sell;
         if(delta > r.p2) return (r.intent == SIGNAL_BUY ? 1 : 0);
         if(delta < -r.p2) return (r.intent == SIGNAL_SELL ? 1 : 0);
         break;
      }
      case 7: { // Volume Cycle
         double vol[];
         ArraySetAsSeries(vol, true);
         if(CopyVolume(_Symbol, PERIOD_CURRENT, 0, r.p1, vol) > 0) {
            int maxIdx = ArrayMaximum(vol);
            int minIdx = ArrayMinimum(vol);
            if(maxIdx == 0) return (r.intent == SIGNAL_SELL ? 1 : 0);
            if(minIdx == 0) return (r.intent == SIGNAL_BUY ? 1 : 0);
         }
         break;
      }
      case 8: { // AMA
         double ama0 = GetBufferValue(r.handle1, 0, 0);
         double ama1 = GetBufferValue(r.handle1, 0, 1);
         if(ama0 > ama1) return (r.intent == SIGNAL_BUY ? 1 : 0);
         if(ama0 < ama1) return (r.intent == SIGNAL_SELL ? 1 : 0);
         break;
      }
      case 9: { // Padrão 2 barras
         double h0 = iHigh(_Symbol, PERIOD_CURRENT, 0);
         double l0 = iLow(_Symbol, PERIOD_CURRENT, 0);
         double h1 = iHigh(_Symbol, PERIOD_CURRENT, 1);
         double l1 = iLow(_Symbol, PERIOD_CURRENT, 1);
         double c0 = iClose(_Symbol, PERIOD_CURRENT, 0);
         double o0 = iOpen(_Symbol, PERIOD_CURRENT, 0);
         bool inside = (h0 < h1 && l0 > l1);
         bool outside = (h0 > h1 && l0 < l1);
         if(inside || outside) {
            if(c0 > o0) return (r.intent == SIGNAL_BUY ? 1 : 0);
            if(c0 < o0) return (r.intent == SIGNAL_SELL ? 1 : 0);
         }
         break;
      }
      case 10: { // Relative Strength
         double r1 = GetBufferValue(r.handle1, 0, 0);
         double r2 = GetBufferValue(r.handle2, 0, 0);
         if(r1 > r2 + 5) return (r.intent == SIGNAL_BUY ? 1 : 0);
         if(r1 < r2 - 5) return (r.intent == SIGNAL_SELL ? 1 : 0);
         break;
      }
   }
   return 0;
}

ENUM_SIGNAL AvaliaTudo() {
   int buyVotos = 0, buyRules = 0;
   int sellVotos = 0, sellRules = 0;

   for(int i = 0; i < g_nRules; i++) {
      if(g_rules[i].intent == SIGNAL_BUY) {
         buyRules++;
         buyVotos += AvaliaRegra(i);
      } else if(g_rules[i].intent == SIGNAL_SELL) {
         sellRules++;
         sellVotos += AvaliaRegra(i);
      }
   }

   if(buyRules > 0 && buyVotos == buyRules) return SIGNAL_BUY;
   if(sellRules > 0 && sellVotos == sellRules) return SIGNAL_SELL;

   return SIGNAL_NONE;
}

//--- PARSER
void ResetStrategy() {
   for(int i = 0; i < MAX_RULES; i++) g_rules[i].Reset();
   g_nRules = 0;
   g_trade.SetExpertMagicNumber(EA_MAGIC);
}

void AddRule(string txt, ENUM_SIGNAL intent) {
   string t = txt;
   StringToLower(t);

   // MA
   if(StringFind(t, "média") >= 0 || StringFind(t, "ma") >= 0) {
      if(g_nRules >= MAX_RULES) return;
      int cursor = StringFind(t, "média");
      if(cursor < 0) cursor = StringFind(t, "ma");
      Rule r; r.Reset(); r.intent = intent;
      r.type = 1;
      r.p1 = (int)ExtraiNumero(t, cursor);
      r.p2 = (int)ExtraiNumero(t, cursor);
      if(r.p2 == 0) { r.p2 = r.p1; r.p1 = 9; }
      r.handle1 = iMA(_Symbol, PERIOD_CURRENT, r.p1, 0, MODE_EMA, PRICE_CLOSE);
      r.handle2 = iMA(_Symbol, PERIOD_CURRENT, r.p2, 0, MODE_EMA, PRICE_CLOSE);
      if(r.handle1 != INVALID_HANDLE && r.handle2 != INVALID_HANDLE) { r.active = true; g_rules[g_nRules++] = r; }
   }

   // RSI
   if(StringFind(t, "rsi") >= 0) {
      if(g_nRules >= MAX_RULES) return;
      int cursor = StringFind(t, "rsi");
      Rule r; r.Reset(); r.intent = intent;
      r.type = 2;
      r.p1 = (int)ExtraiNumero(t, cursor);
      if(r.p1 == 0) r.p1 = 14;
      r.d1 = ExtraiNumero(t, cursor); // over
      r.d2 = ExtraiNumero(t, cursor); // under
      if(r.d1 > 0 && r.d2 == 0) {
         if(StringFind(t, "acima") >= 0) { r.d1 = r.d1; r.d2 = 0; }
         else { r.d2 = r.d1; r.d1 = 0; }
      }
      r.handle1 = iRSI(_Symbol, PERIOD_CURRENT, r.p1, PRICE_CLOSE);
      if(r.handle1 != INVALID_HANDLE) { r.active = true; g_rules[g_nRules++] = r; }
   }

   // Stoch
   if(StringFind(t, "stochastic") >= 0 || StringFind(t, "estocástico") >= 0) {
      if(g_nRules >= MAX_RULES) return;
      int cursor = StringFind(t, "stochastic");
      if(cursor < 0) cursor = StringFind(t, "estocástico");
      Rule r; r.Reset(); r.intent = intent;
      r.type = 3;
      r.p1 = (int)ExtraiNumero(t, cursor); if(r.p1 == 0) r.p1 = 5;
      r.p2 = (int)ExtraiNumero(t, cursor); if(r.p2 == 0) r.p2 = 3;
      r.p3 = (int)ExtraiNumero(t, cursor); if(r.p3 == 0) r.p3 = 3;
      r.handle1 = iStochastic(_Symbol, PERIOD_CURRENT, r.p1, r.p2, r.p3, MODE_SMA, STO_LOWHIGH);
      if(r.handle1 != INVALID_HANDLE) { r.active = true; g_rules[g_nRules++] = r; }
   }

   // BB
   if(StringFind(t, "bollinger") >= 0 || StringFind(t, "bb") >= 0) {
      if(g_nRules >= MAX_RULES) return;
      int cursor = StringFind(t, "bollinger");
      if(cursor < 0) cursor = StringFind(t, "bb");
      Rule r; r.Reset(); r.intent = intent;
      r.type = 4;
      r.p1 = (int)ExtraiNumero(t, cursor); if(r.p1 == 0) r.p1 = 20;
      r.d1 = ExtraiNumero(t, cursor); if(r.d1 == 0) r.d1 = 2.0;
      r.handle1 = iBands(_Symbol, PERIOD_CURRENT, r.p1, 0, r.d1, PRICE_CLOSE);
      if(r.handle1 != INVALID_HANDLE) { r.active = true; g_rules[g_nRules++] = r; }
   }

   // Breakout
   if(StringFind(t, "breakout") >= 0 || StringFind(t, "rompimento") >= 0) {
      if(g_nRules >= MAX_RULES) return;
      Rule r; r.Reset(); r.intent = intent;
      r.type = 5; r.active = true; g_rules[g_nRules++] = r;
   }

   // Delta
   if(StringFind(t, "delta") >= 0 || StringFind(t, "agressão") >= 0) {
      if(g_nRules >= MAX_RULES) return;
      int cursor = StringFind(t, "delta");
      if(cursor < 0) cursor = StringFind(t, "agressão");
      Rule r; r.Reset(); r.intent = intent;
      r.type = 6;
      r.p1 = (int)ExtraiNumero(t, cursor); if(r.p1 == 0) r.p1 = 60;
      r.p2 = (int)ExtraiNumero(t, cursor); if(r.p2 == 0) r.p2 = 300;
      r.active = true; g_rules[g_nRules++] = r;
   }

   // Volume
   if(StringFind(t, "volume") >= 0 || StringFind(t, "ciclo") >= 0) {
      if(g_nRules >= MAX_RULES) return;
      int cursor = StringFind(t, "volume");
      if(cursor < 0) cursor = StringFind(t, "ciclo");
      Rule r; r.Reset(); r.intent = intent;
      r.type = 7;
      r.p1 = (int)ExtraiNumero(t, cursor); if(r.p1 == 0) r.p1 = 12;
      r.active = true; g_rules[g_nRules++] = r;
   }

   // AMA
   if(StringFind(t, "ama") >= 0 || StringFind(t, "adaptativa") >= 0) {
      if(g_nRules >= MAX_RULES) return;
      int cursor = StringFind(t, "ama");
      if(cursor < 0) cursor = StringFind(t, "adaptativa");
      Rule r; r.Reset(); r.intent = intent;
      r.type = 8;
      r.p1 = (int)ExtraiNumero(t, cursor); if(r.p1 == 0) r.p1 = 10;
      r.handle1 = iAMA(_Symbol, PERIOD_CURRENT, r.p1, 2, 30, 0, PRICE_CLOSE);
      if(r.handle1 != INVALID_HANDLE) { r.active = true; g_rules[g_nRules++] = r; }
   }

   // Pattern
   if(StringFind(t, "padrão") >= 0 || StringFind(t, "barras") >= 0) {
      if(g_nRules >= MAX_RULES) return;
      Rule r; r.Reset(); r.intent = intent;
      r.type = 9; r.active = true; g_rules[g_nRules++] = r;
   }

   // RS
   if(StringFind(t, "força") >= 0 || StringFind(t, "relativa") >= 0) {
      if(g_nRules >= MAX_RULES) return;
      int cursor = StringFind(t, "força");
      if(cursor < 0) cursor = StringFind(t, "relativa");
      Rule r; r.Reset(); r.intent = intent;
      r.type = 10;
      r.p1 = (int)ExtraiNumero(t, cursor); if(r.p1 == 0) r.p1 = 14;
      string bench = "US30";
      r.handle1 = iRSI(_Symbol, PERIOD_CURRENT, r.p1, PRICE_CLOSE);
      r.handle2 = iRSI(bench, PERIOD_CURRENT, r.p1, PRICE_CLOSE);
      if(r.handle1 != INVALID_HANDLE && r.handle2 != INVALID_HANDLE) { r.active = true; g_rules[g_nRules++] = r; }
   }
}

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   GravaLog("Interpretando: " + prompt);

   string segments[];
   ushort sep1 = StringGetCharacter(".", 0);
   ushort sep2 = StringGetCharacter("|", 0);
   ushort sep3 = StringGetCharacter("\n", 0);

   string p2 = prompt;
   StringReplace(p2, "|", ".");
   StringReplace(p2, "\n", ".");
   StringSplit(p2, sep1, segments);

   for(int i = 0; i < ArraySize(segments); i++) {
      string s = segments[i];
      StringToLower(s);
      int cursor = 0;

      if(StringFind(s, "risco") >= 0) {
         cursor = StringFind(s, "risco");
         p_risk = ExtraiNumero(s, cursor);
      }
      if(StringFind(s, "stop") >= 0 && StringFind(s, "move") < 0) {
         cursor = StringFind(s, "stop");
         p_sl = ExtraiNumero(s, cursor);
      }
      if(StringFind(s, "take") >= 0) {
         cursor = StringFind(s, "take");
         p_tp = ExtraiNumero(s, cursor);
      }
      if(StringFind(s, "máximo") >= 0) {
         cursor = StringFind(s, "máximo");
         p_maxTrades = (int)ExtraiNumero(s, cursor);
      }
      if(StringFind(s, "breakeven") >= 0 || StringFind(s, "atingir") >= 0) {
         cursor = StringFind(s, "atingir");
         if(cursor < 0) cursor = StringFind(s, "breakeven");
         p_breakeven = (int)ExtraiNumero(s, cursor);
         p_breakevenPlus = (int)ExtraiNumero(s, cursor);
      }
      if(StringFind(s, "trailing") >= 0 || StringFind(s, "rastreio") >= 0) {
         cursor = StringFind(s, "trailing");
         if(cursor < 0) cursor = StringFind(s, "rastreio");
         p_trailingStop = (int)ExtraiNumero(s, cursor);
         p_trailingStep = (int)ExtraiNumero(s, cursor);
      }
      if(StringFind(s, "notícias") >= 0) {
         cursor = StringFind(s, "notícias");
         p_newsVeto = (int)ExtraiNumero(s, cursor);
      }
      if(StringFind(s, "martingale") >= 0) p_martingale = true;
      if(StringFind(s, "cada") >= 0 && (StringFind(s, "min") >= 0 || StringFind(s, "minutos") >= 0)) p_frequency = PeriodoTexto(s);
      if(StringFind(s, "depois das") >= 0 || StringFind(s, "após") >= 0) {
         cursor = StringFind(s, "h");
         if(cursor > 0) {
            int c2 = cursor - 2;
            if(c2 < 0) c2 = 0;
            p_startHour = (int)ExtraiNumero(s, c2);
         }
      }

      // Intents
      if(StringFind(s, "compra") >= 0) AddRule(s, SIGNAL_BUY);
      if(StringFind(s, "vende") >= 0) AddRule(s, SIGNAL_SELL);
   }
}

//--- TRADE EXECUTION
double CalculaLote(double risco) {
   double capital = AccountInfoDouble(ACCOUNT_BALANCE);
   double rAbs = capital * (risco / 100.0);

   if(p_martingale) {
      if(HistorySelect(0, TimeCurrent())) {
         int total = HistoryDealsTotal();
         for(int i = total - 1; i >= 0; i--) {
            ulong ticket = HistoryDealGetTicket(i);
            if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
               double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
               if(profit < 0) rAbs *= 2.0;
               break;
            }
         }
      }
   }

   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double slPoints = (p_sl > 0 ? p_sl : 300);

   double lot = rAbs / (slPoints * _Point * (tickVal / tickSize));

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / step) * step;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return lot;
}

void EnviaOrdem(ENUM_SIGNAL s) {
   if(PositionsTotal() >= p_maxTrades) return;
   if(AguardaNoticias()) { GravaLog("Trade vetado por notícias."); return; }

   double lote = CalculaLote(p_risk);
   double sl = 0, tp = 0;
   double price = 0;

   if(s == SIGNAL_BUY) {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(p_sl > 0) sl = price - p_sl * _Point;
      if(p_tp > 0) tp = price + p_tp * _Point;
      if(g_trade.Buy(lote, _Symbol, price, sl, tp)) GravaLog("Compra enviada.");
   } else if(s == SIGNAL_SELL) {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(p_sl > 0) sl = price + p_sl * _Point;
      if(p_tp > 0) tp = price - p_tp * _Point;
      if(g_trade.Sell(lote, _Symbol, price, sl, tp)) GravaLog("Venda enviada.");
   }
}

void GerenciaPosicoes() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(g_pos.SelectByIndex(i)) {
         if(g_pos.Magic() == EA_MAGIC && g_pos.Symbol() == _Symbol) {
            double profitPoints = (g_pos.PositionType() == POSITION_TYPE_BUY ? (SymbolInfoDouble(_Symbol, SYMBOL_BID) - g_pos.PriceOpen()) : (g_pos.PriceOpen() - SymbolInfoDouble(_Symbol, SYMBOL_ASK))) / _Point;

            // Breakeven
            if(p_breakeven > 0 && profitPoints >= p_breakeven) {
               double newSL = (g_pos.PositionType() == POSITION_TYPE_BUY ? (g_pos.PriceOpen() + p_breakevenPlus * _Point) : (g_pos.PriceOpen() - p_breakevenPlus * _Point));
               if(g_pos.StopLoss() == 0 || (g_pos.PositionType() == POSITION_TYPE_BUY && newSL > g_pos.StopLoss()) || (g_pos.PositionType() == POSITION_TYPE_SELL && newSL < g_pos.StopLoss())) {
                  g_trade.PositionModify(g_pos.Ticket(), newSL, g_pos.TakeProfit());
               }
            }

            // Trailing Stop
            if(p_trailingStop > 0 && profitPoints >= p_trailingStop) {
               double newSL = (g_pos.PositionType() == POSITION_TYPE_BUY ? (SymbolInfoDouble(_Symbol, SYMBOL_BID) - p_trailingStop * _Point) : (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + p_trailingStop * _Point));
               if((g_pos.PositionType() == POSITION_TYPE_BUY && newSL > g_pos.StopLoss() + p_trailingStep * _Point) || (g_pos.PositionType() == POSITION_TYPE_SELL && (g_pos.StopLoss() == 0 || newSL < g_pos.StopLoss() - p_trailingStep * _Point))) {
                  g_trade.PositionModify(g_pos.Ticket(), newSL, g_pos.TakeProfit());
               }
            }
         }
      }
   }
}

//--- EVENT HANDLERS
int OnInit() {
   EventSetTimer(5);
   ResetStrategy();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   ResetStrategy();
}

void CalculaStats() {
   if(!HistorySelect(0, TimeCurrent())) return;
   int total = HistoryDealsTotal();
   int wins = 0, losses = 0;
   double profit = 0, grossProfit = 0, grossLoss = 0;

   for(int i = 0; i < total; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
         double p = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         profit += p;
         if(p > 0) { wins++; grossProfit += p; }
         else if(p < 0) { losses++; grossLoss += MathAbs(p); }
      }
   }

   double winRate = (wins + losses > 0) ? (double)wins / (wins + losses) * 100.0 : 0;
   double pf = (grossLoss > 0) ? grossProfit / grossLoss : grossProfit;

   GravaLog(StringFormat("Stats: Profit=%.2f, WinRate=%.1f%%, PF=%.2f", profit, winRate, pf));
}

void OnTimer() {
   GravaCSV();
   CalculaStats();

   // Real-time prompt update
   int handle = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      string prompt = FileReadString(handle);
      FileClose(handle);
      if(prompt != "" && prompt != g_lastPrompt) {
         InterpretaPrompt(prompt);
         g_lastPrompt = prompt;
      }
   }
}

void OnTick() {
   GerenciaPosicoes();

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.hour < p_startHour) return;

   datetime now = iTime(_Symbol, p_frequency, 0);
   if(now != g_lastExecution) {
      ENUM_SIGNAL s = AvaliaTudo();
      if(s != SIGNAL_NONE) {
         EnviaOrdem(s);
         g_lastExecution = now;
      }
   }
}
