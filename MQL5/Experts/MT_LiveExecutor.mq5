//+------------------------------------------------------------------+
//|                                              MT_LiveExecutor.mq5 |
//|                                  Copyright 2024, MT-LiveExecutor |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MT-LiveExecutor"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

//=========================  MT5-KNOWLEDGE-CORE  =========================
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// ---------- CONSTANTS & ENUMS ----------
#define EA_MAGIC 123456
enum Signal {BUY=1, SELL=-1, NONE=0};

// ---------- STRUCTS ----------
struct Rule {
   bool     active;
   int      type;       // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: DailyBreak, 6: Delta, 7: Volume, 8: AMA, 9: Bar2, 10: RS
   int      tf;
   int      p1, p2, p3;
   double   d1, d2;
   string   s1;
   string   op;         // Relational operator (">", "<", etc.)
   int      handle;
   int      handle2;
   int      intent;     // BUY or SELL

   void Reset() {
      active = false;
      type = 0;
      tf = 0;
      p1 = 0; p2 = 0; p3 = 0;
      d1 = 0; d2 = 0;
      s1 = "";
      op = "";
      if(handle != INVALID_HANDLE) {
         IndicatorRelease(handle);
         handle = INVALID_HANDLE;
      }
      if(handle2 != INVALID_HANDLE) {
         IndicatorRelease(handle2);
         handle2 = INVALID_HANDLE;
      }
      intent = 0;
   }
};

// ---------- GLOBALS ----------
Rule buyRules[20];
Rule sellRules[20];
int nBuyRules = 0;
int nSellRules = 0;

int      p_maxTrades = 3;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
datetime last_bar_time = 0;

double   p_riskPercent = 1.0;
int      p_stopPoints = 300;
int      p_takePoints = 500;
int      p_startHour = 0;

int      p_breakeven = 0;
int      p_breakevenProfit = 0;
int      p_trailingStop = 0;
int      p_trailingStep = 0;
bool     p_martingale = false;
bool     p_exitOpposite = false;

CTrade trade;

// ---------- FORWARD DECLARATIONS ----------
void InterpretaPrompt(string prompt);
void AddRuleSpecific(string txt, int intent, int type);
int PeriodoTexto(string nome);
double ExtraiNumero(string txt, string anchor, int offset=0, int startPos=0);
string ExtraiTexto(string txt, string anchor, int offset=0);
double GetBufferValue(int handle, int buffer, int shift);
Signal AvaliaRegra(Rule &r);
Signal AvaliaTudo();
bool EnviaOrdem(Signal s, double lote, double sl, double tp);
void GerenciaPosicoes();
void CalculaStats();
void GravaLog(string texto);
void GravaEstadoCSV(ulong ticket, double price, double sl, double tp, string reason);
void ResetStrategy();
double CalculaLote(double riscoPercent, int slPoints);
bool AguardaNoticias();

// ---------- EVENT HANDLERS ----------
int OnInit() {
   trade.SetExpertMagicNumber(EA_MAGIC);
   EventSetTimer(3600); // Hourly timer for stats
   ResetStrategy();

   // Initial attempt to read prompt from file
   string filename = "prompt.txt";
   if(FileIsExist(filename, FILE_COMMON)) {
      int h = FileOpen(filename, FILE_READ|FILE_TXT|FILE_COMMON);
      if(h != INVALID_HANDLE) {
         string prompt = FileReadString(h);
         FileClose(h);
         InterpretaPrompt(prompt);
         FileDelete(filename, FILE_COMMON);
      }
   }

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   EventKillTimer();
   CalculaStats();
   ResetStrategy();
}

