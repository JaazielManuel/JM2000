//=========================  MT5-LIVE-EXECUTOR  =========================
// Profit Master v8.0 - 2026
// Optimized for MQL5 terminal execution via Portuguese NLP prompts.
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// ---------- 1. DATA STRUCTURES & ENUMS ----------

enum Signal { BUY = 1, SELL = -1, NONE = 0 };

enum RuleType {
   RT_MA_CROSS,
   RT_RSI_THRESHOLD,
   RT_STOCH_CROSS,
   RT_BB_BOUNCE,
   RT_DAILY_BREAK,
   RT_DELTA_AGG,
   RT_VOL_CYCLE,
   RT_AMA,
   RT_BAR_PATTERN,
   RT_RS_RELATIVE
};

struct Rule {
   bool      active;
   RuleType  type;
   ENUM_TIMEFRAMES tf;
   int       p1, p2, p3;
   double    d1, d2;
   string    s1;
   bool      is_cross;
   int       handle1;
   int       handle2;
   int       p3_handle;
};

// ---------- 2. GLOBAL PARAMETERS & STATE ----------

Rule      rules[30];
int       nRules = 0;
CTrade    trade;
CPositionInfo posInfo;
CSymbolInfo   symInfo;
CAccountInfo  accInfo;

// Strategy Parameters
int       p_startHour = 0;
int       p_newsVetoMin = 0;
int       p_maxTrades = 1;
double    p_riskPercent = 1.0;
int       p_stopPoints = 0;
int       p_takePoints = 0;
int       p_trailingStopPoints = 0;
int       p_breakEvenPoints = 0;
int       p_breakEvenProfit = 0;
bool      p_martingale = false;
bool      p_hedge = false;
bool      p_notificacoes = false;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

// Runtime State
datetime  lastBarTime = 0;
int       dynamicSafetyPoints = 0;
int       atrHandle = INVALID_HANDLE;
datetime  lastSafetyDecay = 0;

// ---------- 3. UTILS & HELPERS ----------

double NS(double price) { return NormalizeDouble(price, _Digits); }
double NV(double vol)   {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   return NormalizeDouble(MathFloor(vol/step)*step, 2);
}

void UpdatePriceCache() {
   MqlTick tick;
   if(SymbolInfoTick(_Symbol, tick)) {
      // Prices are updated in the tick structure
   }
}

// Memory: PeriodoTexto maps Portuguese temporal keywords
ENUM_TIMEFRAMES PeriodoTexto(string nome) {
   nome = StringToLower(nome);
   if(StringFind(nome, "m1") >= 0)  return PERIOD_M1;
   if(StringFind(nome, "m5") >= 0)  return PERIOD_M5;
   if(StringFind(nome, "m15") >= 0) return PERIOD_M15;
   if(StringFind(nome, "m30") >= 0) return PERIOD_M30;
   if(StringFind(nome, "h1") >= 0)  return PERIOD_H1;
   if(StringFind(nome, "h4") >= 0)  return PERIOD_H4;
   if(StringFind(nome, "d1") >= 0)  return PERIOD_D1;

   // Check for numeric strings
   int mins = (int)StringToInteger(nome);
   if(mins == 1) return PERIOD_M1;
   if(mins == 5) return PERIOD_M5;
   if(mins == 15) return PERIOD_M15;
   if(mins == 30) return PERIOD_M30;
   if(mins == 60) return PERIOD_H1;
   if(mins == 240) return PERIOD_H4;
   if(mins == 1440) return PERIOD_D1;

   return PERIOD_CURRENT;
}

double ExtraiNumero(string txt, string chave) {
   int pos = StringFind(txt, chave);
   if(pos < 0) return 0;

   string sub = StringSubstr(txt, pos + StringLen(chave));
   // Simple numeric extraction
   string res = "";
   for(int i=0; i<StringLen(sub); i++) {
      ushort c = StringGetCharacter(sub, i);
      if((c >= '0' && c <= '9') || c == '.') {
         res += ShortToString(c);
      } else if(StringLen(res) > 0) {
         break;
      }
   }
   return StringToDouble(res);
}

// ---------- 4. NLP PROMPT PARSER ----------

