//========================================================================
// MT-LiveExecutor - Agente Executor MQL5
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\DealInfo.mqh>
#include <Trade\HistoryOrderInfo.mqh>

//--- Estruturas
enum ENUM_SIGNAL { SIGNAL_NONE=0, SIGNAL_BUY=1, SIGNAL_SELL=-1 };

struct Rule {
   int            type;       // 1:MA, 2:RSI, 3:Stoch, 4:BB, 5:DailyBreak, 6:Delta, 7:Vol, 8:AMA, 9:Bar2, 10:RS, 11:AI
   ENUM_SIGNAL    intent;     // BUY ou SELL
   ENUM_TIMEFRAMES timeframe;
   int            p1, p2, p3;
   double         d1, d2;
   string         s1;
   int            handle1, handle2;

   void Reset() {
      if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease(handle1);
      if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease(handle2);
      type = 0; intent = SIGNAL_NONE; timeframe = PERIOD_CURRENT;
      p1 = 0; p2 = 0; p3 = 0; d1 = 0; d2 = 0; s1 = "";
      handle1 = INVALID_HANDLE; handle2 = INVALID_HANDLE;
   }
};

//--- Globais
Rule     rules[20];
int      nRules = 0;
CTrade   trade;
int      EA_MAGIC = 123456;

// Parâmetros da Estratégia
double   p_riskPercent = 1.0;
int      p_stopPoints = 300;
int      p_takePoints = 500;
int      p_maxTrades = 3;
int      p_beStart = 0;
int      p_bePlus = 0;
int      p_trailingStop = 0;
int      p_trailingStep = 0;
string   p_startTime = "00:00";
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
bool     p_useMartingale = false;

datetime lastPromptUpdate = 0;
datetime lastBarTime = 0;

//--- 1. BIBLIOTECA COMPLETA DE ENTRADAS (MT5-KNOWLEDGE-CORE)
double GetBufferValue(int handle, int buffer, int shift) {
   double val[1];
   if(CopyBuffer(handle, buffer, shift, 1, val) <= 0) return 0;
   return val[0];
}

//--- Utilidades de Parsing
double ExtraiValorApos(string texto, string chave) {
   int pos = StringFind(texto, chave);
   if(pos < 0) return -1;
   int start = pos + StringLen(chave);
   return StringToDouble(StringSubstr(texto, start));
}

int ExtraiNumero(string texto, int &startPos) {
   string num = "";
   bool found = false;
   for(int i = startPos; i < StringLen(texto); i++) {
      ushort c = StringGetCharacter(texto, i);
      if(c >= '0' && c <= '9') {
         num += ShortToString(c);
         found = true;
      } else if(found) {
         startPos = i;
         return (int)StringToInteger(num);
      }
   }
   return (found) ? (int)StringToInteger(num) : 0;
}

ENUM_TIMEFRAMES PeriodoTexto(string texto) {
   if(StringFind(texto, "m15") >= 0 || StringFind(texto, "15 min") >= 0) return PERIOD_M15;
   if(StringFind(texto, "m1") >= 0 || (StringFind(texto, "1 min") >= 0 && StringFind(texto, "15 min") < 0))  return PERIOD_M1;
   if(StringFind(texto, "m5") >= 0 || StringFind(texto, "5 min") >= 0)  return PERIOD_M5;
   if(StringFind(texto, "h1") >= 0 || StringFind(texto, "1 hora") >= 0)  return PERIOD_H1;
   if(StringFind(texto, "d1") >= 0 || StringFind(texto, "diário") >= 0)  return PERIOD_D1;
   return PERIOD_CURRENT;
}

void ResetStrategy() {
   for(int i = 0; i < 20; i++) rules[i].Reset();
   nRules = 0;
}