void OnTick() {
   // Real-time update check (efficiently)
   static uint last_prompt_check = 0;
   if(GetTickCount() - last_prompt_check > 1000) { // Check every 1 second
      last_prompt_check = GetTickCount();
      string filename = "prompt.txt";
      if(FileIsExist(filename, FILE_COMMON)) {
         int h = FileOpen(filename, FILE_READ|FILE_TXT|FILE_COMMON);
         if(h != INVALID_HANDLE) {
            string prompt = FileReadString(h);
            FileClose(h);
            InterpretaPrompt(prompt);
            FileDelete(filename, FILE_COMMON);
         }
      }
   }

   // Frequency check
   datetime current_bar = iTime(_Symbol, p_frequency, 0);
   if(current_bar == last_bar_time) return;
   last_bar_time = current_bar;

   // Start hour filter
   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.hour < p_startHour) return;

   // News filter
   if(AguardaNoticias()) return;

   // Signal evaluation
   Signal s = AvaliaTudo();

   // Trade execution logic
   if(s != NONE) {
      // Check max trades
      int openTrades = 0;
      for(int i=PositionsTotal()-1; i>=0; i--) {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelectByTicket(ticket)) {
            if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) openTrades++;
         }
      }

      if(openTrades < p_maxTrades) {
         double lote = CalculaLote(p_riskPercent, p_stopPoints);
         double sl = 0, tp = 0;
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

         if(s == BUY) {
            sl = bid - p_stopPoints * _Point;
            tp = ask + p_takePoints * _Point;
            EnviaOrdem(BUY, lote, sl, tp);
         } else if(s == SELL) {
            sl = ask + p_stopPoints * _Point;
            tp = bid - p_takePoints * _Point;
            EnviaOrdem(SELL, lote, sl, tp);
         }
      }
   }

   GerenciaPosicoes();
}

void OnTimer() {
   CalculaStats();
}

// ---------- PLACEHOLDERS FOR NEXT STEPS ----------
void ResetStrategy() {
   for(int i=0; i<20; i++) {
      buyRules[i].Reset();
      sellRules[i].Reset();
   }
   nBuyRules = 0;
   nSellRules = 0;
}

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   GravaLog("Interpretando novo prompt...");

   string normalized = prompt;
   StringReplace(normalized, "|", ".");
   StringReplace(normalized, "\n", ".");

   string segments[];
   StringSplit(normalized, '.', segments);

   int currentIntent = 0; // 1: BUY, -1: SELL

   for(int i=0; i<ArraySize(segments); i++) {
      string segment = segments[i];
      StringToLower(segment);
      StringTrimLeft(segment);
      StringTrimRight(segment);
      if(segment == "") continue;

      // Identify intent
      if(StringFind(segment, "compra") >= 0) currentIntent = 1;
      else if(StringFind(segment, "vende") >= 0) currentIntent = -1;

      // Global parameters
      if(StringFind(segment, "stop de") >= 0) p_stopPoints = (int)ExtraiNumero(segment, "stop de");
      if(StringFind(segment, "take de") >= 0) p_takePoints = (int)ExtraiNumero(segment, "take de");
      if(StringFind(segment, "risco de") >= 0) p_riskPercent = ExtraiNumero(segment, "risco de");
      if(StringFind(segment, "máximo") >= 0 && StringFind(segment, "trades") >= 0) p_maxTrades = (int)ExtraiNumero(segment, "máximo");

      if(StringFind(segment, "cada") >= 0 && StringFind(segment, "minutos") >= 0) {
         int m = (int)ExtraiNumero(segment, "cada");
         if(m == 1) p_frequency = PERIOD_M1;
         else if(m == 5) p_frequency = PERIOD_M5;
         else if(m == 15) p_frequency = PERIOD_M15;
         else if(m == 30) p_frequency = PERIOD_M30;
         else if(m == 60) p_frequency = PERIOD_H1;
      }

      if(StringFind(segment, "depois das") >= 0 || StringFind(segment, "após as") >= 0) {
         p_startHour = (int)ExtraiNumero(segment, "as");
      }

      // Breakeven & Trailing
      if(StringFind(segment, "breakeven") >= 0 || StringFind(segment, "move stop para entrada") >= 0) {
         p_breakeven = (int)ExtraiNumero(segment, "atingir");
         p_breakevenProfit = (int)ExtraiNumero(segment, "entrada");
      }
      if(StringFind(segment, "trailing") >= 0 || StringFind(segment, "rastreio") >= 0) {
         p_trailingStop = (int)ExtraiNumero(segment, "trailing");
         p_trailingStep = (int)ExtraiNumero(segment, "step");
      }

      if(StringFind(segment, "martingale") >= 0) p_martingale = true;
      if(StringFind(segment, "saída por oposto") >= 0) p_exitOpposite = true;

      // Compound rules with " e "
      string rules[];
      StringSplit(segment, ' ', rules); // Simple split to find indicators joined by 'e'

      // Better approach: search for all indicator keywords in the segment
      if(currentIntent != 0) {
         if(StringFind(segment, "média") >= 0) AddRuleSpecific(segment, currentIntent, 1);
         if(StringFind(segment, "rsi") >= 0) AddRuleSpecific(segment, currentIntent, 2);
         if(StringFind(segment, "estocástico") >= 0) AddRuleSpecific(segment, currentIntent, 3);
         if(StringFind(segment, "bollinger") >= 0) AddRuleSpecific(segment, currentIntent, 4);
         if(StringFind(segment, "breakout") >= 0) AddRuleSpecific(segment, currentIntent, 5);
         if(StringFind(segment, "delta") >= 0) AddRuleSpecific(segment, currentIntent, 6);
         if(StringFind(segment, "volume") >= 0) AddRuleSpecific(segment, currentIntent, 7);
         if(StringFind(segment, "ama") >= 0) AddRuleSpecific(segment, currentIntent, 8);
         if(StringFind(segment, "padrão") >= 0) AddRuleSpecific(segment, currentIntent, 9);
         if(StringFind(segment, "força relativa") >= 0) AddRuleSpecific(segment, currentIntent, 10);
      }
   }
}

