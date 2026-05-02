//=========================  MT_LiveExecutor  =========================
// Agent: Jules
// Purpose: Multi-strategy real-time executor with NLP interpretation
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// --- Constants ---
#define EA_MAGIC 123456
#define MAX_RULES 20

// --- Enums ---
enum Signal {BUY=1, SELL=-1, NONE=0};

// Rule Types
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

// --- Structs ---
struct Rule {
   int      type;
   bool     active;
   ENUM_TIMEFRAMES tf;
   int      p1, p2, p3;
   double   d1, d2;
   string   s1;
   int      handle1, handle2;
   Signal   intent; // BUY or SELL context from prompt
};

// --- Global Parameters ---
Rule rules[MAX_RULES];
int nRules = 0;

ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
double p_riskPercent = 1.0;
int p_stopPoints = 300;
int p_takePoints = 500;
int p_maxTrades = 3;
bool p_useMartingale = false;
string p_startTime = "00:00";
int p_beStart = 0;
int p_bePlus = 0;
int p_trailingStart = 0;
int p_trailingStep = 10;

datetime last_prompt_mod = 0;
CTrade trade;
CPositionInfo pos_info;
CSymbolInfo sym_info;
CAccountInfo acc_info;

// --- Utility Functions ---

ENUM_TIMEFRAMES PeriodoTexto(string nome) {
   nome = StringSubstr(nome, 0); // copy
   StringToLower(nome);
   if(StringFind(nome, "15 minutos") >= 0 || StringFind(nome, "15 min") >= 0 || StringFind(nome, "m15") >= 0) return PERIOD_M15;
   if(StringFind(nome, "5 minutos") >= 0 || StringFind(nome, "5 min") >= 0 || StringFind(nome, "m5") >= 0) return PERIOD_M5;
   if(StringFind(nome, "1 minuto") >= 0 || StringFind(nome, "1 min") >= 0 || StringFind(nome, "m1") >= 0) return PERIOD_M1;
   if(StringFind(nome, "1 hora") >= 0 || StringFind(nome, "h1") >= 0) return PERIOD_H1;
   if(StringFind(nome, "diário") >= 0 || StringFind(nome, "d1") >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

double ExtraiNumero(string txt, int &endPos) {
   string res = "";
   bool found = false;
   int i = endPos;
   for(; i < StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.') {
         res += CharToString((uchar)c);
         found = true;
      } else if(found) {
         break;
      }
   }
   endPos = i;
   return found ? StringToDouble(res) : 0;
}

double ExtraiValorApos(string prompt, string keyword) {
   int pos = StringFind(prompt, keyword);
   if(pos < 0) return 0;
   int endPos = pos + StringLen(keyword);
   return ExtraiNumero(prompt, endPos);
}

double GetBufferValue(int handle, int buffer, int index) {
   double arr[];
   ArraySetAsSeries(arr, true);
   if(CopyBuffer(handle, buffer, index, 1, arr) > 0) return arr[0];
   return 0;
}

// --- Indicator Signal Functions ---

Signal CruzamentoMA(Rule &r, int shift) {
   if(r.handle1 == INVALID_HANDLE) return NONE;

   if(r.handle2 != INVALID_HANDLE && r.handle2 != 0) {
      double f1 = GetBufferValue(r.handle1, 0, shift + 1);
      double f2 = GetBufferValue(r.handle1, 0, shift + 2);
      double s1 = GetBufferValue(r.handle2, 0, shift + 1);
      double s2 = GetBufferValue(r.handle2, 0, shift + 2);
      if(f2 <= s2 && f1 > s1) return BUY;
      if(f2 >= s2 && f1 < s1) return SELL;
   } else {
      double ma1 = GetBufferValue(r.handle1, 0, shift + 1);
      double ma2 = GetBufferValue(r.handle1, 0, shift + 2);
      double c1 = iClose(_Symbol, r.tf, shift + 1);
      double c2 = iClose(_Symbol, r.tf, shift + 2);
      if(c2 <= ma2 && c1 > ma1) return BUY;
      if(c2 >= ma2 && c1 < ma1) return SELL;
   }
   return NONE;
}

Signal RSIThreshold(Rule &r, int shift) {
   if(r.handle1 == INVALID_HANDLE) return NONE;
   double rsi1 = GetBufferValue(r.handle1, 0, shift + 1);
   double rsi2 = GetBufferValue(r.handle1, 0, shift + 2);
   double val = (r.d1 > 0) ? r.d1 : ((r.intent == BUY) ? 30 : 70);
   if(r.intent == BUY) {
      if(rsi2 <= val && rsi1 > val) return BUY;
   } else {
      if(rsi2 >= val && rsi1 < val) return SELL;
   }
   return NONE;
}

Signal StochCross(Rule &r, int shift) {
   if(r.handle1 == INVALID_HANDLE) return NONE;
   double k1 = GetBufferValue(r.handle1, 0, shift + 1);
   double k2 = GetBufferValue(r.handle1, 0, shift + 2);
   double d1 = GetBufferValue(r.handle1, 1, shift + 1);
   double d2 = GetBufferValue(r.handle1, 1, shift + 2);
   if(k2 <= d2 && k1 > d1) return BUY;
   if(k2 >= d2 && k1 < d1) return SELL;
   return NONE;
}

Signal BBounce(Rule &r, int shift) {
   if(r.handle1 == INVALID_HANDLE) return NONE;
   double upper = GetBufferValue(r.handle1, 1, shift + 1);
   double lower = GetBufferValue(r.handle1, 2, shift + 1);
   double close = iClose(_Symbol, r.tf, shift + 1);
   if(close < lower) return BUY;
   if(close > upper) return SELL;
   return NONE;
}

Signal DailyBreak(Rule &r, int shift) {
   double hi = iHigh(_Symbol, PERIOD_D1, 1);
   double lo = iLow(_Symbol, PERIOD_D1, 1);
   double close = iClose(_Symbol, PERIOD_CURRENT, shift + 1);
   if(close > hi) return BUY;
   if(close < lo) return SELL;
   return NONE;
}

Signal DeltaAggression(Rule &r, int shift) {
   MqlTick arr[];
   int seconds = (r.p1 > 0) ? r.p1 : 60;
   int trigger = (r.p2 > 0) ? r.p2 : 300;
   int n = CopyTicksRange(_Symbol, arr, COPY_TICKS_TRADE, TimeCurrent() - seconds, TimeCurrent());
   long buy = 0, sell = 0;
   for(int i = 0; i < n; i++) {
      if((arr[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++;
      else if((arr[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sell++;
   }
   long delta = buy - sell;
   if(delta > trigger) return BUY;
   if(delta < -trigger) return SELL;
   return NONE;
}

Signal VolumeCycle(Rule &r, int shift) {
   double vol[];
   ArraySetAsSeries(vol, true);
   int len = (r.p1 > 0) ? r.p1 : 12;
   if(CopyVolume(_Symbol, r.tf, shift + 1, len, vol) > 0) {
      int max_idx = ArrayMaximum(vol);
      int min_idx = ArrayMinimum(vol);
      if(0 == min_idx) return BUY;
      if(0 == max_idx) return SELL;
   }
   return NONE;
}

Signal AMA(Rule &r, int shift) {
   if(r.handle1 == INVALID_HANDLE) return NONE;
   double ama1 = GetBufferValue(r.handle1, 0, shift + 1);
   double ama2 = GetBufferValue(r.handle1, 0, shift + 2);
   if(ama1 > ama2) return BUY;
   if(ama1 < ama2) return SELL;
   return NONE;
}

Signal Bar2Pattern(Rule &r, int shift) {
   double h0 = iHigh(_Symbol, r.tf, shift + 1);
   double l0 = iLow(_Symbol, r.tf, shift + 1);
   double h1 = iHigh(_Symbol, r.tf, shift + 2);
   double l1 = iLow(_Symbol, r.tf, shift + 2);
   double c0 = iClose(_Symbol, r.tf, shift + 1);
   double o0 = iOpen(_Symbol, r.tf, shift + 1);
   if(h0 < h1 && l0 > l1) return (c0 > o0) ? BUY : SELL;
   if(h0 > h1 && l0 < l1) return (c0 > o0) ? SELL : BUY;
   return NONE;
}

Signal RSRelative(Rule &r, int shift) {
   if(r.handle1 == INVALID_HANDLE || r.handle2 == INVALID_HANDLE) return NONE;
   double r1 = GetBufferValue(r.handle1, 0, shift + 1);
   double r2 = GetBufferValue(r.handle2, 0, shift + 1);
   if(r1 > r2 + 5) return BUY;
   if(r1 < r2 - 5) return SELL;
   return NONE;
}

Signal AISignal(Rule &r, int shift) {
   if(r.handle1 == INVALID_HANDLE) return NONE;
   double atr = GetBufferValue(r.handle1, 0, shift + 1);
   double body = MathAbs(iClose(_Symbol, r.tf, shift + 1) - iOpen(_Symbol, r.tf, shift + 1));
   if(body > 1.5 * atr) {
      return (iClose(_Symbol, r.tf, shift + 1) > iOpen(_Symbol, r.tf, shift + 1)) ? BUY : SELL;
   }
   return NONE;
}

// --- Strategy Management ---

void ResetStrategy() {
   for(int i = 0; i < nRules; i++) {
      if(rules[i].handle1 != INVALID_HANDLE && rules[i].handle1 != 0) IndicatorRelease(rules[i].handle1);
      if(rules[i].handle2 != INVALID_HANDLE && rules[i].handle2 != 0) IndicatorRelease(rules[i].handle2);
   }
   nRules = 0;
   p_frequency = PERIOD_M15;
   p_riskPercent = 1.0;
   p_stopPoints = 300;
   p_takePoints = 500;
   p_maxTrades = 3;
   p_useMartingale = false;
   p_startTime = "00:00";
   p_beStart = 0;
   p_bePlus = 0;
   p_trailingStart = 0;
}

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   string work = prompt;
   StringToLower(work);

   p_frequency = PeriodoTexto(work);
   double val;
   if((val = ExtraiValorApos(work, "stop de")) > 0) p_stopPoints = (int)val;
   if((val = ExtraiValorApos(work, "take de")) > 0) p_takePoints = (int)val;
   if((val = ExtraiValorApos(work, "risco de")) > 0) p_riskPercent = val;
   if((val = ExtraiValorApos(work, "máximo")) > 0) p_maxTrades = (int)val;
   if(StringFind(work, "martingale") >= 0) p_useMartingale = true;

   if(StringFind(work, "move stop para entrada") >= 0) {
      p_beStart = (int)ExtraiValorApos(work, "atingir +");
      p_bePlus = (int)ExtraiValorApos(work, "entrada +");
   }

   int tPos = StringFind(work, "depois das ");
   if(tPos >= 0) {
      int endPos = tPos + 11;
      double h = ExtraiNumero(work, endPos);
      p_startTime = StringFormat("%02d:00", (int)h);
   }

   string segments[];
   string sep = "|";
   StringReplace(work, " e ", sep);
   StringReplace(work, ".", sep);
   StringReplace(work, ",", sep);
   ushort u_sep = StringGetCharacter(sep, 0);
   int nSegs = StringSplit(work, u_sep, segments);

   Signal currentIntent = NONE;
   int lastMA_p1=0, lastMA_p2=0;
   int lastRSI_p1=14;

   for(int i = 0; i < nSegs && nRules < MAX_RULES; i++) {
      string seg = segments[i];
      StringTrimLeft(seg); StringTrimRight(seg);
      if(StringLen(seg) < 3) continue;

      if(StringFind(seg, "compra") >= 0) currentIntent = BUY;
      else if(StringFind(seg, "vende") >= 0) currentIntent = SELL;

      Rule r;
      r.active = true;
      r.tf = PeriodoTexto(seg);
      if(r.tf == PERIOD_CURRENT) r.tf = p_frequency;
      r.intent = currentIntent;
      r.handle1 = INVALID_HANDLE; r.handle2 = INVALID_HANDLE;

      if(StringFind(seg, " ma ") >= 0 || StringFind(seg, " ma/") >= 0 || StringFind(seg, "média") >= 0) {
         r.type = RT_MA;
         int pos = 0;
         int p1 = (int)ExtraiNumero(seg, pos);
         int p2 = (int)ExtraiNumero(seg, pos);
         if(p1 > 0) lastMA_p1 = p1; if(p2 > 0) lastMA_p2 = p2;
         r.p1 = lastMA_p1; r.p2 = lastMA_p2;
         r.handle1 = iMA(_Symbol, r.tf, r.p1, 0, MODE_EMA, PRICE_CLOSE);
         if(r.p2 > 0) r.handle2 = iMA(_Symbol, r.tf, r.p2, 0, MODE_EMA, PRICE_CLOSE);
         rules[nRules++] = r;
      }
      else if(StringFind(seg, "rsi") >= 0) {
         r.type = RT_RSI;
         int pos = 0;
         double n1 = ExtraiNumero(seg, pos);
         double n2 = ExtraiNumero(seg, pos);
         if(n1 > 0 && n1 < 40) { lastRSI_p1 = (int)n1; r.d1 = n2; }
         else { r.d1 = n1; }
         r.p1 = lastRSI_p1;
         r.handle1 = iRSI(_Symbol, r.tf, r.p1, PRICE_CLOSE);
         rules[nRules++] = r;
      }
      else if(StringFind(seg, "stoch") >= 0 || StringFind(seg, "estocástico") >= 0) {
         r.type = RT_STOCH;
         r.handle1 = iStochastic(_Symbol, r.tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
         rules[nRules++] = r;
      }
      else if(StringFind(seg, "bollinger") >= 0 || StringFind(seg, " bb ") >= 0) {
         r.type = RT_BB;
         r.handle1 = iBands(_Symbol, r.tf, 20, 0, 2.0, PRICE_CLOSE);
         rules[nRules++] = r;
      }
      else if(StringFind(seg, "rompimento diário") >= 0) { r.type = RT_DAILYBREAK; rules[nRules++] = r; }
      else if(StringFind(seg, "delta") >= 0) { r.type = RT_DELTA; rules[nRules++] = r; }
      else if(StringFind(seg, "volume") >= 0) { r.type = RT_VOL; rules[nRules++] = r; }
      else if(StringFind(seg, "ama") >= 0 || StringFind(seg, "adaptativa") >= 0) {
         r.type = RT_AMA; r.handle1 = iAMA(_Symbol, r.tf, 10, 2, 30, PRICE_CLOSE); rules[nRules++] = r;
      }
      else if(StringFind(seg, "padrão barras") >= 0) { r.type = RT_BAR2; rules[nRules++] = r; }
      else if(StringFind(seg, "força relativa") >= 0) {
         r.type = RT_RS; r.handle1 = iRSI(_Symbol, r.tf, 14, PRICE_CLOSE); r.handle2 = iRSI("US30", r.tf, 14, PRICE_CLOSE); rules[nRules++] = r;
      }
      else if(StringFind(seg, "previsão") >= 0 || StringFind(seg, "ai") >= 0) {
         r.type = RT_AI_PRED; r.handle1 = iATR(_Symbol, r.tf, 14); rules[nRules++] = r;
      }
   }
}

// --- Logic Evaluation ---

Signal AvaliaRegra(Rule &r, int shift) {
   switch(r.type) {
      case RT_MA: return CruzamentoMA(r, shift);
      case RT_RSI: return RSIThreshold(r, shift);
      case RT_STOCH: return StochCross(r, shift);
      case RT_BB: return BBounce(r, shift);
      case RT_DAILYBREAK: return DailyBreak(r, shift);
      case RT_DELTA: return DeltaAggression(r, shift);
      case RT_VOL: return VolumeCycle(r, shift);
      case RT_AMA: return AMA(r, shift);
      case RT_BAR2: return Bar2Pattern(r, shift);
      case RT_RS: return RSRelative(r, shift);
      case RT_AI_PRED: return AISignal(r, shift);
   }
   return NONE;
}

Signal AvaliaTudo() {
   if(nRules == 0) return NONE;
   int voto = 0;
   for(int i = 0; i < nRules; i++) {
      if(rules[i].active) {
         Signal s = AvaliaRegra(rules[i], 0);
         if(s == BUY) voto++;
         else if(s == SELL) voto--;
      }
   }
   if(voto > 0 && voto >= (nRules / 2 + 1)) return BUY;
   if(voto < 0 && MathAbs(voto) >= (nRules / 2 + 1)) return SELL;
   return NONE;
}

// --- Trade Execution ---

void GravaLog(string texto);

double CalculaLote(double riscoPercent) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riscoAbs = capital * (riscoPercent / 100.0);
   if(p_useMartingale) {
      HistorySelect(TimeCurrent() - 86400, TimeCurrent());
      int total = HistoryDealsTotal();
      for(int i = total - 1; i >= 0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) riscoAbs *= 2.0;
            break;
         }
      }
   }
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(p_stopPoints == 0 || tickValue == 0 || tickSize == 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double stopLossValue = p_stopPoints * (tickValue / (tickSize / _Point));
   double volume = riscoAbs / stopLossValue;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   volume = MathFloor(volume / step) * step;
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(volume < minVol) volume = minVol;
   if(volume > maxVol) volume = maxVol;
   return NormalizeDouble(volume, 2);
}

bool AguardaNoticias() {
   int handle = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_ANSI);
   if(handle != INVALID_HANDLE) {
      string content = FileReadString(handle); FileClose(handle);
      if(content == "1") return true;
   }
   return false;
}

void EnviaOrdem(Signal s, string reason) {
   if(s == NONE) return;
   if(AguardaNoticias()) { GravaLog("Trade vetado por notícias."); return; }
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) {
         if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) count++;
      }
   }
   if(count >= p_maxTrades) return;
   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = (s == BUY) ? price - p_stopPoints * _Point : price + p_stopPoints * _Point;
   double tp = (s == BUY) ? price + p_takePoints * _Point : price - p_takePoints * _Point;
   double volume = CalculaLote(p_riskPercent);
   MqlTradeRequest request; ZeroMemory(request);
   request.action = TRADE_ACTION_DEAL; request.symbol = _Symbol; request.volume = volume;
   request.type = (s == BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   request.price = price; request.sl = sl; request.tp = tp; request.magic = EA_MAGIC; request.comment = reason;
   if(OrderCalcMargin(request.type, _Symbol, volume, price, request.margin) && request.margin <= AccountInfoDouble(ACCOUNT_MARGIN_FREE)) {
      trade.SetExpertMagicNumber(EA_MAGIC);
      if(s == BUY) trade.Buy(volume, _Symbol, price, sl, tp, reason);
      else trade.Sell(volume, _Symbol, price, sl, tp, reason);
      if(trade.ResultRetcode() == TRADE_RETCODE_DONE) {
         SendNotification("Trade executado: " + reason);
         GravaLog("Ordem enviada: " + reason + " Lote: " + DoubleToString(volume, 2));
      } else GravaLog("Erro ao enviar ordem: " + trade.ResultComment());
   } else GravaLog("Margem insuficiente.");
}

void GerenciaPosicoes() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double currentSL = PositionGetDouble(POSITION_SL);
         if(p_beStart > 0) {
            double points = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? (currentPrice - openPrice) / _Point : (openPrice - currentPrice) / _Point;
            if(points >= p_beStart) {
               double targetSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? openPrice + p_bePlus * _Point : openPrice - p_bePlus * _Point;
               if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && currentSL < targetSL) || (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (currentSL > targetSL || currentSL == 0)))
                  trade.PositionModify(ticket, targetSL, PositionGetDouble(POSITION_TP));
            }
         }
         if(p_trailingStart > 0) {
            double points = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? (currentPrice - openPrice) / _Point : (openPrice - currentPrice) / _Point;
            if(points >= p_trailingStart) {
               double targetSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? currentPrice - p_trailingStart * _Point : currentPrice + p_trailingStart * _Point;
               if(MathAbs(targetSL - currentSL) >= p_trailingStep * _Point) {
                  if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && targetSL > currentSL) || (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (targetSL < currentSL || currentSL == 0)))
                     trade.PositionModify(ticket, targetSL, PositionGetDouble(POSITION_TP));
               }
            }
         }
      }
   }
}

