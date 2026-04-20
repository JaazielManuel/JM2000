//=========================  MT5-KNOWLEDGE-CORE  =========================
// MT-LiveExecutor: Agente de Execução Direta via Prompt NLP
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// Enumeração de sinais
enum Signal {BUY=1, SELL=-1, NONE=0};

// Estrutura para armazenar as regras interpretadas
struct Rule {
   bool       active;
   uint       tf;
   int        p1, p2, p3;
   double     d1, d2;
   string     s1;
   Signal     intent;
   int        handle1, handle2;
   int        type; // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: DailyBreak, 6: Delta, 7: Vol, 8: AMA, 9: Bar2, 10: RS
};

// Variáveis Globais de Configuração
string   p_currentPrompt = "";
Rule     p_rules[30];
int      p_nRules = 0;
double   p_riskPercent = 1.0;
int      p_stopPoints = 300;
int      p_takePoints = 500;
int      p_maxTrades = 3;
int      p_beStart = 0;
int      p_bePlus = 0;
int      p_trailingStart = 0;
int      p_trailingStep = 10;
bool     p_useMartingale = false;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
int      p_startHour = 0;
int      p_endHour = 24;

uint     EA_MAGIC = 123456;
CTrade   trade;

// --- BIBLIOTECA DE ENTRADAS ---

double GetBufferValue(int handle, int buffer, int shift) {
   if(handle == INVALID_HANDLE || handle == 0) return 0;
   double arr[]; ArraySetAsSeries(arr, true);
   if(CopyBuffer(handle, buffer, shift, 1, arr) > 0) return arr[0];
   return 0;
}

Signal EvalRule(int i, int shift) {
   Rule r = p_rules[i];
   if(!r.active) return NONE;

   switch(r.type) {
      case 1: { // MA
         double v1 = GetBufferValue(r.handle1, 0, shift);
         double v2 = GetBufferValue(r.handle1, 0, shift+1);
         if(r.handle2 != INVALID_HANDLE) {
            double s1 = GetBufferValue(r.handle2, 0, shift);
            double s2 = GetBufferValue(r.handle2, 0, shift+1);
            if(v2 < s2 && v1 > s1) return BUY;
            if(v2 > s2 && v1 < s1) return SELL;
         } else {
            double p1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
            double p2 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift+1);
            if(p2 < v2 && p1 > v1) return BUY;
            if(p2 > v2 && p1 < v1) return SELL;
         }
         break;
      }
      case 2: { // RSI
         double v = GetBufferValue(r.handle1, 0, shift);
         if(r.intent == BUY && v > r.d1) return BUY;
         if(r.intent == SELL && v < r.d1) return SELL;
         if(r.intent == NONE) {
            if(v > 70) return SELL;
            if(v < 30) return BUY;
         }
         break;
      }
      case 3: { // Stoch
         double k1 = GetBufferValue(r.handle1, 0, shift);
         double d1 = GetBufferValue(r.handle1, 1, shift);
         double k2 = GetBufferValue(r.handle1, 0, shift+1);
         double d2 = GetBufferValue(r.handle1, 1, shift+1);
         if(k2 < d2 && k1 > d1) return BUY;
         if(k2 > d2 && k1 < d1) return SELL;
         break;
      }
      case 4: { // BB
         double up = GetBufferValue(r.handle1, 1, shift);
         double lo = GetBufferValue(r.handle1, 2, shift);
         double close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
         if(close < lo) return BUY;
         if(close > up) return SELL;
         break;
      }
      case 5: { // Daily Break
         double hi = iHigh(_Symbol, PERIOD_D1, 1);
         double lo = iLow(_Symbol, PERIOD_D1, 1);
         double close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
         if(close > hi) return BUY;
         if(close < lo) return SELL;
         break;
      }
   }
   return NONE;
}

// --- Funções de Sistema ---

