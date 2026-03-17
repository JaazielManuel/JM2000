//=========================  MT5-LIVE-EXECUTOR (Profit Master v8.0)  =========================
// MetaTrader 5 Expert Advisor for Natural Language Strategy Execution
// Updated for 2026 Standards
//============================================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// --- Global Enums ---
enum Signal { BUY=1, SELL=-1, NONE=0 };

enum RuleType {
   RULE_MA_CROSS,
   RULE_RSI,
   RULE_STOCH,
   RULE_BB,
   RULE_DAILY_BREAK,
   RULE_DELTA,
   RULE_VOLUME,
   RULE_AMA,
   RULE_PATTERN,
   RULE_RELATIVE
};

// --- Structs ---
struct Rule {
   bool      active;
   RuleType  type;
   ENUM_TIMEFRAMES tf;
   int       p1, p2, p3_handle; // p3_handle for secondary indicator handles
   double    d1, d2;
   string    s1;
   bool      is_cross; // Flag for threshold crossover logic
   int       handle;   // Main indicator handle
};

// --- Global Variables ---
Rule rules[30];
int nRules = 0;

// Strategy Parameters
double p_stopPoints = 0;
double p_takePoints = 0;
double p_riskPercent = 1.0;
int    p_maxTrades = 1;
int    p_newsVetoMins = 0;
int    p_startTimeHour = 0;
int    p_frequencyMins = 0;
double p_breakEvenPoints = 0;
double p_breakEvenTrigger = 0;
bool   p_useTrailing = false;
bool   p_useMartingale = false;
bool   p_useHedge = false;
bool   p_useNotifications = false;

// State Variables
datetime lastBarTime = 0;
int      dynamicSafetyPoints = 0;
datetime lastSafetyDecay = 0;
int      atrHandle = INVALID_HANDLE;

// Library Wrappers and Helper Functions
double iClose(string symbol, ENUM_TIMEFRAMES tf, int shift) {
   double price[1];
   if(CopyClose(symbol, tf, shift, 1, price) > 0) return price[0];
   return 0;
}

double iOpen(string symbol, ENUM_TIMEFRAMES tf, int shift) {
   double price[1];
   if(CopyOpen(symbol, tf, shift, 1, price) > 0) return price[0];
   return 0;
}

double iHigh(string symbol, ENUM_TIMEFRAMES tf, int shift) {
   double price[1];
   if(CopyHigh(symbol, tf, shift, 1, price) > 0) return price[0];
   return 0;
}

double iLow(string symbol, ENUM_TIMEFRAMES tf, int shift) {
   double price[1];
   if(CopyLow(symbol, tf, shift, 1, price) > 0) return price[0];
   return 0;
}

datetime iTime(string symbol, ENUM_TIMEFRAMES tf, int shift) {
   datetime time[1];
   if(CopyTime(symbol, tf, shift, 1, time) > 0) return time[0];
   return 0;
}

// Normalized values helpers
double NS(double price) { return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)); }
double NV(double vol) {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   return MathFloor(vol/step) * step;
}

//=========================  MT5-KNOWLEDGE-CORE  =========================

// 1.1 MÉDIAS & CRUZAMENTOS
Signal CruzamentoMA(int fast=9, int slow=21, ENUM_TIMEFRAMES timeframe=PERIOD_CURRENT, int shift=1)
{
   int hFast = iMA(_Symbol, timeframe, fast, 0, MODE_EMA, PRICE_CLOSE);
   int hSlow = iMA(_Symbol, timeframe, slow, 0, MODE_EMA, PRICE_CLOSE);

   double f[2], s[2];
   if(CopyBuffer(hFast, 0, shift, 2, f) < 2 || CopyBuffer(hSlow, 0, shift, 2, s) < 2) return NONE;

   // f[1], s[1] are most recent (shift)
   // f[0], s[0] are previous (shift+1)
   if(f[0] <= s[0] && f[1] > s[1]) return BUY;
   if(f[0] >= s[0] && f[1] < s[1]) return SELL;
   return NONE;
}