//--- Interpretador Principal
void InterpretaPrompt(string prompt) {
   string work = prompt;
   StringToLower(work);
   ResetStrategy();

   // Parâmetros Globais
   double r = ExtraiValorApos(work, "risco de ");
   if(r > 0) p_riskPercent = r;

   double st = ExtraiValorApos(work, "stop de ");
   if(st > 0) p_stopPoints = (int)st;

   double tk = ExtraiValorApos(work, "take de ");
   if(tk > 0) p_takePoints = (int)tk;

   if(StringFind(work, "martingale") >= 0) p_useMartingale = true;

   p_frequency = PeriodoTexto(work);

   // Start Time
   int hPos = StringFind(work, "depois das ");
   if(hPos >= 0) {
      int cursor = hPos + 11;
      int hour = ExtraiNumero(work, cursor);
      p_startTime = IntegerToString(hour) + ":00";
   }

   // Breakeven e Trailing
   double be = ExtraiValorApos(work, "atingir +");
   if(be > 0) p_beStart = (int)be;
   double bep = ExtraiValorApos(work, "entrada +");
   if(bep > 0) p_bePlus = (int)bep;

   double tr = ExtraiValorApos(work, "trailing de ");
   if(tr > 0) {
      p_trailingStop = (int)tr;
      p_trailingStep = 10;
   }

   // Quebra o prompt em segmentos
   string segments[];
   string sep = "|";
   StringReplace(work, " e ", sep);
   StringReplace(work, ".", sep);
   StringReplace(work, ",", sep);
   ushort u_sep = StringGetCharacter(sep, 0);
   int total = StringSplit(work, u_sep, segments);

   ENUM_SIGNAL currentIntent = SIGNAL_NONE;

   for(int i = 0; i < total && nRules < 20; i++) {
      string s = segments[i];
      if(StringFind(s, "compra") >= 0) currentIntent = SIGNAL_BUY;
      if(StringFind(s, "vende") >= 0)  currentIntent = SIGNAL_SELL;

      if(currentIntent == SIGNAL_NONE) continue;

      // MA
      if(StringFind(s, " ma ") >= 0 || StringFind(s, "média") >= 0) {
         int cursor = 0;
         int p1 = ExtraiNumero(s, cursor);
         int p2 = ExtraiNumero(s, cursor);
         rules[nRules].type = 1;
         rules[nRules].intent = currentIntent;
         rules[nRules].p1 = (p1 > 0) ? p1 : 20;
         rules[nRules].p2 = p2;
         rules[nRules].timeframe = PeriodoTexto(s);
         rules[nRules].handle1 = iMA(_Symbol, rules[nRules].timeframe, rules[nRules].p1, 0, MODE_SMA, PRICE_CLOSE);
         if(p2 > 0) rules[nRules].handle2 = iMA(_Symbol, rules[nRules].timeframe, rules[nRules].p2, 0, MODE_SMA, PRICE_CLOSE);
         nRules++;
      }
      // RSI
      else if(StringFind(s, "rsi") >= 0) {
         int cursor = 0;
         int p1 = ExtraiNumero(s, cursor);
         int p2 = ExtraiNumero(s, cursor);
         rules[nRules].type = 2;
         rules[nRules].intent = currentIntent;
         if(p2 > 0) { rules[nRules].p1 = p1; rules[nRules].d1 = p2; }
         else { rules[nRules].p1 = 14; rules[nRules].d1 = (p1 > 0) ? p1 : 50; }
         rules[nRules].timeframe = PeriodoTexto(s);
         rules[nRules].handle1 = iRSI(_Symbol, rules[nRules].timeframe, rules[nRules].p1, PRICE_CLOSE);
         nRules++;
      }
      // Stochastic
      else if(StringFind(s, "estocástico") >= 0 || StringFind(s, "stoch") >= 0) {
         rules[nRules].type = 3;
         rules[nRules].intent = currentIntent;
         rules[nRules].timeframe = PeriodoTexto(s);
         rules[nRules].handle1 = iStochastic(_Symbol, rules[nRules].timeframe, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
         nRules++;
      }
      // BB
      else if(StringFind(s, "bollinger") >= 0 || StringFind(s, "bandas") >= 0) {
         rules[nRules].type = 4;
         rules[nRules].intent = currentIntent;
         rules[nRules].timeframe = PeriodoTexto(s);
         rules[nRules].handle1 = iBands(_Symbol, rules[nRules].timeframe, 20, 0, 2.0, PRICE_CLOSE);
         nRules++;
      }
   }
}

//--- Avaliação de Regras
bool AvaliaRegra(Rule &r) {
   if(r.type == 1) { // MA
      if(r.handle2 != INVALID_HANDLE) { // MA vs MA Crossover
         double f1 = GetBufferValue(r.handle1, 0, 1);
         double s1 = GetBufferValue(r.handle2, 0, 1);
         double f2 = GetBufferValue(r.handle1, 0, 2);
         double s2 = GetBufferValue(r.handle2, 0, 2);
         if(r.intent == SIGNAL_BUY) return (f2 < s2 && f1 > s1);
         if(r.intent == SIGNAL_SELL) return (f2 > s2 && f1 < s1);
      } else { // Price vs MA
         double ma1 = GetBufferValue(r.handle1, 0, 1);
         double ma2 = GetBufferValue(r.handle1, 0, 2);
         double c1 = iClose(_Symbol, r.timeframe, 1);
         double c2 = iClose(_Symbol, r.timeframe, 2);
         if(r.intent == SIGNAL_BUY) return (c2 < ma2 && c1 > ma1);
         if(r.intent == SIGNAL_SELL) return (c2 > ma2 && c1 < ma1);
      }
   }
   if(r.type == 2) { // RSI
      double rsi1 = GetBufferValue(r.handle1, 0, 1);
      double rsi2 = GetBufferValue(r.handle1, 0, 2);
      if(r.intent == SIGNAL_BUY) return (rsi2 < r.d1 && rsi1 > r.d1);
      if(r.intent == SIGNAL_SELL) return (rsi2 > r.d1 && rsi1 < r.d1);
   }
   if(r.type == 3) { // Stoch
      double k1 = GetBufferValue(r.handle1, 0, 1);
      double d1 = GetBufferValue(r.handle1, 1, 1);
      double k2 = GetBufferValue(r.handle1, 0, 2);
      double d2 = GetBufferValue(r.handle1, 1, 2);
      if(r.intent == SIGNAL_BUY) return (k2 < d2 && k1 > d1);
      if(r.intent == SIGNAL_SELL) return (k2 > d2 && k1 < d1);
   }
   if(r.type == 4) { // BB
      double close = iClose(_Symbol, r.timeframe, 1);
      double lower = GetBufferValue(r.handle1, 2, 1);
      double upper = GetBufferValue(r.handle1, 1, 1);
      if(r.intent == SIGNAL_BUY) return (close < lower);
      if(r.intent == SIGNAL_SELL) return (close > upper);
   }
   return false;
}

ENUM_SIGNAL AvaliaTudo() {
   if(nRules == 0) return SIGNAL_NONE;
   int buyConfirmations = 0, sellConfirmations = 0;
   int buyRules = 0, sellRules = 0;
   for(int i = 0; i < nRules; i++) {
      if(rules[i].intent == SIGNAL_BUY) { buyRules++; if(AvaliaRegra(rules[i])) buyConfirmations++; }
      else if(rules[i].intent == SIGNAL_SELL) { sellRules++; if(AvaliaRegra(rules[i])) sellConfirmations++; }
   }
   if(buyRules > 0 && buyConfirmations == buyRules) return SIGNAL_BUY;
   if(sellRules > 0 && sellConfirmations == sellRules) return SIGNAL_SELL;
   return SIGNAL_NONE;
}

//--- Gestão de Ordens
double CalculaLote(double riscoPercent) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riscoAbs = capital * riscoPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(p_stopPoints == 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double stopLossValue = p_stopPoints * (tickValue / (tickSize / _Point));
   double lote = NormalizeDouble(riscoAbs / stopLossValue, 2);
   if(p_useMartingale) {
      HistorySelect(TimeCurrent() - 86400, TimeCurrent());
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) lote *= 2.0;
            break;
         }
      }
   }
   double stepLote = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   return MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), NormalizeDouble(lote / stepLote, 0) * stepLote));
}

