//+------------------------------------------------------------------+
//|                                              MT_LiveExecutor.mq5 |
//|                                  Copyright 2023, MT-LiveExecutor |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, MT-LiveExecutor"
#property link      "https://www.mql5.com"
#property version   "1.40"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

//=========================  DEFINES & GLOBALS  =========================
#define EA_MAGIC 123456
#define MAX_RULES 30

enum Signal {BUY=1, SELL=-1, NONE=0};

struct Rule {
   bool     active;
   int      type;
   // 1: MA Cross, 2: RSI, 3: Stoch, 4: BB, 5: DailyBreak, 6: Delta, 7: Vol, 8: AMA, 9: Bar2, 10: RS
   ENUM_TIMEFRAMES tf;
   int      p1, p2, p3;
   double   d1, d2;
   string   s1;
   int      intent; // 1 for BUY, -1 for SELL
   int      handle1, handle2;

   void Reset() {
      if(handle1 != INVALID_HANDLE) { IndicatorRelease(handle1); handle1 = INVALID_HANDLE; }
      if(handle2 != INVALID_HANDLE) { IndicatorRelease(handle2); handle2 = INVALID_HANDLE; }
      active = false; type = 0; tf = PERIOD_CURRENT; p1 = 0; p2 = 0; p3 = 0; d1 = 0; d2 = 0; s1 = ""; intent = 0;
   }
};

Rule g_rules[MAX_RULES];
int  g_nRules = 0;

// Strategy Parameters
double p_risk = 1.0;
int    p_slPoints = 300;
int    p_tpPoints = 500;
int    p_maxTrades = 3;
int    p_breakeven = 300;
int    p_breakevenPlus = 50;
int    p_trailingStop = 0;
int    p_trailingStep = 50;
int    p_newsVeto = 20;
int    p_startHour = 0;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
bool   p_martingale = false;
bool   p_exitOpposite = true;

CTrade trade;

//=========================  EVENT HANDLERS  =========================

int OnInit() {
   trade.SetExpertMagicNumber(EA_MAGIC);
   EventSetTimer(5);
   for(int i=0; i<MAX_RULES; i++) {
      g_rules[i].handle1 = INVALID_HANDLE;
      g_rules[i].handle2 = INVALID_HANDLE;
   }
   GravaLog("MT-LiveExecutor Iniciado.");
   CheckPromptFile();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   EventKillTimer();
   ResetStrategy();
}

void OnTimer() {
   CheckPromptFile();
   GravaCSV();
   AIOptimizer();
}

void OnTick() {
   GerenciaPosicoes();
   static datetime lastBar = 0;
   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar != lastBar) {
      lastBar = currentBar;
      MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
      if(dt.hour >= p_startHour && !AguardaNoticias()) {
         Signal s = AvaliaTudo();
         if(s != NONE) {
            if(p_exitOpposite) FechaOposto(s);
            if(PositionsTotal() < p_maxTrades) EnviaOrdem(s);
         }
      }
   }
}

