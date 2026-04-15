//=========================  MT5-KNOWLEDGE-CORE  =========================
// MT-LiveExecutor: Single module for real-time strategy interpretation
// and execution.
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// ---------- 1. DATA STRUCTURES & GLOBALS ----------

enum Signal { BUY = 1, SELL = -1, NONE = 0 };

enum RuleType {
   RT_MA_CROSS,
   RT_RSI_THRESHOLD,
   RT_STOCH_CROSS,
   RT_BB_BOUNCE,
   RT_DAILY_BREAK,
   RT_DELTA,
   RT_VOLUME_CYCLE,
   RT_AMA,
   RT_BAR2_PATTERN,
   RT_RS_RELATIVE,
   RT_AI_PRED
};

struct Rule {
   bool      active;
   RuleType  type;
   ENUM_TIMEFRAMES tf;
   int       p1, p2, p3;
   double    d1, d2;
   string    s1;
   int       p1_handle, p2_handle;
   Signal    intent; // BUY or SELL expected from this rule
};

// Strategy-wide parameters
string    p_prompt = "";
Rule      p_rules[30];
int       p_nRules = 0;
double    p_riskPercent = 1.0;
int       p_stopPoints = 300;
int       p_takePoints = 500;
int       p_maxTrades = 3;
int       p_beStart = 0;
int       p_bePlus = 0;
int       p_trailingStart = 0;
int       p_trailingStep = 10;
bool      p_useMartingale = false;
datetime  p_startTimeSeconds = 0;
datetime  p_endTimeSeconds = 0;
ENUM_TIMEFRAMES p_frequency = PERIOD_CURRENT;
int       EA_MAGIC = 20260101;

// State management
datetime  lastBarTime = 0;
datetime  lastCSVWrite = 0;

// Objects
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symInfo;
CAccountInfo accInfo;

// Forward declarations
void InterpretaPrompt(string prompt);
Signal AvaliaTudo();
Signal AvaliaRegra(int index);
double CalculaLote(double riscoPercent);
void EnviaOrdem(Signal s, double lote);
void GerenciaPosicoes();
bool AguardaNoticias();
void GravaLog(string texto);
void GravaCSV();
void CalculaEstatisticas();
void ResetStrategy();
void AIOptimizer();
double GetBufferValue(int handle, int buffer, int shift);
double ExtraiNumero(string txt, string keyword, int startPos = 0);
string ExtraiValorApos(string txt, string keyword);
string ExtractTime(string txt, string keyword);
ENUM_TIMEFRAMES PeriodoTexto(string nome);

