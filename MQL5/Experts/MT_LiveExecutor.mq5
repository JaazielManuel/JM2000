//+------------------------------------------------------------------+
//|                                             MT_LiveExecutor.mq5 |
//|                                  Copyright 2026, Profit Master  |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Profit Master"
#property link      "https://www.mql5.com"
#property version   "9.50"
#property strict
#property description "Profit Master v8.0 - MT-LiveExecutor"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

//=========================  MT5-KNOWLEDGE-CORE  =========================

enum Signal {BUY=1, SELL=-1, NONE=0};
enum RuleType {MA_CROSS, RSI_THRESHOLD, STOCH_CROSS, BB_BOUNCE, DAILY_BREAK, DELTA_AGG, VOL_CYCLE, AMA_KAUFMAN, BAR_PATTERN, RS_RELATIVE};

struct Rule {
   bool       active;
   RuleType   type;
   int        tf;
   int        p1, p2;
   double     d1, d2;
   string     s1;
   int        p1_handle;
   int        p2_handle;
   int        p3_handle;
   bool       is_cross;
};

// Global variables
Rule rules[30];
int nRules = 0;
input string InpPrompt = "A cada 15 minutos, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Não operar 20 min antes ou depois de notícias de alto impacto. Máximo 3 trades simultâneos. Ao atingir +30 pontos, move stop para entrada +5 pontos.";

// Strategy parameters
double p_risk = 1.0;
int p_stopPoints = 0;
int p_takePoints = 0;
int p_newsVetoMins = 0;
int p_maxTrades = 100;
int p_frequency = 0;
int p_beTrigger = 0;
int p_bePoints = 0;
int p_trailingStop = 0;
bool p_martingale = false;
bool p_hedge = false;
bool p_notifications = false;
datetime p_startTime = 0;

// Internal state
datetime lastBarTime = 0;
int dynamicSafetyPoints = 0;
datetime lastSafetyDecay = 0;
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symbInfo;
int atrHandle = INVALID_HANDLE;

// Legacy MQL4 wrappers for compatibility
double iClose(string symbol, int tf, int shift) {
   double res[1];
   if(CopyClose(symbol, (ENUM_TIMEFRAMES)tf, shift, 1, res) > 0) return res[0];
   return 0;
}
double iOpen(string symbol, int tf, int shift) {
   double res[1];
   if(CopyOpen(symbol, (ENUM_TIMEFRAMES)tf, shift, 1, res) > 0) return res[0];
   return 0;
}
double iHigh(string symbol, int tf, int shift) {
   double res[1];
   if(CopyHigh(symbol, (ENUM_TIMEFRAMES)tf, shift, 1, res) > 0) return res[0];
   return 0;
}
double iLow(string symbol, int tf, int shift) {
   double res[1];
   if(CopyLow(symbol, (ENUM_TIMEFRAMES)tf, shift, 1, res) > 0) return res[0];
   return 0;
}
datetime iTime(string symbol, int tf, int shift) {
   datetime res[1];
   if(CopyTime(symbol, (ENUM_TIMEFRAMES)tf, shift, 1, res) > 0) return res[0];
   return 0;
}

// 1.1 MÉDIAS & CRUZAMENTOS
Signal CruzamentoMA(int handle1, int handle2, int shift=1)
{
   double f[2], s[2];
   if(CopyBuffer(handle1, 0, shift, 2, f) <= 0) return NONE;
   if(handle2 != INVALID_HANDLE) {
      if(CopyBuffer(handle2, 0, shift, 2, s) <= 0) return NONE;
   } else {
      // Comparison with Price
      if(CopyClose(_Symbol, (ENUM_TIMEFRAMES)p_frequency, shift, 2, s) <= 0) return NONE;
   }

   // f[1], s[1] are OLD (shift+1). f[0], s[0] are NEW (shift).
   if(handle2 == INVALID_HANDLE) {
      // Price (s) vs MA (f)
      if(s[1] < f[1] && s[0] > f[0]) return BUY;  // Price crossed above MA
      if(s[1] > f[1] && s[0] < f[0]) return SELL; // Price crossed below MA
   } else {
      // Fast (f) vs Slow (s)
      if(f[1] < s[1] && f[0] > s[0]) return BUY;  // Fast crossed above Slow
      if(f[1] > s[1] && f[0] < s[0]) return SELL; // Fast crossed below Slow
   }
   return NONE;
}

