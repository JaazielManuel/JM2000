//=========================  MT-LIVEEXECUTOR  =========================
// Central de Execução de Estratégias via Prompt NLP (Português)
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// ---------- GLOBAL ENUMS & STRUCTS ----------
enum Signal {BUY=1, SELL=-1, NONE=0};

enum RuleType {
   RULE_MA_CROSS,
   RULE_RSI,
   RULE_STOCH,
   RULE_BB,
   RULE_DAILY_BREAK,
   RULE_DELTA,
   RULE_VOLUME,
   RULE_AMA,
   RULE_BAR2,
   RULE_RS_REL
};

struct Rule {
   bool      active;
   RuleType  type;
   int       tf;
   int       p1, p2, p3;
   double    d1, d2;
   string    s1;
   Signal    intent; // BUY or SELL
   int       p1_handle, p2_handle; // Store indicator handles
};

// ---------- GLOBAL VARIABLES ----------
Rule     p_rules[30];
int      p_nRules = 0;
double   p_riskPercent = 1.0;
int      p_stopPoints = 300;
int      p_takePoints = 500;
int      p_trailingStopPoints = 0;
int      p_breakEvenPoints = 0;
int      p_breakEvenProfit = 50;
int      p_maxSimultaneous = 3;
bool     p_hedge = false;
bool     p_useMartingale = false;
string   p_startTime = "00:00";
string   p_endTime = "23:59";
long     p_startTimeSeconds = 0;
long     p_endTimeSeconds = 86399;
int      p_timeframeMinutes = 1; // Default to M1
datetime p_lastBarTime = 0;

int      dynamicSafetyPoints = 0;
const long EA_MAGIC = 20260101;

CTrade         trade;
CPositionInfo  posInfo;
CSymbolInfo    symInfo;

// ---------- 1. INDICATOR FUNCTIONS (MT5-KNOWLEDGE-CORE) ----------

// 1.1 MÉDIAS & CRUZAMENTOS
Signal CruzamentoMA(Rule &r, int shift=1) {
   if(r.p1_handle == INVALID_HANDLE) return NONE;

   double ma[], ma2[];
   ArraySetAsSeries(ma, true);
   ArraySetAsSeries(ma2, true);

   if(CopyBuffer(r.p1_handle, 0, shift, 2, ma) <= 0) return NONE;

   if(r.p2_handle != INVALID_HANDLE) {
      if(CopyBuffer(r.p2_handle, 0, shift, 2, ma2) <= 0) return NONE;
      if(ma[1] < ma2[1] && ma[0] > ma2[0]) return BUY;
      if(ma[1] > ma2[1] && ma[0] < ma2[0]) return SELL;
   } else {
      double p0 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
      double p1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift+1);
      if(p1 < ma[1] && p0 > ma[0]) return BUY;
      if(p1 > ma[1] && p0 < ma[0]) return SELL;
   }

   return NONE;
}

// 1.2 RSI
Signal RSIThreshold(Rule &r, int shift=1) {
   if(r.p1_handle == INVALID_HANDLE) return NONE;

   double v[];
   ArraySetAsSeries(v, true);
   if(CopyBuffer(r.p1_handle, 0, shift, 2, v) <= 0) return NONE;

   // Check for crossing
   double val = v[0];
   double prev = v[1];

   // If intent is BUY, we usually look for crossing ABOVE a threshold or being BELOW (mean reversion)
   // Based on prompt: "RSI subir acima de 55"
   if(r.intent == BUY) {
      if(prev <= r.d1 && val > r.d1) return BUY; // Cross above
      if(val < r.d2) return BUY; // Mean reversion (if d2 is defined as oversold)
   } else if(r.intent == SELL) {
      if(prev >= r.d1 && val < r.d1) return SELL; // Cross below
      if(val > r.d1) return SELL; // Overbought
   }

   return NONE;
}