// ---------- 2. NLP PARSER & HELPERS ----------

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   p_prompt = prompt;
   string work = prompt;
   StringToLower(work);
   StringReplace(work, " e ", "|");
   StringReplace(work, ".", "|");
   StringReplace(work, ",", "|");

   string segments[];
   int nSegments = StringSplit(work, '|', segments);

   Signal currentIntent = NONE;

   for(int i = 0; i < nSegments; i++) {
      string seg = segments[i];
      StringTrimLeft(seg); StringTrimRight(seg);
      if(seg == "") continue;

      // Update intent
      if(StringFind(seg, "compra") >= 0) currentIntent = BUY;
      else if(StringFind(seg, "vende") >= 0) currentIntent = SELL;

      // Global Parameters
      if(StringFind(seg, "stop de") >= 0) p_stopPoints = (int)ExtraiNumero(seg, "stop de");
      if(StringFind(seg, "take de") >= 0) p_takePoints = (int)ExtraiNumero(seg, "take de");
      if(StringFind(seg, "risco de") >= 0) p_riskPercent = ExtraiNumero(seg, "risco de");
      if(StringFind(seg, "máximo") >= 0 && StringFind(seg, "trades") >= 0) p_maxTrades = (int)ExtraiNumero(seg, "máximo");
      if(StringFind(seg, "martingale") >= 0) p_useMartingale = true;

      // Management
      if(StringFind(seg, "atingir") >= 0) p_beStart = (int)ExtraiNumero(seg, "atingir");
      if(StringFind(seg, "move stop para entrada") >= 0) p_bePlus = (int)ExtraiNumero(seg, "entrada");

      // Frequency and Time
      if(StringFind(seg, "a cada") >= 0) p_frequency = PeriodoTexto(seg);
      if(StringFind(seg, "depois das") >= 0) {
         string t = ExtractTime(seg, "depois das");
         p_startTimeSeconds = (datetime)StringToTime(t) % 86400;
      }
      if(StringFind(seg, "até as") >= 0 || StringFind(seg, "antes das") >= 0) {
         string t = ExtractTime(seg, "as ");
         p_endTimeSeconds = (datetime)StringToTime(t) % 86400;
      }

      // Parse Rules
      if(StringFind(seg, "média") >= 0 || (StringFind(seg, " ma ") >= 0 || StringFind(seg, " ma/") >= 0)) {
         p_rules[p_nRules].active = true;
         p_rules[p_nRules].type = RT_MA_CROSS;
         p_rules[p_nRules].p1 = (int)ExtraiNumero(seg, "média");
         if(p_rules[p_nRules].p1 == 0) p_rules[p_nRules].p1 = (int)ExtraiNumero(seg, " ma");
         if(p_rules[p_nRules].p1 == 0) p_rules[p_nRules].p1 = 20; // Default

         int slash = StringFind(seg, "/");
         if(slash >= 0) p_rules[p_nRules].p2 = (int)ExtraiNumero(seg, "/", slash);

         p_rules[p_nRules].tf = PeriodoTexto(seg);
         p_rules[p_nRules].intent = currentIntent;
         p_rules[p_nRules].p1_handle = iMA(_Symbol, p_rules[p_nRules].tf, p_rules[p_nRules].p1, 0, MODE_EMA, PRICE_CLOSE);
         if(p_rules[p_nRules].p2 > 0)
            p_rules[p_nRules].p2_handle = iMA(_Symbol, p_rules[p_nRules].tf, p_rules[p_nRules].p2, 0, MODE_EMA, PRICE_CLOSE);
         p_nRules++;
      }
      else if(StringFind(seg, "rsi") >= 0) {
         p_rules[p_nRules].active = true;
         p_rules[p_nRules].type = RT_RSI_THRESHOLD;
         double num = ExtraiNumero(seg, "rsi");
         if(num > 0 && num <= 25) p_rules[p_nRules].p1 = (int)num; else p_rules[p_nRules].p1 = 14;

         p_rules[p_nRules].d1 = ExtraiNumero(seg, "acima");
         if(p_rules[p_nRules].d1 == 0) p_rules[p_nRules].d1 = ExtraiNumero(seg, ">");
         if(p_rules[p_nRules].d1 == 0) p_rules[p_nRules].d1 = ExtraiNumero(seg, "sobre");
         if(p_rules[p_nRules].d1 == 0 && num > 25 && (StringFind(seg, "acima") >= 0 || StringFind(seg, "sobe") >= 0)) p_rules[p_nRules].d1 = num;

         p_rules[p_nRules].d2 = ExtraiNumero(seg, "abaixo");
         if(p_rules[p_nRules].d2 == 0) p_rules[p_nRules].d2 = ExtraiNumero(seg, "<");
         if(p_rules[p_nRules].d2 == 0) p_rules[p_nRules].d2 = ExtraiNumero(seg, "under");
         if(p_rules[p_nRules].d2 == 0 && num > 25 && (StringFind(seg, "abaixo") >= 0 || StringFind(seg, "cai") >= 0)) p_rules[p_nRules].d2 = num;

         p_rules[p_nRules].tf = PeriodoTexto(seg);
         p_rules[p_nRules].intent = currentIntent;
         p_rules[p_nRules].p1_handle = iRSI(_Symbol, p_rules[p_nRules].tf, p_rules[p_nRules].p1, PRICE_CLOSE);
         p_nRules++;
      }
      else if(StringFind(seg, "estocástico") >= 0 || StringFind(seg, "stoch") >= 0) {
         p_rules[p_nRules].active = true;
         p_rules[p_nRules].type = RT_STOCH_CROSS;
         p_rules[p_nRules].p1 = 5; p_rules[p_nRules].p2 = 3; p_rules[p_nRules].p3 = 3;
         p_rules[p_nRules].tf = PeriodoTexto(seg);
         p_rules[p_nRules].intent = currentIntent;
         p_rules[p_nRules].p1_handle = iStochastic(_Symbol, p_rules[p_nRules].tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
         p_nRules++;
      }
      else if(StringFind(seg, "bollinger") >= 0 || StringFind(seg, "bandas") >= 0) {
         p_rules[p_nRules].active = true;
         p_rules[p_nRules].type = RT_BB_BOUNCE;
         p_rules[p_nRules].p1 = 20; p_rules[p_nRules].d1 = 2.0;
         p_rules[p_nRules].tf = PeriodoTexto(seg);
         p_rules[p_nRules].intent = currentIntent;
         p_rules[p_nRules].p1_handle = iBands(_Symbol, p_rules[p_nRules].tf, 20, 0, 2.0, PRICE_CLOSE);
         p_nRules++;
      }
      else if(StringFind(seg, "volume") >= 0) {
         p_rules[p_nRules].active = true;
         p_rules[p_nRules].type = RT_VOLUME_CYCLE;
         p_rules[p_nRules].p1 = 12;
         p_rules[p_nRules].tf = PeriodoTexto(seg);
         p_rules[p_nRules].intent = currentIntent;
         p_nRules++;
      }
      else if(StringFind(seg, "ama") >= 0 || StringFind(seg, "adaptativa") >= 0) {
         p_rules[p_nRules].active = true;
         p_rules[p_nRules].type = RT_AMA;
         p_rules[p_nRules].p1 = 10;
         p_rules[p_nRules].tf = PeriodoTexto(seg);
         p_rules[p_nRules].intent = currentIntent;
         p_rules[p_nRules].p1_handle = iAMA(_Symbol, p_rules[p_nRules].tf, 10, 2, 30, 0, PRICE_CLOSE);
         p_nRules++;
      }
      else if(StringFind(seg, "padrão") >= 0 || StringFind(seg, "barras") >= 0) {
         p_rules[p_nRules].active = true;
         p_rules[p_nRules].type = RT_BAR2_PATTERN;
         p_rules[p_nRules].tf = PeriodoTexto(seg);
         p_rules[p_nRules].intent = currentIntent;
         p_nRules++;
      }
      else if(StringFind(seg, "previsão") >= 0 || StringFind(seg, "ai") >= 0) {
         p_rules[p_nRules].active = true;
         p_rules[p_nRules].type = RT_AI_PRED;
         p_rules[p_nRules].intent = currentIntent;
         p_nRules++;
      }
   }
}

