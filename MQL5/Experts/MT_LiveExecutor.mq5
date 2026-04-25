//=========================  MT5-KNOWLEDGE-CORE  =========================
// MT-LiveExecutor - Advanced MQL5 Execution Agent
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\DealInfo.mqh>
#include <Trade\HistoryOrderInfo.mqh>
#include <Indicators\Indicators.mqh>

// ---------- DEFINES & ENUMS ----------
#define EA_MAGIC 123456
#define LOG_FILE "MT_LiveExecutor_Log.txt"
#define STATE_FILE "MT_LiveExecutor_State.csv"
#define NEWS_FILE "news_veto.txt"
#define PROMPT_FILE "prompt.txt"

enum Signal {BUY=1, SELL=-1, NONE=0};

enum RuleType {
   RT_NONE=0,
   RT_MA=1,
   RT_RSI=2,
   RT_STOCH=3,
   RT_BB=4,
   RT_DAILYBREAK=5,
   RT_DELTA=6,
   RT_VOL=7,
   RT_AMA=8,
   RT_BAR2=9,
   RT_RS=10,
   RT_AI_PRED=11
};

struct Rule {
   bool      active;
   RuleType  type;
   Signal    intent; // BUY, SELL or NONE (filter)
   int       handle1;
   int       handle2;
   int       p1, p2, p3;
   double    d1, d2;
   string    s1;
   ENUM_TIMEFRAMES tf;
};

// ---------- GLOBAL PARAMETERS ----------
Rule rules[20];
int nRules = 0;

double p_riskPercent = 1.0;
int    p_stopPoints = 300;
int    p_takePoints = 500;
int    p_maxTrades = 3;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
string p_startTime = "00:00";
bool   p_useMartingale = false;
int    p_beStart = 0;
int    p_bePlus = 0;
int    p_trailingStart = 0;
int    p_trailingStep = 10;

string currentPrompt = "";
datetime lastTickTime = 0;
datetime lastBarTime = 0;
CTrade trade;

// ---------- HELPER UTILITIES ----------

double GetBufferValue(int handle, int buffer, int shift) {
   double val[];
   ArraySetAsSeries(val, true);
   if(CopyBuffer(handle, buffer, shift, 1, val) <= 0) return 0;
   return val[0];
}

double NormalizeVolume(double volume) {
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double res = MathFloor(volume / stepVol) * stepVol;
   if(res < minVol) res = minVol;
   if(res > maxVol) res = maxVol;
   return NormalizeDouble(res, 2);
}

void GravaLog(string texto) {
   int h = FileOpen(LOG_FILE, FILE_WRITE|FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      FileSeek(h, 0, SEEK_END);
      FileWriteString(h, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + ": " + texto + "\n");
      FileClose(h);
   }
   Print(texto);
}

// ---------- NLP PARSING MODULE ----------

void ResetStrategy() {
   for(int i=0; i<nRules; i++) {
      if(rules[i].handle1 != INVALID_HANDLE && rules[i].handle1 != 0) IndicatorRelease(rules[i].handle1);
      if(rules[i].handle2 != INVALID_HANDLE && rules[i].handle2 != 0) IndicatorRelease(rules[i].handle2);
   }
   nRules = 0;
   ZeroMemory(rules);
   p_riskPercent = 1.0;
   p_stopPoints = 300;
   p_takePoints = 500;
   p_maxTrades = 3;
   p_frequency = PERIOD_M15;
   p_startTime = "00:00";
   p_useMartingale = false;
   p_beStart = 0;
   p_bePlus = 0;
   p_trailingStart = 0;
   p_trailingStep = 10;
}

double ExtraiNumero(string txt, int &endPos) {
   string res = "";
   bool found = false;
   int start = endPos;
   for(int i=start; i<StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.') {
         res += CharToString((char)c);
         found = true;
      } else if(found) {
         endPos = i;
         return StringToDouble(res);
      }
   }
   endPos = StringLen(txt);
   return found ? StringToDouble(res) : 0;
}

