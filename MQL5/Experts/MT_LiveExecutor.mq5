//=========================  MT5-KNOWLEDGE-CORE  =========================
// MT-LiveExecutor - High-Performance Live Strategy Interpreter
//========================================================================

#property copyright "Copyright 2024, Jules"
#property version   "1.20"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// ---------- DEFINES & ENUMS ----------
#define EA_MAGIC 123456
#define MAX_RULES 50

enum Signal {BUY=1, SELL=-1, NONE=0};

// ---------- STRUCTS ----------
struct Rule {
   bool     active;
   int      type;    // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: Breakout, 9: Pattern, 10: AI
   int      tf;
   int      p1, p2, p3;
   double   d1, d2;   // Thresholds or levels
   string   s1;       // Intent: "BUY" or "SELL"
   string   cond;     // Condition: "above", "below", "cross_above", "cross_below"
   int      handle;

   void Reset() {
      active = false;
      type = 0;
      tf = PERIOD_CURRENT;
      p1 = p2 = p3 = 0;
      d1 = d2 = 0;
      s1 = "";
      cond = "";
      if(handle != INVALID_HANDLE && handle != 0) {
         IndicatorRelease(handle);
      }
      handle = INVALID_HANDLE;
   }
};

// ---------- GLOBALS ----------
Rule     g_rules[MAX_RULES];
int      g_nRules = 0;
datetime g_lastBarTime = 0;

// Strategy Parameters
double   p_risk = 1.0;
int      p_slPoints = 300;
int      p_tpPoints = 500;
int      p_maxTrades = 3;
int      p_breakeven = 0;
int      p_breakevenStep = 0;
int      p_trailingStop = 0;
int      p_trailingStep = 0;
int      p_startHour = -1;
int      p_newsVeto = 20; // minutes
bool     p_martingale = false;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

CTrade         trade;
CPositionInfo  posInfo;

// ---------- NLP PARSER ----------

double ExtraiNumero(string txt, int &cursor) {
   int len = StringLen(txt);
   string numStr = "";
   bool found = false;
   bool dotFound = false;

   for(int i = cursor; i < len; i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.' || c == ',') {
         if(c == ',') c = '.';
         if(c == '.') {
            if(dotFound) break;
            dotFound = true;
         }
         numStr += ShortToString(c);
         found = true;
      } else if(found) {
         cursor = i;
         break;
      }
      if(i == len - 1) cursor = len;
   }
   return StringToDouble(numStr);
}

int PeriodoTexto(string nome) {
   string t = nome;
   StringToLower(t);

   if(StringFind(t, "m15") >= 0) return PERIOD_M15;
   if(StringFind(t, "m1") >= 0)  return PERIOD_M1;
   if(StringFind(t, "m5") >= 0)  return PERIOD_M5;
   if(StringFind(t, "m30") >= 0) return PERIOD_M30;
   if(StringFind(t, "h1") >= 0)  return PERIOD_H1;
   if(StringFind(t, "h4") >= 0)  return PERIOD_H4;
   if(StringFind(t, "d1") >= 0)  return PERIOD_D1;

   int c = 0;
   double val = ExtraiNumero(t, c);
   if(val > 0) {
      if(StringFind(t, "min") >= 0) {
         if(val == 1) return PERIOD_M1;
         if(val == 5) return PERIOD_M5;
         if(val == 15) return PERIOD_M15;
         if(val == 30) return PERIOD_M30;
      }
      if(StringFind(t, "hora") >= 0 || StringFind(t, "h") >= 0) {
         if(val == 1) return PERIOD_H1;
         if(val == 4) return PERIOD_H4;
      }
   }
   return PERIOD_CURRENT;
}