//=========================  INTERNAL FUNCTIONS  =========================

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   GravaLog("Interpretando Prompt: " + prompt);
   string work = prompt;
   StringReplace(work, " e ", "|");
   StringReplace(work, ".", "|");

   string segments[];
   int nSegments = StringSplit(work, '|', segments);
   int currentIntent = 0;

   for(int i=0; i<nSegments; i++) {
      string seg = segments[i]; StringTrimLeft(seg); StringTrimRight(seg);
      if(seg == "") continue;

      if(StringFind(seg, "risco") >= 0) p_risk = ExtraiNumero(seg, "risco");
      if(StringFind(seg, "stop") >= 0) p_slPoints = (int)ExtraiNumero(seg, "stop");
      if(StringFind(seg, "take") >= 0) p_tpPoints = (int)ExtraiNumero(seg, "take");
      if(StringFind(seg, "máximo") >= 0) p_maxTrades = (int)ExtraiNumero(seg, "máximo");
      if(StringFind(seg, "breakeven") >= 0 || StringFind(seg, "move stop") >= 0) {
         p_breakeven = (int)ExtraiNumero(seg, "atingir");
         if(p_breakeven == 0) p_breakeven = (int)ExtraiNumero(seg, "move stop para");
         p_breakevenPlus = (int)ExtraiNumero(seg, "entrada +");
      }
      if(StringFind(seg, "trailing") >= 0 || StringFind(seg, "rastreio") >= 0) p_trailingStop = (int)ExtraiNumero(seg, "trailing");
      if(StringFind(seg, "martingale") >= 0) p_martingale = true;
      if(StringFind(seg, "notícias") >= 0) p_newsVeto = (int)ExtraiNumero(seg, "notícias");
      if(StringFind(seg, "depois das") >= 0) p_startHour = (int)ExtraiNumero(seg, "depois das");
      else if(StringFind(seg, "após às") >= 0) p_startHour = (int)ExtraiNumero(seg, "após às");
      else if(StringFind(seg, "10h") >= 0) p_startHour = 10;
      if(StringFind(seg, "cada") >= 0 || StringFind(seg, "minutos") >= 0) p_frequency = PeriodoTexto(seg);

      if(StringFind(seg, "compra") >= 0) currentIntent = 1;
      else if(StringFind(seg, "vende") >= 0 || StringFind(seg, "Vende") >= 0) currentIntent = -1;

      if(currentIntent != 0) {
         if(StringFind(seg, "média") >= 0 || StringFind(seg, "ema") >= 0) {
            int f = (int)ExtraiNumero(seg, "média"); if(f==0) f=(int)ExtraiNumero(seg, "ema"); if(f==0) f=20;
            int s = (int)ExtraiNumero(seg, "/");
            if(s == 0) { int p_pos = StringFind(seg, (string)f); if(p_pos>=0) s = (int)ExtraiNumero(StringSubstr(seg, p_pos+StringLen((string)f)), ""); }
            AddRule(1, f, s, 0, 0, 0, "", currentIntent);
         }
         if(StringFind(seg, "rsi") >= 0 || StringFind(seg, "RSI") >= 0) {
            int per = (int)ExtraiNumero(seg, "rsi"); if(per==0) per=14;
            double val = ExtraiNumero(seg, "acima");
            if(val == 0) val = ExtraiNumero(seg, "abaixo");
            if(val == 0) val = ExtraiNumero(seg, "subir");
            if(val == 0) val = ExtraiNumero(seg, "cair");
            if(val == 0) val = (currentIntent == 1) ? 55 : 45;
            AddRule(2, per, 0, 0, val, 0, "", currentIntent);
         }
         if(StringFind(seg, "estocástico") >= 0 || StringFind(seg, "stoch") >= 0) AddRule(3, 5, 3, 3, 0, 0, "", currentIntent);
         if(StringFind(seg, "bollinger") >= 0 || StringFind(seg, "bandas") >= 0) AddRule(4, 20, 2, 0, 0, 0, "", currentIntent);
         if(StringFind(seg, "rompimento diário") >= 0) AddRule(5, 0, 0, 0, 0, 0, "", currentIntent);
         if(StringFind(seg, "delta") >= 0 || StringFind(seg, "agressão") >= 0) AddRule(6, 60, 300, 0, 0, 0, "", currentIntent);
         if(StringFind(seg, "ciclo de volume") >= 0) AddRule(7, 12, 0, 0, 0, 0, "", currentIntent);
         if(StringFind(seg, "ama") >= 0 || StringFind(seg, "adaptativa") >= 0) AddRule(8, 10, 2, 30, 0, 0, "", currentIntent);
         if(StringFind(seg, "2 barras") >= 0 || StringFind(seg, "inside bar") >= 0) AddRule(9, 0, 0, 0, 0, 0, "", currentIntent);
         if(StringFind(seg, "força relativa") >= 0) AddRule(10, 14, 0, 0, 0, 0, "US30", currentIntent);
      }
   }
}

void AddRule(int type, int p1, int p2, int p3, double d1, double d2, string s1, int intent) {
   if(g_nRules >= MAX_RULES) return;
   Rule r; r.Reset(); r.active = true; r.type = type;
   r.p1 = p1; r.p2 = p2; r.p3 = p3; r.d1 = d1; r.d2 = d2; r.s1 = s1; r.intent = intent; r.tf = p_frequency;
   if(type == 1) { r.handle1 = iMA(_Symbol, r.tf, r.p1, 0, MODE_EMA, PRICE_CLOSE); if(r.p2 > 0) r.handle2 = iMA(_Symbol, r.tf, r.p2, 0, MODE_EMA, PRICE_CLOSE); }
   if(type == 2) r.handle1 = iRSI(_Symbol, r.tf, r.p1, PRICE_CLOSE);
   if(type == 3) r.handle1 = iStochastic(_Symbol, r.tf, r.p1, r.p2, r.p3, MODE_SMA, STO_LOWHIGH);
   if(type == 4) r.handle1 = iBands(_Symbol, r.tf, r.p1, 0, d1==0?2.0:d1, PRICE_CLOSE);
   if(type == 7) r.handle1 = iOBV(_Symbol, r.tf, PRICE_CLOSE);
   if(type == 8) r.handle1 = iAMA(_Symbol, r.tf, r.p1, r.p2, r.p3, 0, PRICE_CLOSE);
   if(type == 10) { r.handle1 = iRSI(_Symbol, r.tf, r.p1, PRICE_CLOSE); r.handle2 = iRSI(r.s1, r.tf, r.p1, PRICE_CLOSE); }
   if(r.handle1 == INVALID_HANDLE && type != 5 && type != 6 && type != 9) return;
   g_rules[g_nRules] = r; g_nRules++;
}