void InterpretaPrompt(string prompt) {
   StringToLower(prompt);

   // Reset Strategy Parameters
   p_startHour = (int)ExtraiNumero(prompt, "depois das ");
   p_newsVetoMin = (int)ExtraiNumero(prompt, "operar ");
   p_maxTrades = (int)ExtraiNumero(prompt, "máximo ");
   if(p_maxTrades == 0) p_maxTrades = 1;

   p_riskPercent = ExtraiNumero(prompt, "risco de ");
   if(p_riskPercent == 0) p_riskPercent = 1.0;

   p_stopPoints = (int)ExtraiNumero(prompt, "stop de ");
   p_takePoints = (int)ExtraiNumero(prompt, "take de ");

   p_trailingStopPoints = (int)ExtraiNumero(prompt, "trailing stop");
   if(p_trailingStopPoints == 0) p_trailingStopPoints = (int)ExtraiNumero(prompt, "trailing ");

   p_breakEvenPoints = (int)ExtraiNumero(prompt, "atingir +");
   p_breakEvenProfit = (int)ExtraiNumero(prompt, "entrada +");

   p_martingale = (StringFind(prompt, "martingale") >= 0);
   p_hedge = (StringFind(prompt, "hedge") >= 0);
   p_notificacoes = (StringFind(prompt, "notificações") >= 0);

   // Frequency
   int freqMins = (int)ExtraiNumero(prompt, "a cada ");
   if(freqMins > 0) {
      if(freqMins == 1) p_frequency = PERIOD_M1;
      else if(freqMins == 5) p_frequency = PERIOD_M5;
      else if(freqMins == 15) p_frequency = PERIOD_M15;
      else if(freqMins == 30) p_frequency = PERIOD_M30;
      else if(freqMins == 60) p_frequency = PERIOD_H1;
      else if(freqMins == 240) p_frequency = PERIOD_H4;
      else if(freqMins == 1440) p_frequency = PERIOD_D1;
      else p_frequency = PERIOD_M15;
   }

   // Clear existing rules
   for(int i=0; i<30; i++) {
      if(rules[i].handle1 != INVALID_HANDLE) IndicatorRelease(rules[i].handle1);
      if(rules[i].handle2 != INVALID_HANDLE) IndicatorRelease(rules[i].handle2);
      if(rules[i].p3_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p3_handle);
      rules[i].active = false;
   }
   nRules = 0;
   lastBarTime = 0; // Force immediate re-evaluation

   // Segment and add rules
   string cleanedPrompt = prompt;
   StringReplace(cleanedPrompt, " e ", "|");
   StringReplace(cleanedPrompt, " + ", "|");
   StringReplace(cleanedPrompt, " e o ", "|");
   StringReplace(cleanedPrompt, " e a ", "|");

   string segments[];
   ushort separator = StringGetCharacter("|", 0);
   int nSegs = StringSplit(cleanedPrompt, separator, segments);

   for(int i=0; i<nSegs; i++) {
      AddRuleSegment(segments[i]);
   }
}