void AddRule(string segment, Signal intent) {
   if(g_nRules >= MAX_RULES) return;

   string txt = segment;
   StringToLower(txt);

   static int lastMA = 20;
   static int lastRSI = 14;

   // Intent strings
   string sIntent = (intent == BUY) ? "BUY" : "SELL";

   // 1. Moving Average
   if(StringFind(txt, "média") >= 0 || StringFind(txt, "ema") >= 0 || StringFind(txt, "sma") >= 0) {
      int cursor = StringFind(txt, "média");
      if(cursor < 0) cursor = StringFind(txt, "ema");
      if(cursor < 0) cursor = StringFind(txt, "sma");
      cursor += 3;

      double p = ExtraiNumero(txt, cursor);
      if(p > 0) lastMA = (int)p;

      g_rules[g_nRules].Reset();
      g_rules[g_nRules].active = true;
      g_rules[g_nRules].type = 1;
      g_rules[g_nRules].p1 = lastMA;
      g_rules[g_nRules].tf = PeriodoTexto(txt);
      g_rules[g_nRules].s1 = sIntent;

      if(StringFind(txt, "cruzar acima") >= 0) g_rules[g_nRules].cond = "cross_above";
      else if(StringFind(txt, "cruzar abaixo") >= 0) g_rules[g_nRules].cond = "cross_below";
      else if(StringFind(txt, "acima") >= 0) g_rules[g_nRules].cond = "above";
      else if(StringFind(txt, "abaixo") >= 0) g_rules[g_nRules].cond = "below";

      g_rules[g_nRules].handle = iMA(_Symbol, (ENUM_TIMEFRAMES)g_rules[g_nRules].tf, g_rules[g_nRules].p1, 0, MODE_EMA, PRICE_CLOSE);
      g_nRules++;
   }

   // 2. RSI
   if(g_nRules < MAX_RULES && StringFind(txt, "rsi") >= 0) {
      int cursor = StringFind(txt, "rsi") + 3;
      double p = ExtraiNumero(txt, cursor);
      if(p > 0) lastRSI = (int)p;

      g_rules[g_nRules].Reset();
      g_rules[g_nRules].active = true;
      g_rules[g_nRules].type = 2;
      g_rules[g_nRules].p1 = lastRSI;
      g_rules[g_nRules].tf = PeriodoTexto(txt);
      g_rules[g_nRules].s1 = sIntent;

      cursor = StringFind(txt, "acima");
      if(cursor >= 0) {
         g_rules[g_nRules].d1 = ExtraiNumero(txt, cursor);
         g_rules[g_nRules].cond = (StringFind(txt, "subir") >= 0 || StringFind(txt, "cruzar") >= 0) ? "cross_above" : "above";
      }
      cursor = StringFind(txt, "abaixo");
      if(cursor >= 0) {
         g_rules[g_nRules].d1 = ExtraiNumero(txt, cursor);
         g_rules[g_nRules].cond = (StringFind(txt, "cair") >= 0 || StringFind(txt, "cruzar") >= 0) ? "cross_below" : "below";
      }

      g_rules[g_nRules].handle = iRSI(_Symbol, (ENUM_TIMEFRAMES)g_rules[g_nRules].tf, g_rules[g_nRules].p1, PRICE_CLOSE);
      g_nRules++;
   }

   // 3. Stoch
   if(g_nRules < MAX_RULES && (StringFind(txt, "estocástico") >= 0 || StringFind(txt, "stoch") >= 0)) {
      g_rules[g_nRules].Reset();
      g_rules[g_nRules].active = true;
      g_rules[g_nRules].type = 3;
      g_rules[g_nRules].p1 = 5; g_rules[g_nRules].p2 = 3; g_rules[g_nRules].p3 = 3;
      g_rules[g_nRules].tf = PeriodoTexto(txt);
      g_rules[g_nRules].s1 = sIntent;
      g_rules[g_nRules].cond = "cross";
      g_rules[g_nRules].handle = iStochastic(_Symbol, (ENUM_TIMEFRAMES)g_rules[g_nRules].tf, g_rules[g_nRules].p1, g_rules[g_nRules].p2, g_rules[g_nRules].p3, MODE_SMA, STO_LOWHIGH);
      g_nRules++;
   }

   // 4. Bollinger
   if(g_nRules < MAX_RULES && (StringFind(txt, "bollinger") >= 0 || StringFind(txt, "bandas") >= 0)) {
      g_rules[g_nRules].Reset();
      g_rules[g_nRules].active = true;
      g_rules[g_nRules].type = 4;
      g_rules[g_nRules].p1 = 20; g_rules[g_nRules].d1 = 2.0;
      g_rules[g_nRules].tf = PeriodoTexto(txt);
      g_rules[g_nRules].s1 = sIntent;
      g_rules[g_nRules].handle = iBands(_Symbol, (ENUM_TIMEFRAMES)g_rules[g_nRules].tf, g_rules[g_nRules].p1, 0, g_rules[g_nRules].d1, PRICE_CLOSE);
      g_nRules++;
   }

   // 9. Pattern
   if(g_nRules < MAX_RULES && (StringFind(txt, "padrão") >= 0 || StringFind(txt, "inside bar") >= 0 || StringFind(txt, "outside bar") >= 0)) {
      g_rules[g_nRules].Reset();
      g_rules[g_nRules].active = true;
      g_rules[g_nRules].type = 9;
      g_rules[g_nRules].tf = PeriodoTexto(txt);
      g_rules[g_nRules].s1 = sIntent;
      g_nRules++;
   }

   // 10. AI
   if(g_nRules < MAX_RULES && (StringFind(txt, "ia") >= 0 || StringFind(txt, "inteligência") >= 0)) {
      g_rules[g_nRules].Reset();
      g_rules[g_nRules].active = true;
      g_rules[g_nRules].type = 10;
      g_rules[g_nRules].s1 = sIntent;
      g_nRules++;
   }
}

