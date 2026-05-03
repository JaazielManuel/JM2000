//=========================  MT5-KNOWLEDGE-CORE  =========================
// MT-LiveExecutor - Agente de Execução em Tempo Real
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// --- Constants
#define EA_MAGIC 123456

// --- Enums
enum Signal { BUY=1, SELL=-1, NONE=0 };

// Rule types
#define RT_MA          1
#define RT_RSI         2
#define RT_STOCH       3
#define RT_BB          4
#define RT_DAILYBREAK  5
#define RT_DELTA       6
#define RT_VOL         7
#define RT_AMA         8
#define RT_BAR2        9
#define RT_RS          10
#define RT_AI_PRED     11

// --- Structs
struct Rule {
   bool     active;
   int      type;
   ENUM_TIMEFRAMES tf;
   int      p1, p2, p3;
   double   d1, d2;
   string   s1;
   int      handle1, handle2;
};

// --- Global Variables
Rule rules[20];
int nRules = 0;
double p_riskPercent = 1.0;
int p_stopPoints = 0;
int p_takePoints = 0;
int p_maxTrades = 3;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
string p_startTime = "00:00";
bool p_useMartingale = false;
int p_beStart = 0;
int p_bePlus = 0;
int p_trailingStart = 0;
int p_trailingStep = 10;
int p_newsVetoMin = 0;
datetime lastPromptUpdate = 0;

CTrade trade;