double ExtraiValorApos(string txt, string keyword) {
   int pos = StringFind(txt, keyword);
   if(pos < 0) return 0;
   int endPos = pos + StringLen(keyword);
   return ExtraiNumero(txt, endPos);
}

string ExtractTime(string txt) {
   int pos = StringFind(txt, "h");
   if(pos < 0) return "00:00";

   // Formato 10h30 ou 10h
   string h = "", m = "00";
   int i = pos - 1;
   while(i >= 0 && StringGetCharacter(txt, i) >= '0' && StringGetCharacter(txt, i) <= '9') {
      h = CharToString((char)StringGetCharacter(txt, i)) + h;
      i--;
   }

   i = pos + 1;
   string m_tmp = "";
   while(i < StringLen(txt) && StringGetCharacter(txt, i) >= '0' && StringGetCharacter(txt, i) <= '9') {
      m_tmp += CharToString((char)StringGetCharacter(txt, i));
      i++;
   }
   if(StringLen(m_tmp) > 0) m = m_tmp;
   if(StringLen(h) == 1) h = "0" + h;
   if(StringLen(m) == 1) m = "0" + m;

   return h + ":" + m;
}

ENUM_TIMEFRAMES PeriodoTexto(string txt) {
   string t = txt;
   StringToLower(t);
   if(StringFind(t, "1 minuto") >= 0 || StringFind(t, "m1") >= 0) return PERIOD_M1;
   if(StringFind(t, "5 minuto") >= 0 || StringFind(t, "m5") >= 0) return PERIOD_M5;
   if(StringFind(t, "15 minuto") >= 0 || StringFind(t, "m15") >= 0) return PERIOD_M15;
   if(StringFind(t, "30 minuto") >= 0 || StringFind(t, "m30") >= 0) return PERIOD_M30;
   if(StringFind(t, "1 hora") >= 0 || StringFind(t, "h1") >= 0) return PERIOD_H1;
   if(StringFind(t, "4 hora") >= 0 || StringFind(t, "h4") >= 0) return PERIOD_H4;
   if(StringFind(t, "diario") >= 0 || StringFind(t, "d1") >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   string p = prompt;
   StringToLower(p);

   // Global Frequency
   p_frequency = PeriodoTexto(p);

   // Split into segments
   string segments[];
   string tmp = p;
   StringReplace(tmp, " e ", "|");
   StringReplace(tmp, ".", "|");
   StringReplace(tmp, ",", "|");
   int total = StringSplit(tmp, '|', segments);

   Signal currentIntent = NONE;

   for(int i=0; i<total; i++) {
      string s = segments[i];
      StringTrimLeft(s); StringTrimRight(s);
      if(StringLen(s) == 0) continue;

      if(StringFind(s, "compra") >= 0) currentIntent = BUY;
      else if(StringFind(s, "vende") >= 0) currentIntent = SELL;

      Rule r;
      ZeroMemory(r);
      r.intent = currentIntent;
      r.tf = PeriodoTexto(s);
      if(r.tf == PERIOD_CURRENT) r.tf = p_frequency;

      bool added = false;

      if(StringFind(s, " ma ") >= 0 || StringFind(s, "média") >= 0) {
         r.type = RT_MA;
         int dummy = 0;
         r.p1 = (int)ExtraiNumero(s, dummy); // period
         if(r.p1 == 0) r.p1 = 20;
         // Check for dual MA
         int pos = StringFind(s, "/");
         if(pos > 0) {
            int end = pos + 1;
            r.p2 = (int)ExtraiNumero(s, end);
            r.handle1 = iMA(_Symbol, r.tf, r.p1, 0, MODE_SMA, PRICE_CLOSE);
            r.handle2 = iMA(_Symbol, r.tf, r.p2, 0, MODE_SMA, PRICE_CLOSE);
         } else {
            r.handle1 = iMA(_Symbol, r.tf, r.p1, 0, MODE_SMA, PRICE_CLOSE);
         }
         added = true;
      }
      else if(StringFind(s, "rsi") >= 0) {
         r.type = RT_RSI;
         int dummy = 0;
         double n1 = ExtraiNumero(s, dummy);
         double n2 = ExtraiNumero(s, dummy);
         if(n1 < 40) { r.p1 = (int)n1; r.d1 = n2; }
         else { r.p1 = 14; r.d1 = n1; }
         if(r.p1 == 0) r.p1 = 14;
         if(r.d1 == 0) r.d1 = (currentIntent == BUY) ? 30 : 70;
         r.handle1 = iRSI(_Symbol, r.tf, r.p1, PRICE_CLOSE);
         added = true;
      }
      else if(StringFind(s, "estocástico") >= 0 || StringFind(s, "stoch") >= 0) {
         r.type = RT_STOCH;
         r.handle1 = iStochastic(_Symbol, r.tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
         added = true;
      }
      else if(StringFind(s, "bollinger") >= 0 || StringFind(s, "bb") >= 0) {
         r.type = RT_BB;
         r.handle1 = iBands(_Symbol, r.tf, 20, 0, 2.0, PRICE_CLOSE);
         added = true;
      }
      else if(StringFind(s, "rompimento diário") >= 0) {
         r.type = RT_DAILYBREAK;
         added = true;
      }
      else if(StringFind(s, "delta") >= 0) {
         r.type = RT_DELTA;
         added = true;
      }
      else if(StringFind(s, "volume") >= 0) {
         r.type = RT_VOL;
         added = true;
      }
      else if(StringFind(s, "ama") >= 0 || StringFind(s, "adaptativa") >= 0) {
         r.type = RT_AMA;
         r.handle1 = iAMA(_Symbol, r.tf, 10, 2, 30, 0, PRICE_CLOSE);
         added = true;
      }
      else if(StringFind(s, "padrão barras") >= 0) {
         r.type = RT_BAR2;
         added = true;
      }
      else if(StringFind(s, "força relativa") >= 0) {
         r.type = RT_RS;
         r.handle1 = iRSI(_Symbol, r.tf, 14, PRICE_CLOSE);
         r.handle2 = iRSI("US30", r.tf, 14, PRICE_CLOSE);
         added = true;
      }
      else if(StringFind(s, "previsão") >= 0 || StringFind(s, "ai") >= 0) {
         r.type = RT_AI_PRED;
         r.handle1 = iATR(_Symbol, r.tf, 14);
         added = true;
      }

      if(added && nRules < 20) {
         r.active = true;
         rules[nRules] = r;
         nRules++;
      }
   }

   // Global parameters
   p_riskPercent = ExtraiValorApos(p, "risco de");
   if(p_riskPercent == 0) p_riskPercent = 1.0;

   p_stopPoints = (int)ExtraiValorApos(p, "stop de");
   if(p_stopPoints == 0) p_stopPoints = 300;

   p_takePoints = (int)ExtraiValorApos(p, "take de");
   if(p_takePoints == 0) p_takePoints = 500;

   p_maxTrades = (int)ExtraiValorApos(p, "máximo");
   if(p_maxTrades == 0) p_maxTrades = 3;

   p_startTime = ExtractTime(p);

   if(StringFind(p, "martingale") >= 0) p_useMartingale = true;

   p_beStart = (int)ExtraiValorApos(p, "atingir +");
   p_bePlus = (int)ExtraiValorApos(p, "entrada +");

   p_trailingStart = (int)ExtraiValorApos(p, "trailing de");
}


// ---------- SIGNAL EVALUATION FUNCTIONS ----------

Signal AvaliaRegra(Rule &r) {
   switch(r.type) {
      case RT_MA: {
         if(r.handle2 != INVALID_HANDLE && r.handle2 != 0) {
            double f1 = GetBufferValue(r.handle1, 0, 1);
            double s1 = GetBufferValue(r.handle2, 0, 1);
            double f2 = GetBufferValue(r.handle1, 0, 2);
            double s2 = GetBufferValue(r.handle2, 0, 2);
            if(f2 < s2 && f1 > s1) return BUY;
            if(f2 > s2 && f1 < s1) return SELL;
         } else {
            double ma = GetBufferValue(r.handle1, 0, 1);
            double close = iClose(_Symbol, r.tf, 1);
            double prevMa = GetBufferValue(r.handle1, 0, 2);
            double prevClose = iClose(_Symbol, r.tf, 2);
            if(prevClose < prevMa && close > ma) return BUY;
            if(prevClose > prevMa && close < ma) return SELL;
         }
         break;
      }
      case RT_RSI: {
         double v = GetBufferValue(r.handle1, 0, 1);
         if(r.intent == BUY && v > r.d1) return BUY;
         if(r.intent == SELL && v < r.d1) return SELL;
         break;
      }
      case RT_STOCH: {
         double k1 = GetBufferValue(r.handle1, 0, 1);
         double d1 = GetBufferValue(r.handle1, 1, 1);
         double k2 = GetBufferValue(r.handle1, 0, 2);
         double d2 = GetBufferValue(r.handle1, 1, 2);
         if(k2 < d2 && k1 > d1) return BUY;
         if(k2 > d2 && k1 < d1) return SELL;
         break;
      }
      case RT_BB: {
         double close = iClose(_Symbol, r.tf, 1);
         double upper = GetBufferValue(r.handle1, 1, 1);
         double lower = GetBufferValue(r.handle1, 2, 1);
         if(close < lower) return BUY;
         if(close > upper) return SELL;
         break;
      }
      case RT_AMA: {
         double ama1 = GetBufferValue(r.handle1, 0, 1);
         double ama2 = GetBufferValue(r.handle1, 0, 2);
         if(ama1 > ama2) return BUY;
         if(ama1 < ama2) return SELL;
         break;
      }
      case RT_AI_PRED: {
         double atr = GetBufferValue(r.handle1, 0, 1);
         double body = MathAbs(iClose(_Symbol, r.tf, 1) - iOpen(_Symbol, r.tf, 1));
         if(body > 1.5 * atr) {
            return (iClose(_Symbol, r.tf, 1) > iOpen(_Symbol, r.tf, 1)) ? BUY : SELL;
         }
         break;
      }
      case RT_DAILYBREAK: {
         double hi = iHigh(_Symbol, PERIOD_D1, 1);
         double lo = iLow(_Symbol, PERIOD_D1, 1);
         double close = iClose(_Symbol, r.tf, 1);
         if(close > hi) return BUY;
         if(close < lo) return SELL;
         break;
      }
      case RT_VOL: {
         long v1 = iVolume(_Symbol, r.tf, 1);
         long v2 = iVolume(_Symbol, r.tf, 2);
         if(v1 > v2) return (iClose(_Symbol, r.tf, 1) > iOpen(_Symbol, r.tf, 1)) ? BUY : SELL;
         break;
      }
      case RT_BAR2: {
         double h0=iHigh(_Symbol, r.tf, 1);
         double l0=iLow(_Symbol, r.tf, 1);
         double h1=iHigh(_Symbol, r.tf, 2);
         double l1=iLow(_Symbol, r.tf, 2);
         if(h0<h1 && l0>l1) return (iClose(_Symbol, r.tf, 1)>iOpen(_Symbol, r.tf, 1))? BUY : SELL;
         if(h0>h1 && l0<l1) return (iClose(_Symbol, r.tf, 1)>iOpen(_Symbol, r.tf, 1))? SELL: BUY;
         break;
      }
   }
   return NONE;
}

Signal AvaliaTudo() {
   int buyLeg = 0, sellLeg = 0;
   int buyRules = 0, sellRules = 0;

   for(int i=0; i<nRules; i++) {
      Signal s = AvaliaRegra(rules[i]);
      if(rules[i].intent == BUY) {
         buyRules++;
         if(s == BUY) buyLeg++;
      }
      else if(rules[i].intent == SELL) {
         sellRules++;
         if(s == SELL) sellLeg++;
      }
      else { // Neutral filter
         if(s == BUY) { buyLeg++; sellLeg--; }
         else if(s == SELL) { buyLeg--; sellLeg++; }
         buyRules++; sellRules++;
      }
   }

   if(buyRules > 0 && buyLeg == buyRules) return BUY;
   if(sellRules > 0 && sellLeg == sellRules) return SELL;
   return NONE;
}


// ---------- TRADE EXECUTION & RISK MANAGEMENT ----------

bool AguardaNoticias() {
   int h = FileOpen(NEWS_FILE, FILE_READ|FILE_TXT|FILE_COMMON);
   if(h == INVALID_HANDLE) return false;

   string content = FileReadString(h);
   FileClose(h);

   if(content == "1") return true;

   datetime eventTime = StringToTime(content);
   if(eventTime > 0) {
      if(TimeCurrent() >= eventTime - 20*60 && TimeCurrent() <= eventTime + 20*60) return true;
   }
   return false;
}

double CalculaLote(double riscoPercent) {
   double capital = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double riskAmount = capital * riscoPercent / 100.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(p_stopPoints <= 0) return NormalizeVolume(0.1);

   double lot = riskAmount / (p_stopPoints * (tickValue / (tickSize / _Point)));

   if(p_useMartingale) {
      HistorySelect(TimeCurrent() - 24*3600, TimeCurrent());
      int total = HistoryDealsTotal();
      for(int i=total-1; i>=0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) lot *= 2.0;
            break;
         }
      }
   }

   return NormalizeVolume(lot);
}