void InterpretaPrompt(string prompt) {
   for(int i = 0; i < MAX_RULES; i++) g_rules[i].Reset();
   g_nRules = 0;

   string p = prompt;
   StringReplace(p, "|", ".");
   StringReplace(p, "\n", ".");

   int c = 0;
   if(StringFind(p, "risco") >= 0) { c = StringFind(p, "risco"); p_risk = ExtraiNumero(p, c); }
   if(StringFind(p, "stop de") >= 0) { c = StringFind(p, "stop de"); p_slPoints = (int)ExtraiNumero(p, c); }
   if(StringFind(p, "take de") >= 0) { c = StringFind(p, "take de"); p_tpPoints = (int)ExtraiNumero(p, c); }
   if(StringFind(p, "máximo") >= 0 && StringFind(p, "trades") >= 0) { c = StringFind(p, "máximo"); p_maxTrades = (int)ExtraiNumero(p, c); }

   if(StringFind(p, "move stop para entrada") >= 0 || StringFind(p, "breakeven") >= 0) {
      c = StringFind(p, "atingir");
      if(c >= 0) p_breakeven = (int)ExtraiNumero(p, c);
      c = StringFind(p, "entrada");
      if(c >= 0) { c += 7; p_breakevenStep = (int)ExtraiNumero(p, c); }
   }

   if(StringFind(p, "trailing") >= 0 || StringFind(p, "rastreio") >= 0) {
      c = StringFind(p, "trailing"); if(c < 0) c = StringFind(p, "rastreio");
      p_trailingStop = (int)ExtraiNumero(p, c); p_trailingStep = (int)ExtraiNumero(p, c);
   }

   if(StringFind(p, "depois das") >= 0 || StringFind(p, "após as") >= 0) {
      c = StringFind(p, "depois das"); if(c < 0) c = StringFind(p, "após as");
      p_startHour = (int)ExtraiNumero(p, c);
   }

   if(StringFind(p, "notícias") >= 0) {
      c = StringFind(p, "notícias") - 10; if(c < 0) c = 0;
      p_newsVeto = (int)ExtraiNumero(p, c);
   }

   if(StringFind(p, "martingale") >= 0) p_martingale = true;

   p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(p);

   string segments[];
   int n = StringSplit(p, '.', segments);

   Signal currentIntent = NONE;
   for(int i = 0; i < n; i++) {
      string seg = segments[i];
      StringToLower(seg);

      if(StringFind(seg, "compra") >= 0) currentIntent = BUY;
      else if(StringFind(seg, "vende") >= 0) currentIntent = SELL;

      if(currentIntent != NONE) AddRule(seg, currentIntent);
   }
}

// ---------- UTILITIES ----------

double GetBufferValue(int handle, int buffer, int index) {
   double val[];
   ArraySetAsSeries(val, true);
   if(CopyBuffer(handle, buffer, index, 1, val) > 0) return val[0];
   return 0;
}

void GravaLog(string texto) {
   string msg = TimeToString(TimeCurrent()) + ": " + texto;
   Print(msg);
   SendNotification(msg);

   int h = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE|FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      FileSeek(h, 0, SEEK_END);
      FileWrite(h, msg);
      FileClose(h);
   }
}