void AddRuleSpecific(string txt, int intent, int type) {
   Rule r;
   r.Reset();
   r.intent = intent;
   r.active = true;
   r.type = type;

   int keywordPos = -1;
   if(type == 1) keywordPos = StringFind(txt, "média");
   if(type == 2) keywordPos = StringFind(txt, "rsi");

   switch(type) {
      case 1:
         r.p1 = (int)ExtraiNumero(txt, "média de", 0, (keywordPos >= 0 ? keywordPos : 0));
         r.tf = PeriodoTexto(txt);
         r.handle = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_EMA, PRICE_CLOSE);
         break;
      case 2:
         r.p1 = (int)ExtraiNumero(txt, "rsi", 0, (keywordPos >= 0 ? keywordPos : 0));
         r.d1 = ExtraiNumero(txt, "acima", 0, (keywordPos >= 0 ? keywordPos : 0));
         if(r.d1 == 0) r.d1 = ExtraiNumero(txt, "abaixo", 0, (keywordPos >= 0 ? keywordPos : 0));
         r.op = (StringFind(txt, "acima", (keywordPos >= 0 ? keywordPos : 0)) >= 0) ? ">" : "<";
         r.tf = PeriodoTexto(txt);
         r.handle = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
         break;
      case 3:
         r.p1 = 5; r.p2 = 3; r.p3 = 3;
         r.tf = PeriodoTexto(txt);
         r.handle = iStochastic(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, r.p2, r.p3, MODE_SMA, STO_LOWHIGH);
         break;
      case 4:
         r.p1 = 20; r.d1 = 2.0;
         r.tf = PeriodoTexto(txt);
         r.handle = iBands(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, r.d1, PRICE_CLOSE);
         break;
      case 6:
         r.p1 = (int)ExtraiNumero(txt, "delta de");
         break;
      case 7:
         r.p1 = 12;
         r.tf = PeriodoTexto(txt);
         break;
      case 8:
         r.p1 = 10;
         r.tf = PeriodoTexto(txt);
         r.handle = iAMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 2, 30, 0, PRICE_CLOSE);
         break;
      case 9:
         r.tf = PeriodoTexto(txt);
         break;
      case 10:
         r.s1 = ExtraiTexto(txt, "com");
         if(r.s1 == "") r.s1 = ExtraiTexto(txt, "bench"); // Alternative
         r.tf = PeriodoTexto(txt);
         // Pre-create handles
         r.handle = iRSI(r.s1, (ENUM_TIMEFRAMES)r.tf, 14, PRICE_CLOSE);
         r.handle2 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, 14, PRICE_CLOSE);
         break;
   }

   if(r.type > 0) {
      if(intent == 1 && nBuyRules < 20) buyRules[nBuyRules++] = r;
      else if(intent == -1 && nSellRules < 20) sellRules[nSellRules++] = r;
   }
}