// 1.3 ESTOCÁSTICO
Signal StochCross(Rule &r, int shift=1) {
   if(r.p1_handle == INVALID_HANDLE) return NONE;

   double k[], d[];
   ArraySetAsSeries(k, true);
   ArraySetAsSeries(d, true);

   if(CopyBuffer(r.p1_handle, 0, shift, 2, k) <= 0) return NONE;
   if(CopyBuffer(r.p1_handle, 1, shift, 2, d) <= 0) return NONE;

   if(k[1] < d[1] && k[0] > d[0]) return BUY;
   if(k[1] > d[1] && k[0] < d[0]) return SELL;

   return NONE;
}

// 1.4 BOLLINGER BOUNCE
Signal BBounce(Rule &r, int shift=1) {
   if(r.p1_handle == INVALID_HANDLE) return NONE;

   double upper[], lower[], mid[];
   ArraySetAsSeries(upper, true);
   ArraySetAsSeries(lower, true);
   ArraySetAsSeries(mid, true);

   if(CopyBuffer(r.p1_handle, 0, shift, 1, mid) <= 0) return NONE;
   if(CopyBuffer(r.p1_handle, 1, shift, 1, upper) <= 0) return NONE;
   if(CopyBuffer(r.p1_handle, 2, shift, 1, lower) <= 0) return NONE;

   double close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);

   if(close < lower[0]) return BUY;
   if(close > upper[0]) return SELL;

   return NONE;
}

// 1.5 BREAKOUT DIÁRIO
Signal DailyBreak(Rule &r, int shift=1) {
   static datetime today=0;
   static double hi=0, lo=0;
   datetime currentDay = iTime(_Symbol, PERIOD_D1, 0);
   if(currentDay != today) {
      today = currentDay;
      hi = iHigh(_Symbol, PERIOD_D1, 1);
      lo = iLow(_Symbol, PERIOD_D1, 1);
   }
   double close = iClose(_Symbol, PERIOD_M1, shift);
   if(close > hi) return BUY;
   if(close < lo) return SELL;
   return NONE;
}