double ExtraiNumero(string txt, string keyword, int startPos = 0) {
   int pos = StringFind(txt, keyword, startPos);
   if(pos < 0) return 0;
   string sub = StringSubstr(txt, pos + StringLen(keyword));
   string res = "";
   bool found = false;
   for(int i = 0; i < StringLen(sub); i++) {
      ushort c = StringGetCharacter(sub, i);
      if((c >= '0' && c <= '9') || c == '.') {
         res += ShortToString(c);
         found = true;
      } else if(found) break;
   }
   return StringToDouble(res);
}

string ExtractTime(string txt, string keyword) {
   int pos = StringFind(txt, keyword);
   if(pos < 0) return "00:00";
   string sub = StringSubstr(txt, pos + StringLen(keyword));
   StringTrimLeft(sub);
   string res = "";
   for(int i = 0; i < StringLen(sub); i++) {
      ushort c = StringGetCharacter(sub, i);
      if((c >= '0' && c <= '9') || c == ':' || c == 'h') res += ShortToString(c);
      else break;
   }
   StringReplace(res, "h", ":00");
   if(StringFind(res, ":") < 0) res += ":00";
   return res;
}

ENUM_TIMEFRAMES PeriodoTexto(string nome) {
   if(StringFind(nome, "30 minutos") >= 0 || StringFind(nome, "m30") >= 0) return PERIOD_M30;
   if(StringFind(nome, "15 minutos") >= 0 || StringFind(nome, "m15") >= 0) return PERIOD_M15;
   if(StringFind(nome, "5 minutos") >= 0 || StringFind(nome, "m5") >= 0) return PERIOD_M5;
   if(StringFind(nome, "1 minuto") >= 0 || StringFind(nome, "minuto") >= 0 || StringFind(nome, "m1") >= 0) return PERIOD_M1;
   if(StringFind(nome, "hora") >= 0 || StringFind(nome, "h1") >= 0) return PERIOD_H1;
   if(StringFind(nome, "diário") >= 0 || StringFind(nome, "d1") >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

void ResetStrategy() {
   for(int i = 0; i < 30; i++) {
      if(p_rules[i].p1_handle != INVALID_HANDLE && p_rules[i].p1_handle != 0) IndicatorRelease(p_rules[i].p1_handle);
      if(p_rules[i].p2_handle != INVALID_HANDLE && p_rules[i].p2_handle != 0) IndicatorRelease(p_rules[i].p2_handle);
      p_rules[i].active = false;
      p_rules[i].p1_handle = INVALID_HANDLE;
      p_rules[i].p2_handle = INVALID_HANDLE;
      p_rules[i].p1 = 0; p_rules[i].p2 = 0; p_rules[i].p3 = 0;
      p_rules[i].d1 = 0; p_rules[i].d2 = 0;
      p_rules[i].intent = NONE;
   }
   p_nRules = 0;
   p_riskPercent = 1.0;
   p_stopPoints = 300;
   p_takePoints = 500;
   p_maxTrades = 3;
   p_beStart = 0; p_bePlus = 0;
   p_trailingStart = 0;
   p_startTimeSeconds = 0; p_endTimeSeconds = 0;
   p_frequency = PERIOD_CURRENT;
}

// ---------- 3. SIGNAL EVALUATION & EXECUTION ----------

Signal AvaliaTudo() {
   int buyLeg = 0, sellLeg = 0;
   int buyRules = 0, sellRules = 0;

   for(int i = 0; i < p_nRules; i++) {
      Signal s = AvaliaRegra(i);
      if(p_rules[i].intent == BUY || p_rules[i].intent == NONE) {
         if(s == BUY) buyLeg++;
         buyRules++;
      }
      if(p_rules[i].intent == SELL || p_rules[i].intent == NONE) {
         if(s == SELL) sellLeg++;
         sellRules++;
      }
   }

   if(buyRules > 0 && buyLeg == buyRules) return BUY;
   if(sellRules > 0 && sellLeg == sellRules) return SELL;
   return NONE;
}

Signal AvaliaRegra(int index) {
   Rule r = p_rules[index];
   if(!r.active) return NONE;

   if(r.type == RT_MA_CROSS) {
      double ma1 = GetBufferValue(r.p1_handle, 0, 1);
      double ma1_prev = GetBufferValue(r.p1_handle, 0, 2);
      double price = iClose(_Symbol, r.tf, 1);
      double price_prev = iClose(_Symbol, r.tf, 2);
      if(r.p2_handle == INVALID_HANDLE) {
         if(price_prev <= ma1_prev && price > ma1) return BUY;
         if(price_prev >= ma1_prev && price < ma1) return SELL;
      } else {
         double ma2 = GetBufferValue(r.p2_handle, 0, 1);
         double ma2_prev = GetBufferValue(r.p2_handle, 0, 2);
         if(ma1_prev <= ma2_prev && ma1 > ma2) return BUY;
         if(ma1_prev >= ma2_prev && ma1 < ma2) return SELL;
      }
   }
   else if(r.type == RT_RSI_THRESHOLD) {
      double val = GetBufferValue(r.p1_handle, 0, 1);
      double prev = GetBufferValue(r.p1_handle, 0, 2);
      if(r.intent == BUY && r.d1 > 0 && prev <= r.d1 && val > r.d1) return BUY;
      if(r.intent == SELL && r.d2 > 0 && prev >= r.d2 && val < r.d2) return SELL;
      if(r.intent == NONE) {
         if(val < r.d2) return BUY;
         if(val > r.d1) return SELL;
      }
   }
   else if(r.type == RT_STOCH_CROSS) {
      double k1 = GetBufferValue(r.p1_handle, 0, 1);
      double d1 = GetBufferValue(r.p1_handle, 1, 1);
      double k2 = GetBufferValue(r.p1_handle, 0, 2);
      double d2 = GetBufferValue(r.p1_handle, 1, 2);
      if(k2 <= d2 && k1 > d1) return BUY;
      if(k2 >= d2 && k1 < d1) return SELL;
   }
   else if(r.type == RT_BB_BOUNCE) {
      double lower = GetBufferValue(r.p1_handle, 2, 1);
      double upper = GetBufferValue(r.p1_handle, 1, 1);
      double close = iClose(_Symbol, r.tf, 1);
      if(close < lower) return BUY;
      if(close > upper) return SELL;
   }
   else if(r.type == RT_VOLUME_CYCLE) {
      double vol[]; ArraySetAsSeries(vol, true);
      CopyVolume(_Symbol, r.tf, 1, r.p1, vol);
      int maxIdx = ArrayMaximum(vol);
      int minIdx = ArrayMinimum(vol);
      if(minIdx == 0) return BUY;
      if(maxIdx == 0) return SELL;
   }
   else if(r.type == RT_AMA) {
      double ama = GetBufferValue(r.p1_handle, 0, 1);
      double prev = GetBufferValue(r.p1_handle, 0, 2);
      if(ama > prev) return BUY;
      if(ama < prev) return SELL;
   }
   else if(r.type == RT_BAR2_PATTERN) {
      double h0 = iHigh(_Symbol, r.tf, 1), l0 = iLow(_Symbol, r.tf, 1);
      double h1 = iHigh(_Symbol, r.tf, 2), l1 = iLow(_Symbol, r.tf, 2);
      if(h0 < h1 && l0 > l1) return (iClose(_Symbol, r.tf, 1) > iOpen(_Symbol, r.tf, 1)) ? BUY : SELL;
      if(h0 > h1 && l0 < l1) return (iClose(_Symbol, r.tf, 1) > iOpen(_Symbol, r.tf, 1)) ? SELL : BUY;
   }
   else if(r.type == RT_AI_PRED) {
      double atr[]; int h = iATR(_Symbol, r.tf, 14);
      CopyBuffer(h, 0, 1, 1, atr); IndicatorRelease(h);
      double body = MathAbs(iClose(_Symbol, r.tf, 1) - iOpen(_Symbol, r.tf, 1));
      if(body > atr[0] * 1.5) return (iClose(_Symbol, r.tf, 1) > iOpen(_Symbol, r.tf, 1)) ? BUY : SELL;
   }
   return NONE;
}

double GetBufferValue(int handle, int buffer, int shift) {
   double arr[]; ArraySetAsSeries(arr, true);
   if(CopyBuffer(handle, buffer, shift, 1, arr) > 0) return arr[0];
   return 0;
}

void EnviaOrdem(Signal s, double lote) {
   if(s == NONE || AguardaNoticias()) return;
   double sl = 0, tp = 0, price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(s == BUY) {
      sl = (p_stopPoints > 0) ? price - p_stopPoints * _Point : 0;
      tp = (p_takePoints > 0) ? price + p_takePoints * _Point : 0;
   } else {
      sl = (p_stopPoints > 0) ? price + p_stopPoints * _Point : 0;
      tp = (p_takePoints > 0) ? price - p_takePoints * _Point : 0;
   }
   double margin;
   if(!OrderCalcMargin((s == BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL), _Symbol, lote, price, margin)) return;
   if(margin > AccountInfoDouble(ACCOUNT_FREEMARGIN)) { GravaLog("Margem insuficiente"); return; }
   if(s == BUY) trade.Buy(lote, _Symbol, price, sl, tp, "MT-LiveExecutor");
   else trade.Sell(lote, _Symbol, price, sl, tp, "MT-LiveExecutor");
   if(trade.ResultRetcode() == TRADE_RETCODE_DONE) {
      GravaLog((s == BUY ? "BUY" : "SELL") + " executado: " + DoubleToString(lote, 2));
      SendNotification("MT-LiveExecutor: Ordem aberta em " + _Symbol);
   } else GravaLog("Erro: " + trade.ResultComment());
}

double CalculaLote(double riscoPercent) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY), riscoAbs = capital * riscoPercent / 100.0;
   if(p_useMartingale) {
      HistorySelect(TimeCurrent() - 86400, TimeCurrent());
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--) {
         ulong t = HistoryDealGetTicket(i);
         if(HistoryDealGetString(t, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC) {
            if(HistoryDealGetDouble(t, DEAL_PROFIT) < 0) riscoAbs *= 2;
            break;
         }
      }
   }
   double tickV = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE), tickS = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double stop = (p_stopPoints > 0 ? p_stopPoints * _Point : 100 * _Point);
   double lote = riscoAbs / (stop * (tickV / tickS));
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lote = MathFloor(lote / step) * step;
   return MathMin(MathMax(lote, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN)), SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX));
}