// 1.2 RSI
Signal RSIThreshold(int period=14, double over=70, double under=30, ENUM_TIMEFRAMES tf=PERIOD_CURRENT, int shift=0, bool is_cross=false)
{
   int handle = iRSI(_Symbol, tf, period, PRICE_CLOSE);
   double v[2];
   if(CopyBuffer(handle, 0, shift, 2, v) < 2) { IndicatorRelease(handle); return NONE; }
   IndicatorRelease(handle);

   // Adaptive logic: detection of Trend (Buy > Sell level) vs Mean Reversion (Buy < Sell level)
   // But here we use 'over' as BUY level and 'under' as SELL level for trend, or vice-versa.
   // Let's use the explicit logic from prompt if possible, or a heuristic.
   // Prompt: "subir acima de 55" (BUY), "cair abaixo de 45" (SELL).
   // Here d1=55 (over), d2=45 (under).

   if(is_cross) {
      if(v[0] <= over && v[1] > over) return BUY;
      if(v[0] >= under && v[1] < under) return SELL;
   } else {
      if(v[1] > over) return BUY;
      if(v[1] < under) return SELL;
   }

   // Fallback for standard mean reversion if levels are like 70/30
   if(over == 70 && under == 30) {
      if(v[1] < 30) return BUY;
      if(v[1] > 70) return SELL;
   }

   return NONE;
}

// 1.3 ESTOCÁSTICO
Signal StochCross(ENUM_TIMEFRAMES tf=PERIOD_CURRENT, int k=5, int d=3, int slowing=3, int shift=0)
{
   int handle = iStochastic(_Symbol, tf, k, d, slowing, MODE_SMA, STO_LOWHIGH);
   double main[2], sig[2];
   if(CopyBuffer(handle, 0, shift, 2, main) < 2 || CopyBuffer(handle, 1, shift, 2, sig) < 2) return NONE;

   if(main[0] <= sig[0] && main[1] > sig[1]) return BUY;
   if(main[0] >= sig[0] && main[1] < sig[1]) return SELL;
   return NONE;
}

// 1.4 BOLLINGER BOUNCE
Signal BBounce(int period=20, double desv=2, ENUM_TIMEFRAMES tf=PERIOD_CURRENT, int shift=0)
{
   int handle = iBands(_Symbol, tf, period, 0, desv, PRICE_CLOSE);
   double up[1], lo[1], cl[1];
   if(CopyBuffer(handle, 1, shift, 1, up) < 1 || CopyBuffer(handle, 2, shift, 1, lo) < 1) return NONE;
   cl[0] = iClose(_Symbol, tf, shift);

   if(cl[0] < lo[0]) return BUY;
   if(cl[0] > up[0]) return SELL;
   return NONE;
}

// 1.5 BREAKOUT DIÁRIO
Signal DailyBreak(int shift=0)
{
   double hi = iHigh(_Symbol, PERIOD_D1, 1);
   double lo = iLow(_Symbol, PERIOD_D1, 1);
   double close = iClose(_Symbol, PERIOD_M1, shift);

   if(close > hi) return BUY;
   if(close < lo) return SELL;
   return NONE;
}