// 1.6 MICROESTRUTURA: DELTA DE AGRESSÃO
Signal DeltaAggression(Rule &r, int shift=1) {
   MqlTick arr[];
   int n = CopyTicksRange(_Symbol, arr, COPY_TICKS_TRADE, TimeCurrent() - r.p1, TimeCurrent());
   if(n <= 0) return NONE;
   long buy = 0, sell = 0;
   for(int i=0; i<n; i++) {
      if((arr[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++;
      else if((arr[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sell++;
   }
   long delta = buy - sell;
   if(delta > r.d1) return BUY;
   if(delta < -r.d1) return SELL;
   return NONE;
}

// 1.7 CICLO DE VOLUME (Williams)
Signal VolumeCycle(Rule &r, int shift=1) {
   long vol[];
   ArraySetAsSeries(vol, true);
   if(CopyVolume(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift, r.p1, vol) <= 0) return NONE;
   int maxIdx = ArrayMaximum(vol);
   int minIdx = ArrayMinimum(vol);
   if(maxIdx == 0) return SELL;
   if(minIdx == 0) return BUY;
   return NONE;
}

// 1.8 MÉDIA MÓVEL ADAPTATIVA (Kaufman)
Signal AMA(Rule &r, int shift=1) {
   if(r.p1_handle == INVALID_HANDLE) return NONE;
   double ama[], prev[];
   ArraySetAsSeries(ama, true);
   ArraySetAsSeries(prev, true);
   if(CopyBuffer(r.p1_handle, 0, shift, 2, ama) <= 0) return NONE;
   if(ama[0] > ama[1]) return BUY;
   if(ama[0] < ama[1]) return SELL;
   return NONE;
}

// 1.9 PADRÃO DE 2 BARRAS (inside / outside)
Signal Bar2Pattern(Rule &r, int shift=1) {
   double h0 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
   double l0 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
   double h1 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift+1);
   double l1 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift+1);
   double c0 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
   double o0 = iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);

   if(h0 < h1 && l0 > l1) return (c0 > o0) ? BUY : SELL; // Inside Bar
   if(h0 > h1 && l0 < l1) return (c0 > o0) ? SELL : BUY; // Outside Bar
   return NONE;
}

// 1.10 FORÇA RELATIVA ENTRE ATIVOS
Signal RSRelative(Rule &r, int shift=1) {
   if(r.p1_handle == INVALID_HANDLE || r.p2_handle == INVALID_HANDLE) return NONE;
   double r1[], r2[];
   ArraySetAsSeries(r1, true);
   ArraySetAsSeries(r2, true);
   if(CopyBuffer(r.p1_handle, 0, shift, 1, r1) <= 0) return NONE;
   if(CopyBuffer(r.p2_handle, 0, shift, 1, r2) <= 0) return NONE;
   if(r1[0] > r2[0] + 5) return BUY;
   if(r1[0] < r2[0] - 5) return SELL;
   return NONE;
}

// ---------- 2. NLP UTILITY FUNCTIONS ----------

double ExtractNumber(string text, string keyword) {
   int pos = StringFind(text, keyword);
   if(pos < 0) return 0;
   string sub = StringSubstr(text, pos + StringLen(keyword));
   StringTrimLeft(sub);
   string numStr = "";
   for(int i=0; i<StringLen(sub); i++) {
      ushort c = StringGetCharacter(sub, i);
      if((c >= '0' && c <= '9') || c == '.' || c == ',') {
         if(c == ',') numStr += ".";
         else numStr += CharToString((uchar)c);
      } else if(numStr != "") break;
      else if(c != ' ' && c != '+' && c != '-') break;
   }
   return StringToDouble(numStr);
}

string ExtractTime(string text, string keyword) {
   int pos = StringFind(text, keyword);
   if(pos < 0) return "";
   string sub = StringSubstr(text, pos + StringLen(keyword));
   StringTrimLeft(sub);
   string timeStr = "";
   for(int i=0; i<StringLen(sub); i++) {
      ushort c = StringGetCharacter(sub, i);
      if((c >= '0' && c <= '9') || c == ':' || c == 'h') {
         if(c == 'h') timeStr += ":00";
         else timeStr += CharToString((uchar)c);
      } else if(timeStr != "") break;
   }
   if(StringLen(timeStr) == 2) timeStr += ":00";
   return timeStr;
}

int PeriodoTexto(string nome) {
   nome = StringFormat("%s", nome);
   StringToLower(nome);
   if(StringFind(nome, "m15") >= 0) return PERIOD_M15;
   if(StringFind(nome, "m30") >= 0) return PERIOD_M30;
   if(StringFind(nome, "m5") >= 0)  return PERIOD_M5;
   if(StringFind(nome, "m1") >= 0)  return PERIOD_M1;
   if(StringFind(nome, "h1") >= 0)  return PERIOD_H1;
   if(StringFind(nome, "h4") >= 0)  return PERIOD_H4;
   if(StringFind(nome, "d1") >= 0)  return PERIOD_D1;
   if(StringFind(nome, "minutos") >= 0 || StringFind(nome, "min") >= 0) {
      double m = ExtractNumber(nome, "");
      if(m == 1) return PERIOD_M1;
      if(m == 5) return PERIOD_M5;
      if(m == 15) return PERIOD_M15;
      if(m == 30) return PERIOD_M30;
   }
   return PERIOD_CURRENT;
}

// ---------- 3. NLP INTERPRETER ----------

void ResetStrategy() {
   for(int i=0; i<p_nRules; i++) {
      if(p_rules[i].p1_handle != INVALID_HANDLE) IndicatorRelease(p_rules[i].p1_handle);
      if(p_rules[i].p2_handle != INVALID_HANDLE) IndicatorRelease(p_rules[i].p2_handle);
   }
   ZeroMemory(p_rules);
   p_nRules = 0;
   p_riskPercent = 1.0;
   p_stopPoints = 300;
   p_takePoints = 500;
   p_trailingStopPoints = 0;
   p_breakEvenPoints = 0;
   p_breakEvenProfit = 50;
   p_maxSimultaneous = 3;
   p_hedge = false;
   p_useMartingale = false;
   p_startTimeSeconds = 0;
   p_endTimeSeconds = 86399;
   p_timeframeMinutes = 1;
}

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   string lowerPrompt = prompt;
   StringToLower(lowerPrompt);

   // Global parameters
   if(StringFind(lowerPrompt, "risco de") >= 0) p_riskPercent = ExtractNumber(lowerPrompt, "risco de");
   if(StringFind(lowerPrompt, "stop de") >= 0) p_stopPoints = (int)ExtractNumber(lowerPrompt, "stop de");
   if(StringFind(lowerPrompt, "take de") >= 0) p_takePoints = (int)ExtractNumber(lowerPrompt, "take de");
   if(StringFind(lowerPrompt, "máximo") >= 0 && StringFind(lowerPrompt, "simultâneos") >= 0)
      p_maxSimultaneous = (int)ExtractNumber(lowerPrompt, "máximo");

   if(StringFind(lowerPrompt, "atingir +") >= 0) p_breakEvenPoints = (int)ExtractNumber(lowerPrompt, "atingir +");
   if(StringFind(lowerPrompt, "move stop para entrada +") >= 0)
      p_breakEvenProfit = (int)ExtractNumber(lowerPrompt, "move stop para entrada +");

   if(StringFind(lowerPrompt, "trailing") >= 0) p_trailingStopPoints = (int)ExtractNumber(lowerPrompt, "trailing");
   if(StringFind(lowerPrompt, "martingale") >= 0) p_useMartingale = true;
   if(StringFind(lowerPrompt, "hedge") >= 0) p_hedge = true;

   if(StringFind(lowerPrompt, "depois das") >= 0) {
      string t = ExtractTime(lowerPrompt, "depois das");
      p_startTimeSeconds = StringToTime("2020.01.01 " + t) - StringToTime("2020.01.01 00:00");
   }

   // Timeframe
   p_timeframeMinutes = PeriodoTexto(lowerPrompt);

   // Rules segmentation
   string segments[];
   ushort sep = '.';
   if(StringFind(lowerPrompt, ",") >= 0) sep = ',';
   StringSplit(lowerPrompt, sep, segments);

   Signal currentIntent = NONE;

   for(int i=0; i<ArraySize(segments); i++) {
      string s = segments[i];
      StringTrimLeft(s);

      if(StringFind(s, "compra") >= 0) currentIntent = BUY;
      else if(StringFind(s, "vende") >= 0) currentIntent = SELL;

      if(currentIntent == NONE) continue;

      // MA CROSS
      if(StringFind(s, "média") >= 0 && (StringFind(s, "cruzar") >= 0 || StringFind(s, "cruzamento") >= 0)) {
         p_rules[p_nRules].active = true;
         p_rules[p_nRules].type = RULE_MA_CROSS;
         p_rules[p_nRules].intent = currentIntent;
         p_rules[p_nRules].tf = p_timeframeMinutes;
         p_rules[p_nRules].p1 = (int)ExtractNumber(s, "média");
         // Check for second MA
         int pos = StringFind(s, "/");
         p_rules[p_nRules].p1_handle = iMA(_Symbol, (ENUM_TIMEFRAMES)p_rules[p_nRules].tf, p_rules[p_nRules].p1, 0, MODE_EMA, PRICE_CLOSE);
         if(pos >= 0) {
            p_rules[p_nRules].p2 = (int)ExtractNumber(StringSubstr(s, pos), "");
            p_rules[p_nRules].p2_handle = iMA(_Symbol, (ENUM_TIMEFRAMES)p_rules[p_nRules].tf, p_rules[p_nRules].p2, 0, MODE_EMA, PRICE_CLOSE);
         } else {
            p_rules[p_nRules].p2 = 0;
            p_rules[p_nRules].p2_handle = INVALID_HANDLE;
         }
         p_nRules++;
      }

      // RSI
      if(StringFind(s, "rsi") >= 0) {
         p_rules[p_nRules].active = true;
         p_rules[p_nRules].type = RULE_RSI;
         p_rules[p_nRules].intent = currentIntent;
         p_rules[p_nRules].tf = p_timeframeMinutes;
         p_rules[p_nRules].p1 = (int)ExtractNumber(s, "rsi");
         if(p_rules[p_nRules].p1 == 0) p_rules[p_nRules].p1 = 14;

         if(StringFind(s, "acima de") >= 0) p_rules[p_nRules].d1 = ExtractNumber(s, "acima de");
         if(StringFind(s, "abaixo de") >= 0) p_rules[p_nRules].d1 = ExtractNumber(s, "abaixo de");

         p_rules[p_nRules].p1_handle = iRSI(_Symbol, (ENUM_TIMEFRAMES)p_rules[p_nRules].tf, p_rules[p_nRules].p1, PRICE_CLOSE);
         p_nRules++;
      }

      // Add more indicators here...
   }
}

// ---------- 4. CORE TRADING LOGIC ----------

Signal AvaliaRegra(Rule &r, int shift) {
   switch(r.type) {
      case RULE_MA_CROSS: return CruzamentoMA(r, shift);
      case RULE_RSI:      return RSIThreshold(r, shift);
      case RULE_STOCH:    return StochCross(r, shift);
      case RULE_BB:       return BBounce(r, shift);
      case RULE_DAILY_BREAK: return DailyBreak(r, shift);
      case RULE_DELTA:    return DeltaAggression(r, shift);
      case RULE_VOLUME:   return VolumeCycle(r, shift);
      case RULE_AMA:      return AMA(r, shift);
      case RULE_BAR2:     return Bar2Pattern(r, shift);
      case RULE_RS_REL:   return RSRelative(r, shift);
   }
   return NONE;
}

Signal AvaliaTudo() {
   int buyVotes = 0, buyRules = 0;
   int sellVotes = 0, sellRules = 0;

   for(int i=0; i<p_nRules; i++) {
      if(!p_rules[i].active) continue;
      Signal s = AvaliaRegra(p_rules[i], 1);

      if(p_rules[i].intent == BUY) {
         buyRules++;
         if(s == BUY) buyVotes++;
      } else if(p_rules[i].intent == SELL) {
         sellRules++;
         if(s == SELL) sellVotes++;
      }
   }

   if(buyRules > 0 && buyVotes == buyRules) return BUY;
   if(sellRules > 0 && sellVotes == sellRules) return SELL;

   return NONE;
}

double CalculaLote(double riscoPercent, int slPoints) {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * (riscoPercent / 100.0);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(slPoints <= 0) slPoints = p_stopPoints;
   double slDistance = slPoints * point;

   double volume = riskMoney / (slDistance * (tickValue / tickSize));

   // Martingale
   if(p_useMartingale) {
      HistorySelect(TimeCurrent() - 86400, TimeCurrent());
      int total = HistoryDealsTotal();
      for(int i=total-1; i>=0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            if(profit < 0) volume *= 2.0;
            break;
         }
      }
   }

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   volume = MathFloor(volume / step) * step;
   if(volume < minLot) volume = minLot;
   if(volume > maxLot) volume = maxLot;

   return volume;
}

bool AguardaNoticias() {
   int handle = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      string content = FileReadString(handle);
      FileClose(handle);
      if(content == "1") return true;
   }
   return false;
}