void CalculaStats() {
   HistorySelect(0, TimeCurrent());
   int total = HistoryDealsTotal();
   int wins = 0, losses = 0;
   double profit = 0, drawdown = 0, maxEquity = 0;

   for(int i = 0; i < total; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
         double p = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         profit += p;
         if(p > 0) wins++; else if(p < 0) losses++;
         if(profit > maxEquity) maxEquity = profit;
         double dd = maxEquity - profit;
         if(dd > drawdown) drawdown = dd;
      }
   }
   double winRate = (wins + losses > 0) ? (double)wins / (wins + losses) * 100.0 : 0;
   GravaLog("STATS: WinRate: " + DoubleToString(winRate, 2) + "% | Profit: " + DoubleToString(profit, 2) + " | Drawdown: " + DoubleToString(drawdown, 2));
}

// ---------- NEWS FILTER ----------

bool AguardaNoticias() {
   int h = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      string content = FileReadString(h);
      FileClose(h);
      if(StringFind(content, "VETO") >= 0) return true;
   }
   h = FileOpen("calendar.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      while(!FileIsEnding(h)) {
         string line = FileReadString(h);
         if(StringFind(line, "High") >= 0 || StringFind(line, "Alto") >= 0) {
            string parts[];
            StringSplit(line, ';', parts);
            if(ArraySize(parts) > 0) {
               datetime newsTime = StringToTime(parts[0]);
               if(MathAbs(TimeCurrent() - newsTime) < p_newsVeto * 60) { FileClose(h); return true; }
            }
         }
      }
      FileClose(h);
   }
   return false;
}

// ---------- SIGNAL ENGINE ----------

Signal AvaliaRegra(Rule &r) {
   if(!r.active) return NONE;

   double val0, val1, val0_p, val1_p;

   switch(r.type) {
      case 1: // MA
         val0 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
         val1 = GetBufferValue(r.handle, 0, 0);
         val0_p = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         val1_p = GetBufferValue(r.handle, 0, 1);

         if(r.cond == "cross_above" && val0_p < val1_p && val0 > val1) return BUY;
         if(r.cond == "cross_below" && val0_p > val1_p && val0 < val1) return SELL;
         if(r.cond == "above" && val0 > val1) return BUY;
         if(r.cond == "below" && val0 < val1) return SELL;
         break;

      case 2: // RSI
         val0 = GetBufferValue(r.handle, 0, 0);
         val0_p = GetBufferValue(r.handle, 0, 1);

         if(r.cond == "cross_above" && val0_p < r.d1 && val0 > r.d1) return BUY;
         if(r.cond == "cross_below" && val0_p > r.d1 && val0 < r.d1) return SELL;
         if(r.cond == "above" && val0 > r.d1) return BUY;
         if(r.cond == "below" && val0 < r.d1) return SELL;
         break;

      case 3: // Stoch
         val0 = GetBufferValue(r.handle, 0, 0); val1 = GetBufferValue(r.handle, 1, 0);
         val0_p = GetBufferValue(r.handle, 0, 1); val1_p = GetBufferValue(r.handle, 1, 1);
         if(val0_p < val1_p && val0 > val1) return BUY;
         if(val0_p > val1_p && val0 < val1) return SELL;
         break;

      case 4: // Bollinger
         val0 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
         val1 = GetBufferValue(r.handle, 2, 0); // Lower
         val1_p = GetBufferValue(r.handle, 1, 0); // Upper
         if(val0 < val1) return BUY;
         if(val0 > val1_p) return SELL;
         break;

      case 9: // Pattern (Inside/Outside)
         val0 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0); val1 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
         val0_p = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1); val1_p = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         if(val0 < val0_p && val1 > val1_p) return (iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0)) ? BUY : SELL;
         if(val0 > val0_p && val1 < val1_p) return (iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0)) ? SELL : BUY;
         break;

      case 10: // AI
         int ha = FileOpen("signal_ai.txt", FILE_READ|FILE_TXT|FILE_COMMON);
         if(ha != INVALID_HANDLE) {
            string s = FileReadString(ha); FileClose(ha);
            if(StringFind(s, "BUY") >= 0) return BUY;
            if(StringFind(s, "SELL") >= 0) return SELL;
         }
         break;
   }
   return NONE;
}

Signal AvaliaTudo() {
   int buyVotos = 0, buyRules = 0, sellVotos = 0, sellRules = 0;
   for(int i = 0; i < g_nRules; i++) {
      Signal s = AvaliaRegra(g_rules[i]);
      if(g_rules[i].s1 == "BUY") { buyRules++; if(s == BUY) buyVotos++; }
      else if(g_rules[i].s1 == "SELL") { sellRules++; if(s == SELL) sellVotos++; }
   }
   if(buyRules > 0 && buyVotos == buyRules) return BUY;
   if(sellRules > 0 && sellVotos == sellRules) return SELL;
   return NONE;
}