void AddRuleSegment(string txt) {
   if(nRules >= 30) return;

   // RSI
   if(StringFind(txt, "rsi") >= 0) {
      int period = (int)ExtraiNumero(txt, "(");
      if(period == 0) period = 14;

      double over = ExtraiNumero(txt, "acima de ");
      double under = ExtraiNumero(txt, "abaixo de ");

      // Secondary check for "subir acima" or "cair abaixo"
      if(over == 0) over = ExtraiNumero(txt, "subir acima de ");
      if(under == 0) under = ExtraiNumero(txt, "cair abaixo de ");

      // Check for momentum keywords (buy if above, sell if below)
      bool isMomentum = (StringFind(txt, "compra") >= 0 && over > 0) || (StringFind(txt, "vende") >= 0 && under > 0);

      rules[nRules].active = true;
      rules[nRules].type = RT_RSI_THRESHOLD;
      rules[nRules].p1 = period;

      if(isMomentum) {
         // Momentum: Buy if above threshold (d1), Sell if below threshold (d2)
         rules[nRules].d1 = over;
         rules[nRules].d2 = under;
         rules[nRules].s1 = "momentum";
      } else {
         // Mean Reversion: Sell if above threshold (d1), Buy if below threshold (d2)
         rules[nRules].d1 = (over > 0) ? over : 70;
         rules[nRules].d2 = (under > 0) ? under : 30;
         rules[nRules].s1 = "reversion";
      }

      rules[nRules].handle1 = iRSI(_Symbol, p_frequency, period, PRICE_CLOSE);
      rules[nRules].is_cross = (StringFind(txt, "subir") >= 0 || StringFind(txt, "cair") >= 0);
      nRules++;
   }

   // Moving Average
   if(StringFind(txt, "média") >= 0 || StringFind(txt, "ma") >= 0) {
      int p1 = (int)ExtraiNumero(txt, "de ");
      if(p1 == 0) p1 = (int)ExtraiNumero(txt, "ma ");

      rules[nRules].active = true;
      rules[nRules].type = RT_MA_CROSS;
      rules[nRules].p1 = p1;
      rules[nRules].handle1 = iMA(_Symbol, p_frequency, p1, 0, MODE_SMA, PRICE_CLOSE);
      rules[nRules].is_cross = (StringFind(txt, "cruzar") >= 0);
      nRules++;
   }

   // Stochastic
   if(StringFind(txt, "estocástico") >= 0 || StringFind(txt, "stoch") >= 0) {
      rules[nRules].active = true;
      rules[nRules].type = RT_STOCH_CROSS;
      rules[nRules].handle1 = iStochastic(_Symbol, p_frequency, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
      nRules++;
   }

   // Bollinger Bands
   if(StringFind(txt, "bollinger") >= 0 || StringFind(txt, "bb") >= 0) {
      rules[nRules].active = true;
      rules[nRules].type = RT_BB_BOUNCE;
      rules[nRules].handle1 = iBands(_Symbol, p_frequency, 20, 0, 2.0, PRICE_CLOSE);
      nRules++;
   }
}

// ---------- 5. INDICATOR SIGNAL FUNCTIONS (KNOWLEDGE-CORE) ----------

Signal EvaluateRule(int index, int shift) {
   Rule r = rules[index];
   if(!r.active) return NONE;

   double buffer1[], buffer2[], buffer3[];
   ArraySetAsSeries(buffer1, true);
   ArraySetAsSeries(buffer2, true);
   ArraySetAsSeries(buffer3, true);

   switch(r.type) {
      case RT_RSI_THRESHOLD:
         if(CopyBuffer(r.handle1, 0, shift, 2, buffer1) < 2) return NONE;
         if(r.s1 == "momentum") {
            if(r.is_cross) {
               if(buffer1[1] < r.d1 && buffer1[0] >= r.d1) return BUY;
               if(buffer1[1] > r.d2 && buffer1[0] <= r.d2) return SELL;
            } else {
               if(buffer1[0] > r.d1) return BUY;
               if(buffer1[0] < r.d2) return SELL;
            }
         } else {
            if(r.is_cross) {
               if(buffer1[1] < r.d2 && buffer1[0] >= r.d2) return BUY;
               if(buffer1[1] > r.d1 && buffer1[0] <= r.d1) return SELL;
            } else {
               if(buffer1[0] > r.d1) return SELL;
               if(buffer1[0] < r.d2) return BUY;
            }
         }
         break;

      case RT_MA_CROSS:
         if(CopyBuffer(r.handle1, 0, shift, 2, buffer1) < 2) return NONE;
         double close[2];
         if(CopyClose(_Symbol, p_frequency, shift, 2, close) < 2) return NONE;
         if(r.is_cross) {
            if(close[1] < buffer1[1] && close[0] > buffer1[0]) return BUY;
            if(close[1] > buffer1[1] && close[0] < buffer1[0]) return SELL;
         } else {
            if(close[0] > buffer1[0]) return BUY;
            if(close[0] < buffer1[0]) return SELL;
         }
         break;

      case RT_STOCH_CROSS:
         if(CopyBuffer(r.handle1, 0, shift, 2, buffer1) < 2) return NONE; // Main
         if(CopyBuffer(r.handle1, 1, shift, 2, buffer2) < 2) return NONE; // Signal
         if(buffer1[1] < buffer2[1] && buffer1[0] > buffer2[0]) return BUY;
         if(buffer1[1] > buffer2[1] && buffer1[0] < buffer2[0]) return SELL;
         break;

      case RT_BB_BOUNCE:
         if(CopyBuffer(r.handle1, 1, shift, 1, buffer1) < 1) return NONE; // Upper
         if(CopyBuffer(r.handle1, 2, shift, 1, buffer2) < 1) return NONE; // Lower
         double currentClose = iClose(_Symbol, p_frequency, shift);
         if(currentClose < buffer2[0]) return BUY;
         if(currentClose > buffer1[0]) return SELL;
         break;
   }
   return NONE;
}

Signal AvaliaTudo() {
   if(nRules == 0) return NONE;

   Signal firstSignal = NONE;
   for(int i=0; i<nRules; i++) {
      Signal s = EvaluateRule(i, 1); // Eval on shift=1
      if(s == NONE) return NONE; // Unanimous (AND)

      if(firstSignal == NONE) firstSignal = s;
      else if(firstSignal != s) return NONE; // Conflict
   }
   return firstSignal;
}

// Support for legacy i-functions
double iClose(string symbol, ENUM_TIMEFRAMES timeframe, int shift) {
   double price[1];
   if(CopyClose(symbol, timeframe, shift, 1, price) > 0) return price[0];
   return 0;
}

// ---------- 6. TRADE EXECUTION & RISK MANAGEMENT ----------

double CalculaLote(double riscoPercent) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riscoAbs = capital * riscoPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   int slPoints = p_stopPoints;
   if(slPoints <= 0) slPoints = 300; // Default buffer

   // Martingale
   if(p_martingale) {
      if(HistorySelect(TimeCurrent() - 86400, TimeCurrent())) {
         int nDeals = HistoryDealsTotal();
         if(nDeals > 0) {
            ulong ticket = HistoryDealGetTicket(nDeals - 1);
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) {
               riscoAbs *= 2;
            }
         }
      }
   }

   double stopInPoints = slPoints * _Point;
   double volume = riscoAbs / (slPoints * (tickValue / (tickSize / _Point)));
   return NV(volume);
}