void EnviaOrdem(Signal s) {
   if(s == NONE) return;

   if(PositionsTotal() >= p_maxSimultaneous) return;
   if(AguardaNoticias()) return;

   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = (s == BUY) ? price - p_stopPoints * _Point : price + p_stopPoints * _Point;
   double tp = (s == BUY) ? price + p_takePoints * _Point : price - p_takePoints * _Point;
   double lot = CalculaLote(p_riskPercent, p_stopPoints);

   trade.SetExpertMagicNumber(EA_MAGIC);
   if(s == BUY) trade.Buy(lot, _Symbol, price, sl, tp, "MT-LiveExecutor BUY");
   else trade.Sell(lot, _Symbol, price, sl, tp, "MT-LiveExecutor SELL");
}

void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == EA_MAGIC) {
         double openPrice = posInfo.PriceOpen();
         double currentPrice = (posInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double sl = posInfo.StopLoss();

         double profitPoints = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (currentPrice - openPrice) / _Point : (openPrice - currentPrice) / _Point;

         // Break-even
         if(p_breakEvenPoints > 0 && profitPoints >= p_breakEvenPoints) {
            double targetSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? openPrice + p_breakEvenProfit * _Point : openPrice - p_breakEvenProfit * _Point;
            if((posInfo.PositionType() == POSITION_TYPE_BUY && (sl < targetSL || sl == 0)) ||
               (posInfo.PositionType() == POSITION_TYPE_SELL && (sl > targetSL || sl == 0))) {
               trade.PositionModify(posInfo.Ticket(), targetSL, posInfo.TakeProfit());
            }
         }

         // Trailing Stop
         if(p_trailingStopPoints > 0 && profitPoints >= p_trailingStopPoints) {
             double targetSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? currentPrice - p_trailingStopPoints * _Point : currentPrice + p_trailingStopPoints * _Point;
             if((posInfo.PositionType() == POSITION_TYPE_BUY && targetSL > sl) ||
                (posInfo.PositionType() == POSITION_TYPE_SELL && (targetSL < sl || sl == 0))) {
                trade.PositionModify(posInfo.Ticket(), targetSL, posInfo.TakeProfit());
             }
         }
      }
   }
}