// 1.2 RSI
Signal RSIThreshold(int handle, double d1, double d2, bool is_cross, int shift=1)
{
   double v[2];
   if(CopyBuffer(handle, 0, shift, 2, v) <= 0) return NONE;

   if(is_cross) {
      // d1 is BUY trigger, d2 is SELL trigger
      if(v[1] < d1 && v[0] >= d1) return BUY;
      if(v[1] > d2 && v[0] <= d2) return SELL;
   } else {
      // Level check
      if(v[0] > d1) return BUY;
      if(v[0] < d2) return SELL;
   }
   return NONE;
}

// 1.3 ESTOCÁSTICO
Signal StochCross(int handle, int shift=1)
{
   double k[2], d[2];
   if(CopyBuffer(handle, 0, shift, 2, k) <= 0) return NONE;
   if(CopyBuffer(handle, 1, shift, 2, d) <= 0) return NONE;

   if(k[0] < d[0] && k[1] > d[1]) return BUY;
   if(k[0] > d[0] && k[1] < d[1]) return SELL;
   return NONE;
}

// 1.4 BOLLINGER BOUNCE
Signal BBounce(int handle, int shift=1)
{
   double up[1], lo[1], cl[1];
   if(CopyBuffer(handle, 1, shift, 1, up) <= 0) return NONE;
   if(CopyBuffer(handle, 2, shift, 1, lo) <= 0) return NONE;
   if(CopyClose(_Symbol, PERIOD_CURRENT, shift, 1, cl) <= 0) return NONE;

   if(cl[0] < lo[0]) return BUY;
   if(cl[0] > up[0]) return SELL;
   return NONE;
}

// 1.5 BREAKOUT DIÁRIO
Signal DailyBreak(int shift=1)
{
   double hi = iHigh(_Symbol, PERIOD_D1, 1);
   double lo = iLow(_Symbol, PERIOD_D1, 1);
   double close = iClose(_Symbol, PERIOD_CURRENT, shift);

   if(close > hi) return BUY;
   if(close < lo) return SELL;
   return NONE;
}