bool AguardaNoticias() {
   int handle = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_ANSI);
   if(handle != INVALID_HANDLE) {
      string content = FileReadString(handle);
      FileClose(handle);
      if(StringFind(content, "VETO=1") >= 0) return true;
   }
   return false;
}

bool IsTimeAllowed() {
   int hStart = (int)StringToInteger(StringSubstr(p_startTime, 0, 2));
   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.hour < hStart) return false;
   return true;
}

void EnviaOrdem(ENUM_SIGNAL s, string reason) {
   if(s == SIGNAL_NONE || PositionsTotal() >= p_maxTrades || AguardaNoticias() || !IsTimeAllowed()) return;
   double lote = CalculaLote(p_riskPercent);
   trade.SetExpertMagicNumber(EA_MAGIC);
   for(int i = 0; i < 3; i++) {
      double price = (s == SIGNAL_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl = (s == SIGNAL_BUY) ? price - p_stopPoints * _Point : price + p_stopPoints * _Point;
      double tp = (s == SIGNAL_BUY) ? price + p_takePoints * _Point : price - p_takePoints * _Point;
      if(s == SIGNAL_BUY ? trade.Buy(lote, _Symbol, price, sl, tp, reason) : trade.Sell(lote, _Symbol, price, sl, tp, reason)) return;
      int res = trade.ResultRetcode();
      if(res != TRADE_RETCODE_REQUOTES && res != TRADE_RETCODE_OFFQUOTES) break;
      Sleep(100);
   }
}

//--- Gestão de Posições
void GerenciaPosicoes() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
         double open = PositionGetDouble(POSITION_PRICE_OPEN);
         double curSL = PositionGetDouble(POSITION_SL);
         double curPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profitPoints = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? (curPrice - open) / _Point : (open - curPrice) / _Point;
         // Breakeven
         if(p_beStart > 0 && profitPoints >= p_beStart) {
            double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? open + p_bePlus * _Point : open - p_bePlus * _Point;
            if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && (curSL < open || curSL == 0)) || (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (curSL > open || curSL == 0)))
               trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
         }
         // Trailing Stop
         if(p_trailingStop > 0 && profitPoints >= p_trailingStop) {
            double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? curPrice - p_trailingStop * _Point : curPrice + p_trailingStop * _Point;
            if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && newSL > curSL + p_trailingStep * _Point) || (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (newSL < curSL - p_trailingStep * _Point || curSL == 0)))
               trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
         }
      }
   }
}