// ---------- 4. MANAGEMENT, FILTERING & UTILITIES ----------

void GerenciaPosicoes() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC && posInfo.Symbol() == _Symbol) {
         double price = (posInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double open = posInfo.PriceOpen(), sl = posInfo.StopLoss(), tp = posInfo.TakeProfit();
         if(p_beStart > 0) {
            double profit = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (price - open) : (open - price);
            if(profit >= p_beStart * _Point) {
               double nSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? open + p_bePlus * _Point : open - p_bePlus * _Point;
               if((posInfo.PositionType() == POSITION_TYPE_BUY && (sl < nSL || sl == 0)) || (posInfo.PositionType() == POSITION_TYPE_SELL && (sl > nSL || sl == 0))) trade.PositionModify(posInfo.Ticket(), nSL, tp);
            }
         }
         if(p_trailingStart > 0) {
            double profit = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (price - open) : (open - price);
            if(profit >= p_trailingStart * _Point) {
               double nSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? price - p_trailingStart * _Point : price + p_trailingStart * _Point;
               if(MathAbs(nSL - sl) >= p_trailingStep * _Point) {
                  if((posInfo.PositionType() == POSITION_TYPE_BUY && nSL > sl) || (posInfo.PositionType() == POSITION_TYPE_SELL && (nSL < sl || sl == 0))) trade.PositionModify(posInfo.Ticket(), nSL, tp);
               }
            }
         }
      }
   }
}