// --- Logging & Persistence ---

void GravaLog(string texto) {
   int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(handle != INVALID_HANDLE) { FileSeek(handle, 0, SEEK_END); FileWrite(handle, TimeToString(TimeCurrent()) + ": " + texto); FileClose(handle); }
   Print(texto);
}

void GravaCSV() {
   int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(handle != INVALID_HANDLE) {
      FileWrite(handle, "Ticket", "Symbol", "Type", "Volume", "PriceOpen", "Time", "SL", "TP", "Profit", "Reason");
      for(int i = 0; i < PositionsTotal(); i++) {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC)
            FileWrite(handle, ticket, PositionGetString(POSITION_SYMBOL), PositionGetInteger(POSITION_TYPE), PositionGetDouble(POSITION_VOLUME), PositionGetDouble(POSITION_PRICE_OPEN), TimeToString(PositionGetInteger(POSITION_TIME)), PositionGetDouble(POSITION_SL), PositionGetDouble(POSITION_TP), PositionGetDouble(POSITION_PROFIT), PositionGetString(POSITION_COMMENT));
      }
      FileClose(handle);
   }
}

void AIOptimizer() {
   HistorySelect(TimeCurrent() - 36000, TimeCurrent());
   int wins = 0, count = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0 && count < 10; i--) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) { if(HistoryDealGetDouble(ticket, DEAL_PROFIT) > 0) wins++; count++; }
   }
   if(count >= 5 && (double)wins / count < 0.4) { p_riskPercent *= 0.9; GravaLog("AI Optimizer: Reduzindo risco."); }
}