void ResetStrategy() {
   for(int i=0; i<30; i++) {
      if(p_rules[i].handle1 != INVALID_HANDLE && p_rules[i].handle1 != 0) IndicatorRelease(p_rules[i].handle1);
      if(p_rules[i].handle2 != INVALID_HANDLE && p_rules[i].handle2 != 0) IndicatorRelease(p_rules[i].handle2);
   }
   ZeroMemory(p_rules);
   p_nRules = 0; p_riskPercent = 1.0; p_stopPoints = 300; p_takePoints = 500;
   p_maxTrades = 3; p_beStart = 0; p_bePlus = 0; p_trailingStart = 0;
   p_trailingStep = 10; p_useMartingale = false; p_frequency = PERIOD_M15;
   p_startHour = 0; p_endHour = 24;
}

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   string norm = prompt; StringToLower(norm);

   p_stopPoints = (int)StringToInteger(ExtraiValorApos(norm, "stop de")); if(p_stopPoints == 0) p_stopPoints = 300;
   p_takePoints = (int)StringToInteger(ExtraiValorApos(norm, "take de")); if(p_takePoints == 0) p_takePoints = 500;
   string rStr = ExtraiValorApos(norm, "risco de"); if(rStr != "") p_riskPercent = ExtraiNumero(rStr);
   if(StringFind(norm, "martingale") >= 0) p_useMartingale = true;
   string mStr = ExtraiValorApos(norm, "máximo"); if(mStr != "") p_maxTrades = (int)StringToInteger(mStr);
   if(StringFind(norm, "move stop para entrada") >= 0) {
      p_beStart = (int)StringToInteger(ExtraiValorApos(norm, "atingir +"));
      p_bePlus = (int)StringToInteger(ExtraiValorApos(norm, "entrada +"));
   }
   string tsStr = ExtraiValorApos(norm, "trailing stop de"); if(tsStr == "") tsStr = ExtraiValorApos(norm, "atingir +");
   if(tsStr != "") p_trailingStart = (int)StringToInteger(tsStr);
   p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(ExtraiValorApos(norm, "a cada"));
   string hStr = ExtraiValorApos(norm, "depois das"); if(hStr != "") p_startHour = (int)StringToInteger(hStr);

   string segments[]; StringReplace(norm, " e ", "|"); StringReplace(norm, ".", "|"); StringReplace(norm, ",", "|");
   int nSeg = StringSplit(norm, StringGetCharacter("|", 0), segments);
   Signal curIntent = NONE;
   for(int i=0; i<nSeg && p_nRules < 30; i++) {
      string seg = segments[i]; StringTrimLeft(seg); StringTrimRight(seg); if(seg == "") continue;
      if(StringFind(seg, "compra") >= 0) curIntent = BUY; else if(StringFind(seg, "vende") >= 0) curIntent = SELL;

      if(StringFind(seg, "média") >= 0 || StringFind(seg, " ma ") >= 0) {
         p_rules[p_nRules].active = true; p_rules[p_nRules].type = 1; p_rules[p_nRules].intent = curIntent; p_rules[p_nRules].tf = p_frequency;
         int p1 = (int)ExtraiNumero(seg); if(p1 == 0) p1 = 20;
         p_rules[p_nRules].handle1 = iMA(_Symbol, p_frequency, p1, 0, MODE_EMA, PRICE_CLOSE);
         int slash = StringFind(seg, "/");
         if(slash >= 0) p_rules[p_nRules].handle2 = iMA(_Symbol, p_frequency, (int)ExtraiNumero(seg, slash+1), 0, MODE_EMA, PRICE_CLOSE);
         p_nRules++;
      } else if(StringFind(seg, "rsi") >= 0) {
         p_rules[p_nRules].active = true; p_rules[p_nRules].type = 2; p_rules[p_nRules].intent = curIntent; p_rules[p_nRules].tf = p_frequency;
         int per = (int)ExtraiNumero(seg); if(per == 0) per = 14;
         p_rules[p_nRules].handle1 = iRSI(_Symbol, p_frequency, per, PRICE_CLOSE);
         p_rules[p_nRules].d1 = ExtraiNumero(seg, StringFind(seg, "de")+2);
         p_nRules++;
      } else if(StringFind(seg, "estocástico") >= 0) {
         p_rules[p_nRules].active = true; p_rules[p_nRules].type = 3; p_rules[p_nRules].intent = curIntent; p_rules[p_nRules].tf = p_frequency;
         p_rules[p_nRules].handle1 = iStochastic(_Symbol, p_frequency, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
         p_nRules++;
      } else if(StringFind(seg, "bollinger") >= 0) {
         p_rules[p_nRules].active = true; p_rules[p_nRules].type = 4; p_rules[p_nRules].intent = curIntent; p_rules[p_nRules].tf = p_frequency;
         p_rules[p_nRules].handle1 = iBands(_Symbol, p_frequency, 20, 0, 2.0, PRICE_CLOSE);
         p_nRules++;
      } else if(StringFind(seg, "rompimento diário") >= 0) {
         p_rules[p_nRules].active = true; p_rules[p_nRules].type = 5; p_rules[p_nRules].intent = curIntent; p_rules[p_nRules].tf = p_frequency;
         p_nRules++;
      }
   }
}