// --- NLP Utilities
ENUM_TIMEFRAMES PeriodoTexto(string text) {
   string work = text;
   StringToLower(work);
   // Process longer units first to prevent collisions (e.g., "15 minutos" vs "1 minuto")
   if (StringFind(work, "30 minutos") >= 0 || StringFind(work, "m30") >= 0) return PERIOD_M30;
   if (StringFind(work, "15 minutos") >= 0 || StringFind(work, "m15") >= 0 || StringFind(work, "15 min") >= 0) return PERIOD_M15;
   if (StringFind(work, "5 minutos") >= 0 || StringFind(work, "m5") >= 0) return PERIOD_M5;
   if (StringFind(work, "1 minuto") >= 0 || StringFind(work, "m1") >= 0) return PERIOD_M1;
   if (StringFind(work, "1 hora") >= 0 || StringFind(work, "h1") >= 0) return PERIOD_H1;
   if (StringFind(work, "4 horas") >= 0 || StringFind(work, "h4") >= 0) return PERIOD_H4;
   if (StringFind(work, "diário") >= 0 || StringFind(work, "d1") >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

double ExtraiNumero(string text, int &startPos) {
   string res = "";
   bool found = false;
   for (int i = startPos; i < StringLen(text); i++) {
      ushort c = StringGetCharacter(text, i);
      if ((c >= '0' && c <= '9') || c == '.') {
         res += ShortToString(c);
         found = true;
      } else if (found) {
         startPos = i;
         return StringToDouble(res);
      }
   }
   startPos = StringLen(text);
   return found ? StringToDouble(res) : 0;
}

double ExtraiValorApos(string text, string keyword) {
   string work = text;
   StringToLower(work);
   string kw = keyword;
   StringToLower(kw);
   int pos = StringFind(work, kw);
   if (pos < 0) return 0;
   pos += StringLen(kw);
   return ExtraiNumero(text, pos);
}

string ExtraiStringApos(string text, string keyword) {
   string work = text;
   StringToLower(work);
   string kw = keyword;
   StringToLower(kw);
   int pos = StringFind(work, kw);
   if (pos < 0) return "";
   pos += StringLen(kw);
   while (pos < StringLen(text) && StringGetCharacter(text, pos) == ' ') pos++;
   int end = pos;
   while (end < StringLen(text) && StringGetCharacter(text, end) != ' ' && StringGetCharacter(text, end) != ',' && StringGetCharacter(text, end) != '|') end++;
   return StringSubstr(text, pos, end - pos);
}

// --- Internal Functions
void ResetStrategy() {
   for (int i = 0; i < nRules; i++) {
      if (rules[i].handle1 != INVALID_HANDLE && rules[i].handle1 != 0) IndicatorRelease(rules[i].handle1);
      if (rules[i].handle2 != INVALID_HANDLE && rules[i].handle2 != 0) IndicatorRelease(rules[i].handle2);
   }
   nRules = 0;
   p_riskPercent = 1.0;
   p_stopPoints = 0;
   p_takePoints = 0;
   p_maxTrades = 3;
   p_frequency = PERIOD_M15;
   p_startTime = "00:00";
   p_useMartingale = false;
   p_beStart = 0;
   p_bePlus = 0;
   p_trailingStart = 0;
   p_trailingStep = 10;
   p_newsVetoMin = 0;
   Print("Estratégia resetada.");
}

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   string work = prompt;
   StringToLower(work);

   double val = ExtraiValorApos(work, "risco de");
   if (val > 0) p_riskPercent = val;

   val = ExtraiValorApos(work, "stop de");
   if (val > 0) p_stopPoints = (int)val;

   val = ExtraiValorApos(work, "take de");
   if (val > 0) p_takePoints = (int)val;

   val = ExtraiValorApos(work, "máximo");
   if (val > 0) p_maxTrades = (int)val;

   if (StringFind(work, "martingale") >= 0) p_useMartingale = true;

   p_frequency = PeriodoTexto(work);

   int posBE = StringFind(work, "move stop para entrada");
   if (posBE >= 0) {
      p_beStart = (int)ExtraiValorApos(work, "atingir +");
      p_bePlus = (int)ExtraiValorApos(work, "entrada +");
   }

   int posStart = StringFind(work, "depois das");
   if (posStart >= 0) {
      p_startTime = ExtraiStringApos(work, "depois das");
   } else if (StringFind(work, "início") >= 0) {
      p_startTime = ExtraiStringApos(work, "início");
   }

   val = ExtraiValorApos(work, "notícias de alto impacto");
   if (val == 0) val = ExtraiValorApos(work, "notícias");
   if (val > 0) p_newsVetoMin = (int)val;

   string tempWork = work;
   StringReplace(tempWork, " e ", "|");
   StringReplace(tempWork, ".", "|");
   StringReplace(tempWork, ",", "|");
   string segments[];
   int total = StringSplit(tempWork, '|', segments);

   for (int i = 0; i < total; i++) {
      if (nRules >= 20) break;
      string s = segments[i];
      Rule r;
      r.active = false;
      r.tf = PeriodoTexto(s);
      if (r.tf == PERIOD_CURRENT) r.tf = p_frequency;
      r.handle1 = INVALID_HANDLE;
      r.handle2 = INVALID_HANDLE;

      if (StringFind(s, " ma ") >= 0 || StringFind(s, "média") >= 0) {
         r.type = RT_MA;
         int p = 0;
         r.p1 = (int)ExtraiNumero(s, p);
         if (r.p1 == 0) r.p1 = 20;
         r.p2 = (int)ExtraiNumero(s, p);
         r.handle1 = iMA(_Symbol, r.tf, r.p1, 0, MODE_SMA, PRICE_CLOSE);
         if (r.p2 > 0) r.handle2 = iMA(_Symbol, r.tf, r.p2, 0, MODE_SMA, PRICE_CLOSE);
         r.active = true;
      }
      else if (StringFind(s, "rsi") >= 0) {
         r.type = RT_RSI;
         int p = 0;
         double n1 = ExtraiNumero(s, p);
         double n2 = ExtraiNumero(s, p);
         if (n1 < 40) { r.p1 = (int)n1; r.d1 = n2; }
         else { r.p1 = 14; r.d1 = n1; }
         if (r.p1 == 0) r.p1 = 14;
         r.handle1 = iRSI(_Symbol, r.tf, r.p1, PRICE_CLOSE);
         r.active = true;
      }
      else if (StringFind(s, "estocástico") >= 0 || StringFind(s, "stoch") >= 0) {
         r.type = RT_STOCH;
         r.handle1 = iStochastic(_Symbol, r.tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
         r.active = true;
      }
      else if (StringFind(s, "bollinger") >= 0 || StringFind(s, "bb") >= 0) {
         r.type = RT_BB;
         r.handle1 = iBands(_Symbol, r.tf, 20, 0, 2.0, PRICE_CLOSE);
         r.active = true;
      }
      else if (StringFind(s, "rompimento diário") >= 0) {
         r.type = RT_DAILYBREAK;
         r.active = true;
      }
      else if (StringFind(s, "volume") >= 0) {
         r.type = RT_VOL;
         r.active = true;
      }
      else if (StringFind(s, "ama") >= 0 || StringFind(s, "adaptativa") >= 0) {
         r.type = RT_AMA;
         r.handle1 = iAMA(_Symbol, r.tf, 10, 2, 30, 0, PRICE_CLOSE);
         r.active = true;
      }
      else if (StringFind(s, "padrão barras") >= 0) {
         r.type = RT_BAR2;
         r.active = true;
      }
      else if (StringFind(s, "força relativa") >= 0) {
         r.type = RT_RS;
         r.active = true;
      }
      else if (StringFind(s, "previsão") >= 0 || StringFind(s, "ai") >= 0) {
         r.type = RT_AI_PRED;
         r.handle1 = iATR(_Symbol, r.tf, 14);
         r.active = true;
      }

      if (r.active) {
         rules[nRules] = r;
         nRules++;
      }
   }
   Print("Estratégia interpretada: ", nRules, " regras carregadas.");
}

// --- Technical Indicator Helpers
double GetBufferValue(int handle, int buffer, int index) {
   double val[];
   ArraySetAsSeries(val, true);
   if (CopyBuffer(handle, buffer, index, 1, val) > 0) return val[0];
   return 0;
}

Signal CruzamentoMA(int h1, int h2, ENUM_TIMEFRAMES tf) {
   if (h1 == INVALID_HANDLE) return NONE;
   double m1_0 = GetBufferValue(h1, 0, 1);
   double m1_1 = GetBufferValue(h1, 0, 2);
   if (h2 != INVALID_HANDLE && h2 != 0) {
      double m2_0 = GetBufferValue(h2, 0, 1);
      double m2_1 = GetBufferValue(h2, 0, 2);
      if (m1_1 < m2_1 && m1_0 > m2_0) return BUY;
      if (m1_1 > m2_1 && m1_0 < m2_0) return SELL;
   } else {
      double p0 = iClose(_Symbol, tf, 1);
      double p1 = iClose(_Symbol, tf, 2);
      if (p1 < m1_1 && p0 > m1_0) return BUY;
      if (p1 > m1_1 && p0 < m1_0) return SELL;
   }
   return NONE;
}

Signal RSIThreshold(int h1, double threshold) {
   if (h1 == INVALID_HANDLE) return NONE;
   double r0 = GetBufferValue(h1, 0, 1);
   double r1 = GetBufferValue(h1, 0, 2);
   if (threshold == 0) {
      if (r1 < 30 && r0 > 30) return BUY;
      if (r1 > 70 && r0 < 70) return SELL;
   } else {
      if (r1 < threshold && r0 > threshold) return BUY;
      if (r1 > threshold && r0 < threshold) return SELL;
   }
   return NONE;
}

Signal StochCross(int h1) {
   if (h1 == INVALID_HANDLE) return NONE;
   double k0 = GetBufferValue(h1, 0, 1);
   double k1 = GetBufferValue(h1, 0, 2);
   double d0 = GetBufferValue(h1, 1, 1);
   double d1 = GetBufferValue(h1, 1, 2);
   if (k1 < d1 && k0 > d0) return BUY;
   if (k1 > d1 && k0 < d0) return SELL;
   return NONE;
}

Signal BBounce(int h1, ENUM_TIMEFRAMES tf) {
   if (h1 == INVALID_HANDLE) return NONE;
   double upper = GetBufferValue(h1, 1, 1);
   double lower = GetBufferValue(h1, 2, 1);
   double close = iClose(_Symbol, tf, 1);
   if (close < lower) return BUY;
   if (close > upper) return SELL;
   return NONE;
}

Signal DailyBreak() {
   double hi = iHigh(_Symbol, PERIOD_D1, 1);
   double lo = iLow(_Symbol, PERIOD_D1, 1);
   double close = iClose(_Symbol, PERIOD_CURRENT, 0);
   if (close > hi) return BUY;
   if (close < lo) return SELL;
   return NONE;
}

Signal DeltaAggression() {
   MqlTick arr[];
   int n = CopyTicksRange(_Symbol, arr, COPY_TICKS_TRADE, TimeCurrent() - 60, TimeCurrent());
   long buy = 0, sell = 0;
   for (int i = 0; i < n; i++) {
      if ((arr[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++;
      else if ((arr[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sell++;
   }
   if (buy > sell + 100) return BUY;
   if (sell > buy + 100) return SELL;
   return NONE;
}

Signal VolumeCycle(ENUM_TIMEFRAMES tf) {
   long vol[];
   ArraySetAsSeries(vol, true);
   if (CopyVolume(_Symbol, tf, 1, 10, vol) < 10) return NONE;
   if (vol[0] > vol[1] * 2) return BUY;
   return NONE;
}

Signal AMA(int h1) {
   if (h1 == INVALID_HANDLE) return NONE;
   double a0 = GetBufferValue(h1, 0, 1);
   double a1 = GetBufferValue(h1, 0, 2);
   if (a0 > a1) return BUY;
   if (a0 < a1) return SELL;
   return NONE;
}

Signal Bar2Pattern(ENUM_TIMEFRAMES tf) {
   double h0 = iHigh(_Symbol, tf, 1);
   double l0 = iLow(_Symbol, tf, 1);
   double h1 = iHigh(_Symbol, tf, 2);
   double l1 = iLow(_Symbol, tf, 2);
   if (h0 < h1 && l0 > l1) return (iClose(_Symbol, tf, 1) > iOpen(_Symbol, tf, 1)) ? BUY : SELL;
   if (h0 > h1 && l0 < l1) return (iClose(_Symbol, tf, 1) > iOpen(_Symbol, tf, 1)) ? SELL : BUY;
   return NONE;
}

Signal RSRelative(int h1, int h2) {
   if (h1 == INVALID_HANDLE || h2 == INVALID_HANDLE) return NONE;
   double r1 = GetBufferValue(h1, 0, 1);
   double r2 = GetBufferValue(h2, 0, 1);
   if (r1 > r2 + 5) return BUY;
   if (r1 < r2 - 5) return SELL;
   return NONE;
}

Signal AISignal(int h1, ENUM_TIMEFRAMES tf) {
   if (h1 == INVALID_HANDLE) return NONE;
   double atr = GetBufferValue(h1, 0, 1);
   double body = MathAbs(iClose(_Symbol, tf, 1) - iOpen(_Symbol, tf, 1));
   if (body > atr * 1.5) return (iClose(_Symbol, tf, 1) > iOpen(_Symbol, tf, 1)) ? BUY : SELL;
   return NONE;
}

// --- Logic Evaluation
Signal AvaliaRegra(Rule &r) {
   switch (r.type) {
      case RT_MA:          return CruzamentoMA(r.handle1, r.handle2, r.tf);
      case RT_RSI:         return RSIThreshold(r.handle1, r.d1);
      case RT_STOCH:       return StochCross(r.handle1);
      case RT_BB:          return BBounce(r.handle1, r.tf);
      case RT_DAILYBREAK:  return DailyBreak();
      case RT_DELTA:       return DeltaAggression();
      case RT_VOL:         return VolumeCycle(r.tf);
      case RT_AMA:         return AMA(r.handle1);
      case RT_BAR2:        return Bar2Pattern(r.tf);
      case RT_RS:          return RSRelative(r.handle1, r.handle2);
      case RT_AI_PRED:     return AISignal(r.handle1, r.tf);
   }
   return NONE;
}

Signal AvaliaTudo() {
   int vote = 0;
   for (int i = 0; i < nRules; i++) {
      if (rules[i].active) {
         Signal s = AvaliaRegra(rules[i]);
         if (s == BUY) vote++;
         else if (s == SELL) vote--;
      }
   }
   if (vote > 0) return BUY;
   if (vote < 0) return SELL;
   return NONE;
}

// --- Trading Functions
void EnviaOrdem(Signal s, string reason) {
   if (s == NONE) return;
   double lote = CalculaLote();
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double price = (s == BUY) ? ask : bid;
   double sl = 0, tp = 0;
   if (p_stopPoints > 0) sl = (s == BUY) ? bid - p_stopPoints * _Point : ask + p_stopPoints * _Point;
   if (p_takePoints > 0) tp = (s == BUY) ? ask + p_takePoints * _Point : bid - p_takePoints * _Point;
   double margin;
   if (!OrderCalcMargin((s == BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL), _Symbol, lote, price, margin)) return;
   if (margin > AccountInfoDouble(ACCOUNT_FREEMARGIN)) return;
   trade.SetExpertMagicNumber(EA_MAGIC);
   if (s == BUY ? trade.Buy(lote, _Symbol, price, sl, tp, reason) : trade.Sell(lote, _Symbol, price, sl, tp, reason)) {
      SendNotification("MT-LiveExecutor: Ordem de " + ((s == BUY) ? "COMPRA" : "VENDA") + " enviada. Motivo: " + reason);
      GravaLog("Ordem enviada: " + ((s == BUY) ? "BUY " : "SELL ") + DoubleToString(lote, 2) + " Reason: " + reason);
   }
}

double CalculaLote() {
   double riskAmount = AccountInfoDouble(ACCOUNT_EQUITY) * p_riskPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double multiplier = 1.0;
   if (p_useMartingale) {
      HistorySelect(TimeCurrent() - 86400 * 30, TimeCurrent());
      for (int i = HistoryDealsTotal() - 1; i >= 0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if (HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            if (HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) multiplier = 2.0;
            break;
         }
      }
   }
   double stopPoints = (p_stopPoints > 0) ? p_stopPoints : 1000;
   double vol = (riskAmount * multiplier) / (stopPoints * (tickValue / (tickSize / _Point)));
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   vol = MathFloor(vol / step) * step;
   return NormalizeDouble(MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), vol)), 2);
}

void GerenciaPosicoes() {
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if (PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC && PositionGetString(POSITION_SYMBOL) == _Symbol) {
         double profitPoints = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? (SymbolInfoDouble(_Symbol, SYMBOL_BID) - PositionGetDouble(POSITION_PRICE_OPEN)) / _Point : (PositionGetDouble(POSITION_PRICE_OPEN) - SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / _Point;
         if (p_beStart > 0 && profitPoints >= p_beStart) {
            double targetSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? PositionGetDouble(POSITION_PRICE_OPEN) + p_bePlus * _Point : PositionGetDouble(POSITION_PRICE_OPEN) - p_bePlus * _Point;
            if ((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && (PositionGetDouble(POSITION_SL) < targetSL || PositionGetDouble(POSITION_SL) == 0)) || (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (PositionGetDouble(POSITION_SL) > targetSL || PositionGetDouble(POSITION_SL) == 0))) trade.PositionModify(ticket, targetSL, PositionGetDouble(POSITION_TP));
         }
         if (p_trailingStart > 0 && profitPoints >= p_trailingStart) {
            double targetSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) - p_trailingStart * _Point : SymbolInfoDouble(_Symbol, SYMBOL_ASK) + p_trailingStart * _Point;
            if ((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && (targetSL > PositionGetDouble(POSITION_SL) + p_trailingStep * _Point || PositionGetDouble(POSITION_SL) == 0)) || (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (targetSL < PositionGetDouble(POSITION_SL) - p_trailingStep * _Point || PositionGetDouble(POSITION_SL) == 0))) trade.PositionModify(ticket, targetSL, PositionGetDouble(POSITION_TP));
         }
      }
   }
}

// --- Persistence and Logging
void GravaLog(string text) {
   int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE | FILE_READ | FILE_TXT | FILE_ANSI);
   if (handle != INVALID_HANDLE) { FileSeek(handle, 0, SEEK_END); FileWrite(handle, TimeToString(TimeCurrent()) + ": " + text); FileClose(handle); }
}

void GravaCSV() {
   int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV | FILE_ANSI);
   if (handle != INVALID_HANDLE) {
      FileWrite(handle, "Ticket", "Symbol", "Type", "Volume", "PriceOpen", "Time", "SL", "TP", "Profit", "Reason");
      for (int i = 0; i < PositionsTotal(); i++) {
         ulong ticket = PositionGetTicket(i);
         if (PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) FileWrite(handle, ticket, PositionGetString(POSITION_SYMBOL), PositionGetInteger(POSITION_TYPE), PositionGetDouble(POSITION_VOLUME), PositionGetDouble(POSITION_PRICE_OPEN), PositionGetInteger(POSITION_TIME), PositionGetDouble(POSITION_SL), PositionGetDouble(POSITION_TP), PositionGetDouble(POSITION_PROFIT), PositionGetString(POSITION_COMMENT));
      }
      FileClose(handle);
   }
}

bool AguardaNoticias() {
   // Binary veto from file
   int handle = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_ANSI);
   if (handle != INVALID_HANDLE) {
      string content = FileReadString(handle);
      FileClose(handle);
      if (content == "1") return true;
   }

   // Advanced offset veto from calendar simulation/file
   if (p_newsVetoMin > 0) {
      int hCalendar = FileOpen("calendar.txt", FILE_READ | FILE_TXT | FILE_ANSI);
      if (hCalendar != INVALID_HANDLE) {
         while (!FileIsEnding(hCalendar)) {
            string line = FileReadString(hCalendar);
            datetime newsTime = StringToTime(line);
            if (newsTime > 0) {
               if (TimeCurrent() >= newsTime - p_newsVetoMin * 60 && TimeCurrent() <= newsTime + p_newsVetoMin * 60) {
                  FileClose(hCalendar);
                  return true;
               }
            }
         }
         FileClose(hCalendar);
      }
   }
   return false;
}

bool VerificaHorario() {
   if (p_startTime == "00:00") return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string now = StringFormat("%02d:%02d", dt.hour, dt.min);
   // Support formats like "10h" or "10:00"
   string start = p_startTime;
   StringReplace(start, "h", ":00");
   if (StringLen(start) == 2) start += ":00";
   return (now >= start);
}

void AIOptimizer() {
   HistorySelect(TimeCurrent() - 3600 * 24, TimeCurrent());
   int wins = 0, count = 0;
   for (int i = HistoryDealsTotal() - 1; i >= 0 && count < 10; i--) {
      ulong ticket = HistoryDealGetTicket(i);
      if (HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) { if (HistoryDealGetDouble(ticket, DEAL_PROFIT) > 0) wins++; count++; }
   }
   if (count >= 5 && (double)wins / count < 0.4) { p_riskPercent *= 0.8; Print("AI Optimizer: Win rate baixo, reduzindo risco."); }
}

// --- Event Handlers
int OnInit() { EventSetTimer(1); return INIT_SUCCEEDED; }
void OnDeinit(const int reason) { ResetStrategy(); EventKillTimer(); }
void OnTimer() {
   datetime modDate = (datetime)FileGetInteger("prompt.txt", FILE_MODIFY_DATE);
   if (modDate > lastPromptUpdate) {
      int handle = FileOpen("prompt.txt", FILE_READ | FILE_TXT | FILE_ANSI);
      if (handle != INVALID_HANDLE) { InterpretaPrompt(FileReadString(handle)); FileClose(handle); lastPromptUpdate = modDate; }
   }
   static datetime lastAI = 0;
   if (TimeCurrent() - lastAI > 3600) { AIOptimizer(); lastAI = TimeCurrent(); }
}

void OnTick() {
   static datetime lastBar = 0;
   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   GerenciaPosicoes();
   GravaCSV();
   if (currentBar != lastBar) {
      if (!AguardaNoticias() && VerificaHorario()) {
         if (PositionsTotal() < p_maxTrades) {
            Signal s = AvaliaTudo();
            if (s != NONE) EnviaOrdem(s, "Sinal validado na barra");
         }
      }
      lastBar = currentBar;
   }
}