// 1.6 MICROESTRUTURA: DELTA DE AGRESSÃO
Signal DeltaAggression(int seconds=60, int deltaTrigger=300)
{
   MqlTick arr[];
   int n = CopyTicksRange(_Symbol, arr, COPY_TICKS_TRADE, TimeCurrent()-seconds, TimeCurrent());
   long buy=0, sell=0;
   for(int i=0; i<n; i++) {
      if((arr[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++;
      else if((arr[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sell++;
   }
   long delta = buy - sell;
   if(delta > deltaTrigger) return BUY;
   if(delta < -deltaTrigger) return SELL;
   return NONE;
}

// 1.7 CICLO DE VOLUME
Signal VolumeCycle(int len=12, int shift=1)
{
   long vol[];
   if(CopyVolume(_Symbol, PERIOD_CURRENT, shift, len, vol) <= 0) return NONE;
   int maxIdx = ArrayMaximum(vol);
   int minIdx = ArrayMinimum(vol);
   if(maxIdx == 0) return SELL;
   if(minIdx == 0) return BUY;
   return NONE;
}

// 1.8 AMA (Kaufman)
Signal AMA(int handle, int shift=1)
{
   double v[2];
   if(CopyBuffer(handle, 0, shift, 2, v) <= 0) return NONE;
   if(v[0] < v[1]) return BUY;
   if(v[0] > v[1]) return SELL;
   return NONE;
}

// 1.9 PADRÃO DE 2 BARRAS
Signal Bar2Pattern(int shift=1)
{
   double h0=iHigh(_Symbol, PERIOD_CURRENT, shift);
   double l0=iLow(_Symbol, PERIOD_CURRENT, shift);
   double h1=iHigh(_Symbol, PERIOD_CURRENT, shift+1);
   double l1=iLow(_Symbol, PERIOD_CURRENT, shift+1);
   double c0=iClose(_Symbol, PERIOD_CURRENT, shift);
   double o0=iOpen(_Symbol, PERIOD_CURRENT, shift);

   if(h0 < h1 && l0 > l1) return (c0 > o0) ? BUY : SELL;
   if(h0 > h1 && l0 < l1) return (c0 > o0) ? SELL : BUY;
   return NONE;
}

// 1.10 FORÇA RELATIVA
Signal RSRelative(int handle1, int handle2, int shift=1)
{
   double v1[1], v2[1];
   if(CopyBuffer(handle1, 0, shift, 1, v1) > 0 && CopyBuffer(handle2, 0, shift, 1, v2) > 0) {
      if(v1[0] > v2[0] + 5) return BUY;
      if(v1[0] < v2[0] - 5) return SELL;
   }
   return NONE;
}

//+------------------------------------------------------------------+
//| HELPERS                                                          |
//+------------------------------------------------------------------+

double ExtraiNumero(string txt, string chave) {
   int pos = StringFind(txt, chave);
   if(pos < 0) return 0;
   string sub = StringSubstr(txt, pos + StringLen(chave));
   return StringToDouble(sub);
}

int PeriodoTexto(string nome) {
   string n = nome; StringToLower(n);
   if(StringFind(n, "m1") >= 0)  return PERIOD_M1;
   if(StringFind(n, "m5") >= 0)  return PERIOD_M5;
   if(StringFind(n, "m15") >= 0) return PERIOD_M15;
   if(StringFind(n, "m30") >= 0) return PERIOD_M30;
   if(StringFind(n, "h1") >= 0)  return PERIOD_H1;
   if(StringFind(n, "h4") >= 0)  return PERIOD_H4;
   if(StringFind(n, "d1") >= 0)  return PERIOD_D1;
   return PERIOD_CURRENT;
}

ENUM_TIMEFRAMES MinutesToTimeframe(int mins) {
   if(mins <= 1) return PERIOD_M1;
   if(mins <= 5) return PERIOD_M5;
   if(mins <= 15) return PERIOD_M15;
   if(mins <= 30) return PERIOD_M30;
   if(mins <= 60) return PERIOD_H1;
   if(mins <= 240) return PERIOD_H4;
   return PERIOD_D1;
}

//+------------------------------------------------------------------+
//| InterpretaPrompt                                                 |
//+------------------------------------------------------------------+

void InterpretaPrompt(string prompt) {
   // 0. Preliminary cleanup and frequency extraction
   string cleanPrompt = prompt;
   StringReplace(cleanPrompt, ",", ".");

   int freqMins = (int)ExtraiNumero(cleanPrompt, "cada ");
   if(freqMins > 0) p_frequency = MinutesToTimeframe(freqMins);
   else p_frequency = PERIOD_CURRENT;

   // 1. Reset current rules
   for(int i=0; i<30; i++) {
      if(rules[i].p1_handle != INVALID_HANDLE && rules[i].p1_handle != 0) { IndicatorRelease(rules[i].p1_handle); }
      if(rules[i].p2_handle != INVALID_HANDLE && rules[i].p2_handle != 0) { IndicatorRelease(rules[i].p2_handle); }
      if(rules[i].p3_handle != INVALID_HANDLE && rules[i].p3_handle != 0) { IndicatorRelease(rules[i].p3_handle); }
   }
   ZeroMemory(rules);
   for(int i=0; i<30; i++) {
      rules[i].p1_handle = INVALID_HANDLE;
      rules[i].p2_handle = INVALID_HANDLE;
      rules[i].p3_handle = INVALID_HANDLE;
   }
   nRules = 0;
   lastBarTime = 0;

   // 2. Splitting and rule parsing
   string parts[];
   string sep = cleanPrompt;
   StringReplace(sep, " e ", "|");
   StringReplace(sep, " + ", "|");
   ushort u_sep = StringGetCharacter("|", 0);
   int nParts = StringSplit(sep, u_sep, parts);

   for(int i=0; i<nParts; i++) {
      string p = parts[i]; StringToLower(p);

      // Moving Average
      if(StringFind(p, "média") >= 0 || StringFind(p, "ma") >= 0) {
         int idx = -1;
         for(int r=0; r<nRules; r++) if(rules[r].type == MA_CROSS) { idx = r; break; }
         if(idx == -1) { idx = nRules++; rules[idx].type = MA_CROSS; rules[idx].active = true; }

         int period = (int)ExtraiNumero(p, "média de ");
         if(period == 0) period = (int)ExtraiNumero(p, "ma ");
         if(period > 0) rules[idx].p1 = period;

         if(rules[idx].p1_handle == INVALID_HANDLE)
            rules[idx].p1_handle = iMA(_Symbol, (ENUM_TIMEFRAMES)p_frequency, rules[idx].p1, 0, MODE_EMA, PRICE_CLOSE);
         rules[idx].p2_handle = INVALID_HANDLE;

         if(StringFind(p, "cruzar") >= 0) rules[idx].is_cross = true;
      }

      // RSI
      if(StringFind(p, "rsi") >= 0) {
         int idx = -1;
         for(int r=0; r<nRules; r++) if(rules[r].type == RSI_THRESHOLD) { idx = r; break; }
         if(idx == -1) { idx = nRules++; rules[idx].type = RSI_THRESHOLD; rules[idx].active = true; }

         int period = (int)ExtraiNumero(p, "rsi (");
         if(period == 0) period = (int)ExtraiNumero(p, "rsi ");
         if(period > 0) rules[idx].p1 = period;

         // Logic: "compra se ... rsi ... acima de 55" (Buy trigger)
         // Logic: "vende se ... rsi ... abaixo de 45" (Sell trigger)
         if(StringFind(p, "compra") >= 0 || (nParts > 1 && StringFind(parts[0], "compra") >= 0 && i < nParts/2)) {
            rules[idx].d1 = ExtraiNumero(p, "acima de ");
            if(rules[idx].d1 == 0) rules[idx].d1 = ExtraiNumero(p, "abaixo de "); // Mean reversion?
         } else if(StringFind(p, "vende") >= 0 || (nParts > 1 && StringFind(parts[nParts/2], "vende") >= 0 && i >= nParts/2)) {
            rules[idx].d2 = ExtraiNumero(p, "abaixo de ");
            if(rules[idx].d2 == 0) rules[idx].d2 = ExtraiNumero(p, "acima de "); // Mean reversion?
         }

         if(rules[idx].p1_handle == INVALID_HANDLE)
            rules[idx].p1_handle = iRSI(_Symbol, (ENUM_TIMEFRAMES)p_frequency, rules[idx].p1, PRICE_CLOSE);
         if(StringFind(p, "subir") >= 0 || StringFind(p, "cair") >= 0 || StringFind(p, "cruzar") >= 0) rules[idx].is_cross = true;
      }

      // Estocástico
      if(StringFind(p, "estocástico") >= 0 || StringFind(p, "stoch") >= 0) {
         int idx = nRules++; rules[idx].active = true; rules[idx].type = STOCH_CROSS;
         rules[idx].p1 = (int)ExtraiNumero(p, "k="); if(rules[idx].p1 == 0) rules[idx].p1 = 5;
         rules[idx].p2 = (int)ExtraiNumero(p, "d="); if(rules[idx].p2 == 0) rules[idx].p2 = 3;
         rules[idx].p1_handle = iStochastic(_Symbol, (ENUM_TIMEFRAMES)p_frequency, rules[idx].p1, rules[idx].p2, 3, MODE_SMA, STO_LOWHIGH);
      }

      // Bollinger
      if(StringFind(p, "bollinger") >= 0 || StringFind(p, "bb") >= 0) {
         int idx = nRules++; rules[idx].active = true; rules[idx].type = BB_BOUNCE;
         rules[idx].p1 = (int)ExtraiNumero(p, "período "); if(rules[idx].p1 == 0) rules[idx].p1 = 20;
         rules[idx].d1 = ExtraiNumero(p, "desvio "); if(rules[idx].d1 == 0) rules[idx].d1 = 2.0;
         rules[idx].p1_handle = iBands(_Symbol, (ENUM_TIMEFRAMES)p_frequency, rules[idx].p1, 0, rules[idx].d1, PRICE_CLOSE);
      }

      // Rompimento Diário
      if(StringFind(p, "rompimento diário") >= 0 || StringFind(p, "breakout") >= 0) {
         int idx = nRules++; rules[idx].active = true; rules[idx].type = DAILY_BREAK;
      }

      // Delta
      if(StringFind(p, "delta") >= 0) {
         int idx = nRules++; rules[idx].active = true; rules[idx].type = DELTA_AGG;
         rules[idx].p1 = (int)ExtraiNumero(p, "segundos "); if(rules[idx].p1 == 0) rules[idx].p1 = 60;
         rules[idx].d1 = ExtraiNumero(p, "gatilho "); if(rules[idx].d1 == 0) rules[idx].d1 = 300;
      }

      // Ciclo de Volume
      if(StringFind(p, "volume") >= 0 || StringFind(p, "ciclo") >= 0) {
         int idx = nRules++; rules[idx].active = true; rules[idx].type = VOL_CYCLE;
         rules[idx].p1 = (int)ExtraiNumero(p, "tamanho "); if(rules[idx].p1 == 0) rules[idx].p1 = 12;
      }

      // AMA
      if(StringFind(p, "ama") >= 0) {
         int idx = nRules++; rules[idx].active = true; rules[idx].type = AMA_KAUFMAN;
         rules[idx].p1 = (int)ExtraiNumero(p, "período "); if(rules[idx].p1 == 0) rules[idx].p1 = 10;
         rules[idx].p1_handle = iAMA(_Symbol, (ENUM_TIMEFRAMES)p_frequency, rules[idx].p1, 2, 30, 0, PRICE_CLOSE);
      }

      // Padrão de Barras
      if(StringFind(p, "padrão") >= 0 || StringFind(p, "barras") >= 0) {
         int idx = nRules++; rules[idx].active = true; rules[idx].type = BAR_PATTERN;
      }

      // Força Relativa
      if(StringFind(p, "força relativa") >= 0 || StringFind(p, "rs") >= 0) {
         int idx = nRules++; rules[idx].active = true; rules[idx].type = RS_RELATIVE;
         rules[idx].s1 = "US30"; // Example benchmark
         rules[idx].p1 = 14; // Default RSI period
         rules[idx].p1_handle = iRSI(_Symbol, (ENUM_TIMEFRAMES)p_frequency, rules[idx].p1, PRICE_CLOSE);
         rules[idx].p2_handle = iRSI(rules[idx].s1, (ENUM_TIMEFRAMES)p_frequency, rules[idx].p1, PRICE_CLOSE);
      }
   }

   // 3. Strategy-wide parameters
   p_risk = ExtraiNumero(cleanPrompt, "risco de ");
   if(p_risk == 0) p_risk = 1.0;

   p_stopPoints = (int)ExtraiNumero(cleanPrompt, "stop de ");
   p_takePoints = (int)ExtraiNumero(cleanPrompt, "take de ");
   p_newsVetoMins = (int)ExtraiNumero(cleanPrompt, "operar ");
   p_maxTrades = (int)ExtraiNumero(cleanPrompt, "máximo ");
   if(p_maxTrades == 0) p_maxTrades = 100;

   p_beTrigger = (int)ExtraiNumero(cleanPrompt, "atingir +");
   p_bePoints = (int)ExtraiNumero(cleanPrompt, "entrada +");

   if(StringFind(cleanPrompt, "trailing stop") >= 0) p_trailingStop = (int)ExtraiNumero(cleanPrompt, "trailing de ");
   if(StringFind(cleanPrompt, "martingale") >= 0) p_martingale = true;
   if(StringFind(cleanPrompt, "hedge") >= 0) p_hedge = true;
   if(StringFind(cleanPrompt, "notificações") >= 0) p_notifications = true;

   int hour = (int)ExtraiNumero(cleanPrompt, "depois das ");
   if(hour > 0) {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      dt.hour = hour; dt.min = 0; dt.sec = 0;
      p_startTime = StructToTime(dt);
   }

   Print("Estratégia interpretada: ", nRules, " regras. Risco: ", p_risk, "%. Freq: ", p_frequency);
}

//+------------------------------------------------------------------+
//| TRADING LOGIC                                                    |
//+------------------------------------------------------------------+

Signal AvaliaTudo() {
   if(nRules == 0) return NONE;
   int buyVotes = 0, sellVotes = 0, activeRules = 0;

   for(int i=0; i<nRules; i++) {
      if(!rules[i].active) continue;
      activeRules++;
      Signal s = NONE;
      switch(rules[i].type) {
         case MA_CROSS:      s = CruzamentoMA(rules[i].p1_handle, rules[i].p2_handle); break;
         case RSI_THRESHOLD: s = RSIThreshold(rules[i].p1_handle, rules[i].d1, rules[i].d2, rules[i].is_cross); break;
         case STOCH_CROSS:   s = StochCross(rules[i].p1_handle); break;
         case BB_BOUNCE:     s = BBounce(rules[i].p1_handle); break;
         case DAILY_BREAK:   s = DailyBreak(); break;
         case DELTA_AGG:     s = DeltaAggression(rules[i].p1, (int)rules[i].d1); break;
         case VOL_CYCLE:     s = VolumeCycle(rules[i].p1); break;
         case AMA_KAUFMAN:   s = AMA(rules[i].p1_handle); break;
         case BAR_PATTERN:   s = Bar2Pattern(); break;
         case RS_RELATIVE:   s = RSRelative(rules[i].p1_handle, rules[i].p2_handle); break;
      }
      if(s == BUY) buyVotes++;
      if(s == SELL) sellVotes++;
   }

   if(buyVotes == activeRules) return BUY;
   if(sellVotes == activeRules) return SELL;
   return NONE;
}

double CalculaLote(double riscoPercent) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riscoAbs = capital * riscoPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   int stopPoints = p_stopPoints;
   if(stopPoints <= 0) stopPoints = 100; // Default safety

   // Volume = RiscoFinanceiro / (DistanciaSL_em_Pontos * (TickValue / (TickSize / _Point)))
   double volume = riscoAbs / (stopPoints * (tickValue / (tickSize / _Point)));

   // Martingale (check the last deal for the current symbol)
   if(p_martingale) {
      HistorySelect(TimeCurrent()-86400, TimeCurrent());
      int total = HistoryDealsTotal();
      for(int i=total-1; i>=0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol) {
            long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
            if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY) {
               double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT) + HistoryDealGetDouble(ticket, DEAL_COMMISSION) + HistoryDealGetDouble(ticket, DEAL_SWAP);
               if(profit < 0) volume *= 2.0;
               break;
            }
         }
      }
   }

   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   volume = MathFloor(volume/stepVol) * stepVol;
   return MathMin(maxVol, MathMax(minVol, volume));
}

bool IsPriceSafe(double price, bool isSL = false) {
   double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double safetyBuffer = (stopsLevel + dynamicSafetyPoints + 2) * _Point;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(MathAbs(price - bid) < safetyBuffer || MathAbs(price - ask) < safetyBuffer) return false;
   return true;
}

void EnviaOrdem(Signal s) {
   if(s == NONE) return;
   if(PositionsTotal() >= p_maxTrades) return;

   // 1. Hedge Logic: Close opposite positions if p_hedge is false
   if(!p_hedge) {
      for(int i=PositionsTotal()-1; i>=0; i--) {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL) == _Symbol) {
            long type = PositionGetInteger(POSITION_TYPE);
            if((s == BUY && type == POSITION_TYPE_SELL) || (s == SELL && type == POSITION_TYPE_BUY)) {
               trade.PositionClose(ticket);
            }
         }
      }
   }

   // 2. Volume calculation and price normalization
   double lote = CalculaLote(p_risk);
   double sl = 0, tp = 0;
   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // 3. Execution
   if(s == BUY) {
      if(p_stopPoints > 0) sl = price - p_stopPoints * _Point;
      if(p_takePoints > 0) tp = price + p_takePoints * _Point;
      if(sl != 0 && !IsPriceSafe(sl, true)) sl = price - (SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + dynamicSafetyPoints + 2) * _Point;
      if(trade.Buy(lote, _Symbol, price, sl, tp, "MT-LiveExecutor")) {
         if(p_notifications) SendNotification("Compra executada em " + _Symbol + " a " + DoubleToString(price, _Digits));
      }
   } else {
      if(p_stopPoints > 0) sl = price + p_stopPoints * _Point;
      if(p_takePoints > 0) tp = price - p_takePoints * _Point;
      if(sl != 0 && !IsPriceSafe(sl, true)) sl = price + (SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + dynamicSafetyPoints + 2) * _Point;
      if(trade.Sell(lote, _Symbol, price, sl, tp, "MT-LiveExecutor")) {
         if(p_notifications) SendNotification("Venda executada em " + _Symbol + " a " + DoubleToString(price, _Digits));
      }
   }

   if(trade.ResultRetcode() != TRADE_RETCODE_DONE) {
      dynamicSafetyPoints = MathMin(100, dynamicSafetyPoints + 5);
   }
}