// --- Event Handlers ---

int OnInit() { EventSetTimer(1); trade.SetExpertMagicNumber(EA_MAGIC); GravaLog("MT-LiveExecutor iniciado."); return INIT_SUCCEEDED; }
void OnDeinit(const int reason) { EventKillTimer(); ResetStrategy(); GravaLog("MT-LiveExecutor finalizado."); }

void OnTick() {
   if(nRules == 0) return;
   MqlDateTime dt; TimeCurrent(dt);
   if(StringFormat("%02d:%02d", dt.hour, dt.min) < p_startTime) return;
   static datetime lastBar = 0;
   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar != lastBar) {
      Signal s = AvaliaTudo();
      if(s != NONE) EnviaOrdem(s, "Sinal consolidado");
      lastBar = currentBar;
   }
   GerenciaPosicoes(); GravaCSV();
}

void OnTimer() {
   datetime mod = (datetime)FileGetInteger("prompt.txt", FILE_MODIFY_DATE);
   if(mod > last_prompt_mod) {
      int handle = FileOpen("prompt.txt", FILE_READ | FILE_TXT | FILE_ANSI);
      if(handle != INVALID_HANDLE) { string prompt = FileReadString(handle); FileClose(handle); InterpretaPrompt(prompt); last_prompt_mod = mod; GravaLog("Novo prompt interpretado."); }
   }
   static int lastHour = -1;
   MqlDateTime dt; TimeCurrent(dt);
   if(dt.hour != lastHour) { AIOptimizer(); lastHour = dt.hour; }
}