void EnviaOrdem(Signal s, string reason) {
   if(PositionsTotal() >= p_maxTrades) return;
   if(AguardaNoticias()) {
      GravaLog("Veto de notícias ativo. Ordem ignorada.");
      return;
   }

   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = (s == BUY) ? price - p_stopPoints * _Point : price + p_stopPoints * _Point;
   double tp = (s == BUY) ? price + p_takePoints * _Point : price - p_takePoints * _Point;
   double lot = CalculaLote(p_riskPercent);

   double margin;
   if(!OrderCalcMargin((s == BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL), _Symbol, lot, price, margin)) {
      GravaLog("Erro ao calcular margem.");
      return;
   }
   if(margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE)) {
      GravaLog("Margem insuficiente.");
      return;
   }

   trade.SetExpertMagicNumber(EA_MAGIC);
   bool res = false;
   if(s == BUY) res = trade.Buy(lot, _Symbol, price, sl, tp, reason);
   else res = trade.Sell(lot, _Symbol, price, sl, tp, reason);

   if(res) {
      GravaLog("Ordem enviada: " + reason + " | Lote: " + DoubleToString(lot, 2));
   } else {
      GravaLog("Erro ao enviar ordem: " + (string)trade.ResultRetcode() + " - " + trade.ResultComment());
   }
}