int PeriodoTexto(string nome) {
   if(StringFind(nome, "m15") >= 0) return PERIOD_M15; // Order matters to avoid collision
   if(StringFind(nome, "m1") >= 0)  return PERIOD_M1;
   if(StringFind(nome, "m5") >= 0)  return PERIOD_M5;
   if(StringFind(nome, "h1") >= 0)  return PERIOD_H1;
   if(StringFind(nome, "d1") >= 0)  return PERIOD_D1;
   return PERIOD_CURRENT;
}

double ExtraiNumero(string txt, string anchor, int offset=0, int startPos=0) {
   int pos = StringFind(txt, anchor, startPos);
   if(pos < 0) return 0;

   string sub = "";
   bool foundDigit = false;
   for(int i = pos + StringLen(anchor) + offset; i < StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.' || c == ',' || c == '+' || c == '-') {
         if(c == ',') sub += ".";
         else sub += CharToString((uchar)c);
         foundDigit = true;
      } else if(foundDigit) {
         break;
      }
   }
   return StringToDouble(sub);
}

string ExtraiTexto(string txt, string anchor, int offset=0) {
   int pos = StringFind(txt, anchor);
   if(pos < 0) return "";

   string sub = "";
   bool started = false;
   for(int i = pos + StringLen(anchor) + offset; i < StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if(c > 32) {
         sub += CharToString((uchar)c);
         started = true;
      } else if(started) {
         break;
      }
   }
   return sub;
}
double GetBufferValue(int handle, int buffer, int shift) {
   double val[];
   ArraySetAsSeries(val, true);
   if(CopyBuffer(handle, buffer, shift, 1, val) > 0) return val[0];
   return 0;
}

