//=========================  MT-LiveExecutor  =========================
// Description: Dynamic MQL5 Expert Advisor for Natural Language Strategy Execution.
// Integrates MT5-KNOWLEDGE-CORE and real-time NLP parsing.
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
   RT_RSI,
   RT_STOCH,
   RT_BB,
   RT_DAILY_BREAK,
   RT_DELTA,
   RT_VOLUME,
   RT_AMA,
   RT_BAR_PATTERN,
   RT_RELATIVE_STRENGTH
};

struct Rule {
   bool      active;
   RuleType  type;
   ENUM_TIMEFRAMES tf;
   int       p1, p2, p3;
   double    d1, d2;
   string    s1;
   Signal    intent; // BUY, SELL or NONE (filter)
   int       handle;
   int       handle2;
};

// Global Operational Parameters
double         p_riskPercent = 1.0;
int            p_stopPoints = 0;
int            p_takePoints = 0;
int            p_trailingStopPoints = 0;
int            p_beTriggerPoints = 0;
int            p_bePlusPoints = 0;
int            p_maxSimultaneousTrades = 1;
bool           p_hedge = true;
bool           p_useMartingale = false;
long           p_startTimeSeconds = 0;
ENUM_TIMEFRAMES p_frequency = PERIOD_CURRENT;

// System Globals
Rule           rules[30];
int            nRules = 0;
CTrade         trade;
CPositionInfo  posInfo;
CSymbolInfo    symbolInfo;
CAccountInfo   accountInfo;
const long     EA_MAGIC = 20260101;
datetime       lastBarTime = 0;
datetime       lastLogTime = 0;

// Forward Declarations
void ResetStrategy();
void InterpretaPrompt(string prompt);
Signal AvaliaTudo();
double CalculaLote(double riskPercent);
void EnviaOrdem(Signal s);
void GerenciaPosicoes();
bool AguardaNoticias();
void GravaLog(string text);
void GravaCSV();
ENUM_TIMEFRAMES PeriodoTexto(string nome);
double ExtraiNumero(string txt, string keyword);
string ExtractTime(string txt);

// ---------- 2. INITIALIZATION ----------
int OnInit() {
   trade.SetExpertMagicNumber(EA_MAGIC);
   symbolInfo.Name(_Symbol);
   EventSetTimer(1);

   if(GlobalVariableGet("MT_Executor_Prompt_Update") > 0) {
      // Reload logic handled in OnTimer
   } else {
      GravaLog("MT-LiveExecutor iniciado. Aguardando prompt...");
   }

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   EventKillTimer();
   ResetStrategy();
}

// ---------- 3. MT5-KNOWLEDGE-CORE INDICATORS (MQL5 Implementation) ----------

Signal CruzamentoMA(int fast, int slow, ENUM_TIMEFRAMES tf, int h_fast, int h_slow) {
   double f[2], s[2];
   if(CopyBuffer(h_fast, 0, 0, 2, f) < 2 || CopyBuffer(h_slow, 0, 0, 2, s) < 2) return NONE;
   ArraySetAsSeries(f, true); ArraySetAsSeries(s, true);
   if (f[1] < s[1] && f[0] > s[0]) return BUY;
   if (f[1] > s[1] && f[0] < s[0]) return SELL;
   return NONE;
}

Signal RSIThreshold(int period, double over, double under, ENUM_TIMEFRAMES tf, int handle, Signal intent) {
   double v[2];
   if(CopyBuffer(handle, 0, 0, 2, v) < 2) return NONE;
   ArraySetAsSeries(v, true);

   if(intent == BUY) {
      if(v[1] <= under && v[0] > under) return BUY; // Cross above 'under' (momentum/reversal)
      if(v[1] <= over && v[0] > over) return BUY;   // Cross above 'over' (momentum)
      if(v[0] > over || v[0] < under) return BUY;   // State based
   } else if(intent == SELL) {
      if(v[1] >= over && v[0] < over) return SELL; // Cross below 'over'
      if(v[1] >= under && v[0] < under) return SELL; // Cross below 'under'
      if(v[0] < under || v[0] > over) return SELL;
   }

   if (v[0] > over) return SELL;
   if (v[0] < under) return BUY;
   return NONE;
}