void SynchronizeClusterSL(long type) {
   double targetSL = 0;
   // Find the SL of the most recent position of the same type
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_TYPE) == type) {
         targetSL = PositionGetDouble(POSITION_SL);
         break;
      }
   }
   if(targetSL <= 0) return;

   for(int i=0; i<PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_TYPE) == type) {
         if(MathAbs(PositionGetDouble(POSITION_SL) - targetSL) > _Point) {
            trade.PositionModify(ticket, NormalizeDouble(targetSL, _Digits), PositionGetDouble(POSITION_TP));
         }
      }
   }
}

void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double sl = PositionGetDouble(POSITION_SL);

         // Breakeven
         if(p_beTrigger > 0) {
            double profitPoints = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? (currentPrice - openPrice) / _Point : (openPrice - currentPrice) / _Point;
            if(profitPoints >= p_beTrigger) {
               double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? openPrice + p_bePoints * _Point : openPrice - p_bePoints * _Point;
               if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && (sl < newSL || sl == 0)) || (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (sl > newSL || sl == 0))) {
                  trade.PositionModify(ticket, NormalizeDouble(newSL, _Digits), PositionGetDouble(POSITION_TP));
               }
            }
         }

         // Trailing Stop
         if(p_trailingStop > 0) {
            double profitPoints = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? (currentPrice - openPrice) / _Point : (openPrice - currentPrice) / _Point;
            if(profitPoints > p_trailingStop) {
               double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? currentPrice - p_trailingStop * _Point : currentPrice + p_trailingStop * _Point;
               if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && newSL > sl) || (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (newSL < sl || sl == 0))) {
                  trade.PositionModify(ticket, NormalizeDouble(newSL, _Digits), PositionGetDouble(POSITION_TP));
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| AUXILIARY FEATURES                                               |
//+------------------------------------------------------------------+

bool AguardaNoticias() {
   // 1. Check local veto file (MQL5/Files/news_veto.txt in Common folder)
   int fileHandle = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_COMMON);
   if(fileHandle != INVALID_HANDLE) {
      string content = FileReadString(fileHandle);
      FileClose(fileHandle);
      if(StringFind(content, "1") >= 0) return true;
   }

   // 2. Check MQL5 Calendar
   if(p_newsVetoMins == 0) return false;
   MqlCalendarValue values[];
   datetime from = TimeCurrent() - p_newsVetoMins * 60;
   datetime to = TimeCurrent() + p_newsVetoMins * 60;

   if(CalendarValueHistory(values, from, to)) {
      for(int i=0; i<ArraySize(values); i++) {
         MqlCalendarEvent event;
         if(CalendarEventById(values[i].event_id, event)) {
            if(event.importance == CALENDAR_IMPORTANCE_HIGH) return true;
         }
      }
   }
   return false;
}

