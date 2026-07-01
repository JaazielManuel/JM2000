//=========================  MT5-LIVE-EXECUTOR  =========================
// Description: Multi-strategy executor driven by Portuguese prompts.
// EA_MAGIC: 123456
//========================================================================

#property copyright "MT-LiveExecutor"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// --- ENUMS ---
enum ENUM_SIGNAL { SIGNAL_NONE=0, SIGNAL_BUY=1, SIGNAL_SELL=-1 };

// --- STRUCTS ---
struct Rule {
   bool           active;
   int            type;       // 1:MA, 2:RSI, 3:Stoch, 4:BB, 5:Breakout, 6:Delta, 7:Volume, 8:AMA, 9:Pattern, 10:Relative
   ENUM_TIMEFRAMES tf;
   int            handle;     // Main indicator handle
   int            handle2;    // Optional second handle
   int            p1, p2, p3; // Integer parameters
   double         d1, d2;     // Double parameters
   string         s1;         // String parameter
   string         op;         // Operator (">", "<", "cross_above", etc.)
   ENUM_SIGNAL    intent;     // BUY or SELL intent

   void Reset() {
      if(handle != INVALID_HANDLE)  IndicatorRelease(handle);
      if(handle2 != INVALID_HANDLE) IndicatorRelease(handle2);
      active = false;
      type = 0;
      tf = PERIOD_CURRENT;
      handle = INVALID_HANDLE;
      handle2 = INVALID_HANDLE;
      p1 = 0; p2 = 0; p3 = 0;
      d1 = 0; d2 = 0;
      s1 = "";
      op = "";
      intent = SIGNAL_NONE;
   }
};

// --- GLOBALS ---
Rule g_rules[40];
int  g_nRules = 0;

// Stats
double g_totalProfit = 0;
int    g_winTrades = 0;
int    g_lossTrades = 0;
double g_maxDrawdown = 0;
double g_peakEquity = 0;

// Strategy Parameters
double p_risk         = 1.0;
int    p_stopPoints   = 0;
int    p_takePoints   = 0;
int    p_breakeven    = 0;
int    p_beProfit     = 0;
int    p_trailingStop = 0;
int    p_maxTrades    = 3;
int    p_startHour    = 0;
bool   p_martingale   = false;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
bool   p_exitOpposite = false;

// Trading Objects
CTrade g_trade;
CPositionInfo g_posInfo;
const int EA_MAGIC = 123456;

datetime g_lastBar = 0;

// --- UTILITIES ---

void GravaLog(string texto) {
   Print(texto);
   SendNotification("MT-LiveExecutor: " + texto);
   SendMail("MT-LiveExecutor Alert", texto);
}

double ExtraiNumero(string txt, string keyword, int startPos=0) {
   int idx = StringFind(txt, keyword, startPos);
   if(idx < 0) return 0;

   string res = "";
   bool found = false;
   for(int i = idx + StringLen(keyword); i < StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.' || c == '-' || c == '+') {
         res += ShortToString(c);
         found = true;
      } else if(found) break;
   }
   return StringToDouble(res);
}

ENUM_TIMEFRAMES PeriodoTexto(string txt) {
   string t = txt;
   StringToLower(t);
   // Order matters to avoid collisions (e.g., m15 containing m1)
   if(StringFind(t, "m15") >= 0) return PERIOD_M15;
   if(StringFind(t, "m30") >= 0) return PERIOD_M30;
   if(StringFind(t, "m5") >= 0)  return PERIOD_M5;
   if(StringFind(t, "m1") >= 0)  return PERIOD_M1;
   if(StringFind(t, "h1") >= 0)  return PERIOD_H1;
   if(StringFind(t, "h4") >= 0)  return PERIOD_H4;
   if(StringFind(t, "d1") >= 0)  return PERIOD_D1;
   return PERIOD_CURRENT;
}

// --- NLP ENGINE ---