Signal AvaliaTudo() {
   int buyRules = 0, sellRules = 0; int buyVotos = 0, sellVotos = 0;
   for(int i=0; i<g_nRules; i++) {
      if(!g_rules[i].active) continue;
      int res = AvaliaRegra(g_rules[i]);
      if(g_rules[i].intent == 1) { buyRules++; if(res == 1) buyVotos++; }
      else { sellRules++; if(res == -1) sellVotos++; }
   }
   if(buyRules > 0 && buyVotos == buyRules) return BUY;
   if(sellRules > 0 && sellVotos == sellRules) return SELL;
   return NONE;
}

int AvaliaRegra(Rule &r) {
   switch(r.type) {
      case 1: {
         double f0 = GetBufferValue(r.handle1, 0, 0); double f1 = GetBufferValue(r.handle1, 0, 1);
         if(r.handle2 == INVALID_HANDLE) { double c0 = iClose(_Symbol, r.tf, 0); double c1 = iClose(_Symbol, r.tf, 1); if(r.intent == 1 && c1 < f1 && c0 > f0) return 1; if(r.intent == -1 && c1 > f1 && c0 < f0) return -1; }
         else { double s0 = GetBufferValue(r.handle2, 0, 0); double s1 = GetBufferValue(r.handle2, 0, 1); if(r.intent == 1 && f1 < s1 && f0 > s0) return 1; if(r.intent == -1 && f1 > s1 && f0 < s0) return -1; }
         break;
      }
      case 2: { double rsi = GetBufferValue(r.handle1, 0, 0); if(r.intent == 1 && rsi > r.d1) return 1; if(r.intent == -1 && rsi < r.d1) return -1; break; }
      case 3: { double k0 = GetBufferValue(r.handle1, 0, 0); double d0 = GetBufferValue(r.handle1, 1, 0); double k1 = GetBufferValue(r.handle1, 0, 1); double d1 = GetBufferValue(r.handle1, 1, 1); if(r.intent == 1 && k1 < d1 && k0 > d0) return 1; if(r.intent == -1 && k1 > d1 && k0 < d0) return -1; break; }
      case 4: { double up = GetBufferValue(r.handle1, 1, 0); double lo = GetBufferValue(r.handle1, 2, 0); double close = iClose(_Symbol, r.tf, 0); if(r.intent == 1 && close < lo) return 1; if(r.intent == -1 && close > up) return -1; break; }
      case 5: { double hi = iHigh(_Symbol, PERIOD_D1, 1); double lo = iLow(_Symbol, PERIOD_D1, 1); double close = iClose(_Symbol, r.tf, 0); if(r.intent == 1 && close > hi) return 1; if(r.intent == -1 && close < lo) return -1; break; }
      case 6: { MqlTick arr[]; int n = CopyTicksRange(_Symbol, arr, COPY_TICKS_TRADE, (TimeCurrent()-r.p1)*1000, TimeCurrent()*1000); long b=0, s=0; for(int i=0; i<n; i++) if((arr[i].flags & TICK_FLAG_BUY) != 0) b++; else s++; long delta = b - s; if(r.intent == 1 && delta > r.p2) return 1; if(r.intent == -1 && delta < -r.p2) return -1; break; }
      case 7: { double v0 = GetBufferValue(r.handle1, 0, 0); double v1 = GetBufferValue(r.handle1, 0, 1); if(r.intent == 1 && v0 > v1) return 1; if(r.intent == -1 && v0 < v1) return -1; break; }
      case 8: { double a0 = GetBufferValue(r.handle1, 0, 0); double a1 = GetBufferValue(r.handle1, 0, 1); if(r.intent == 1 && a0 > a1) return 1; if(r.intent == -1 && a0 < a1) return -1; break; }
      case 9: { double h0 = iHigh(_Symbol, r.tf, 0), l0 = iLow(_Symbol, r.tf, 0); double h1 = iHigh(_Symbol, r.tf, 1), l1 = iLow(_Symbol, r.tf, 1); bool inside = h0 < h1 && l0 > l1; bool outside = h0 > h1 && l0 < l1; bool bull = iClose(_Symbol, r.tf, 0) > iOpen(_Symbol, r.tf, 0); if(r.intent == 1 && ((inside && bull) || (outside && !bull))) return 1; if(r.intent == -1 && ((inside && !bull) || (outside && bull))) return -1; break; }
      case 10: { double r1 = GetBufferValue(r.handle1, 0, 0); double r2 = GetBufferValue(r.handle2, 0, 0); if(r.intent == 1 && r1 > r2 + 5) return 1; if(r.intent == -1 && r1 < r2 - 5) return -1; break; }
   }
   return 0;
}