void CheckForUpdates() {
   if(GlobalVariableCheck("MT_Executor_Prompt_Update")) {
      if(GlobalVariableGet("MT_Executor_Prompt_Update") != 0) {
         int fileHandle = FileOpen("MT_LiveExecutor_Prompt.txt", FILE_READ | FILE_TXT | FILE_ANSI);
         if(fileHandle != INVALID_HANDLE) {
            string prompt = "";
            while(!FileIsEnding(fileHandle)) prompt += FileReadString(fileHandle);
            FileClose(fileHandle);
            if(prompt != "") {
               InterpretaPrompt(prompt);
               GlobalVariableSet("MT_Executor_Prompt_Update", 0);
               Print("MT-LiveExecutor: Estratégia atualizada via arquivo.");
            }
         }
      }
   }
}

void GravaCSV() {
   int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV);
   if(handle != INVALID_HANDLE) {
      FileWrite(handle, "Ticket", "Symbol", "Price", "SL", "TP", "Time", "Reason");
      for(int i=0; i<PositionsTotal(); i++) {
         if(PositionSelectByTicket(PositionGetTicket(i))) {
            FileWrite(handle, PositionGetInteger(POSITION_TICKET), PositionGetString(POSITION_SYMBOL), PositionGetDouble(POSITION_PRICE_OPEN), PositionGetDouble(POSITION_SL), PositionGetDouble(POSITION_TP), PositionGetInteger(POSITION_TIME), "MT-LiveExecutor Active");
         }
      }
      FileClose(handle);
   }
}