void AddRuleSpecific(string seg, ENUM_SIGNAL intent) {
   string s = seg;
   StringToLower(s);
   ENUM_TIMEFRAMES tf = PeriodoTexto(s);
   if(tf == PERIOD_CURRENT) tf = p_frequency;

   // 1. Moving Average
   int maPos = StringFind(s, "média");
   if(maPos < 0) maPos = StringFind(s, "ma");
   if(maPos >= 0 && g_nRules < 40) {
      Rule r; r.Reset();
      r.intent = intent; r.tf = tf; r.type = 1;
      r.p1 = (int)ExtraiNumero(s, (StringFind(s, "média", maPos) >= 0) ? "média" : "ma", maPos);
      if(r.p1 == 0) r.p1 = 20;

      if(StringFind(s, "cruzar acima", maPos) >= 0) r.op = "cross_above";
      else if(StringFind(s, "cruzar abaixo", maPos) >= 0) r.op = "cross_below";
      else if(StringFind(s, "acima", maPos) >= 0 && StringFind(s, "rsi", maPos) < 0) r.op = ">";
      else if(StringFind(s, "abaixo", maPos) >= 0 && StringFind(s, "rsi", maPos) < 0) r.op = "<";

      r.handle = iMA(_Symbol, r.tf, r.p1, 0, MODE_SMA, PRICE_CLOSE);
      r.active = true; g_rules[g_nRules++] = r;
   }

   // 2. RSI
   int rsiPos = StringFind(s, "rsi");
   if(rsiPos >= 0 && g_nRules < 40) {
      Rule r; r.Reset();
      r.intent = intent; r.tf = tf; r.type = 2;
      r.p1 = (int)ExtraiNumero(s, "rsi", rsiPos);
      if(r.p1 == 0) r.p1 = 14;

      if(StringFind(s, "acima", rsiPos) >= 0 || StringFind(s, "subir", rsiPos) >= 0) {
         r.op = ">";
         r.d1 = ExtraiNumero(s, StringFind(s, "acima", rsiPos) >= 0 ? "acima" : "subir", rsiPos);
         if(r.d1 == 0) r.d1 = 70;
      } else if(StringFind(s, "abaixo", rsiPos) >= 0 || StringFind(s, "cair", rsiPos) >= 0) {
         r.op = "<";
         r.d1 = ExtraiNumero(s, StringFind(s, "abaixo", rsiPos) >= 0 ? "abaixo" : "cair", rsiPos);
         if(r.d1 == 0) r.d1 = 30;
      }
      r.handle = iRSI(_Symbol, r.tf, r.p1, PRICE_CLOSE);
      r.active = true; g_rules[g_nRules++] = r;
   }

   // 3. Stochastic
   int stochPos = StringFind(s, "estocástico");
   if(stochPos < 0) stochPos = StringFind(s, "stoch");
   if(stochPos >= 0 && g_nRules < 40) {
      Rule r; r.Reset();
      r.intent = intent; r.tf = tf; r.type = 3;
      r.p1 = 5; r.p2 = 3; r.p3 = 3;
      r.handle = iStochastic(_Symbol, r.tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
      r.active = true; g_rules[g_nRules++] = r;
   }

   // 4. Bollinger Bands
   int bbPos = StringFind(s, "bollinger");
   if(bbPos < 0) bbPos = StringFind(s, "bb");
   if(bbPos >= 0 && g_nRules < 40) {
      Rule r; r.Reset();
      r.intent = intent; r.tf = tf; r.type = 4;
      r.p1 = 20; r.d1 = 2.0;
      r.handle = iBands(_Symbol, r.tf, 20, 0, 2.0, PRICE_CLOSE);
      r.active = true; g_rules[g_nRules++] = r;
   }

   // 5. Breakout
   if((StringFind(s, "breakout") >= 0 || StringFind(s, "rompimento") >= 0) && g_nRules < 40) {
      Rule r; r.Reset();
      r.intent = intent; r.tf = tf; r.type = 5;
      r.active = true; g_rules[g_nRules++] = r;
   }

   // 6. Delta
   if(StringFind(s, "delta") >= 0 && g_nRules < 40) {
      Rule r; r.Reset();
      r.intent = intent; r.tf = tf; r.type = 6;
      r.p1 = 60; r.p2 = 300;
      r.active = true; g_rules[g_nRules++] = r;
   }

   // 7. Volume
   if(StringFind(s, "volume") >= 0 && g_nRules < 40) {
      Rule r; r.Reset();
      r.intent = intent; r.tf = tf; r.type = 7;
      r.p1 = 12;
      r.active = true; g_rules[g_nRules++] = r;
   }

   // 8. AMA
   if(StringFind(s, "ama") >= 0 && g_nRules < 40) {
      Rule r; r.Reset();
      r.intent = intent; r.tf = tf; r.type = 8;
      r.p1 = 10; r.p2 = 2; r.p3 = 30;
      r.handle = iAMA(_Symbol, r.tf, 10, 2, 30, 0, PRICE_CLOSE);
      r.active = true; g_rules[g_nRules++] = r;
   }

   // 9. Pattern
   if((StringFind(s, "padrão") >= 0 || StringFind(s, "pattern") >= 0) && g_nRules < 40) {
      Rule r; r.Reset();
      r.intent = intent; r.tf = tf; r.type = 9;
      r.active = true; g_rules[g_nRules++] = r;
   }

   // 10. Relative Strength
   int relPos = StringFind(s, "força relativa");
   if(relPos < 0) relPos = StringFind(s, "bench");
   if(relPos >= 0 && g_nRules < 40) {
      Rule r; r.Reset();
      r.intent = intent; r.tf = tf; r.type = 10;
      r.s1 = "US30";
      int quoteStart = StringFind(s, "\"", relPos);
      if(quoteStart >= 0) {
         int quoteEnd = StringFind(s, "\"", quoteStart + 1);
         if(quoteEnd > quoteStart) r.s1 = StringSubstr(s, quoteStart + 1, quoteEnd - quoteStart - 1);
      }
      r.handle = iRSI(_Symbol, r.tf, 14, PRICE_CLOSE);
      r.handle2 = iRSI(r.s1, r.tf, 14, PRICE_CLOSE);
      r.active = true; g_rules[g_nRules++] = r;
   }
}

void InterpretaPrompt(string prompt) {
   GravaLog("Interpretando: " + prompt);
   for(int i=0; i<40; i++) g_rules[i].Reset();
   g_nRules = 0;

   string p = prompt;
   StringReplace(p, "|", ".");
   StringReplace(p, "\n", ".");
   StringReplace(p, " e o ", ".");
   StringReplace(p, " e a ", ".");
   StringReplace(p, " e ", ".");

   string segments[];
   StringSplit(p, '.', segments);

   ENUM_SIGNAL currentIntent = SIGNAL_NONE;

   for(int i=0; i<ArraySize(segments); i++) {
      string s = segments[i];
      StringReplace(s, ",", ".");
      StringToLower(s);

      if(StringFind(s, "compra") >= 0) currentIntent = SIGNAL_BUY;
      else if(StringFind(s, "vende") >= 0) currentIntent = SIGNAL_SELL;

      // Global Params
      if(StringFind(s, "risco de") >= 0) p_risk = ExtraiNumero(s, "risco de");
      if(StringFind(s, "stop de") >= 0) p_stopPoints = (int)ExtraiNumero(s, "stop de");
      if(StringFind(s, "take de") >= 0) p_takePoints = (int)ExtraiNumero(s, "take de");
      if(StringFind(s, "máximo") >= 0 && StringFind(s, "trades") >= 0) p_maxTrades = (int)ExtraiNumero(s, "máximo");

      if(StringFind(s, "depois das") >= 0) p_startHour = (int)ExtraiNumero(s, "depois das");
      else if(StringFind(s, "após as") >= 0) p_startHour = (int)ExtraiNumero(s, "após as");

      if(StringFind(s, "cada") >= 0) {
         ENUM_TIMEFRAMES tf = PeriodoTexto(s);
         if(tf != PERIOD_CURRENT) p_frequency = tf;
      }

      if(StringFind(s, "breakeven") >= 0 || StringFind(s, "move stop para entrada") >= 0) {
         p_breakeven = (int)ExtraiNumero(s, "atingir");
         p_beProfit = (int)ExtraiNumero(s, "entrada");
      }
      if(StringFind(s, "trailing") >= 0 || StringFind(s, "rastreio") >= 0) {
         p_trailingStop = (int)ExtraiNumero(s, StringFind(s, "trailing") >= 0 ? "trailing" : "rastreio");
      }

      if(StringFind(s, "martingale") >= 0) p_martingale = true;
      if(StringFind(s, "saída por oposto") >= 0) p_exitOpposite = true;

      AddRuleSpecific(s, currentIntent);
   }
}

// --- SIGNAL ENGINE ---

int AIPredict() {
   int h = FileOpen("signal_ai.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      string val = FileReadString(h);
      FileClose(h);
      if(val == "BUY") return 1;
      if(val == "SELL") return -1;
   }
   return 0;
}

double GetVal(int handle, int index=0) {
   double buf[]; ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, index, 1, buf) > 0) return buf[0];
   return 0;
}

