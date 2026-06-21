//=========================  MT5-LIVE-EXECUTOR  =========================
// Processador de Linguagem Natural e Executor de Estratégias em Tempo Real
//========================================================================

#property copyright "MT-LiveExecutor"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// ---------- DEFINES & GLOBALS ----------
#define EA_MAGIC 123456
#define MAX_RULES 20

enum Signal {BUY=1, SELL=-1, NONE=0};

struct Rule {
   bool     active;
   int      type;       // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: Breakout, 6: Delta, 7: Volume, 8: AMA, 9: Pattern, 10: RS
   int      intent;     // BUY=1, SELL=-1
   ENUM_TIMEFRAMES tf;
   int      p1, p2, p3;
   double   d1, d2;
   string   s1;
   int      handle;

   void Reset() {
      active = false; type = 0; intent = 0; tf = PERIOD_CURRENT;
      p1 = 0; p2 = 0; p3 = 0; d1 = 0; d2 = 0; s1 = ""; handle = INVALID_HANDLE;
   }
};

// Global Strategy Parameters
Rule rules[MAX_RULES];
int nRules = 0;
double p_risk = 1.0;
double p_sl = 0;
double p_tp = 0;
int p_maxTrades = 3;
double p_breakeven = 0;
double p_bePlus = 0;
double p_trailingStop = 0;
double p_trailingStep = 0;
int p_newsVeto = 20; // minutes
int p_startHour = 0;
bool p_martingale = false;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symInfo;
CAccountInfo accInfo;

datetime lastBar = 0;

// ---------- NLP / PARSER ----------
void InterpretaPrompt(string prompt) {
   ResetStrategy();
   StringToLower(prompt);
   StringReplace(prompt, "|", ".");
   StringReplace(prompt, "\n", ".");

   string segments[];
   int n = StringSplit(prompt, '.', segments);

   int currentIntent = 0; // 1: BUY, -1: SELL

   for(int i=0; i<n; i++) {
      string seg = segments[i];
      StringTrimLeft(seg); StringTrimRight(seg);
      if(seg == "") continue;

      if(StringFind(seg, "compra") >= 0) currentIntent = 1;
      else if(StringFind(seg, "venda") >= 0 || StringFind(seg, "vende") >= 0) currentIntent = -1;

      // Global Parameters
      if(StringFind(seg, "risco") >= 0) p_risk = ExtraiNumero(seg, StringFind(seg, "risco") + 5);
      if(StringFind(seg, "stop de") >= 0) p_sl = ExtraiNumero(seg, StringFind(seg, "stop de") + 7);
      if(StringFind(seg, "take de") >= 0) p_tp = ExtraiNumero(seg, StringFind(seg, "take de") + 7);
      if(StringFind(seg, "máximo") >= 0 && StringFind(seg, "trades") >= 0) p_maxTrades = (int)ExtraiNumero(seg, StringFind(seg, "máximo") + 6);
      if(StringFind(seg, "breakeven") >= 0 || StringFind(seg, "move stop para entrada") >= 0) {
         p_breakeven = ExtraiNumero(seg, StringFind(seg, "atingir") >= 0 ? StringFind(seg, "atingir") + 7 : StringFind(seg, "breakeven") + 9);
         if(StringFind(seg, "+") > 0) p_bePlus = ExtraiNumero(seg, StringFind(seg, "+") + 1);
      }
      if(StringFind(seg, "trailing") >= 0 || StringFind(seg, "rastreio") >= 0) {
         p_trailingStop = ExtraiNumero(seg, StringFind(seg, "trailing") + 8);
         if(StringFind(seg, "passo") >= 0) p_trailingStep = ExtraiNumero(seg, StringFind(seg, "passo") + 5);
      }
      if(StringFind(seg, "notícias") >= 0) p_newsVeto = (int)ExtraiNumero(seg, StringFind(seg, "notícias") - 3);
      if(StringFind(seg, "após as") >= 0 || StringFind(seg, "depois das") >= 0) {
         int idx = StringFind(seg, "após as");
         if(idx == -1) idx = StringFind(seg, "depois das");
         p_startHour = (int)ExtraiNumero(seg, idx + 8);
      }
      if(StringFind(seg, "martingale") >= 0) p_martingale = true;
      if(StringFind(seg, "cada") >= 0 && (StringFind(seg, "min") >= 0 || StringFind(seg, "minutos") >= 0)) p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(seg);

      // Indicators / Rules
      if(currentIntent != 0) AddRule(seg, currentIntent);
   }

   GravaLog("Estratégia atualizada: " + prompt);
}