// 1.6 MICROESTRUTURA: DELTA DE AGRESSÃO
Signal DeltaAggression(int seconds=60, int deltaTrigger=300)
{
   MqlTick arr[];
   int n = CopyTicksRange(_Symbol, arr, COPY_TICKS_TRADE, (TimeCurrent()-seconds)*1000, TimeCurrent()*1000);
   if(n <= 0) return NONE;

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

// 1.7 CICLO DE VOLUME (Williams)
Signal VolumeCycle(int len=12, ENUM_TIMEFRAMES tf=PERIOD_CURRENT, int shift=0)
{
   long vol[];
   if(CopyVolume(_Symbol, tf, shift, len, vol) < len) return NONE;

   int maxIdx = ArrayMaximum(vol);
   int minIdx = ArrayMinimum(vol);

   if(minIdx == 0) return BUY;
   if(maxIdx == 0) return SELL;
   return NONE;
}

// 1.8 MÉDIA MÓVEL ADAPTATIVA (Kaufman)
Signal AMA(int len=10, int fast=2, int slow=30, ENUM_TIMEFRAMES tf=PERIOD_CURRENT, int shift=0)
{
   int handle = iAMA(_Symbol, tf, len, fast, slow, 0, PRICE_CLOSE);
   double val[2];
   if(CopyBuffer(handle, 0, shift, 2, val) < 2) return NONE;

   if(val[0] < val[1]) return BUY;
   if(val[0] > val[1]) return SELL;
   return NONE;
}

// 1.9 PADRÃO DE 2 BARRAS (inside / outside)
Signal Bar2Pattern(ENUM_TIMEFRAMES tf=PERIOD_CURRENT, int shift=0)
{
   double h0 = iHigh(_Symbol, tf, shift);
   double l0 = iLow(_Symbol, tf, shift);
   double h1 = iHigh(_Symbol, tf, shift+1);
   double l1 = iLow(_Symbol, tf, shift+1);
   double c0 = iClose(_Symbol, tf, shift);
   double o0 = iOpen(_Symbol, tf, shift);

   if(h0 < h1 && l0 > l1) return (c0 > o0) ? BUY : SELL;
   if(h0 > h1 && l0 < l1) return (c0 > o0) ? SELL : BUY;
   return NONE;
}

// 1.10 FORÇA RELATIVA ENTRE ATIVOS
Signal RSRelative(string bench="US30", int len=14, ENUM_TIMEFRAMES tf=PERIOD_CURRENT, int shift=0)
{
   int h1 = iRSI(_Symbol, tf, len, PRICE_CLOSE);
   int h2 = iRSI(bench, tf, len, PRICE_CLOSE);
   double r1[1], r2[1];
   if(CopyBuffer(h1, 0, shift, 1, r1) < 1 || CopyBuffer(h2, 0, shift, 1, r2) < 1) return NONE;

   if(r1[0] > r2[0] + 5) return BUY;
   if(r1[0] < r2[0] - 5) return SELL;
   return NONE;
}

// --- Parser Helpers ---

double ExtraiNumero(string texto, string chave) {
   int pos = StringFind(texto, chave);
   if(pos < 0) return 0;
   int start = pos + StringLen(chave);
   int len = StringLen(texto);
   while(start < len) {
      ushort c = StringGetCharacter(texto, start);
      if((c >= '0' && c <= '9') || c == '.' || c == '-' || c == '+') break;
      start++;
   }
   if(start >= len) return 0;
   string sub = StringSubstr(texto, start);
   return StringToDouble(sub);
}

ENUM_TIMEFRAMES PeriodoTexto(string nome) {
   string n = nome; StringToLower(n);
   if(StringFind(n, "m1") >= 0) return PERIOD_M1;
   if(StringFind(n, "m5") >= 0) return PERIOD_M5;
   if(StringFind(n, "m15") >= 0) return PERIOD_M15;
   if(StringFind(n, "m30") >= 0) return PERIOD_M30;
   if(StringFind(n, "h1") >= 0) return PERIOD_H1;
   if(StringFind(n, "h4") >= 0) return PERIOD_H4;
   if(StringFind(n, "d1") >= 0) return PERIOD_D1;

   // Numeric fallback
   int mins = (int)StringToInteger(n);
   if(mins == 1) return PERIOD_M1;
   if(mins == 5) return PERIOD_M5;
   if(mins == 15) return PERIOD_M15;
   if(mins == 30) return PERIOD_M30;
   if(mins == 60) return PERIOD_H1;
   if(mins == 240) return PERIOD_H4;
   if(mins == 1440) return PERIOD_D1;

   return PERIOD_CURRENT;
}

void AddRule(string txt) {
   if(nRules >= 30) return;
   string t = txt; StringToLower(t);

   RuleType type = (RuleType)-1;
   if(StringFind(t, "média") >= 0 || StringFind(t, "ma ") >= 0) type = RULE_MA_CROSS;
   else if(StringFind(t, "rsi") >= 0) type = RULE_RSI;
   else if(StringFind(t, "estocástico") >= 0 || StringFind(t, "stoch") >= 0) type = RULE_STOCH;
   else if(StringFind(t, "bollinger") >= 0 || StringFind(t, "bb") >= 0) type = RULE_BB;

   if((int)type == -1) return;

   int idx = -1;
   for(int i=0; i<nRules; i++) if(rules[i].type == type) { idx = i; break; }

   if(idx == -1) {
      idx = nRules;
      nRules++;
      rules[idx].active = true;
      rules[idx].type = type;
      rules[idx].handle = INVALID_HANDLE;
      rules[idx].p3_handle = INVALID_HANDLE;
      rules[idx].tf = PERIOD_CURRENT;
      rules[idx].p1 = 0; rules[idx].p2 = 0; rules[idx].d1 = 0; rules[idx].d2 = 0;
   }

   if(type == RULE_MA_CROSS) {
      if(StringFind(t, "compra") >= 0 || StringFind(t, "vende") >= 0) {
         int p = (int)ExtraiNumero(t, "média de ");
         if(p > 0) rules[idx].p1 = p;
      }
      if(rules[idx].p1 == 0) rules[idx].p1 = 20;
   }
   else if(type == RULE_RSI) {
      int p = (int)ExtraiNumero(t, "rsi (");
      if(p > 0) rules[idx].p1 = p;
      if(rules[idx].p1 == 0) rules[idx].p1 = 14;

      double v1 = ExtraiNumero(t, "acima de ");
      if(v1 > 0) rules[idx].d1 = v1;

      double v2 = ExtraiNumero(t, "abaixo de ");
      if(v2 > 0) rules[idx].d2 = v2;

      if(StringFind(t, "subir") >= 0 || StringFind(t, "cair") >= 0 || StringFind(t, "cruzar") >= 0) rules[idx].is_cross = true;
   }
}

void InterpretaPrompt(string prompt) {
   for(int i=0; i<30; i++) {
      if(rules[i].handle != INVALID_HANDLE && rules[i].handle != 0) IndicatorRelease(rules[i].handle);
      if(rules[i].p3_handle != INVALID_HANDLE && rules[i].p3_handle != 0) IndicatorRelease(rules[i].p3_handle);
   }
   nRules = 0;
   ZeroMemory(rules);
   for(int i=0; i<30; i++) {
      rules[i].handle = INVALID_HANDLE;
      rules[i].p3_handle = INVALID_HANDLE;
   }
   lastBarTime = 0;
   GravaLog("Interpretando: " + prompt);

   string p = prompt;
   StringReplace(p, " e ", "|");
   StringReplace(p, " + ", "|");
   StringReplace(p, ".", "|");

   string segments[];
   int n = StringSplit(p, '|', segments);

   for(int i=0; i<n; i++) {
      string s = segments[i]; StringTrimLeft(s); StringTrimRight(s);
      string sl = s; StringToLower(sl);

      // Indicators
      if(StringFind(sl, "média") >= 0 || StringFind(sl, "rsi") >= 0 || StringFind(sl, "estocástico") >= 0) {
         AddRule(s);
      }

      if(StringFind(sl, "cada ") >= 0) p_frequencyMins = (int)ExtraiNumero(sl, "cada ");
      if(StringFind(sl, "depois das ") >= 0) p_startTimeHour = (int)ExtraiNumero(sl, "depois das ");
      if(StringFind(sl, "stop de ") >= 0) p_stopPoints = ExtraiNumero(sl, "stop de ");
      if(StringFind(sl, "take de ") >= 0) p_takePoints = ExtraiNumero(sl, "take de ");
      if(StringFind(sl, "risco de ") >= 0) p_riskPercent = ExtraiNumero(sl, "risco de ");
      if(StringFind(sl, "máximo ") >= 0) p_maxTrades = (int)ExtraiNumero(sl, "máximo ");
      if(StringFind(sl, "notícias") >= 0) {
         p_newsVetoMins = (int)ExtraiNumero(sl, "operar ");
         if(p_newsVetoMins == 0) p_newsVetoMins = (int)ExtraiNumero(sl, "não operar ");
      }

      if(StringFind(sl, "move stop para entrada") >= 0) {
         p_breakEvenTrigger = ExtraiNumero(sl, "atingir +");
         p_breakEvenPoints = ExtraiNumero(sl, "entrada +");
      }

      if(StringFind(sl, "trailing") >= 0) p_useTrailing = true;
      if(StringFind(sl, "martingale") >= 0) p_useMartingale = true;
      if(StringFind(sl, "hedge") >= 0) p_useHedge = true;
      if(StringFind(sl, "notificações") >= 0) p_useNotifications = true;
   }
}

// --- Core Logic ---

Signal AvaliaTudo() {
   if(nRules == 0) return NONE;
   int buyVotes = 0, sellVotes = 0, activeRules = 0;

   for(int i=0; i<nRules; i++) {
      if(!rules[i].active) continue;
      activeRules++;
      Signal s = NONE;

      if(rules[i].type == RULE_MA_CROSS) {
         if(rules[i].handle == INVALID_HANDLE) rules[i].handle = iMA(_Symbol, rules[i].tf, rules[i].p1, 0, MODE_EMA, PRICE_CLOSE);
         double cl[2], mav[2];
         if(CopyClose(_Symbol, rules[i].tf, 1, 2, cl) == 2 && CopyBuffer(rules[i].handle, 0, 1, 2, mav) == 2) {
            if(cl[0] <= mav[0] && cl[1] > mav[1]) s = BUY;
            if(cl[0] >= mav[0] && cl[1] < mav[1]) s = SELL;
         }
      }
      else if(rules[i].type == RULE_RSI) {
         s = RSIThreshold(rules[i].p1, rules[i].d1, rules[i].d2, rules[i].tf, 1, rules[i].is_cross);
      }
      else if(rules[i].type == RULE_STOCH) {
         s = StochCross(rules[i].tf, rules[i].p1, rules[i].p2, 3, 1);
      }
      else if(rules[i].type == RULE_BB) {
         s = BBounce(rules[i].p1, rules[i].d1, rules[i].tf, 1);
      }

      if(s == BUY) buyVotes++;
      if(s == SELL) sellVotes++;
   }

   if(activeRules > 0) {
      if(buyVotes == activeRules) return BUY;
      if(sellVotes == activeRules) return SELL;
   }
   return NONE;
}

double CalculaLote(double riscoPercent) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riscoAbs = capital * riscoPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   double stopDist = p_stopPoints * _Point;
   if(stopDist <= 0) stopDist = 100 * _Point; // Safety floor

   double volume = riscoAbs / (stopDist * (tickValue / tickSize));

   // Martingale
   if(p_useMartingale) {
      HistorySelect(TimeCurrent() - 86400, TimeCurrent());
      int total = HistoryDealsTotal();
      for(int i=total-1; i>=0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol) {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            if(profit < 0) volume *= 2.0;
            break;
         }
      }
   }

   return NV(volume);
}