bool AvaliaRegra(Rule &r) {
   if(!r.active) return false;

   if(r.type == 1) { // MA
      double ma0 = GetVal(r.handle, 0);
      double ma1 = GetVal(r.handle, 1);
      double c0 = iClose(_Symbol, r.tf, 0);
      double c1 = iClose(_Symbol, r.tf, 1);

      if(r.op == "cross_above") return (c1 <= ma1 && c0 > ma0);
      if(r.op == "cross_below") return (c1 >= ma1 && c0 < ma0);
      if(r.op == ">") return c0 > ma0;
      if(r.op == "<") return c0 < ma0;
   }
   if(r.type == 2) { // RSI
      double v = GetVal(r.handle, 0);
      if(r.op == ">") return v > r.d1;
      if(r.op == "<") return v < r.d1;
   }
   if(r.type == 3) { // Stoch
      double kb[2], db[2];
      if(CopyBuffer(r.handle, 0, 0, 2, kb) < 2) return false;
      if(CopyBuffer(r.handle, 1, 0, 2, db) < 2) return false;
      ArraySetAsSeries(kb, true); ArraySetAsSeries(db, true);
      if(r.intent == SIGNAL_BUY) return (kb[1] <= db[1] && kb[0] > db[0]);
      if(r.intent == SIGNAL_SELL) return (kb[1] >= db[1] && kb[0] < db[0]);
   }
   if(r.type == 4) { // BB
      double up = GetVal(r.handle, 1);
      double lo = GetVal(r.handle, 2);
      double c = iClose(_Symbol, r.tf, 0);
      if(r.intent == SIGNAL_BUY) return c < lo;
      if(r.intent == SIGNAL_SELL) return c > up;
   }
   if(r.type == 5) { // Breakout
      double hi = iHigh(_Symbol, PERIOD_D1, 1);
      double lo = iLow(_Symbol, PERIOD_D1, 1);
      double close = iClose(_Symbol, r.tf, 0);
      if(r.intent == SIGNAL_BUY) return close > hi;
      if(r.intent == SIGNAL_SELL) return close < lo;
   }
   if(r.type == 6) { // Delta
      MqlTick arr[];
      int n = CopyTicksRange(_Symbol, arr, COPY_TICKS_TRADE, TimeCurrent() - r.p1, TimeCurrent());
      long buy = 0, sell = 0;
      for(int i=0; i<n; i++) if((arr[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++; else if((arr[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sell++;
      long delta = buy - sell;
      if(r.intent == SIGNAL_BUY) return delta > r.p2;
      if(r.intent == SIGNAL_SELL) return delta < -r.p2;
   }
   if(r.type == 7) { // Volume
      long vol[]; ArraySetAsSeries(vol, true);
      if(CopyVolume(_Symbol, r.tf, 0, r.p1, vol) < r.p1) return false;
      int maxIdx = ArrayMaximum(vol);
      int minIdx = ArrayMinimum(vol);
      if(r.intent == SIGNAL_BUY) return (minIdx == 0);
      if(r.intent == SIGNAL_SELL) return (maxIdx == 0);
   }
   if(r.type == 8) { // AMA
      double v0 = GetVal(r.handle, 0);
      double v1 = GetVal(r.handle, 1);
      if(r.intent == SIGNAL_BUY) return v0 > v1;
      if(r.intent == SIGNAL_SELL) return v0 < v1;
   }
   if(r.type == 9) { // Pattern
      double h0 = iHigh(_Symbol, r.tf, 0);
      double l0 = iLow(_Symbol, r.tf, 0);
      double h1 = iHigh(_Symbol, r.tf, 1);
      double l1 = iLow(_Symbol, r.tf, 1);
      bool isInside = (h0 < h1 && l0 > l1);
      bool isOutside = (h0 > h1 && l0 < l1);
      if(isInside || isOutside) {
         bool bull = (iClose(_Symbol, r.tf, 0) > iOpen(_Symbol, r.tf, 0));
         return (r.intent == SIGNAL_BUY) ? bull : !bull;
      }
   }
   if(r.type == 10) { // Relative
      double rsi1 = GetVal(r.handle, 0);
      double rsi2 = GetVal(r.handle2, 0);
      if(r.intent == SIGNAL_BUY) return rsi1 > rsi2 + 5;
      if(r.intent == SIGNAL_SELL) return rsi1 < rsi2 - 5;
   }

   return false;
}

ENUM_SIGNAL AvaliaTudo() {
   int buyRules = 0, sellRules = 0;
   int buyMet = 0, sellMet = 0;

   for(int i=0; i<g_nRules; i++) {
      if(g_rules[i].intent == SIGNAL_BUY) {
         buyRules++;
         if(AvaliaRegra(g_rules[i])) buyMet++;
      } else if(g_rules[i].intent == SIGNAL_SELL) {
         sellRules++;
         if(AvaliaRegra(g_rules[i])) sellMet++;
      }
   }

   if(buyRules > 0 && buyMet == buyRules) return SIGNAL_BUY;
   if(sellRules > 0 && sellMet == sellRules) return SIGNAL_SELL;

   int ai = AIPredict();
   if(ai == 1) return SIGNAL_BUY;
   if(ai == -1) return SIGNAL_SELL;

   return SIGNAL_NONE;
}

// --- TRADE MANAGEMENT ---

double CalculaLote(double riskPercent) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAbs = capital * riskPercent / 100.0;

   if(p_martingale) {
      HistorySelect(0, TimeCurrent());
      int total = HistoryDealsTotal();
      for(int i=total-1; i>=0; i--) {
         ulong t = HistoryDealGetTicket(i);
         if(HistoryDealGetString(t, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC) {
            if(HistoryDealGetDouble(t, DEAL_PROFIT) < 0) riskAbs *= 2;
            break;
         }
      }
   }

   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double sl = (p_stopPoints > 0) ? p_stopPoints : 300;
   double lot = riskAbs / (sl * _Point * (tickVal / tickSize));

   double min = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathMax(min, MathMin(max, NormalizeDouble(lot / step, 0) * step));
   return lot;
}

void EnviaOrdem(ENUM_SIGNAL s) {
   if(s == SIGNAL_NONE) return;

   double lot = CalculaLote(p_risk);
   for(int i=0; i<3; i++) {
      double price = (s == SIGNAL_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl = 0, tp = 0;
      if(s == SIGNAL_BUY) {
         if(p_stopPoints > 0) sl = price - p_stopPoints * _Point;
         if(p_takePoints > 0) tp = price + p_takePoints * _Point;
      } else {
         if(p_stopPoints > 0) sl = price + p_stopPoints * _Point;
         if(p_takePoints > 0) tp = price - p_takePoints * _Point;
      }

      bool res = false;
      if(s == SIGNAL_BUY) res = g_trade.Buy(lot, _Symbol, price, sl, tp);
      else res = g_trade.Sell(lot, _Symbol, price, sl, tp);

      if(res) {
         if(g_trade.ResultRetcode() == TRADE_RETCODE_DONE || g_trade.ResultRetcode() == TRADE_RETCODE_PLACED) {
            GravaLog("Ordem enviada: " + g_trade.ResultRetcodeDescription());
            GravaEstadoCSV(g_trade.ResultOrder(), price, sl, tp, EnumToString(s));
            return;
         }
      }
      GravaLog("Falha ao enviar ordem (tentativa " + (string)(i+1) + "): " + g_trade.ResultRetcodeDescription());
      Sleep(200);
   }
}

void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(g_posInfo.SelectByIndex(i) && g_posInfo.Magic() == EA_MAGIC && g_posInfo.Symbol() == _Symbol) {
         double open = g_posInfo.PriceOpen();
         double curr = (g_posInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double sl = g_posInfo.StopLoss();
         double profit = (g_posInfo.PositionType() == POSITION_TYPE_BUY) ? (curr - open)/_Point : (open - curr)/_Point;

         // Breakeven
         if(p_breakeven > 0 && profit >= p_breakeven) {
            double nsl = (g_posInfo.PositionType() == POSITION_TYPE_BUY) ? open + p_beProfit*_Point : open - p_beProfit*_Point;
            if((g_posInfo.PositionType() == POSITION_TYPE_BUY && sl < nsl) || (g_posInfo.PositionType() == POSITION_TYPE_SELL && (sl > nsl || sl == 0))) {
               g_trade.PositionModify(g_posInfo.Ticket(), nsl, g_posInfo.TakeProfit());
               GravaLog("Breakeven acionado.");
            }
         }
         // Trailing
         if(p_trailingStop > 0 && profit >= p_trailingStop) {
            double nsl = (g_posInfo.PositionType() == POSITION_TYPE_BUY) ? curr - p_trailingStop*_Point : curr + p_trailingStop*_Point;
            if((g_posInfo.PositionType() == POSITION_TYPE_BUY && nsl > sl + _Point) || (g_posInfo.PositionType() == POSITION_TYPE_SELL && (nsl < sl - _Point || sl == 0))) {
               g_trade.PositionModify(g_posInfo.Ticket(), nsl, g_posInfo.TakeProfit());
            }
         }

         // Exit by opposite signal
         if(p_exitOpposite) {
            ENUM_SIGNAL s = AvaliaTudo();
            if((g_posInfo.PositionType() == POSITION_TYPE_BUY && s == SIGNAL_SELL) ||
               (g_posInfo.PositionType() == POSITION_TYPE_SELL && s == SIGNAL_BUY)) {
               g_trade.PositionClose(g_posInfo.Ticket());
               GravaLog("Saída por sinal oposto.");
            }
         }
      }
   }
}

// --- HANDLERS ---

int OnInit() {
   g_trade.SetExpertMagicNumber(EA_MAGIC);
   EventSetTimer(1);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   EventKillTimer();
   for(int i=0; i<40; i++) g_rules[i].Reset();
}

void OnTick() {
   if(FileIsExist("prompt.txt", FILE_COMMON)) {
      int h = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON);
      if(h != INVALID_HANDLE) {
         string p = FileReadString(h);
         FileClose(h);
         FileDelete("prompt.txt", FILE_COMMON);
         InterpretaPrompt(p);
      }
   }

   MqlDateTime dt; TimeCurrent(dt);
   if(dt.hour < p_startHour) return;

   datetime currBar = iTime(_Symbol, p_frequency, 0);
   if(currBar != g_lastBar) {
      g_lastBar = currBar;

      int count = 0;
      for(int i=PositionsTotal()-1; i>=0; i--) if(g_posInfo.SelectByIndex(i) && g_posInfo.Magic() == EA_MAGIC) count++;

      if(count < p_maxTrades) {
         ENUM_SIGNAL s = AvaliaTudo();
         EnviaOrdem(s);
      }
   }
   GerenciaPosicoes();
}

void OnTimer() {
   CalculaStats();
}

void CalculaStats() {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > g_peakEquity) g_peakEquity = equity;
   double dd = (g_peakEquity > 0) ? (g_peakEquity - equity) / g_peakEquity * 100.0 : 0;
   if(dd > g_maxDrawdown) g_maxDrawdown = dd;

   g_totalProfit = 0;
   g_winTrades = 0;
   g_lossTrades = 0;

   HistorySelect(0, TimeCurrent());
   int total = HistoryDealsTotal();
   for(int i=0; i<total; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
         double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         g_totalProfit += profit;
         if(profit > 0) g_winTrades++;
         else if(profit < 0) g_lossTrades++;
      }
   }

   string stats = StringFormat("Performance: Lucro=%.2f, WinRate=%d/%d, Drawdown=%.2f%%",
                               g_totalProfit, g_winTrades, g_winTrades + g_lossTrades, g_maxDrawdown);
   Print(stats);
}

bool AguardaNoticias() {
   // news_veto.txt
   if(FileIsExist("news_veto.txt", FILE_COMMON)) {
      int h = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_COMMON);
      if(h != INVALID_HANDLE) {
         string val = FileReadString(h);
         FileClose(h);
         if(val == "true" || val == "1") return true;
      }
   }

   // calendar.txt
   if(FileIsExist("calendar.txt", FILE_COMMON)) {
      int h = FileOpen("calendar.txt", FILE_READ|FILE_TXT|FILE_COMMON);
      if(h != INVALID_HANDLE) {
         while(!FileIsEnding(h)) {
            string line = FileReadString(h);
            string parts[];
            if(StringSplit(line, ';', parts) >= 4 && parts[3] == "High") {
               datetime newsTime = StringToTime(parts[0]);
               if(MathAbs(TimeCurrent() - newsTime) < 1200) { // 20 min window
                  FileClose(h);
                  return true;
               }
            }
         }
         FileClose(h);
      }
   }
   return false;
}

void GravaEstadoCSV(ulong ticket, double price, double sl, double tp, string motive) {
   int h = FileOpen("states.csv", FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      FileSeek(h, 0, SEEK_END);
      FileWrite(h, ticket, price, sl, tp, TimeToString(TimeCurrent()), motive);
      FileClose(h);
   }
}

void EnviaOrdem(string tipo, double preco, double sl, double tp, double lote) {
   // Compatibility wrapper for mandatory handlers if needed
}