double GetBufferValue(int handle, int buffer, int shift) { double val[1]; if(handle == INVALID_HANDLE) return 0; if(CopyBuffer(handle, buffer, shift, 1, val) < 0) return 0; return val[0]; }

void EnviaOrdem(Signal s) {
   double lote = CalculaLote(p_risk); double preco = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = (s == BUY) ? preco - p_slPoints * _Point : preco + p_slPoints * _Point;
   double tp = (s == BUY) ? preco + p_tpPoints * _Point : preco - p_tpPoints * _Point;
   if(s == BUY) trade.Buy(lote, _Symbol, preco, sl, tp); else trade.Sell(lote, _Symbol, preco, sl, tp);
   if(trade.ResultRetcode() == TRADE_RETCODE_DONE) GravaLog("Ordem executada com sucesso."); else GravaLog("Erro na ordem: " + (string)trade.ResultRetcode());
}

void FechaOposto(Signal s) {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i); if(PositionSelectByTicket(t)) {
         if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC && PositionGetSymbol() == _Symbol) {
            if((s == BUY && PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) || (s == SELL && PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)) trade.PositionClose(t);
         }
      }
   }
}

double CalculaLote(double riscoPercent) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY); double risk = riscoPercent;
   if(p_martingale) { HistorySelect(TimeCurrent()-86400*7, TimeCurrent()); for(int i=HistoryDealsTotal()-1; i>=0; i--) { ulong t = HistoryDealGetTicket(i); if(HistoryDealGetString(t, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC) { if(HistoryDealGetDouble(t, DEAL_PROFIT) < 0) risk *= 2; break; } } }
   double riscoAbs = capital * risk / 100.0; double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE); double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE); double sl = (p_slPoints == 0) ? 100 : p_slPoints; double volume = riscoAbs / (sl * _Point * (tickVal / tickSize)); double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN); double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX); double stepVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP); volume = MathFloor(volume / stepVol) * stepVol; if(volume < minVol) volume = minVol; if(volume > maxVol) volume = maxVol; return volume;
}

void GerenciaPosicoes() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i); if(PositionSelectByTicket(t)) {
         if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC && PositionGetSymbol() == _Symbol) {
            double op = PositionGetDouble(POSITION_PRICE_OPEN); double cp = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK); double pp = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? (cp - op)/_Point : (op - cp)/_Point;
            if(p_breakeven > 0 && pp >= p_breakeven) { double csl = PositionGetDouble(POSITION_SL); double nsl = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? op + p_breakevenPlus * _Point : op - p_breakevenPlus * _Point; if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && (csl < nsl || csl == 0)) || (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (csl > nsl || csl == 0))) trade.PositionModify(t, nsl, PositionGetDouble(POSITION_TP)); }
            if(p_trailingStop > 0 && pp >= p_trailingStop) { double csl = PositionGetDouble(POSITION_SL); double nsl = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? cp - p_trailingStop * _Point : cp + p_trailingStop * _Point; if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) { if(nsl > csl + p_trailingStep * _Point || csl == 0) trade.PositionModify(t, nsl, PositionGetDouble(POSITION_TP)); } else { if(nsl < csl - p_trailingStep * _Point || csl == 0) trade.PositionModify(t, nsl, PositionGetDouble(POSITION_TP)); } }
         }
      }
   }
}

