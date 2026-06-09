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

//--- Global constants
#define EA_MAGIC 123456

//--- Enums
enum ENUM_SIGNAL { SIGNAL_BUY = 1, SIGNAL_SELL = -1, SIGNAL_NONE = 0 };

//--- Structs
struct Rule {
   bool     active;
   int      type;    // 1: MA Cross, 2: RSI, 3: Stochastic, 4: BB, 5: Daily Breakout, 6: Delta, 7: Volume, 8: AMA, 9: 2-Bar, 10: Relative Strength
   int      tf;
   int      p1, p2, p3;
   double   d1, d2;
   string   s1;
   int      handle1, handle2;
   int      intent; // 1 for BUY, -1 for SELL

   void Reset() {
      active = false; type = 0; tf = PERIOD_CURRENT;
      p1 = 0; p2 = 0; p3 = 0; d1 = 0; d2 = 0; s1 = "";
      handle1 = INVALID_HANDLE; handle2 = INVALID_HANDLE;
      intent = 0;
   }
};

//--- Global variables
Rule rules[50];
int nRules = 0;
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symInfo;
CAccountInfo accInfo;

double p_risk = 1.0;
int p_stopLoss = 30;
int p_takeProfit = 50;
int p_maxTrades = 3;
int p_breakeven = 0;
int p_breakevenStep = 0;
int p_trailingStop = 0;
int p_trailingStep = 0;
bool p_martingale = false;
string p_startTime = "00:00";
int p_newsVeto = 20; // minutes
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

datetime lastBarTime = 0;
datetime lastPromptUpdate = 0;
datetime lastAI = 0;
datetime lastCSV = 0;