Signal AvaliaTudo() {
   int bV = 0, sV = 0, aB = 0, aS = 0;
   for(int i=0; i<p_nRules; i++) {
      Signal s = EvalRule(i, 1);
      if(p_rules[i].intent == BUY || p_rules[i].intent == NONE) { aB++; if(s == BUY) bV++; }
      if(p_rules[i].intent == SELL || p_rules[i].intent == NONE) { aS++; if(s == SELL) sV++; }
   }
   if(aB > 0 && bV == aB) return BUY; if(aS > 0 && sV == aS) return SELL;
   return NONE;
}

double CalculaLote(double risk) {
   double cap = AccountInfoDouble(ACCOUNT_EQUITY);
   double tickV = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickS = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lot = (cap * risk / 100.0) / (p_stopPoints * (tickV / (tickS / _Point)));
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / step) * step;
   return MathMax(lot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
}

void EnviaOrdem(Signal s, string r) {
   if(PositionsTotal() >= p_maxTrades) return;
   double lot = CalculaLote(p_riskPercent);
   if(p_useMartingale && HistorySelect(0, TimeCurrent())) {
      for(int i=HistoryDealsTotal()-1; i>=0; i--) {
         ulong t = HistoryDealGetTicket(i);
         if(HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC) { if(HistoryDealGetDouble(t, DEAL_PROFIT) < 0) lot *= 2; break; }
      }
   }
   double sl = (s==BUY)?SymbolInfoDouble(_Symbol, SYMBOL_ASK)-p_stopPoints*_Point:SymbolInfoDouble(_Symbol, SYMBOL_BID)+p_stopPoints*_Point;
   double tp = (s==BUY)?SymbolInfoDouble(_Symbol, SYMBOL_ASK)+p_takePoints*_Point:SymbolInfoDouble(_Symbol, SYMBOL_BID)-p_takePoints*_Point;
   if(s==BUY) trade.Buy(lot, _Symbol, 0, sl, tp, r); else trade.Sell(lot, _Symbol, 0, sl, tp, r);
   if(trade.ResultRetcode() == TRADE_RETCODE_DONE) {
      string msg = (s==BUY?"COMPRA":"VENDA") + " executada: " + _Symbol + " Lote: " + DoubleToString(lot, 2);
      GravaLog(msg);
      SendNotification(msg);
   } else {
      GravaLog("Erro na execução: " + (string)trade.ResultRetcode() + " - " + trade.ResultComment());
   }
}

void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      CPositionInfo pos; if(!pos.SelectByIndex(i) || pos.Magic() != EA_MAGIC) continue;
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double cur = (pos.PositionType()==POSITION_TYPE_BUY)?bid:ask;
      double pnt = (pos.PositionType()==POSITION_TYPE_BUY)?(cur-pos.PriceOpen())/_Point:(pos.PriceOpen()-cur)/_Point;
      if(p_beStart > 0 && pnt >= p_beStart) {
         double nsl = (pos.PositionType()==POSITION_TYPE_BUY)?pos.PriceOpen()+p_bePlus*_Point:pos.PriceOpen()-p_bePlus*_Point;
         if(pos.StopLoss() != nsl) trade.PositionModify(pos.Ticket(), nsl, pos.TakeProfit());
      }
      if(p_trailingStart > 0 && pnt >= p_trailingStart) {
         double nsl = (pos.PositionType()==POSITION_TYPE_BUY)?bid-p_trailingStart*_Point:ask+p_trailingStart*_Point;
         if(MathAbs(nsl-pos.StopLoss()) > p_trailingStep*_Point) trade.PositionModify(pos.Ticket(), nsl, pos.TakeProfit());
      }
   }
}