bool IsPriceSafe(double price, Signal type) {
   double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double minGap = stopsLevel + (dynamicSafetyPoints * _Point) + (2 * _Point);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(type == BUY) return (price < ask - minGap || price > ask + minGap);
   if(type == SELL) return (price < bid - minGap || price > bid + minGap);
   return true;
}

void GravaLog(string texto) {
   string time = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);
   Print(time + " | " + texto);
}

void EnviaOrdem(Signal s) {
   CTrade trade;
   double lote = CalculaLote(p_riskPercent);
   double sl = 0, tp = 0;
   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double stopsLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double safetyBuffer = stopsLevel + (dynamicSafetyPoints * _Point) + (2 * _Point);

   if(s == BUY) {
      if(p_stopPoints > 0) {
         double stopDist = MathMax(p_stopPoints * _Point, safetyBuffer);
         sl = NS(price - stopDist);
      }
      if(p_takePoints > 0) tp = NS(price + p_takePoints * _Point);
      if(trade.Buy(lote, _Symbol, price, sl, tp, "MT-LiveExecutor BUY"))
         GravaLog("Compra executada: Lote=" + DoubleToString(lote, 2) + " SL=" + DoubleToString(sl, _Digits) + " TP=" + DoubleToString(tp, _Digits));
   } else {
      if(p_stopPoints > 0) {
         double stopDist = MathMax(p_stopPoints * _Point, safetyBuffer);
         sl = NS(price + stopDist);
      }
      if(p_takePoints > 0) tp = NS(price - p_takePoints * _Point);
      if(trade.Sell(lote, _Symbol, price, sl, tp, "MT-LiveExecutor SELL"))
         GravaLog("Venda executada: Lote=" + DoubleToString(lote, 2) + " SL=" + DoubleToString(sl, _Digits) + " TP=" + DoubleToString(tp, _Digits));
   }

   if(trade.ResultRetcode() != 10009 && trade.ResultRetcode() != 10008 && trade.ResultRetcode() != 0) {
      GravaLog("Erro ao enviar ordem: " + IntegerToString(trade.ResultRetcode()) + " - " + trade.ResultComment());
      dynamicSafetyPoints = MathMin(dynamicSafetyPoints + 5, 100);
   }
}