// ---------- 5. LOGGING & METRICS ----------

void GravaCSV() {
   int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV | FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      FileWrite(handle, "Ticket", "Symbol", "Type", "PriceOpen", "SL", "TP", "Profit");
      for(int i=0; i<PositionsTotal(); i++) {
         if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC) {
            FileWrite(handle, posInfo.Ticket(), posInfo.Symbol(), posInfo.PositionType(), posInfo.PriceOpen(), posInfo.StopLoss(), posInfo.TakeProfit(), posInfo.Profit());
         }
      }
      FileClose(handle);
   }
}

void CalculaEstatisticas() {
   HistorySelect(0, TimeCurrent());
   int totalDeals = HistoryDealsTotal();
   int wins = 0, losses = 0;
   double profitSum = 0, lossSum = 0;

   for(int i=0; i<totalDeals; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
         double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT) + HistoryDealGetDouble(ticket, DEAL_COMMISSION) + HistoryDealGetDouble(ticket, DEAL_SWAP);
         if(profit > 0) { wins++; profitSum += profit; }
         else if(profit < 0) { losses++; lossSum += MathAbs(profit); }
      }
   }

   double winRate = (wins + losses > 0) ? (double)wins / (wins + losses) * 100.0 : 0;
   double profitFactor = (lossSum > 0) ? profitSum / lossSum : profitSum;

   PrintFormat("Win Rate: %.2f%% | Profit Factor: %.2f", winRate, profitFactor);
}