// ---------- POSITION MANAGEMENT, PERSISTENCE & OPTIMIZATION ----------

void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(PositionSelectByTicket(PositionGetTicket(i))) {
         if(PositionGetInteger(POSITION_MAGIC) != EA_MAGIC) continue;

         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double curSL = PositionGetDouble(POSITION_SL);
         double curPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         int type = (int)PositionGetInteger(POSITION_TYPE);

         // Break-even
         if(p_beStart > 0 && curSL != (openPrice + p_bePlus * _Point)) {
            double profitPoints = (type == POSITION_TYPE_BUY) ? (curPrice - openPrice)/_Point : (openPrice - curPrice)/_Point;
            if(profitPoints >= p_beStart) {
               double newSL = (type == POSITION_TYPE_BUY) ? openPrice + p_bePlus * _Point : openPrice - p_bePlus * _Point;
               trade.PositionModify(PositionGetTicket(i), newSL, PositionGetDouble(POSITION_TP));
            }
         }

         // Trailing Stop
         if(p_trailingStart > 0) {
            double profitPoints = (type == POSITION_TYPE_BUY) ? (curPrice - openPrice)/_Point : (openPrice - curPrice)/_Point;
            if(profitPoints >= p_trailingStart) {
               double newSL = (type == POSITION_TYPE_BUY) ? curPrice - p_trailingStart * _Point : curPrice + p_trailingStart * _Point;
               if((type == POSITION_TYPE_BUY && newSL > curSL + p_trailingStep * _Point) ||
                  (type == POSITION_TYPE_SELL && (newSL < curSL - p_trailingStep * _Point || curSL == 0))) {
                  trade.PositionModify(PositionGetTicket(i), newSL, PositionGetDouble(POSITION_TP));
               }
            }
         }
      }
   }
}