// --- Management & Optimization ---

void GerenciaPosicoes() {
   CPositionInfo pos;
   CTrade trade;
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(pos.SelectByTicket(ticket)) {
         if(pos.Symbol() != _Symbol) continue;

         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

         // Break-even
         if(p_breakEvenTrigger > 0) {
            double profit = 0;
            if(pos.PositionType() == POSITION_TYPE_BUY) profit = (bid - pos.PriceOpen()) / _Point;
            else profit = (pos.PriceOpen() - ask) / _Point;

            if(profit >= p_breakEvenTrigger) {
               double newSL = 0;
               if(pos.PositionType() == POSITION_TYPE_BUY) newSL = NS(pos.PriceOpen() + p_breakEvenPoints * _Point);
               else newSL = NS(pos.PriceOpen() - p_breakEvenPoints * _Point);

               if(pos.StopLoss() != newSL) {
                  // Only move SL forward
                  if(pos.PositionType() == POSITION_TYPE_BUY && (pos.StopLoss() < newSL || pos.StopLoss() == 0)) trade.PositionModify(pos.Ticket(), newSL, pos.TakeProfit());
                  else if(pos.PositionType() == POSITION_TYPE_SELL && (pos.StopLoss() > newSL || pos.StopLoss() == 0)) trade.PositionModify(pos.Ticket(), newSL, pos.TakeProfit());
               }
            }
         }

         // Trailing Stop (Simple distance based)
         if(p_useTrailing && p_stopPoints > 0) {
            double trailingDist = p_stopPoints * _Point;
            if(pos.PositionType() == POSITION_TYPE_BUY) {
               double newSL = NS(bid - trailingDist);
               if(newSL > pos.StopLoss() + _Point) trade.PositionModify(pos.Ticket(), newSL, pos.TakeProfit());
            } else {
               double newSL = NS(ask + trailingDist);
               if((newSL < pos.StopLoss() - _Point) || pos.StopLoss() == 0) trade.PositionModify(pos.Ticket(), newSL, pos.TakeProfit());
            }
         }
      }
   }
}