void EnviaOrdem(Signal s) {
   if(s == NONE) return;

   // Check news veto
   if(AguardaNoticias()) return;

   // Check max trades
   if(PositionsTotal() >= p_maxTrades) return;

   // Hedge check
   if(!p_hedge) {
      for(int i = PositionsTotal() - 1; i >= 0; i--) {
         if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol) {
            if((s == BUY && posInfo.PositionType() == POSITION_TYPE_SELL) ||
               (s == SELL && posInfo.PositionType() == POSITION_TYPE_BUY)) {
               trade.PositionClose(posInfo.Ticket());
            }
         }
      }
   }

   double lote = CalculaLote(p_riskPercent);
   double sl = 0, tp = 0;

   // Safety Buffer
   double brokerMin = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + dynamicSafetyPoints + 2;
   double slDistance = MathMax(p_stopPoints, brokerMin) * _Point;
   double tpDistance = p_takePoints * _Point;

   if(s == BUY) {
      if(p_stopPoints > 0) sl = NS(SymbolInfoDouble(_Symbol, SYMBOL_BID) - slDistance);
      if(p_takePoints > 0) tp = NS(SymbolInfoDouble(_Symbol, SYMBOL_ASK) + tpDistance);
      trade.Buy(lote, _Symbol, 0, sl, tp, "MT-LiveExecutor: BUY");
   } else {
      if(p_stopPoints > 0) sl = NS(SymbolInfoDouble(_Symbol, SYMBOL_ASK) + slDistance);
      if(p_takePoints > 0) tp = NS(SymbolInfoDouble(_Symbol, SYMBOL_BID) - tpDistance);
      trade.Sell(lote, _Symbol, 0, sl, tp, "MT-LiveExecutor: SELL");
   }

   if(trade.ResultRetcode() == TRADE_RETCODE_REQUOTE || trade.ResultRetcode() == TRADE_RETCODE_OFF_QUOTES) {
      dynamicSafetyPoints = MathMin(dynamicSafetyPoints + 5, 100);
   }
}

void GerenciaPosicoes() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol) {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double openPrice = posInfo.PriceOpen();
         double currentSL = posInfo.StopLoss();

         // Break-even
         if(p_breakEvenPoints > 0) {
            double profitPoints = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (bid - openPrice) / _Point : (openPrice - ask) / _Point;
            if(profitPoints >= p_breakEvenPoints) {
               double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? openPrice + p_breakEvenProfit * _Point : openPrice - p_breakEvenProfit * _Point;
               if((posInfo.PositionType() == POSITION_TYPE_BUY && (currentSL < newSL || currentSL == 0)) ||
                  (posInfo.PositionType() == POSITION_TYPE_SELL && (currentSL > newSL || currentSL == 0))) {
                  trade.PositionModify(posInfo.Ticket(), NS(newSL), posInfo.TakeProfit());
               }
            }
         }

         // Trailing Stop
         if(p_trailingStopPoints > 0) {
            double profitPoints = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (bid - openPrice) / _Point : (openPrice - ask) / _Point;
            if(profitPoints >= p_trailingStopPoints) {
               double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? bid - p_trailingStopPoints * _Point : ask + p_trailingStopPoints * _Point;
               if((posInfo.PositionType() == POSITION_TYPE_BUY && newSL > currentSL) ||
                  (posInfo.PositionType() == POSITION_TYPE_SELL && (newSL < currentSL || currentSL == 0))) {
                  trade.PositionModify(posInfo.Ticket(), NS(newSL), posInfo.TakeProfit());
               }
            }
         }
      }
   }
}