bool AguardaNoticias() {
   if(FileIsExist("news_veto.txt", FILE_COMMON)) { int h = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_COMMON); if(h != INVALID_HANDLE) { string v = FileReadString(h); FileClose(h); if(v == "1" || v == "true") return true; } }
   if(FileIsExist("calendar.txt", FILE_COMMON)) { int h = FileOpen("calendar.txt", FILE_READ|FILE_TXT|FILE_COMMON); if(h != INVALID_HANDLE) { while(!FileIsEnding(h)) { string line = FileReadString(h); string fields[]; if(StringSplit(line, ';', fields) >= 3) { if(fields[2] == "High" || fields[2] == "Alto") { datetime nt = StringToTime(fields[0]); if(MathAbs(TimeCurrent() - nt) < p_newsVeto * 60) { FileClose(h); return true; } } } } FileClose(h); } }
   return false;
}

void GravaLog(string texto) { int h = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE|FILE_READ|FILE_TXT|FILE_COMMON); if(h != INVALID_HANDLE) { FileSeek(h, 0, SEEK_END); FileWrite(h, TimeToString(TimeCurrent()) + ": " + texto); FileClose(h); } }

void GravaCSV() { int h = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_COMMON); if(h != INVALID_HANDLE) { FileWrite(h, "Ticket", "Symbol", "Type", "Lots", "Profit"); for(int i=0; i<PositionsTotal(); i++) { ulong t = PositionGetTicket(i); if(PositionSelectByTicket(t)) { if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) FileWrite(h, t, PositionGetSymbol(), PositionGetInteger(POSITION_TYPE), PositionGetDouble(POSITION_VOLUME), PositionGetDouble(POSITION_PROFIT)); } } FileClose(h); } }

void ResetStrategy() { for(int i=0; i<MAX_RULES; i++) g_rules[i].Reset(); g_nRules = 0; p_risk = 1.0; p_slPoints = 300; p_tpPoints = 500; p_maxTrades = 3; p_startHour = 0; }

void CheckPromptFile() { if(FileIsExist("prompt.txt", FILE_COMMON)) { int h = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON); if(h != INVALID_HANDLE) { string c = FileReadString(h); FileClose(h); FileDelete("prompt.txt", FILE_COMMON); InterpretaPrompt(c); } } }

double ExtraiNumero(string txt, string keyword) {
   int pos = StringFind(txt, keyword); if(pos < 0 && keyword != "") return 0;
   int start = (keyword == "") ? 0 : pos + StringLen(keyword);
   string sub = StringSubstr(txt, start); string res = ""; bool found = false;
   for(int i=0; i<StringLen(sub); i++) {
      ushort c = StringGetCharacter(sub, i);
      if((c >= '0' && c <= '9') || c == '.' || c == ',') { if(c == ',') c = '.'; res += ShortToString(c); found = true; }
      else if(found) break;
   }
   return StringToDouble(res);
}

ENUM_TIMEFRAMES PeriodoTexto(string txt) {
   if(StringFind(txt, "m15") >= 0 || StringFind(txt, "15 min") >= 0) return PERIOD_M15;
   if(StringFind(txt, "m1") >= 0 || StringFind(txt, "1 min") >= 0) return PERIOD_M1;
   if(StringFind(txt, "m5") >= 0 || StringFind(txt, "5 min") >= 0) return PERIOD_M5;
   if(StringFind(txt, "h1") >= 0 || StringFind(txt, "1 hora") >= 0) return PERIOD_H1;
   if(StringFind(txt, "d1") >= 0 || StringFind(txt, "diário") >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

void AIOptimizer() { static datetime lr = 0; if(TimeCurrent() - lr < 3600) return; lr = TimeCurrent(); }
double AIPredict() { return 0.5; }

void CalculaStats() {
   HistorySelect(0, TimeCurrent()); int w=0, l=0; double tp=0, dd=0, mp=0, cp=0;
   for(int i=0; i<HistoryDealsTotal(); i++) {
      ulong t = HistoryDealGetTicket(i); if(HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC) {
         double p = HistoryDealGetDouble(t, DEAL_PROFIT); if(p > 0) w++; else if(p < 0) l++; tp += p; cp += p; if(cp > mp) mp = cp; if(mp - cp > dd) dd = mp - cp;
      }
   }
   GravaLog("Stats: WinRate=" + DoubleToString((w+l>0)?(double)w/(w+l):0, 2) + " DD=" + DoubleToString(dd, 2) + " Profit=" + DoubleToString(tp, 2));
}