// ---------- 6. LIFECYCLE HANDLERS ----------

int OnInit() {
   EventSetTimer(1);
   trade.SetExpertMagicNumber(EA_MAGIC);

   // Initial prompt read
   int handle = FileOpen("MT_LiveExecutor_Prompt.txt", FILE_READ | FILE_TXT | FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      string prompt = FileReadString(handle);
      FileClose(handle);
      InterpretaPrompt(prompt);
   }

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   ResetStrategy();
   EventKillTimer();
}

void OnTick() {
   datetime currentBar = iTime(_Symbol, (ENUM_TIMEFRAMES)p_timeframeMinutes, 0);
   bool newBar = (currentBar != p_lastBarTime);
   p_lastBarTime = currentBar;

   GerenciaPosicoes();

   if(newBar) {
      long currentTime = TimeCurrent() % 86400;
      if(currentTime >= p_startTimeSeconds && currentTime <= p_endTimeSeconds) {
         Signal s = AvaliaTudo();
         EnviaOrdem(s);
      }
      GravaCSV();
      CalculaEstatisticas();
   }
}

void OnTimer() {
   if(GlobalVariableCheck("MT_Executor_Prompt_Update")) {
      int handle = FileOpen("MT_LiveExecutor_Prompt.txt", FILE_READ | FILE_TXT | FILE_COMMON);
      if(handle != INVALID_HANDLE) {
         string prompt = FileReadString(handle);
         FileClose(handle);
         InterpretaPrompt(prompt);
         GlobalVariableDel("MT_Executor_Prompt_Update");
         Print("Estratégia atualizada com sucesso.");
      }
   }
}