// ---------- TRADE MANAGEMENT ----------

double CalculaLote(double riskPercent) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAbs = capital * riskPercent / 100.0;
   if(p_martingale) {
      HistorySelect(TimeCurrent() - 86400*30, TimeCurrent());
      int total = HistoryDealsTotal();
      if(total > 0) {
         ulong ticket = HistoryDealGetTicket(total - 1);
         if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC && HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) riskAbs *= 2;
      }
   }
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lot = riskAbs / (p_slPoints * _Point * (tickVal / tickSize));
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / stepLot) * stepLot;
   if(lot < minLot) lot = minLot; if(lot > maxLot) lot = maxLot;
   return lot;
}

void EnviaOrdem(Signal s) {
   if(PositionsTotal() >= p_maxTrades || AguardaNoticias()) return;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(p_startHour >= 0 && dt.hour < p_startHour) return;

   double lot = CalculaLote(p_risk), sl = 0, tp = 0, price = 0;
   trade.SetExpertMagicNumber(EA_MAGIC);
   if(s == BUY) {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(p_slPoints > 0) sl = price - p_slPoints * _Point;
      if(p_tpPoints > 0) tp = price + p_tpPoints * _Point;
      if(trade.Buy(lot, _Symbol, price, sl, tp, "MT-LiveExecutor")) GravaLog("Compra enviada");
   } else if(s == SELL) {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(p_slPoints > 0) sl = price + p_slPoints * _Point;
      if(p_tpPoints > 0) tp = price - p_tpPoints * _Point;
      if(trade.Sell(lot, _Symbol, price, sl, tp, "MT-LiveExecutor")) GravaLog("Venda enviada");
   }
}

void GerenciaPosicoes() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN), curPrice = PositionGetDouble(POSITION_PRICE_CURRENT), sl = PositionGetDouble(POSITION_SL), tp = PositionGetDouble(POSITION_TP);
         long type = PositionGetInteger(POSITION_TYPE);
         double profitPoints = (type == POSITION_TYPE_BUY) ? (curPrice - openPrice) / _Point : (openPrice - curPrice) / _Point;

         if(p_breakeven > 0 && profitPoints >= p_breakeven) {
            double newSL = (type == POSITION_TYPE_BUY) ? openPrice + p_breakevenStep * _Point : openPrice - p_breakevenStep * _Point;
            if((type == POSITION_TYPE_BUY && (sl < newSL || sl == 0)) || (type == POSITION_TYPE_SELL && (sl > newSL || sl == 0))) trade.PositionModify(ticket, newSL, tp);
         }
         if(p_trailingStop > 0 && profitPoints >= p_trailingStop) {
            double newSL = (type == POSITION_TYPE_BUY) ? curPrice - p_trailingStop * _Point : curPrice + p_trailingStop * _Point;
            if((type == POSITION_TYPE_BUY && (newSL > sl + p_trailingStep * _Point)) || (type == POSITION_TYPE_SELL && (newSL < sl - p_trailingStep * _Point || sl == 0))) trade.PositionModify(ticket, newSL, tp);
         }
      }
   }
}

// ---------- EVENT HANDLERS ----------

int OnInit() {
   EventSetTimer(1); trade.SetExpertMagicNumber(EA_MAGIC);
   for(int i = 0; i < MAX_RULES; i++) g_rules[i].handle = INVALID_HANDLE;
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { EventKillTimer(); for(int i = 0; i < MAX_RULES; i++) g_rules[i].Reset(); }

void OnTimer() {
   int h = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      string prompt = FileReadString(h); FileClose(h); FileDelete("prompt.txt", FILE_COMMON);
      InterpretaPrompt(prompt); GravaLog("Novo prompt recebido");
   }
   static datetime lastAI = 0;
   if(TimeCurrent() - lastAI > 3600) { CalculaStats(); lastAI = TimeCurrent(); }
}

void OnTick() {
   GerenciaPosicoes();
   datetime curBar = iTime(_Symbol, p_frequency, 0);
   if(curBar != g_lastBarTime) {
      Signal s = AvaliaTudo();
      if(s != NONE) EnviaOrdem(s);
      g_lastBarTime = curBar;
   }
}