bool AguardaNoticias() {
   int h = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_COMMON);
   if(h != INVALID_HANDLE) {
      string c = FileReadString(h); FileClose(h);
      if(c == "1") return true;
      datetime et = (datetime)StringToTime(c);
      if(et > 0 && MathAbs(TimeCurrent() - et) < 1200) return true;
   }
   return false;
}

void GravaLog(string texto) {
   int h = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE | FILE_READ | FILE_TXT | FILE_COMMON);
   if(h != INVALID_HANDLE) { FileSeek(h, 0, SEEK_END); FileWriteString(h, TimeToString(TimeCurrent()) + ": " + texto + "\r\n"); FileClose(h); }
   Print(texto);
}

void GravaCSV() {
   if(TimeCurrent() - lastCSVWrite < 5) return; lastCSVWrite = TimeCurrent();
   int h = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV | FILE_COMMON);
   if(h != INVALID_HANDLE) {
      FileWrite(h, "Ticket", "Symbol", "Type", "Price", "SL", "TP");
      for(int i = 0; i < PositionsTotal(); i++) if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC) FileWrite(h, posInfo.Ticket(), posInfo.Symbol(), posInfo.PositionType(), posInfo.PriceOpen(), posInfo.StopLoss(), posInfo.TakeProfit());
      FileClose(h);
   }
}