void GravaCSV() {
   int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_ANSI);
   if(handle != INVALID_HANDLE) {
      FileWrite(handle, "Ticket", "Symbol", "Type", "Volume", "PriceOpen", "SL", "TP", "Profit");
      for(int i = 0; i < PositionsTotal(); i++) {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC)
            FileWrite(handle, ticket, _Symbol, (int)PositionGetInteger(POSITION_TYPE), PositionGetDouble(POSITION_VOLUME), PositionGetDouble(POSITION_PRICE_OPEN), PositionGetDouble(POSITION_SL), PositionGetDouble(POSITION_TP), PositionGetDouble(POSITION_PROFIT));
      }
      FileClose(handle);
   }
}

//--- Handlers MQL5
int OnInit() { EventSetTimer(1); return INIT_SUCCEEDED; }
void OnDeinit(const int reason) { EventKillTimer(); ResetStrategy(); }
void OnTimer() {
   datetime mod = (datetime)FileGetInteger("prompt.txt", FILE_MODIFY_DATE);
   if(mod > lastPromptUpdate) {
      int handle = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_ANSI);
      if(handle != INVALID_HANDLE) { string p = FileReadString(handle); FileClose(handle); InterpretaPrompt(p); lastPromptUpdate = mod; }
   }
}
void OnTick() {
   GravaCSV(); GerenciaPosicoes();
   datetime curBar = iTime(_Symbol, p_frequency, 0);
   if(curBar != lastBarTime) { ENUM_SIGNAL s = AvaliaTudo(); if(s != SIGNAL_NONE) EnviaOrdem(s, "MT-Live Signal"); lastBarTime = curBar; }
}