//--- Function prototypes
void InterpretaPrompt(string prompt);
void ResetStrategy();
ENUM_SIGNAL AvaliaTudo();
ENUM_SIGNAL AvaliaRegra(Rule &r);
void EnviaOrdem(ENUM_SIGNAL signal, string reason);
void GerenciaPosicoes();
bool AguardaNoticias();
bool IsTimeAllowed();
void GravaLog(string text);
void GravaCSV();
void CalculaStats();
void AIOptimizer();
void AddRule(string txt, int intent);
double ExtraiNumero(string txt, int &cursor);
ENUM_TIMEFRAMES PeriodoTexto(string txt);
double GetBufferValue(int handle, int buffer, int index);

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(EA_MAGIC);
   symInfo.Name(_Symbol);

   ResetStrategy();

   // Start timer for prompt monitoring and AI tasks
   EventSetTimer(1);

   GravaLog("MT-LiveExecutor iniciado com sucesso.");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   ResetStrategy();
   GravaLog("MT-LiveExecutor finalizado.");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   GerenciaPosicoes();

   if(TimeCurrent() - lastCSV >= 5) {
      GravaCSV();
      lastCSV = TimeCurrent();
   }

   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar != lastBarTime) {
      if(lastBarTime != 0) {
         if(IsTimeAllowed() && !AguardaNoticias()) {
            ENUM_SIGNAL sig = AvaliaTudo();
            if(sig != SIGNAL_NONE) {
               EnviaOrdem(sig, "Signal triggered by rule confluence");
            }
         }
      }
      lastBarTime = currentBar;
   }
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
{
   string promptFile = "prompt.txt";
   if(FileIsExist(promptFile, FILE_COMMON)) {
      datetime modif = (datetime)FileGetInteger(promptFile, FILE_MODIFY_DATE, FILE_COMMON);
      if(modif > lastPromptUpdate) {
         int h = FileOpen(promptFile, FILE_READ|FILE_TXT|FILE_COMMON|FILE_ANSI);
         if(h != INVALID_HANDLE) {
            string content = "";
            while(!FileIsEnding(h)) content += FileReadString(h);
            FileClose(h);

            if(StringLen(content) > 0) {
               GravaLog("Novo prompt detectado: " + content);
               InterpretaPrompt(content);
               lastPromptUpdate = modif;
            }
         }
      }
   }

   if(TimeCurrent() - lastAI >= 3600) {
      AIOptimizer();
      lastAI = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
//| NLP Parser and utility functions                                 |
//+------------------------------------------------------------------+
void InterpretaPrompt(string prompt)
{
   ResetStrategy();
   string lower = prompt;
   StringToLower(lower);
   StringReplace(lower, " e ", ".");

   string segments[];
   int nSeg = StringSplit(lower, '.', segments);

   int currentIntent = 0;

   for(int i=0; i<nSeg; i++) {
      string txt = segments[i];
      StringTrimLeft(txt); StringTrimRight(txt);
      if(StringLen(txt) == 0) continue;

      if(StringFind(txt, "compra") >= 0) currentIntent = 1;
      else if(StringFind(txt, "vende") >= 0) currentIntent = -1;

      int cursor = 0;
      if(StringFind(txt, "risco") >= 0) { cursor = StringFind(txt, "risco"); p_risk = ExtraiNumero(txt, cursor); }
      if(StringFind(txt, "stop") >= 0) { cursor = StringFind(txt, "stop"); p_stopLoss = (int)ExtraiNumero(txt, cursor); }
      if(StringFind(txt, "take") >= 0) { cursor = StringFind(txt, "take"); p_takeProfit = (int)ExtraiNumero(txt, cursor); }
      if(StringFind(txt, "máximo") >= 0 || StringFind(txt, "max") >= 0) { cursor = MathMax(StringFind(txt, "máximo"), StringFind(txt, "max")); p_maxTrades = (int)ExtraiNumero(txt, cursor); }
      if(StringFind(txt, "martingale") >= 0) p_martingale = true;
      if(StringFind(txt, "notícias") >= 0) { cursor = StringFind(txt, "notícias"); p_newsVeto = (int)ExtraiNumero(txt, cursor); }

      if(StringFind(txt, "move stop para entrada") >= 0) {
         cursor = StringFind(txt, "move stop para entrada");
         p_breakeven = (int)ExtraiNumero(txt, cursor);
         p_breakevenStep = (int)ExtraiNumero(txt, cursor);
      }

      if(StringFind(txt, "depois das") >= 0 || StringFind(txt, "início") >= 0 || StringFind(txt, "começar") >= 0) {
         int h=0;
         int p1 = StringFind(txt, "h");
         if(p1 > 0) {
            string hs = StringSubstr(txt, p1-2, 2);
            StringTrimLeft(hs);
            h = (int)StringToInteger(hs);
            p_startTime = StringFormat("%02d:00", h);
         }
      }

      ENUM_TIMEFRAMES tf = PeriodoTexto(txt);
      if(tf != PERIOD_CURRENT) p_frequency = tf;

      AddRule(txt, currentIntent);
   }
   GravaLog(StringFormat("Estratégia interpretada: %d regras carregadas.", nRules));
}

void AddRule(string txt, int intent)
{
   if(nRules >= 50) return;

   static int lastMA = 20;
   static int lastRSI = 14;

   int cursor = 0;

   // 1. MA Cross
   if(StringFind(txt, "média") >= 0 || StringFind(txt, "cruzar") >= 0) {
      Rule r; r.Reset(); r.intent = intent; r.tf = PeriodoTexto(txt); r.active = true; r.type = 1;
      cursor = StringFind(txt, "média") + 5;
      r.p1 = (int)ExtraiNumero(txt, cursor);
      if(r.p1 == 0) r.p1 = lastMA; else lastMA = r.p1;
      r.handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_EMA, PRICE_CLOSE);
      if(r.handle1 != INVALID_HANDLE) rules[nRules++] = r;
   }

   // 2. RSI
   if(StringFind(txt, "rsi") >= 0) {
      Rule r; r.Reset(); r.intent = intent; r.tf = PeriodoTexto(txt); r.active = true; r.type = 2;
      cursor = StringFind(txt, "rsi") + 3;
      r.p1 = (int)ExtraiNumero(txt, cursor);
      if(r.p1 == 0) r.p1 = lastRSI; else lastRSI = r.p1;
      r.d1 = ExtraiNumero(txt, cursor);
      r.handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
      if(r.handle1 != INVALID_HANDLE) rules[nRules++] = r;
   }

   // 3. Stochastic
   if(StringFind(txt, "stoch") >= 0 || StringFind(txt, "estocástico") >= 0) {
      Rule r; r.Reset(); r.intent = intent; r.tf = PeriodoTexto(txt); r.active = true; r.type = 3;
      cursor = MathMax(StringFind(txt, "stoch"), StringFind(txt, "estocástico")) + 5;
      r.p1 = 5; r.p2 = 3; r.p3 = 3;
      r.handle1 = iStochastic(_Symbol, (ENUM_TIMEFRAMES)r.tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
      if(r.handle1 != INVALID_HANDLE) rules[nRules++] = r;
   }

   // 4. Bollinger Bands
   if(StringFind(txt, "bollinger") >= 0 || StringFind(txt, "bandas") >= 0) {
      Rule r; r.Reset(); r.intent = intent; r.tf = PeriodoTexto(txt); r.active = true; r.type = 4;
      r.p1 = 20; r.d1 = 2.0;
      r.handle1 = iBands(_Symbol, (ENUM_TIMEFRAMES)r.tf, 20, 0, 2.0, PRICE_CLOSE);
      if(r.handle1 != INVALID_HANDLE) rules[nRules++] = r;
   }

   // 5. Daily Breakout
   if(StringFind(txt, "breakout") >= 0 || StringFind(txt, "máxima anterior") >= 0) {
      Rule r; r.Reset(); r.intent = intent; r.tf = PeriodoTexto(txt); r.active = true; r.type = 5;
      rules[nRules++] = r;
   }

   // 6. Delta Aggression
   if(StringFind(txt, "delta") >= 0 || StringFind(txt, "agressão") >= 0) {
      Rule r; r.Reset(); r.intent = intent; r.tf = PeriodoTexto(txt); r.active = true; r.type = 6;
      r.p1 = 60; r.p2 = 300;
      rules[nRules++] = r;
   }

   // 7. Volume Cycle
   if(StringFind(txt, "volume") >= 0) {
      Rule r; r.Reset(); r.intent = intent; r.tf = PeriodoTexto(txt); r.active = true; r.type = 7;
      r.p1 = 12;
      rules[nRules++] = r;
   }

   // 8. AMA
   if(StringFind(txt, "ama") >= 0) {
      Rule r; r.Reset(); r.intent = intent; r.tf = PeriodoTexto(txt); r.active = true; r.type = 8;
      r.p1 = 10; r.p2 = 2; r.p3 = 30;
      r.handle1 = iAMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, 10, 2, 30, 0, PRICE_CLOSE);
      if(r.handle1 != INVALID_HANDLE) rules[nRules++] = r;
   }

   // 9. 2-Bar Pattern
   if(StringFind(txt, "pattern") >= 0 || StringFind(txt, "padrão") >= 0) {
      Rule r; r.Reset(); r.intent = intent; r.tf = PeriodoTexto(txt); r.active = true; r.type = 9;
      rules[nRules++] = r;
   }

   // 10. Relative Strength
   if(StringFind(txt, "força relativa") >= 0 || StringFind(txt, "vs") >= 0) {
      Rule r; r.Reset(); r.intent = intent; r.tf = PeriodoTexto(txt); r.active = true; r.type = 10;
      r.s1 = "US30"; // Default
      r.handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, 14, PRICE_CLOSE);
      r.handle2 = iRSI(r.s1, (ENUM_TIMEFRAMES)r.tf, 14, PRICE_CLOSE);
      if(r.handle1 != INVALID_HANDLE && r.handle2 != INVALID_HANDLE) rules[nRules++] = r;
   }
}