bool AguardaNoticias() {
   if(p_newsVetoMins == 0) return false;
   int handle = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      string content = FileReadString(handle);
      FileClose(handle);
      if(content == "1") return true;
   }
   return false;
}

void GravaCSV() {
   int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV | FILE_ANSI);
   if(handle != INVALID_HANDLE) {
      FileWrite(handle, "Ticket", "Symbol", "Type", "Price", "SL", "TP", "Time");
      CPositionInfo pos;
      for(int i=0; i<PositionsTotal(); i++) {
         ulong ticket = PositionGetTicket(i);
         if(pos.SelectByTicket(ticket)) {
            FileWrite(handle, pos.Ticket(), pos.Symbol(), pos.PositionType(), pos.PriceOpen(), pos.StopLoss(), pos.TakeProfit(), pos.Time());
         }
      }
      FileClose(handle);
   }
}

void AIOptimizer() {
   // Analyze rolling history
   HistorySelect(TimeCurrent() - 86400*7, TimeCurrent());
   int total = HistoryDealsTotal();
   double wins = 0, losses = 0;
   for(int i=0; i<total; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT) {
         double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         if(profit > 0) wins++; else losses++;
      }
   }
   double winRate = (wins + losses > 0) ? wins / (wins + losses) : 0;

   // Heuristic adjustment
   if(winRate < 0.4 && wins + losses > 10) p_riskPercent *= 0.9;
   if(winRate > 0.6) p_riskPercent = MathMin(p_riskPercent * 1.05, 5.0);
}