Signal AvaliaRegra(Rule &r) {
   if(!r.active) return NONE;

   switch(r.type) {
      case 1: // MA
      {
         double ma1 = GetBufferValue(r.handle, 0, 1);
         double ma2 = GetBufferValue(r.handle, 0, 2);
         double p1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         double p2 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
         if(p2 < ma2 && p1 > ma1) return BUY;
         if(p2 > ma2 && p1 < ma1) return SELL;
         break;
      }
      case 2: // RSI
      {
         double rsi = GetBufferValue(r.handle, 0, 0);
         if(r.op == ">" && rsi > r.d1) return (r.intent == 1) ? BUY : NONE;
         if(r.op == "<" && rsi < r.d1) return (r.intent == -1) ? SELL : NONE;
         break;
      }
      case 3: // Stoch
      {
         double k1 = GetBufferValue(r.handle, 0, 1);
         double d1 = GetBufferValue(r.handle, 1, 1);
         double k2 = GetBufferValue(r.handle, 0, 2);
         double d2 = GetBufferValue(r.handle, 1, 2);
         if(k2 < d2 && k1 > d1) return BUY;
         if(k2 > d2 && k1 < d1) return SELL;
         break;
      }
      case 4: // BB
      {
         double upper = GetBufferValue(r.handle, 1, 0);
         double lower = GetBufferValue(r.handle, 2, 0);
         double close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
         if(close < lower) return BUY;
         if(close > upper) return SELL;
         break;
      }
      case 5: // Daily Breakout
      {
         double hi = iHigh(_Symbol, PERIOD_D1, 1);
         double lo = iLow(_Symbol, PERIOD_D1, 1);
         double close = iClose(_Symbol, PERIOD_M1, 0);
         if(close > hi) return BUY;
         if(close < lo) return SELL;
         break;
      }
      case 6: // Delta
      {
         MqlTick ticks[];
         int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, TimeCurrent()-60, TimeCurrent());
         long buy=0, sell=0;
         for(int i=0; i<n; i++) if((ticks[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++; else sell++;
         if(buy - sell > r.p1) return BUY;
         if(sell - buy > r.p1) return SELL;
         break;
      }
      case 7: // Volume
      {
         long vol[];
         CopyVolume(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0, r.p1, vol);
         int maxIdx = ArrayMaximum(vol);
         int minIdx = ArrayMinimum(vol);
         if(maxIdx == 0) return SELL;
         if(minIdx == 0) return BUY;
         break;
      }
      case 8: // AMA
      {
         double ama1 = GetBufferValue(r.handle, 0, 1);
         double ama2 = GetBufferValue(r.handle, 0, 2);
         if(ama1 > ama2) return BUY;
         if(ama1 < ama2) return SELL;
         break;
      }
      case 9: // Bar Pattern
      {
         double h0 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
         double l0 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
         double h1 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         double l1 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         bool inside = (h0 < h1 && l0 > l1);
         bool outside = (h0 > h1 && l0 < l1);
         if(inside || outside) return (iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0)) ? BUY : SELL;
         break;
      }
      case 10: // RS
      {
         double v1 = GetBufferValue(r.handle2, 0, 0);
         double v2 = GetBufferValue(r.handle, 0, 0);
         if(v1 > v2 + 5) return BUY;
         if(v1 < v2 - 5) return SELL;
         break;
      }
   }
   return NONE;
}

Signal AvaliaTudo() {
   int buyVotos = 0;
   int sellVotos = 0;

   for(int i=0; i<nBuyRules; i++) {
      if(AvaliaRegra(buyRules[i]) == BUY) buyVotos++;
   }
   for(int i=0; i<nSellRules; i++) {
      if(AvaliaRegra(sellRules[i]) == SELL) sellVotos++;
   }

   if(nBuyRules > 0 && buyVotos == nBuyRules) return BUY;
   if(nSellRules > 0 && sellVotos == nSellRules) return SELL;

   return NONE;
}

bool EnviaOrdem(Signal s, double lote, double sl, double tp) {
   bool res = false;
   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   for(int retry=0; retry<3; retry++) {
      if(s == BUY) res = trade.Buy(lote, _Symbol, price, sl, tp);
      else res = trade.Sell(lote, _Symbol, price, sl, tp);

      uint retcode = trade.ResultRetcode();
      if(res || (retcode != TRADE_RETCODE_REJECT && retcode != TRADE_RETCODE_REQUOTES && retcode != TRADE_RETCODE_PRICE_OFF)) break;

      price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      Sleep(100);
   }

   if(res) {
      GravaLog((s == BUY ? "Compra" : "Venda") + " executada. Lote: " + DoubleToString(lote, 2));
      GravaEstadoCSV(trade.ResultOrder(), price, sl, tp, "Sinal " + (s == BUY ? "BUY" : "SELL"));
   } else {
      GravaLog("Erro na ordem: " + IntegerToString(trade.ResultRetcode()) + " - " + trade.ResultRetcodeDescription());
   }
   return res;
}
void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) {
         if(PositionGetInteger(POSITION_MAGIC) != EA_MAGIC) continue;

         double price = PositionGetDouble(POSITION_PRICE_CURRENT);
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double sl = PositionGetDouble(POSITION_SL);
         double tp = PositionGetDouble(POSITION_TP);
         long type = PositionGetInteger(POSITION_TYPE);

         double profitPoints = (type == POSITION_TYPE_BUY) ? (price - openPrice) / _Point : (openPrice - price) / _Point;

         // Breakeven
         if(p_breakeven > 0 && profitPoints >= p_breakeven) {
            double newSL = (type == POSITION_TYPE_BUY) ? openPrice + p_breakevenProfit * _Point : openPrice - p_breakevenProfit * _Point;
            if((type == POSITION_TYPE_BUY && (sl < newSL || sl == 0)) || (type == POSITION_TYPE_SELL && (sl > newSL || sl == 0))) {
               if(trade.PositionModify(ticket, newSL, tp)) {
                  GravaLog("Breakeven ativado para ticket " + IntegerToString(ticket));
                  GravaEstadoCSV(ticket, openPrice, newSL, tp, "Breakeven");
               }
            }
         }

         // Trailing Stop
         if(p_trailingStop > 0 && profitPoints >= p_trailingStop) {
            double newSL = (type == POSITION_TYPE_BUY) ? price - p_trailingStop * _Point : price + p_trailingStop * _Point;
            if(p_trailingStep > 0) {
               double diff = (type == POSITION_TYPE_BUY) ? newSL - sl : sl - newSL;
               if(diff < p_trailingStep * _Point && sl != 0) continue;
            }
            if((type == POSITION_TYPE_BUY && (sl < newSL || sl == 0)) || (type == POSITION_TYPE_SELL && (sl > newSL || sl == 0))) {
               if(trade.PositionModify(ticket, newSL, tp)) {
                  GravaLog("Trailing Stop ajustado para ticket " + IntegerToString(ticket));
                  GravaEstadoCSV(ticket, openPrice, newSL, tp, "Trailing Stop");
               }
            }
         }

         // Exit by Opposite Signal
         if(p_exitOpposite) {
            Signal s = AvaliaTudo();
            if((type == POSITION_TYPE_BUY && s == SELL) || (type == POSITION_TYPE_SELL && s == BUY)) {
               if(trade.PositionClose(ticket)) {
                  GravaLog("Saída por sinal oposto: " + IntegerToString(ticket));
                  GravaEstadoCSV(ticket, price, sl, tp, "Saída por sinal oposto");
               }
            }
         }
      }
   }
}