Signal StochCross(int k, int d, int slowing, ENUM_TIMEFRAMES tf, int handle) {
   double k_val[2], d_val[2];
   if(CopyBuffer(handle, 0, 0, 2, k_val) < 2 || CopyBuffer(handle, 1, 0, 2, d_val) < 2) return NONE;
   ArraySetAsSeries(k_val, true); ArraySetAsSeries(d_val, true);
   if (k_val[1] < d_val[1] && k_val[0] > d_val[0]) return BUY;
   if (k_val[1] > d_val[1] && k_val[0] < d_val[0]) return SELL;
   return NONE;
}

Signal BBounce(int period, double desv, ENUM_TIMEFRAMES tf, int handle) {
   double upper[1], lower[1];
   if(CopyBuffer(handle, 1, 1, 1, upper) < 1 || CopyBuffer(handle, 2, 1, 1, lower) < 1) return NONE;
   double close = iClose(_Symbol, tf, 1);
   if (close < lower[0]) return BUY;
   if (close > upper[0]) return SELL;
   return NONE;
}

Signal DailyBreak() {
   double hi = iHigh(_Symbol, PERIOD_D1, 1);
   double lo = iLow(_Symbol, PERIOD_D1, 1);
   double close = iClose(_Symbol, PERIOD_M1, 1);
   if (close > hi + _Point) return BUY;
   if (close < lo - _Point) return SELL;
   return NONE;
}