// --- Event Handlers ---

int OnInit() {
   nRules = 0;
   for(int i=0; i<30; i++) {
      rules[i].handle = INVALID_HANDLE;
      rules[i].p3_handle = INVALID_HANDLE;
   }

   EventSetTimer(60);
   lastSafetyDecay = TimeCurrent();
   atrHandle = iATR(_Symbol, PERIOD_H1, 14);

   if(!GlobalVariableCheck("MT_Executor_Prompt_Update")) GlobalVariableSet("MT_Executor_Prompt_Update", 0);

   // Initial prompt
   string initialPrompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Não operar 20 min antes ou depois de notícias de alto impacto. Máximo 3 trades simultâneos. Ao atingir +30 pontos, move stop para entrada +5 pontos.";
   InterpretaPrompt(initialPrompt);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   EventKillTimer();
   IndicatorRelease(atrHandle);
   for(int i=0; i<nRules; i++) if(rules[i].handle != INVALID_HANDLE) IndicatorRelease(rules[i].handle);
}

void OnTick() {
   // Dynamic Safety Decay
   if(TimeCurrent() - lastSafetyDecay > 60) {
      if(dynamicSafetyPoints > 0) dynamicSafetyPoints--;
      lastSafetyDecay = TimeCurrent();
   }

   GerenciaPosicoes();

   // Frequency check
   datetime currentBar = 0;
   ENUM_TIMEFRAMES freqTF = PERIOD_M15; // Closest to 15m
   if(p_frequencyMins > 0) {
      if(p_frequencyMins <= 1) freqTF = PERIOD_M1;
      else if(p_frequencyMins <= 5) freqTF = PERIOD_M5;
      else if(p_frequencyMins <= 15) freqTF = PERIOD_M15;
      else freqTF = PERIOD_H1;
   }
   currentBar = iTime(_Symbol, freqTF, 0);

   if(currentBar != lastBarTime) {
      MqlDateTime dt;
      TimeCurrent(dt);
      if(dt.hour >= p_startTimeHour) {
         if(!AguardaNoticias()) {
            int currentPositions = 0;
            if(!p_useHedge) {
               CPositionInfo pos;
               for(int i=0; i<PositionsTotal(); i++) if(pos.SelectByTicket(PositionGetTicket(i))) if(pos.Symbol()==_Symbol) currentPositions++;
            } else {
               currentPositions = PositionsTotal();
            }

            if(currentPositions < p_maxTrades) {
               Signal s = AvaliaTudo();
               if(s != NONE) {
                  // Hedge check: if not using hedge, close opposite position before opening new one
                  if(!p_useHedge) {
                     CPositionInfo pos;
                     for(int i=PositionsTotal()-1; i>=0; i--) {
                        if(pos.SelectByTicket(PositionGetTicket(i)) && pos.Symbol() == _Symbol) {
                           if((s == BUY && pos.PositionType() == POSITION_TYPE_SELL) || (s == SELL && pos.PositionType() == POSITION_TYPE_BUY)) {
                              CTrade t; t.PositionClose(pos.Ticket());
                           }
                        }
                     }
                  }

                  EnviaOrdem(s);
                  lastBarTime = currentBar;
               }
            }
         }
      }
   }
}

void OnTimer() {
   // No-Restart Update Mechanism
   if(GlobalVariableCheck("MT_Executor_Prompt_Update") && GlobalVariableGet("MT_Executor_Prompt_Update") > 0) {
      int handle = FileOpen("MT_LiveExecutor_Prompt.txt", FILE_READ | FILE_TXT);
      if(handle != INVALID_HANDLE) {
         string newPrompt = FileReadString(handle);
         FileClose(handle);
         InterpretaPrompt(newPrompt);
         GlobalVariableSet("MT_Executor_Prompt_Update", 0);
         Print("Estratégia atualizada com sucesso via prompt!");
      }
   }

   AIOptimizer();
   GravaCSV();
}

void OnTradeTransaction(const MqlTradeTransaction& trans, const MqlTradeRequest& request, const MqlTradeResult& result) {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD) {
      // Logic for cluster SL sync could go here
   }
}