void AddRule(string txt, int intent) {
   if(nRules >= MAX_RULES) return;

   static int lastMA = 20;
   static int lastRSI = 14;

   // Media Movel
   if(StringFind(txt, "média") >= 0 || StringFind(txt, "ema") >= 0 || StringFind(txt, "sma") >= 0) {
      rules[nRules].Reset();
      rules[nRules].active = true;
      rules[nRules].type = 1;
      rules[nRules].intent = intent;
      rules[nRules].p1 = (int)ExtraiNumero(txt, StringFind(txt, "média") + 5);
      if(rules[nRules].p1 == 0) rules[nRules].p1 = (int)ExtraiNumero(txt, StringFind(txt, "ema") + 3);
      if(rules[nRules].p1 == 0) rules[nRules].p1 = lastMA; else lastMA = rules[nRules].p1;
      rules[nRules].tf = (ENUM_TIMEFRAMES)PeriodoTexto(txt);
      nRules++;
   }

   // RSI
   if(StringFind(txt, "rsi") >= 0) {
      rules[nRules].Reset();
      rules[nRules].active = true;
      rules[nRules].type = 2;
      rules[nRules].intent = intent;
      rules[nRules].p1 = (int)ExtraiNumero(txt, StringFind(txt, "rsi") + 3);
      if(rules[nRules].p1 == 0) rules[nRules].p1 = lastRSI; else lastRSI = rules[nRules].p1;
      int idx = StringFind(txt, "acima");
      if(idx == -1) idx = StringFind(txt, "abaixo");
      rules[nRules].d1 = ExtraiNumero(txt, idx + 5);
      rules[nRules].tf = (ENUM_TIMEFRAMES)PeriodoTexto(txt);
      nRules++;
   }

   // Estocástico
   if(StringFind(txt, "estocástico") >= 0 || StringFind(txt, "stoch") >= 0) {
      rules[nRules].Reset();
      rules[nRules].active = true;
      rules[nRules].type = 3;
      rules[nRules].intent = intent;
      rules[nRules].p1 = 5; // K
      rules[nRules].p2 = 3; // D
      rules[nRules].tf = (ENUM_TIMEFRAMES)PeriodoTexto(txt);
      nRules++;
   }

   // Bollinger
   if(StringFind(txt, "bollinger") >= 0 || StringFind(txt, "bb") >= 0) {
      rules[nRules].Reset();
      rules[nRules].active = true;
      rules[nRules].type = 4;
      rules[nRules].intent = intent;
      rules[nRules].p1 = 20; // period
      rules[nRules].d1 = 2.0; // deviation
      rules[nRules].tf = (ENUM_TIMEFRAMES)PeriodoTexto(txt);
      nRules++;
   }
}

double ExtraiNumero(string txt, int start) {
   string res = "";
   bool found = false;
   for(int i=start; i<StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.' || c == ',') {
         if(c == ',') res += "."; else res += StringSubstr(txt, i, 1);
         found = true;
      } else if(found) break;
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
      int m = (int)ExtraiNumero(nome, 0);
      if(m == 1) return PERIOD_M1;
      if(m == 5) return PERIOD_M5;
      if(m == 15) return PERIOD_M15;
      if(m == 30) return PERIOD_M30;
   }
   return PERIOD_CURRENT;
}

// ---------- SIGNAL ENGINE ----------
Signal AvaliaTudo() {
   int buyVotos = 0, sellVotos = 0;
   int buyRules = 0, sellRules = 0;

   for(int i=0; i<nRules; i++) {
      if(!rules[i].active) continue;
      Signal s = AvaliaRegra(rules[i]);
      if(rules[i].intent == 1) {
         buyRules++;
         if(s == BUY) buyVotos++;
      } else if(rules[i].intent == -1) {
         sellRules++;
         if(s == SELL) sellVotos++;
      }
   }

   if(buyRules > 0 && buyVotos == buyRules) return BUY;
   if(sellRules > 0 && sellVotos == sellRules) return SELL;

   return NONE;
}