void GravaCSV() {
   int h = FileOpen(STATE_FILE, FILE_WRITE|FILE_CSV|FILE_COMMON);
   if(h == INVALID_HANDLE) return;

   FileWrite(h, "Ticket", "Symbol", "Type", "Volume", "PriceOpen", "Time", "SL", "TP", "Profit", "Reason");
   for(int i=0; i<PositionsTotal(); i++) {
      if(PositionSelectByTicket(PositionGetTicket(i))) {
         if(PositionGetInteger(POSITION_MAGIC) != EA_MAGIC) continue;
         FileWrite(h, PositionGetTicket(i), _Symbol, PositionGetInteger(POSITION_TYPE), PositionGetDouble(POSITION_VOLUME),
                   PositionGetDouble(POSITION_PRICE_OPEN), PositionGetDateTime(POSITION_TIME), PositionGetDouble(POSITION_SL),
                   PositionGetDouble(POSITION_TP), PositionGetDouble(POSITION_PROFIT), PositionGetString(POSITION_COMMENT));
      }
   }
   FileClose(h);
}

void CalculaEstatisticas(double &winRate, double &pf, double &dd) {
   HistorySelect(0, TimeCurrent());
   int total = HistoryDealsTotal();
   int wins = 0, losses = 0;
   double grossProfit = 0, grossLoss = 0;
   double maxBalance = 0, maxDD = 0;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   for(int i=0; i<total; i++) {
      ulong t = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC) {
         double prf = HistoryDealGetDouble(t, DEAL_PROFIT);
         if(prf > 0) { wins++; grossProfit += prf; }
         else if(prf < 0) { losses++; grossLoss += MathAbs(prf); }
      }
   }
   winRate = (wins + losses > 0) ? (double)wins / (wins + losses) * 100.0 : 0;
   pf = (grossLoss > 0) ? grossProfit / grossLoss : grossProfit;
   dd = 0; // Simplificado
}