void CalculaEstatisticas() {
   HistorySelect(0, TimeCurrent()); double profit = 0; int wins = 0, losses = 0;
   for(int i = 0; i < HistoryDealsTotal(); i++) {
      ulong t = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC) {
         double p = HistoryDealGetDouble(t, DEAL_PROFIT); profit += p;
         if(p > 0) wins++; else if(p < 0) losses++;
      }
   }
   GravaLog("Stats: Profit=" + DoubleToString(profit, 2) + " WR=" + DoubleToString((wins + losses > 0 ? (double)wins / (wins + losses) * 100 : 0), 2) + "%");
}

void AIOptimizer() {
   HistorySelect(TimeCurrent() - 86400 * 7, TimeCurrent()); int wins = 0, tot = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0 && tot < 10; i--) {
      ulong t = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC) { if(HistoryDealGetDouble(t, DEAL_PROFIT) > 0) wins++; tot++; }
   }
   if(tot >= 10) { double wr = (double)wins / tot; if(wr < 0.4) p_riskPercent = MathMax(0.5, p_riskPercent * 0.9); if(wr > 0.6) p_riskPercent = MathMin(2.0, p_riskPercent * 1.1); }
}

int OnInit() { EventSetTimer(1); symInfo.Name(_Symbol); trade.SetExpertMagicNumber(EA_MAGIC); return INIT_SUCCEEDED; }
void OnDeinit(const int reason) { EventKillTimer(); }
void OnTimer() {
   int h = FileOpen("prompt.txt", FILE_READ | FILE_TXT | FILE_COMMON);
   if(h != INVALID_HANDLE) { string p = FileReadString(h); FileClose(h); if(p != "" && p != p_prompt) { InterpretaPrompt(p); GravaLog("Novo prompt: " + p); } }
   if(TimeHour(TimeCurrent()) != TimeHour(TimeCurrent() - 1)) AIOptimizer();
}
void OnTick() {
   GerenciaPosicoes(); GravaCSV();
   if(AguardaNoticias()) return;
   datetime now = TimeCurrent() % 86400;
   if((p_startTimeSeconds > 0 && now < p_startTimeSeconds) || (p_endTimeSeconds > 0 && now > p_endTimeSeconds)) return;
   datetime cb = iTime(_Symbol, p_frequency, 0);
   if(cb != lastBarTime) {
      lastBarTime = cb;
      if(PositionsTotal() < p_maxTrades) { Signal s = AvaliaTudo(); if(s != NONE) EnviaOrdem(s, CalculaLote(p_riskPercent)); }
   }
}