Signal AvaliaRegra(Rule &r) {
   if(r.type == 1) { // MA
      if(r.handle == INVALID_HANDLE) r.handle = iMA(_Symbol, r.tf, r.p1, 0, MODE_EMA, PRICE_CLOSE);
      double ma0 = GetBufferValue(r.handle, 0, 0);
      double ma1 = GetBufferValue(r.handle, 0, 1);
      double close0 = iClose(_Symbol, r.tf, 0);
      double close1 = iClose(_Symbol, r.tf, 1);

      if(r.intent == 1) {
         if(close1 < ma1 && close0 > ma0) return BUY;
         if(close0 > ma0) return BUY;
      } else {
         if(close1 > ma1 && close0 < ma0) return SELL;
         if(close0 < ma0) return SELL;
      }
   }

   if(r.type == 2) { // RSI
      if(r.handle == INVALID_HANDLE) r.handle = iRSI(_Symbol, r.tf, r.p1, PRICE_CLOSE);
      double rsi0 = GetBufferValue(r.handle, 0, 0);
      if(r.intent == 1 && rsi0 > r.d1) return BUY;
      if(r.intent == -1 && rsi0 < r.d1) return SELL;
   }

   if(r.type == 3) { // Stoch
      if(r.handle == INVALID_HANDLE) r.handle = iStochastic(_Symbol, r.tf, r.p1, r.p2, 3, MODE_SMA, STO_LOWHIGH);
      double k0 = GetBufferValue(r.handle, 0, 0);
      double d0 = GetBufferValue(r.handle, 1, 0);
      double k1 = GetBufferValue(r.handle, 0, 1);
      double d1 = GetBufferValue(r.handle, 1, 1);
      if(r.intent == 1 && k1 < d1 && k0 > d0) return BUY;
      if(r.intent == -1 && k1 > d1 && k0 < d0) return SELL;
   }

   if(r.type == 4) { // Bollinger
      if(r.handle == INVALID_HANDLE) r.handle = iBands(_Symbol, r.tf, r.p1, 0, r.d1, PRICE_CLOSE);
      double upper = GetBufferValue(r.handle, 1, 0);
      double lower = GetBufferValue(r.handle, 2, 0);
      double close = iClose(_Symbol, r.tf, 0);
      if(r.intent == 1 && close < lower) return BUY;
      if(r.intent == -1 && close > upper) return SELL;
   }

   return NONE;
}

double GetBufferValue(int handle, int buffer, int shift) {
   double val[];
   ArraySetAsSeries(val, true);
   if(CopyBuffer(handle, buffer, shift, 1, val) > 0) return val[0];
   return 0;
}

// ---------- TRADE / POSITION MANAGEMENT ----------
void EnviaOrdem(Signal s) {
   if(s == NONE) return;
   if(PositionsTotal() >= p_maxTrades) return;
   if(AguardaNoticias()) return;

   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.hour < p_startHour) return;

   double lote = CalculaLote(p_risk);
   double sl = 0, tp = 0;
   double price = 0;

   if(s == BUY) {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(p_sl > 0) sl = price - p_sl * _Point;
      if(p_tp > 0) tp = price + p_tp * _Point;
      if(trade.Buy(lote, _Symbol, price, sl, tp)) {
         GravaLog("Compra enviada: Lote=" + (string)lote + " SL=" + (string)sl + " TP=" + (string)tp);
      }
   } else if(s == SELL) {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(p_sl > 0) sl = price + p_sl * _Point;
      if(p_tp > 0) tp = price - p_tp * _Point;
      if(trade.Sell(lote, _Symbol, price, sl, tp)) {
         GravaLog("Venda enviada: Lote=" + (string)lote + " SL=" + (string)sl + " TP=" + (string)tp);
      }
   }
}