void AIOptimizer() {
   double wr, pf, dd;
   CalculaEstatisticas(wr, pf, dd);
   if(wr < 40 && wr > 0) p_riskPercent *= 0.8;
   if(wr > 60 && pf > 1.5) p_riskPercent = MathMin(p_riskPercent * 1.2, 2.0);
   GravaLog("AI Optimizer: WR=" + DoubleToString(wr, 1) + "% PF=" + DoubleToString(pf, 2) + " Risco=" + DoubleToString(p_riskPercent, 2));
}

// ---------- HANDLERS ----------

int OnInit() {
   EventSetTimer(1);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   EventKillTimer();
}

void OnTimer() {
   // Ler prompt.txt se existir e for novo
   int h = FileOpen(PROMPT_FILE, FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      string p = FileReadString(h);
      FileClose(h);
      if(p != currentPrompt) {
         currentPrompt = p;
         InterpretaPrompt(p);
         GravaLog("Novo prompt interpretado: " + p);
      }
   }

   static datetime lastAI = 0;
   if(TimeCurrent() - lastAI > 3600) {
      AIOptimizer();
      lastAI = TimeCurrent();
   }
}

void OnTick() {
   // Trade management must run on every tick
   GerenciaPosicoes();
   GravaCSV();

   datetime now = iTime(_Symbol, p_frequency, 0);
   if(now == lastBarTime) return;
   lastBarTime = now;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string curTime = StringFormat("%02d:%02d", dt.hour, dt.min);
   if(curTime < p_startTime) return;

   Signal s = AvaliaTudo();
   if(s != NONE) {
      EnviaOrdem(s, "Estratégia NLP");
   }
}