void AIOptimizer() {
   HistorySelect(TimeCurrent()-86400*30, TimeCurrent());
   int total = HistoryDealsTotal();
   int wins = 0, losses = 0;
   double profit = 0;

   for(int i=0; i<total; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      double p = HistoryDealGetDouble(ticket, DEAL_PROFIT) + HistoryDealGetDouble(ticket, DEAL_COMMISSION) + HistoryDealGetDouble(ticket, DEAL_SWAP);
      if(p > 0) wins++;
      else if(p < 0) losses++;
      profit += p;
   }

   double winRate = (wins + losses > 0) ? (double)wins / (wins + losses) : 0;
   if(winRate < 0.4 && wins + losses > 10) p_risk *= 0.8; // Heuristic adjustment

   // ATR optimization
   if(atrHandle == INVALID_HANDLE) atrHandle = iATR(_Symbol, PERIOD_CURRENT, 14);
   double atr[1];
   if(CopyBuffer(atrHandle, 0, 0, 1, atr) > 0) {
      if(p_stopPoints == 0) p_stopPoints = (int)(atr[0] * 1.5 / _Point);
   }
}

//+------------------------------------------------------------------+
//| LIFECYCLE HANDLERS                                               |
//+------------------------------------------------------------------+

int OnInit() {
   InterpretaPrompt(InpPrompt);
   EventSetTimer(60);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   for(int i=0; i<nRules; i++) {
      if(rules[i].p1_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p1_handle);
      if(rules[i].p2_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p2_handle);
      if(rules[i].p3_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p3_handle);
   }
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   EventKillTimer();
}

void OnTick() {
   if(TimeCurrent() < p_startTime) return;
   if(AguardaNoticias()) return;

   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar != lastBarTime) {
      Signal s = AvaliaTudo();
      if(s != NONE) {
         EnviaOrdem(s);
         lastBarTime = currentBar;
         GravaCSV();
      }
   }

   GerenciaPosicoes();

   // Safety decay
   if(TimeCurrent() - lastSafetyDecay > 60) {
      if(dynamicSafetyPoints > 0) dynamicSafetyPoints--;
      lastSafetyDecay = TimeCurrent();
   }
}

void OnTimer() {
   CheckForUpdates();
   AIOptimizer();
}

void OnTradeTransaction(const MqlTradeTransaction& trans, const MqlTradeRequest& request, const MqlTradeResult& result) {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD) {
      if(HistoryDealSelect(trans.deal)) {
         long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_IN) {
            long type = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
            SynchronizeClusterSL(type);
         }
      }
   }
}