Signal DeltaAggression(int seconds, int deltaTrigger) {
   MqlTick arr[];
   int n = CopyTicksRange(_Symbol, arr, COPY_TICKS_TRADE, TimeCurrent() - seconds, TimeCurrent());
   long buy = 0, sell = 0;
   for (int i = 0; i < n; i++) {
      if ((arr[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++;
      else if ((arr[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sell++;
   }
   long delta = buy - sell;
   if (delta > deltaTrigger) return BUY;
   if (delta < -deltaTrigger) return SELL;
   return NONE;
}

Signal VolumeCycle(int len, ENUM_TIMEFRAMES tf) {
   long vol[12];
   if(CopyVolume(_Symbol, tf, 1, len, vol) < len) return NONE;
   int highIdx = ArrayMaximum(vol);
   int lowIdx = ArrayMinimum(vol);
   if (highIdx == 0) return SELL;
   if (lowIdx == 0) return BUY;
   return NONE;
}

Signal AMACross(int handle) {
   double ama[2];
   if(CopyBuffer(handle, 0, 0, 2, ama) < 2) return NONE;
   ArraySetAsSeries(ama, true);
   if (ama[1] < ama[0]) return BUY;
   if (ama[1] > ama[0]) return SELL;
   return NONE;
}

Signal Bar2Pattern(ENUM_TIMEFRAMES tf) {
   double h0 = iHigh(_Symbol, tf, 1);
   double l0 = iLow(_Symbol, tf, 1);
   double h1 = iHigh(_Symbol, tf, 2);
   double l1 = iLow(_Symbol, tf, 2);
   double c0 = iClose(_Symbol, tf, 1);
   double o0 = iOpen(_Symbol, tf, 1);
   if (h0 < h1 && l0 > l1) return (c0 > o0) ? BUY : SELL;
   if (h0 > h1 && l0 < l1) return (c0 > o0) ? SELL : BUY;
   return NONE;
}

Signal RSRelative(string bench, int len, ENUM_TIMEFRAMES tf, int h1, int h2) {
   double r1[1], r2[1];
   if(CopyBuffer(h1, 0, 1, 1, r1) < 1 || CopyBuffer(h2, 0, 1, 1, r2) < 1) return NONE;
   if (r1[0] > r2[0] + 5) return BUY;
   if (r1[0] < r2[0] - 5) return SELL;
   return NONE;
}

// ---------- 4. NLP ENGINE & STRATEGY MANAGEMENT ----------

void ResetStrategy() {
   for(int i = 0; i < nRules; i++) {
      if(rules[i].handle != INVALID_HANDLE) IndicatorRelease(rules[i].handle);
      if(rules[i].handle2 != INVALID_HANDLE) IndicatorRelease(rules[i].handle2);
   }
   ZeroMemory(rules);
   nRules = 0;
   p_riskPercent = 1.0;
   p_stopPoints = 0;
   p_takePoints = 0;
   p_trailingStopPoints = 0;
   p_beTriggerPoints = 0;
   p_bePlusPoints = 0;
   p_maxSimultaneousTrades = 1;
   p_hedge = true;
   p_useMartingale = false;
   p_startTimeSeconds = 0;
   p_frequency = PERIOD_CURRENT;
   lastBarTime = 0;
}

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   string lowerPrompt = prompt;
   StringToLower(lowerPrompt);

   // Global Operational Parameters Extraction
   p_riskPercent = ExtraiNumero(lowerPrompt, "risco de");
   if(p_riskPercent == 0) p_riskPercent = 1.0;

   p_stopPoints = (int)ExtraiNumero(lowerPrompt, "stop de");
   p_takePoints = (int)ExtraiNumero(lowerPrompt, "take de");
   p_trailingStopPoints = (int)ExtraiNumero(lowerPrompt, "trailing de");
   if(p_trailingStopPoints == 0) p_trailingStopPoints = (int)ExtraiNumero(lowerPrompt, "atingir +");

   if(StringFind(lowerPrompt, "move stop para entrada") >= 0) {
      p_beTriggerPoints = (int)ExtraiNumero(lowerPrompt, "atingir +");
      p_bePlusPoints = (int)ExtraiNumero(lowerPrompt, "entrada +");
   }

   p_maxSimultaneousTrades = (int)ExtraiNumero(lowerPrompt, "máximo");
   if(p_maxSimultaneousTrades == 0) p_maxSimultaneousTrades = 1;

   if(StringFind(lowerPrompt, "martingale") >= 0) p_useMartingale = true;
   if(StringFind(lowerPrompt, "hedge") >= 0) p_hedge = true;

   string startTimeStr = ExtractTime(lowerPrompt);
   if(startTimeStr != "") {
      p_startTimeSeconds = (long)StringToTime(startTimeStr) % 86400;
   }

   p_frequency = PeriodoTexto(lowerPrompt);

   // Indicator Rules Extraction
   string segments[];
   ushort sep = StringGetCharacter(".", 0);
   if(StringSplit(lowerPrompt, sep, segments) <= 0) {
      ArrayResize(segments, 1);
      segments[0] = lowerPrompt;
   }

   for(int i = 0; i < ArraySize(segments); i++) {
      string seg = segments[i];
      Signal currentIntent = NONE;
      if(StringFind(seg, "compra") >= 0) currentIntent = BUY;
      else if(StringFind(seg, "vende") >= 0) currentIntent = SELL;

      // MA Cross
      if(StringFind(seg, "média") >= 0 || StringFind(seg, "ma") >= 0) {
         int p1 = (int)ExtraiNumero(seg, "média de");
         if(p1 == 0) p1 = (int)ExtraiNumero(seg, "ma");
         if(p1 == 0) p1 = 20;

         rules[nRules].active = true;
         rules[nRules].type = RT_MA_CROSS;
         rules[nRules].p1 = p1;
         rules[nRules].tf = p_frequency;
         rules[nRules].intent = currentIntent;
         // For price crossing MA, handle1 = price (fast), handle2 = MA (slow)
         rules[nRules].handle = iMA(_Symbol, p_frequency, 1, 0, MODE_SMA, PRICE_CLOSE);
         rules[nRules].handle2 = iMA(_Symbol, p_frequency, p1, 0, MODE_EMA, PRICE_CLOSE);
         nRules++;
      }

      // RSI
      if(StringFind(seg, "rsi") >= 0) {
         int per = (int)ExtraiNumero(seg, "rsi (");
         if(per == 0) per = (int)ExtraiNumero(seg, "rsi");
         if(per == 0) per = 14;

         double over = ExtraiNumero(seg, "acima de");
         if(over == 0) over = 70;
         double under = ExtraiNumero(seg, "abaixo de");
         if(under == 0) under = 30;

         rules[nRules].active = true;
         rules[nRules].type = RT_RSI;
         rules[nRules].p1 = per;
         rules[nRules].d1 = over;
         rules[nRules].d2 = under;
         rules[nRules].tf = p_frequency;
         rules[nRules].intent = currentIntent;
         rules[nRules].handle = iRSI(_Symbol, p_frequency, per, PRICE_CLOSE);
         nRules++;
      }

      // Bollinger Bands
      if(StringFind(seg, "bollinger") >= 0 || StringFind(seg, "bandas") >= 0) {
         int per = (int)ExtraiNumero(seg, "períodos");
         if(per == 0) per = 20;
         double dev = ExtraiNumero(seg, "desvio");
         if(dev == 0) dev = 2.0;

         rules[nRules].active = true;
         rules[nRules].type = RT_BB;
         rules[nRules].p1 = per;
         rules[nRules].d1 = dev;
         rules[nRules].tf = p_frequency;
         rules[nRules].intent = currentIntent;
         rules[nRules].handle = iBands(_Symbol, p_frequency, per, 0, dev, PRICE_CLOSE);
         nRules++;
      }

      // Daily Breakout
      if(StringFind(seg, "rompimento diário") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = RT_DAILY_BREAK;
         rules[nRules].intent = currentIntent;
         nRules++;
      }
   }

   GravaLog("Estratégia atualizada: " + (string)nRules + " regras ativas. Frequência: " + EnumToString(p_frequency));
}

ENUM_TIMEFRAMES PeriodoTexto(string txt) {
   if(StringFind(txt, "15 minutos") >= 0 || StringFind(txt, "m15") >= 0) return PERIOD_M15;
   if(StringFind(txt, "30 minutos") >= 0 || StringFind(txt, "m30") >= 0) return PERIOD_M30;
   if(StringFind(txt, "5 minutos") >= 0 || StringFind(txt, "m5") >= 0) return PERIOD_M5;
   if(StringFind(txt, "1 minuto") >= 0 || StringFind(txt, "m1") >= 0) return PERIOD_M1;
   if(StringFind(txt, "1 hora") >= 0 || StringFind(txt, "h1") >= 0) return PERIOD_H1;
   if(StringFind(txt, "diário") >= 0 || StringFind(txt, "d1") >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

double ExtraiNumero(string txt, string keyword) {
   int pos = StringFind(txt, keyword);
   if(pos < 0) return 0;
   string sub = StringSubstr(txt, pos + StringLen(keyword));
   string res = "";
   bool foundDigit = false;
   for(int i = 0; i < StringLen(sub); i++) {
      ushort c = StringGetCharacter(sub, i);
      if((c >= '0' && c <= '9') || c == '.' || c == ',') {
         if(c == ',') res += ".";
         else res += CharToString((uchar)c);
         foundDigit = true;
      } else if(foundDigit) break;
   }
   return StringToDouble(res);
}

string ExtractTime(string txt) {
   int pos = StringFind(txt, "depois das");
   if(pos < 0) pos = StringFind(txt, "após");
   if(pos < 0) return "";
   string sub = StringSubstr(txt, pos + 10);
   string res = "";
   for(int i = 0; i < StringLen(sub); i++) {
      ushort c = StringGetCharacter(sub, i);
      if((c >= '0' && c <= '9') || c == ':' || c == 'h') {
         if(c == 'h') res += ":00";
         else res += CharToString((uchar)c);
      } else if(StringLen(res) > 0) break;
   }
   if(StringLen(res) == 2) res += ":00";
   return res;
}

// ---------- 5. TRADING LOGIC & EXECUTION ----------

Signal AvaliaTudo() {
   int buyLeg = 0, sellLeg = 0;
   int buyRules = 0, sellRules = 0;

   for(int i = 0; i < nRules; i++) {
      if(!rules[i].active) continue;
      Signal sig = NONE;

      switch(rules[i].type) {
         case RT_MA_CROSS: sig = CruzamentoMA(rules[i].p1, 0, rules[i].tf, rules[i].handle, rules[i].handle2); break;
         case RT_RSI:      sig = RSIThreshold(rules[i].p1, rules[i].d1, rules[i].d2, rules[i].tf, rules[i].handle, rules[i].intent); break;
         case RT_BB:       sig = BBounce(rules[i].p1, rules[i].d1, rules[i].tf, rules[i].handle); break;
         case RT_DAILY_BREAK: sig = DailyBreak(); break;
         // Add more cases as needed
      }

      if(rules[i].intent == BUY) {
         if(sig == BUY) buyLeg++;
         buyRules++;
      } else if(rules[i].intent == SELL) {
         if(sig == SELL) sellLeg++;
         sellRules++;
      } else { // Filter mode (must agree)
         if(sig == BUY) buyLeg++;
         if(sig == SELL) sellLeg++;
         buyRules++; sellRules++;
      }
   }

   if(buyRules > 0 && buyLeg == buyRules) return BUY;
   if(sellRules > 0 && sellLeg == sellRules) return SELL;
   return NONE;
}

double CalculaLote(double riskPercent) {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = equity * riskPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double stopPoints = (p_stopPoints > 0) ? (double)p_stopPoints : 1000.0; // Default if no stop

   double volume = riskAmount / (stopPoints * (tickValue / (tickSize / _Point)));
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   volume = MathMax(minLot, MathMin(maxLot, NormalizeDouble(volume / stepLot, 0) * stepLot));
   return NormalizeDouble(volume, 2);
}

void EnviaOrdem(Signal s) {
   if(s == NONE) return;

   // Hedge logic: close opposite if not allowed
   if(!p_hedge) {
      for(int i = PositionsTotal() - 1; i >= 0; i--) {
         if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == EA_MAGIC) {
            if((s == BUY && posInfo.PositionType() == POSITION_TYPE_SELL) ||
               (s == SELL && posInfo.PositionType() == POSITION_TYPE_BUY)) {
               trade.PositionClose(posInfo.Ticket());
            }
         }
      }
   }

   // Trade limit
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == EA_MAGIC) count++;
   }
   if(count >= p_maxSimultaneousTrades) return;

   double lot = CalculaLote(p_riskPercent);
   if(p_useMartingale) {
      if(HistorySelect(TimeCurrent() - 86400, TimeCurrent())) {
         for(int i = HistoryDealsTotal() - 1; i >= 0; i--) {
            ulong t = HistoryDealGetTicket(i);
            if(HistoryDealGetString(t, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC) {
               if(HistoryDealGetDouble(t, DEAL_PROFIT) < 0) lot *= 2.0;
               break;
            }
         }
      }
   }

   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0, tp = 0;

   if(p_stopPoints > 0) sl = (s == BUY) ? price - p_stopPoints * _Point : price + p_stopPoints * _Point;
   if(p_takePoints > 0) tp = (s == BUY) ? price + p_takePoints * _Point : price - p_takePoints * _Point;

   if(s == BUY) trade.Buy(lot, _Symbol, price, sl, tp, "MT-LiveExecutor Entry");
   else trade.Sell(lot, _Symbol, price, sl, tp, "MT-LiveExecutor Entry");

   if(trade.ResultRetcode() == TRADE_RETCODE_DONE) {
      GravaLog("Ordem enviada: " + EnumToString(s) + " " + (string)lot + " lotes.");
   } else {
      GravaLog("Erro ao enviar ordem: " + (string)trade.ResultRetcode() + " " + trade.ResultComment());
   }
}

void GerenciaPosicoes() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(!posInfo.SelectByIndex(i) || posInfo.Symbol() != _Symbol || posInfo.Magic() != EA_MAGIC) continue;

      double price = posInfo.PriceOpen();
      double currentPrice = (posInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double diff = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (currentPrice - price) : (price - currentPrice);
      int points = (int)(diff / _Point);

      // Break-even
      if(p_beTriggerPoints > 0 && points >= p_beTriggerPoints) {
         double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? price + p_bePlusPoints * _Point : price - p_bePlusPoints * _Point;
         if(posInfo.StopLoss() != newSL) trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
      }

      // Trailing Stop
      if(p_trailingStopPoints > 0 && points >= p_trailingStopPoints) {
         double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? currentPrice - p_trailingStopPoints * _Point : currentPrice + p_trailingStopPoints * _Point;
         if(posInfo.PositionType() == POSITION_TYPE_BUY && (newSL > posInfo.StopLoss() || posInfo.StopLoss() == 0)) trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
         if(posInfo.PositionType() == POSITION_TYPE_SELL && (newSL < posInfo.StopLoss() || posInfo.StopLoss() == 0)) trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
      }
   }
}

// ---------- 6. UTILITIES & EVENT HANDLERS ----------

bool AguardaNoticias() {
   int handle = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      string content = FileReadString(handle);
      FileClose(handle);
      if(content == "1") return true;
      datetime vetoTime = StringToTime(content);
      if(vetoTime > 0 && MathAbs(TimeCurrent() - vetoTime) < 1200) return true;
   }
   return false;
}

void GravaLog(string text) {
   Print("MT-LiveExecutor: ", text);
   int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE | FILE_READ | FILE_TXT | FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      FileSeek(handle, 0, SEEK_END);
      FileWriteString(handle, TimeToString(TimeCurrent()) + ": " + text + "\r\n");
      FileClose(handle);
   }
}

void GravaCSV() {
   if(TimeCurrent() - lastLogTime < 5) return;
   lastLogTime = TimeCurrent();
   int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_TXT | FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      FileWriteString(handle, "Ticket,Symbol,Type,Volume,Price,SL,TP\r\n");
      for(int i = 0; i < PositionsTotal(); i++) {
         if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC) {
            FileWriteString(handle, (string)posInfo.Ticket() + "," + posInfo.Symbol() + "," + EnumToString(posInfo.PositionType()) + "," +
                            (string)posInfo.Volume() + "," + (string)posInfo.PriceOpen() + "," + (string)posInfo.StopLoss() + "," + (string)posInfo.TakeProfit() + "\r\n");
         }
      }
      FileClose(handle);
   }
}

void OnTick() {
   GerenciaPosicoes();
   GravaCSV();

   if(AguardaNoticias()) return;

   long nowSeconds = TimeCurrent() % 86400;
   if(p_startTimeSeconds > 0 && nowSeconds < p_startTimeSeconds) return;

   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar != lastBarTime) {
      Signal s = AvaliaTudo();
      if(s != NONE) EnviaOrdem(s);
      lastBarTime = currentBar;
   }
}

void OnTimer() {
   if(GlobalVariableGet("MT_Executor_Prompt_Update") > 0) {
      int handle = FileOpen("MT_LiveExecutor_Prompt.txt", FILE_READ | FILE_TXT | FILE_COMMON);
      if(handle != INVALID_HANDLE) {
         string prompt = FileReadString(handle);
         FileClose(handle);
         InterpretaPrompt(prompt);
         GlobalVariableSet("MT_Executor_Prompt_Update", 0);
      }
   }
}