// ---------- 7. ADVANCED FEATURES & STATE PERSISTENCE ----------

bool AguardaNoticias() {
   int fileHandle = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_COMMON);
   if(fileHandle != INVALID_HANDLE) {
      string content = FileReadString(fileHandle);
      FileClose(fileHandle);
      if(content == "1") return true;
   }
   return false;
}

void AIOptimizer() {
   if(!HistorySelect(0, TimeCurrent())) return;

   int totalDeals = HistoryDealsTotal();
   double winRate = 0, profitFactor = 0, drawdown = 0, maxBalance = 0;
   int winDeals = 0;
   double totalProfit = 0, totalLoss = 0;

   for(int i=0; i<totalDeals; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      if(profit > 0) { winDeals++; totalProfit += profit; }
      else if(profit < 0) totalLoss += MathAbs(profit);
   }

   if(totalDeals > 0) winRate = (double)winDeals / totalDeals;
   if(totalLoss > 0) profitFactor = totalProfit / totalLoss;

   // Suggest adjustment (Simplified)
   if(winRate < 0.4 && p_riskPercent > 0.5) p_riskPercent -= 0.1;
   else if(winRate > 0.6 && p_riskPercent < 3.0) p_riskPercent += 0.1;
}

void GravaCSV() {
   int fileHandle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV | FILE_ANSI);
   if(fileHandle != INVALID_HANDLE) {
      FileWrite(fileHandle, "Ticket", "Symbol", "Type", "PriceOpen", "SL", "TP", "Time");
      for(int i=0; i<PositionsTotal(); i++) {
         if(posInfo.SelectByIndex(i)) {
            FileWrite(fileHandle, posInfo.Ticket(), posInfo.Symbol(), posInfo.PositionType(),
                     posInfo.PriceOpen(), posInfo.StopLoss(), posInfo.TakeProfit(), posInfo.Time());
         }
      }
      FileClose(fileHandle);
   }
}

void GravaLog(string texto) {
   Print("MT-LiveExecutor: ", texto);
}

// Cleanup handles on deinit
void OnDeinit(const int reason) {
   for(int i=0; i<nRules; i++) {
      if(rules[i].handle1 != INVALID_HANDLE) IndicatorRelease(rules[i].handle1);
      if(rules[i].handle2 != INVALID_HANDLE) IndicatorRelease(rules[i].handle2);
      if(rules[i].p3_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p3_handle);
   }
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
}

// ---------- 8. NO-RESTART UPDATE MECHANISM & TICK HANDLER ----------

int OnInit() {
   EventSetTimer(60); // Check prompt updates every minute
   lastSafetyDecay = TimeCurrent();
   return INIT_SUCCEEDED;
}

void OnTimer() {
   // Check prompt update via Global Variable
   if(GlobalVariableGet("MT_Executor_Prompt_Update") > 0) {
      int fileHandle = FileOpen("MT_LiveExecutor_Prompt.txt", FILE_READ | FILE_TXT);
      if(fileHandle != INVALID_HANDLE) {
         string prompt = FileReadString(fileHandle);
         InterpretaPrompt(prompt);
         FileClose(fileHandle);
         GlobalVariableSet("MT_Executor_Prompt_Update", 0);
         GravaLog("Strategy updated successfully.");
      }
   }

   // Safety Points Decay
   if(TimeCurrent() - lastSafetyDecay >= 60) {
      if(dynamicSafetyPoints > 0) dynamicSafetyPoints--;
      lastSafetyDecay = TimeCurrent();
   }

   // AI Optimizer
   AIOptimizer();
}

void OnTick() {
   // Start Hour Check
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.hour < p_startHour) return;

   // Evaluation & Execution
   datetime currentBar = (datetime)SeriesInfoInteger(_Symbol, p_frequency, SERIES_LASTBAR_DATE);
   if(currentBar != lastBarTime) {
      Signal s = AvaliaTudo();
      if(s != NONE) {
         EnviaOrdem(s);
         lastBarTime = currentBar;
      }
   }

   // Real-time management
   GerenciaPosicoes();
   GravaCSV();
}

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result) {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD) {
      // Logic for SynchronizeClusterSL if needed
   }
}