void CalculaStats() {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   GravaLog("Stats: Balance: " + DoubleToString(balance, 2) + " Equity: " + DoubleToString(equity, 2));
   // More advanced stats can be added here
}

void GravaLog(string texto) {
   Print(texto);
   SendNotification(texto);
}

void GravaEstadoCSV(ulong ticket, double price, double sl, double tp, string reason) {
   string filename = "states.csv";
   int h = FileOpen(filename, FILE_WRITE|FILE_READ|FILE_CSV|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      FileSeek(h, 0, SEEK_END);
      FileWrite(h, ticket, price, sl, tp, TimeToString(TimeCurrent()), reason);
      FileClose(h);
   }
}

double CalculaLote(double riscoPercent, int slPoints) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riscoAbs = capital * riscoPercent / 100.0;

   if(p_martingale) {
      // Find last closed trade result
      HistorySelect(TimeCurrent()-86400*30, TimeCurrent());
      for(int i=HistoryDealsTotal()-1; i>=0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            if(profit < 0) riscoAbs *= 2;
            break;
         }
      }
   }

   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   double lote = (slPoints > 0) ? (riscoAbs / (slPoints * _Point * (tickVal / tickSize))) : 0.1;

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lote = MathRound(lote / step) * step;

   double minLote = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLote = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lote < minLote) lote = minLote;
   if(lote > maxLote) lote = maxLote;

   return lote;
}
bool AguardaNoticias() {
   string filename = "calendar.txt";
   if(!FileIsExist(filename, FILE_COMMON)) return false;

   int h = FileOpen(filename, FILE_READ|FILE_TXT|FILE_COMMON);
   if(h == INVALID_HANDLE) return false;

   datetime now = TimeCurrent();
   bool veto = false;

   while(!FileIsEnding(h)) {
      string line = FileReadString(h);
      if(line == "") continue;

      datetime eventTime = StringToTime(line);
      if(MathAbs(now - eventTime) < 1200) { // 20 minutes window
         veto = true;
         break;
      }
   }
   FileClose(h);

   if(veto) GravaLog("Veto de notícias ativado.");
   return veto;
}