void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != EA_MAGIC) continue;

         double open = PositionGetDouble(POSITION_PRICE_OPEN);
         double sl = PositionGetDouble(POSITION_SL);
         double tp = PositionGetDouble(POSITION_TP);
         long type = PositionGetInteger(POSITION_TYPE);

         double profitPoints = (type == POSITION_TYPE_BUY) ?
                               (SymbolInfoDouble(_Symbol, SYMBOL_BID) - open) / _Point :
                               (open - SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / _Point;

         // Breakeven
         if(p_breakeven > 0 && profitPoints >= p_breakeven) {
            double newSL = (type == POSITION_TYPE_BUY) ? open + p_bePlus * _Point : open - p_bePlus * _Point;
            if((type == POSITION_TYPE_BUY && (sl < newSL || sl == 0)) ||
               (type == POSITION_TYPE_SELL && (sl > newSL || sl == 0))) {
               trade.PositionModify(ticket, newSL, tp);
            }
         }

         // Trailing Stop
         if(p_trailingStop > 0 && profitPoints >= p_trailingStop) {
            double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double newSL = (type == POSITION_TYPE_BUY) ? currentBid - p_trailingStop * _Point : currentAsk + p_trailingStop * _Point;

            if(type == POSITION_TYPE_BUY) {
               if(sl < newSL - p_trailingStep * _Point || sl == 0) trade.PositionModify(ticket, newSL, tp);
            } else {
               if(sl > newSL + p_trailingStep * _Point || sl == 0) trade.PositionModify(ticket, newSL, tp);
            }
         }
      }
   }
}

double CalculaLote(double risco) {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * (risco / 100.0);
   double slPoints = (p_sl > 0) ? p_sl : 100;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(p_martingale) {
      // Martingale: Double lot if last trade was a loss
      HistorySelect(TimeCurrent()-86400, TimeCurrent());
      int total = HistoryDealsTotal();
      if(total > 0) {
         ulong ticket = HistoryDealGetTicket(total-1);
         if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) riskMoney *= 2;
      }
   }

   double lote = (riskMoney) / (slPoints * _Point * (tickValue / tickSize));
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lote = MathFloor(lote / step) * step;
   return MathMax(MathMin(lote, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX)), SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
}

void CalculaStats() {
   // Win Rate, Drawdown etc would be updated here
}

// ---------- EVENT HANDLERS ----------
int OnInit() {
   trade.SetExpertMagicNumber(EA_MAGIC);
   EventSetTimer(1);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   ResetStrategy();
   EventKillTimer();
}

void OnTick() {
   if(iTime(_Symbol, p_frequency, 0) != lastBar) {
      lastBar = iTime(_Symbol, p_frequency, 0);
      Signal s = AvaliaTudo();
      if(s != NONE) EnviaOrdem(s);
   }
   GerenciaPosicoes();
}

void OnTimer() {
   int h = FileOpen("prompt.txt", FILE_READ|FILE_ANSI|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      string p = FileReadString(h);
      FileClose(h);
      FileDelete("prompt.txt", FILE_COMMON);
      InterpretaPrompt(p);
   }
   CalculaStats();
}

// ---------- UTILITIES ----------
bool AguardaNoticias() {
   int h = FileOpen("news_veto.txt", FILE_READ|FILE_ANSI|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      string val = FileReadString(h);
      FileClose(h);
      if(val == "1") return true;
   }

   h = FileOpen("calendar.txt", FILE_READ|FILE_ANSI|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      while(!FileIsEnding(h)) {
         string line = FileReadString(h);
         if(StringFind(line, "High") >= 0 || StringFind(line, "Alto") >= 0) {
            // Assume format: YYYY.MM.DD HH:MM;Symbol;Impact;Title
            string parts[];
            StringSplit(line, ';', parts);
            datetime newsTime = StringToTime(parts[0]);
            if(MathAbs(TimeCurrent() - newsTime) < p_newsVeto * 60) {
               FileClose(h);
               return true;
            }
         }
      }
      FileClose(h);
   }
   return false;
}

void GravaLog(string texto) {
   Print(texto);
   SendNotification(texto);
   int h = FileOpen("MT_LiveExecutor_Log.csv", FILE_WRITE|FILE_READ|FILE_ANSI|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      FileSeek(h, 0, SEEK_END);
      FileWrite(h, TimeToString(TimeCurrent()), texto);
      FileClose(h);
   }
}

void ResetStrategy() {
   for(int i=0; i<MAX_RULES; i++) {
      if(rules[i].handle != INVALID_HANDLE) IndicatorRelease(rules[i].handle);
      rules[i].Reset();
   }
   nRules = 0;
}