bool AguardaNoticias() {
   int h = FileOpen("news_veto.txt", FILE_READ|FILE_TXT); if(h == INVALID_HANDLE) return false;
   string c = FileReadString(h); FileClose(h); if(c == "1") return true;
   datetime v = StringToTime(c); return (v > 0 && TimeCurrent() >= v - 1200 && TimeCurrent() <= v + 1200);
}

void GravaLog(string t) {
   int h = FileOpen("MT_LiveExecutor_Log.txt", FILE_READ|FILE_WRITE|FILE_TXT);
   if(h != INVALID_HANDLE) { FileSeek(h, 0, SEEK_END); FileWriteString(h, TimeToString(TimeCurrent()) + ": " + t + "\n"); FileClose(h); }
   Print(t);
}

void GravaCSV() {
   int h = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV);
   if(h != INVALID_HANDLE) {
      FileWrite(h, "Ticket", "Symbol", "Type", "Open", "SL", "TP", "Profit");
      for(int i=0; i<PositionsTotal(); i++) {
         CPositionInfo p; if(p.SelectByIndex(i) && p.Magic() == EA_MAGIC)
            FileWrite(h, p.Ticket(), p.Symbol(), p.PositionType(), p.PriceOpen(), p.StopLoss(), p.TakeProfit(), p.Profit());
      }
      FileClose(h);
   }
}

void CalculaEstatisticas() {
   if(!HistorySelect(0, TimeCurrent())) return;
   int tot = 0, win = 0; double gp = 0, gl = 0;
   for(int i=0; i<HistoryDealsTotal(); i++) {
      ulong t = HistoryDealGetTicket(i); if(HistoryDealGetInteger(t, DEAL_MAGIC) != EA_MAGIC) continue;
      double p = HistoryDealGetDouble(t, DEAL_PROFIT); if(p == 0) continue;
      tot++; if(p > 0) { win++; gp += p; } else gl -= p;
   }
   if(tot >= 10) {
      double wr = (double)win/tot; if(wr < 0.4) p_riskPercent = MathMax(0.1, p_riskPercent - 0.1);
      else if(wr > 0.6) p_riskPercent = MathMin(2.0, p_riskPercent + 0.1);
   }
}

int PeriodoTexto(string n) { if(StringFind(n, "15")>=0) return PERIOD_M15; if(StringFind(n, "1")>=0) return PERIOD_M1; return PERIOD_M15; }
double ExtraiNumero(string t, int s=0) {
   string r = ""; bool f = false; for(int i=s; i<StringLen(t); i++) {
      ushort c = StringGetCharacter(t, i); if((c>='0' && c<='9')||c=='.') { r+=CharToString((uchar)c); f=true; } else if(f) break;
   } return StringToDouble(r);
}
string ExtraiValorApos(string t, string k) {
   int p = StringFind(t, k); if(p<0) return ""; string s = StringSubstr(t, p+StringLen(k)); StringTrimLeft(s);
   int e = StringFind(s, " "); return (e<0)?s:StringSubstr(s, 0, e);
}

int OnInit() { trade.SetExpertMagicNumber(EA_MAGIC); EventSetTimer(1); ResetStrategy(); return(INIT_SUCCEEDED); }
void OnDeinit(const int r) { EventKillTimer(); ResetStrategy(); }
void OnTick() {
   static datetime lb = 0; datetime cb = iTime(_Symbol, p_frequency, 0); GerenciaPosicoes();
   if(cb == lb) return; lb = cb; MqlDateTime dt; TimeCurrent(dt);
   if(dt.hour < p_startHour || dt.hour >= p_endHour || AguardaNoticias()) return;
   Signal s = AvaliaTudo(); if(s != NONE) EnviaOrdem(s, "NLP");
}
void OnTimer() {
   int h = FileOpen("prompt.txt", FILE_READ|FILE_TXT);
   if(h != INVALID_HANDLE) { string p = FileReadString(h); FileClose(h); if(p != "" && p != p_currentPrompt) { p_currentPrompt = p; InterpretaPrompt(p); } }
   static int c = 0; if(++c % 5 == 0) GravaCSV(); if(c % 3600 == 0) CalculaEstatisticas();
}