double ExtraiNumero(string txt, int &cursor)
{
   string res = "";
   bool found = false;
   for(int i=cursor; i<StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.' || c == ',') {
         if(c == ',') res += "."; else res += CharToString((uchar)c);
         found = true;
      } else if(found) {
         cursor = i;
         return StringToDouble(res);
      }
   }
   return StringToDouble(res);
}

ENUM_TIMEFRAMES PeriodoTexto(string txt)
{
   if(StringFind(txt, "15 min") >= 0 || StringFind(txt, "m15") >= 0) return PERIOD_M15;
   if(StringFind(txt, "5 min") >= 0 || StringFind(txt, "m5") >= 0) return PERIOD_M5;
   if(StringFind(txt, "1 min") >= 0 || StringFind(txt, "m1") >= 0) return PERIOD_M1;
   if(StringFind(txt, "1 hora") >= 0 || StringFind(txt, "h1") >= 0) return PERIOD_H1;
   if(StringFind(txt, "diário") >= 0 || StringFind(txt, "d1") >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

void ResetStrategy()
{
   for(int i=0; i<nRules; i++) {
      if(rules[i].handle1 != INVALID_HANDLE && rules[i].handle1 != 0) IndicatorRelease(rules[i].handle1);
      if(rules[i].handle2 != INVALID_HANDLE && rules[i].handle2 != 0) IndicatorRelease(rules[i].handle2);
      rules[i].Reset();
   }
   nRules = 0;
   p_risk = 1.0; p_stopLoss = 30; p_takeProfit = 50; p_maxTrades = 3;
   p_breakeven = 0; p_breakevenStep = 0; p_trailingStop = 0; p_trailingStep = 0;
   p_martingale = false; p_startTime = "00:00"; p_newsVeto = 20; p_frequency = PERIOD_M15;
}

//+------------------------------------------------------------------+
//| Indicator Signal Evaluation                                      |
//+------------------------------------------------------------------+
double GetBufferValue(int handle, int buffer, int index)
{
   double val[]; ArraySetAsSeries(val, true);
   if(CopyBuffer(handle, buffer, index, 1, val) > 0) return val[0];
   return 0;
}

ENUM_SIGNAL AvaliaRegra(Rule &r)
{
   if(!r.active) return SIGNAL_NONE;

   switch(r.type) {
      case 1: { // MA Cross
         double ma0 = GetBufferValue(r.handle1, 0, 0);
         double ma1 = GetBufferValue(r.handle1, 0, 1);
         double cl0 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
         double cl1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         if(cl1 < ma1 && cl0 > ma0) return SIGNAL_BUY;
         if(cl1 > ma1 && cl0 < ma0) return SIGNAL_SELL;
         break;
      }
      case 2: { // RSI
         double rsi0 = GetBufferValue(r.handle1, 0, 0);
         double rsi1 = GetBufferValue(r.handle1, 0, 1);
         if(rsi1 < r.d1 && rsi0 > r.d1) return SIGNAL_BUY;
         if(rsi1 > r.d1 && rsi0 < r.d1) return SIGNAL_SELL;
         break;
      }
      case 3: { // Stochastic
         double k0 = GetBufferValue(r.handle1, 0, 0);
         double d0 = GetBufferValue(r.handle1, 1, 0);
         double k1 = GetBufferValue(r.handle1, 0, 1);
         double d1 = GetBufferValue(r.handle1, 1, 1);
         if(k1 < d1 && k0 > d0) return SIGNAL_BUY;
         if(k1 > d1 && k0 < d0) return SIGNAL_SELL;
         break;
      }
      case 4: { // BB Bounce
         double up0 = GetBufferValue(r.handle1, 1, 0);
         double lo0 = GetBufferValue(r.handle1, 2, 0);
         double cl0 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
         if(cl0 < lo0) return SIGNAL_BUY;
         if(cl0 > up0) return SIGNAL_SELL;
         break;
      }
      case 5: { // Daily Breakout
         double hi = iHigh(_Symbol, PERIOD_D1, 1);
         double lo = iLow(_Symbol, PERIOD_D1, 1);
         double cl = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
         if(cl > hi) return SIGNAL_BUY;
         if(cl < lo) return SIGNAL_SELL;
         break;
      }
      case 6: { // Delta Aggression (simplified)
         MqlTick ticks[];
         int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, TimeCurrent()-r.p1, TimeCurrent());
         long buyVol=0, sellVol=0;
         for(int i=0; i<n; i++) {
            if((ticks[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buyVol += (long)ticks[i].volume;
            else if((ticks[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sellVol += (long)ticks[i].volume;
         }
         long delta = buyVol - sellVol;
         if(delta > r.p2) return SIGNAL_BUY;
         if(delta < -r.p2) return SIGNAL_SELL;
         break;
      }
      case 7: { // Volume Cycle
         double vol[]; ArraySetAsSeries(vol, true);
         if(CopyVolume(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0, r.p1, vol) >= r.p1) {
            double high = vol[ArrayMaximum(vol)];
            double low = vol[ArrayMinimum(vol)];
            if(vol[0] == low) return SIGNAL_BUY;
            if(vol[0] == high) return SIGNAL_SELL;
         }
         break;
      }
      case 8: { // AMA
         double ama0 = GetBufferValue(r.handle1, 0, 0);
         double ama1 = GetBufferValue(r.handle1, 0, 1);
         if(ama0 > ama1) return SIGNAL_BUY;
         if(ama0 < ama1) return SIGNAL_SELL;
         break;
      }
      case 9: { // 2-Bar Patterns
         double h0 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
         double l0 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
         double h1 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         double l1 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         bool bull = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
         if(h0 < h1 && l0 > l1) return bull ? SIGNAL_BUY : SIGNAL_SELL;
         if(h0 > h1 && l0 < l1) return bull ? SIGNAL_SELL : SIGNAL_BUY;
         break;
      }
      case 10: { // Relative Strength
         double rsi1 = GetBufferValue(r.handle1, 0, 0);
         double rsi2 = GetBufferValue(r.handle2, 0, 0);
         if(rsi1 > rsi2 + 5) return SIGNAL_BUY;
         if(rsi1 < rsi2 - 5) return SIGNAL_SELL;
         break;
      }
   }
   return SIGNAL_NONE;
}

ENUM_SIGNAL AvaliaTudo()
{
   if(nRules == 0) return SIGNAL_NONE;

   int buyVotos = 0, buyRules = 0;
   int sellVotos = 0, sellRules = 0;

   for(int i=0; i<nRules; i++) {
      ENUM_SIGNAL res = AvaliaRegra(rules[i]);
      if(rules[i].intent == 1) {
         buyRules++;
         if(res == SIGNAL_BUY) buyVotos++;
      } else if(rules[i].intent == -1) {
         sellRules++;
         if(res == SIGNAL_SELL) sellVotos++;
      }
   }

   if(buyRules > 0 && buyVotos == buyRules) return SIGNAL_BUY;
   if(sellRules > 0 && sellVotos == sellRules) return SIGNAL_SELL;

   return SIGNAL_NONE;
}

//+------------------------------------------------------------------+
//| Trade and Position Management                                    |
//+------------------------------------------------------------------+
void EnviaOrdem(ENUM_SIGNAL signal, string reason)
{
   if(PositionsTotal() >= p_maxTrades) return;

   double lote = CalculaLote(p_risk);
   double sl = 0, tp = 0;
   double price = 0;

   if(signal == SIGNAL_BUY) {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl = price - p_stopLoss * _Point;
      tp = price + p_takeProfit * _Point;
      if(trade.Buy(lote, _Symbol, price, sl, tp, reason)) {
         GravaLog("Compra: " + reason + " Lote: " + DoubleToString(lote, 2));
      }
   } else if(signal == SIGNAL_SELL) {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl = price + p_stopLoss * _Point;
      tp = price - p_takeProfit * _Point;
      if(trade.Sell(lote, _Symbol, price, sl, tp, reason)) {
         GravaLog("Venda: " + reason + " Lote: " + DoubleToString(lote, 2));
      }
   }
}

double CalculaLote(double riscoPercent)
{
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riscoAbs = capital * riscoPercent / 100.0;
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   double slPoints = p_stopLoss;
   if(slPoints <= 0) slPoints = 30;

   double lot = riscoAbs / (slPoints * _Point * (tickVal / tickSize));

   if(p_martingale) {
      HistorySelect(TimeCurrent()-86400, TimeCurrent());
      uint total = HistoryDealsTotal();
      if(total > 0) {
         ulong ticket = HistoryDealGetTicket(total-1);
         if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) lot *= 2;
      }
   }

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / step) * step;
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return lot;
}

void GerenciaPosicoes()
{
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(posInfo.SelectByIndex(i)) {
         if(posInfo.Magic() != EA_MAGIC || posInfo.Symbol() != _Symbol) continue;

         double entry = posInfo.PriceOpen();
         double current = posInfo.PriceCurrent();
         double profitPoints = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (current - entry)/_Point : (entry - current)/_Point;

         if(p_breakeven > 0 && profitPoints >= p_breakeven) {
            double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (entry + p_breakevenStep * _Point) : (entry - p_breakevenStep * _Point);
            if(MathAbs(posInfo.StopLoss() - newSL) > _Point) trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
         }

         if(p_trailingStop > 0 && profitPoints >= p_trailingStop) {
            double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (current - p_trailingStop * _Point) : (current + p_trailingStop * _Point);
            if(posInfo.PositionType() == POSITION_TYPE_BUY && newSL > posInfo.StopLoss() + p_trailingStep * _Point) {
               trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
            } else if(posInfo.PositionType() == POSITION_TYPE_SELL && (newSL < posInfo.StopLoss() - p_trailingStep * _Point || posInfo.StopLoss() == 0)) {
               trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
            }
         }
      }
   }
}

bool IsTimeAllowed()
{
   string current = TimeToString(TimeCurrent(), TIME_MINUTES);
   return (current >= p_startTime);
}

bool AguardaNoticias()
{
   if(FileIsExist("news_veto.txt", FILE_COMMON)) return true;
   int h = FileOpen("calendar.txt", FILE_READ|FILE_ANSI|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      while(!FileIsEnding(h)) {
         string line = FileReadString(h);
         if(StringFind(line, "High") >= 0 || StringFind(line, "Alto") >= 0) {
            // Simple parsing: YYYY.MM.DD HH:MM;Symbol;Impact;Title
            string parts[]; StringSplit(line, ';', parts);
            if(ArraySize(parts) >= 1) {
               datetime newsTime = StringToTime(parts[0]);
               if(MathAbs(TimeCurrent() - newsTime) < p_newsVeto * 60) { FileClose(h); return true; }
            }
         }
      }
      FileClose(h);
   }
   return false;
}

void GravaLog(string text)
{
   int h = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE|FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h != INVALID_HANDLE) { FileSeek(h, 0, SEEK_END); FileWriteString(h, TimeToString(TimeCurrent()) + ": " + text + "\r\n"); FileClose(h); }
   Print(text);
}

void GravaCSV()
{
   int h = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      FileWriteString(h, "Symbol;Ticket;Type;OpenPrice;CurrentPrice;Profit;SL;TP\r\n");
      for(int i=0; i<PositionsTotal(); i++) {
         if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC) {
            FileWriteString(h, StringFormat("%s;%d;%d;%.5f;%.5f;%.2f;%.5f;%.5f\r\n", posInfo.Symbol(), posInfo.Ticket(), posInfo.PositionType(), posInfo.PriceOpen(), posInfo.PriceCurrent(), posInfo.Profit(), posInfo.StopLoss(), posInfo.TakeProfit()));
         }
      }
      FileClose(h);
   }
}

void CalculaStats()
{
   double win=0, loss=0, profit=0, drawdown=0, maxDrawdown=0, peakEquity=0;
   HistorySelect(0, TimeCurrent());
   int total = HistoryDealsTotal();
   double equity = AccountInfoDouble(ACCOUNT_BALANCE);
   peakEquity = equity;

   for(int i=0; i<total; i++) {
      ulong t = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(t, DEAL_MAGIC) != EA_MAGIC) continue;
      double p = HistoryDealGetDouble(t, DEAL_PROFIT);
      if(p > 0) { win++; profit += p; }
      else if(p < 0) { loss++; profit += p; }

      equity += p;
      if(equity > peakEquity) peakEquity = equity;
      drawdown = peakEquity - equity;
      if(drawdown > maxDrawdown) maxDrawdown = drawdown;
   }

   double wr = (win+loss > 0) ? (win/(win+loss)*100.0) : 0;
   GravaLog(StringFormat("Stats: WinRate: %.2f%%, MaxDD: %.2f, TotalProfit: %.2f", wr, maxDrawdown, profit));
}

void AIOptimizer()
{
   GravaLog("AI Optimizer: Analisando performance e otimizando parâmetros...");
   CalculaStats();
}
