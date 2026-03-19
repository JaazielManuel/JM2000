//=========================  MT-LiveExecutor  =========================
// Profit Master v8.0 - 2026
// MQL5 Core Engine for Live Execution
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// ---------- GLOBAL DEFINITIONS ----------
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
   RULE_BAR_PATTERN,
   RULE_RS_RELATIVE
};

struct Rule {
   bool      active;
   RuleType  type;
   ENUM_TIMEFRAMES tf;
   int       p1, p2, p3_handle; // p3_handle stores secondary indicator handles
   double    d1, d2;
   string    s1;
   bool      is_cross;
   int       handle;
};

// Global State
Rule rules[30];
int nRules = 0;
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symbolInfo;
CAccountInfo accountInfo;

// Strategy Parameters (populated by InterpretaPrompt)
double p_riskPercent = 1.0;
int    p_stopPoints = 300;
int    p_takePoints = 500;
int    p_trailingStopPoints = 0;
int    p_breakEvenPoints = 0;
int    p_breakEvenLock = 50;
bool   p_martingale = false;
bool   p_hedge = false;
int    p_maxTrades = 3;
int    p_startHour = 0;
int    p_newsVetoMinutes = 20;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

// Runtime Cache
datetime lastBarTime = 0;
double dynamicSafetyPoints = 0;
int atrHandle = INVALID_HANDLE;

// ---------- HELPER WRAPPERS ----------
double iClose(string symbol, ENUM_TIMEFRAMES tf, int shift) {
   double res[1];
   if(CopyClose(symbol, tf, shift, 1, res) > 0) return res[0];
   return 0;
}
double iHigh(string symbol, ENUM_TIMEFRAMES tf, int shift) {
   double res[1];
   if(CopyHigh(symbol, tf, shift, 1, res) > 0) return res[0];
   return 0;
}
double iLow(string symbol, ENUM_TIMEFRAMES tf, int shift) {
   double res[1];
   if(CopyLow(symbol, tf, shift, 1, res) > 0) return res[0];
   return 0;
}
double iOpen(string symbol, ENUM_TIMEFRAMES tf, int shift) {
   double res[1];
   if(CopyOpen(symbol, tf, shift, 1, res) > 0) return res[0];
   return 0;
}
datetime iTime(string symbol, ENUM_TIMEFRAMES tf, int shift) {
   datetime res[1];
   if(CopyTime(symbol, tf, shift, 1, res) > 0) return res[0];
   return 0;
}

// ---------- INDICATOR SIGNALS (MT5-KNOWLEDGE-CORE) ----------

Signal CheckMA(Rule &r, int shift) {
   double val[2], prev[2];
   if(CopyBuffer(r.handle, 0, shift, 2, val) <= 0) return NONE;

   if(r.p2 > 0) { // Crossover between two MAs
      double val2[2];
      if(CopyBuffer(r.p3_handle, 0, shift, 2, val2) <= 0) return NONE;
      if(val[1] > val2[1] && val[0] <= val2[0]) return SELL;
      if(val[1] < val2[1] && val[0] >= val2[0]) return BUY;
   } else { // Price vs MA
      double close = iClose(_Symbol, r.tf, shift);
      double closePrev = iClose(_Symbol, r.tf, shift + 1);
      if(closePrev < val[1] && close >= val[0]) return BUY;
      if(closePrev > val[1] && close <= val[0]) return SELL;
   }
   return NONE;
}

Signal CheckRSI(Rule &r, int shift) {
   double val[2];
   if(CopyBuffer(r.handle, 0, shift, 2, val) <= 0) return NONE;

   if(r.is_cross) {
      if(val[1] < r.d1 && val[0] >= r.d1) return BUY; // Upward cross
      if(val[1] > r.d2 && val[0] <= r.d2) return SELL; // Downward cross
   } else {
      if(val[0] > r.d1) return SELL; // Overbought
      if(val[0] < r.d2) return BUY;  // Oversold
   }
   return NONE;
}

Signal CheckStoch(Rule &r, int shift) {
   double k[2], d[2];
   if(CopyBuffer(r.handle, 0, shift, 2, k) <= 0) return NONE;
   if(CopyBuffer(r.handle, 1, shift, 2, d) <= 0) return NONE;

   if(k[1] < d[1] && k[0] >= d[0]) return BUY;
   if(k[1] > d[1] && k[0] <= d[0]) return SELL;
   return NONE;
}

Signal CheckBB(Rule &r, int shift) {
   double upper[1], lower[1], close[1];
   if(CopyBuffer(r.handle, 1, shift, 1, upper) <= 0) return NONE;
   if(CopyBuffer(r.handle, 2, shift, 1, lower) <= 0) return NONE;
   close[0] = iClose(_Symbol, r.tf, shift);

   if(close[0] < lower[0]) return BUY;
   if(close[0] > upper[0]) return SELL;
   return NONE;
}

Signal CheckDailyBreak(int shift) {
   static datetime today = 0;
   static double hi = 0, lo = 0;
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

Signal CheckDelta(int seconds, int trigger) {
   MqlTick arr[];
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

Signal CheckVolume(Rule &r, int shift) {
   long vol[20];
   if(CopyVolume(_Symbol, r.tf, shift, r.p1, vol) <= 0) return NONE;
   int maxIdx = 0, minIdx = 0;
   for(int i=0; i<r.p1; i++) {
      if(vol[i] > vol[maxIdx]) maxIdx = i;
      if(vol[i] < vol[minIdx]) minIdx = i;
   }
   if(maxIdx == 0) return SELL;
   if(minIdx == 0) return BUY;
   return NONE;
}

Signal CheckAMA(Rule &r, int shift) {
   double val[2];
   if(CopyBuffer(r.handle, 0, shift, 2, val) <= 0) return NONE;
   if(val[1] < val[0]) return BUY;
   if(val[1] > val[0]) return SELL;
   return NONE;
}

Signal CheckBarPattern(ENUM_TIMEFRAMES tf, int shift) {
   double h0 = iHigh(_Symbol, tf, shift);
   double l0 = iLow(_Symbol, tf, shift);
   double h1 = iHigh(_Symbol, tf, shift + 1);
   double l1 = iLow(_Symbol, tf, shift + 1);
   double c0 = iClose(_Symbol, tf, shift);
   double o0 = iOpen(_Symbol, tf, shift);

   if(h0 < h1 && l0 > l1) return (c0 > o0) ? BUY : SELL; // Inside
   if(h0 > h1 && l0 < l1) return (c0 > o0) ? SELL : BUY; // Outside
   return NONE;
}

Signal CheckRSRelative(Rule &r, int shift) {
   double r1[1], r2[1];
   if(CopyBuffer(r.handle, 0, shift, 1, r1) <= 0) return NONE;
   if(CopyBuffer(r.p3_handle, 0, shift, 1, r2) <= 0) return NONE;

   if(r1[0] > r2[0] + 5) return BUY;
   if(r1[0] < r2[0] - 5) return SELL;
   return NONE;
}

// ---------- PARSER HELPERS ----------

double ExtraiNumero(string txt, string chave) {
   int pos = StringFind(txt, chave);
   if(pos < 0) return 0;
   string sub = StringSubstr(txt, pos + StringLen(chave));
   return StringToDouble(sub);
}

ENUM_TIMEFRAMES PeriodoTexto(string nome) {
   nome = StringToLower(nome);
   if(StringFind(nome, "m1") >= 0) return PERIOD_M1;
   if(StringFind(nome, "m5") >= 0) return PERIOD_M5;
   if(StringFind(nome, "m15") >= 0) return PERIOD_M15;
   if(StringFind(nome, "m30") >= 0) return PERIOD_M30;
   if(StringFind(nome, "h1") >= 0) return PERIOD_H1;
   if(StringFind(nome, "h4") >= 0) return PERIOD_H4;
   if(StringFind(nome, "d1") >= 0) return PERIOD_D1;

   double num = StringToDouble(nome);
   if(num == 1) return PERIOD_M1;
   if(num == 5) return PERIOD_M5;
   if(num == 15) return PERIOD_M15;
   if(num == 30) return PERIOD_M30;
   if(num == 60) return PERIOD_H1;
   if(num == 240) return PERIOD_H4;
   if(num == 1440) return PERIOD_D1;

   return PERIOD_CURRENT;
}

void AddRule(RuleType type, ENUM_TIMEFRAMES tf, int p1=0, int p2=0, double d1=0, double d2=0, string s1="", bool is_cross=false) {
   // Check for existing rule of same type to update instead of duplicate
   for(int i=0; i<nRules; i++) {
      if(rules[i].type == type && rules[i].tf == tf) {
         rules[i].p1 = p1; rules[i].p2 = p2; rules[i].d1 = d1; rules[i].d2 = d2;
         rules[i].s1 = s1; rules[i].is_cross = is_cross;
         return;
      }
   }
   if(nRules >= 30) return;

   rules[nRules].active = true;
   rules[nRules].type = type;
   rules[nRules].tf = tf;
   rules[nRules].p1 = p1;
   rules[nRules].p2 = p2;
   rules[nRules].d1 = d1;
   rules[nRules].d2 = d2;
   rules[nRules].s1 = s1;
   rules[nRules].is_cross = is_cross;
   rules[nRules].handle = INVALID_HANDLE;
   rules[nRules].p3_handle = INVALID_HANDLE;

   // Initialize Handles
   if(type == RULE_MA_CROSS) {
      rules[nRules].handle = iMA(_Symbol, tf, p1, 0, MODE_EMA, PRICE_CLOSE);
      if(p2 > 0) rules[nRules].p3_handle = iMA(_Symbol, tf, p2, 0, MODE_EMA, PRICE_CLOSE);
   } else if(type == RULE_RSI) {
      rules[nRules].handle = iRSI(_Symbol, tf, p1, PRICE_CLOSE);
   } else if(type == RULE_STOCH) {
      rules[nRules].handle = iStochastic(_Symbol, tf, p1, p2, 3, MODE_SMA, STO_LOWHIGH);
   } else if(type == RULE_BB) {
      rules[nRules].handle = iBands(_Symbol, tf, p1, 0, d1, PRICE_CLOSE);
   } else if(type == RULE_AMA) {
      rules[nRules].handle = iAMA(_Symbol, tf, p1, 2, 30, 0, PRICE_CLOSE);
   }

   nRules++;
}

// ---------- CORE PARSER ----------

void InterpretaPrompt(string prompt) {
   string p = StringToLower(prompt);

   // Reset Strategy State
   for(int i=0; i<nRules; i++) {
      if(rules[i].handle != INVALID_HANDLE) IndicatorRelease(rules[i].handle);
      if(rules[i].p3_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p3_handle);
   }
   ZeroMemory(rules);
   nRules = 0;
   lastBarTime = 0;

   // Segment Parser
   string segments[];
   string sep = " | ";
   ushort u_sep = StringGetCharacter(sep, 1);
   string cleanPrompt = prompt;
   StringReplace(cleanPrompt, " e ", " | ");
   StringReplace(cleanPrompt, " + ", " | ");
   int nSeg = StringSplit(cleanPrompt, u_sep, segments);

   // Global Params
   p_riskPercent = (ExtraiNumero(p, "risco de ") > 0) ? ExtraiNumero(p, "risco de ") : 1.0;
   p_stopPoints = (int)ExtraiNumero(p, "stop de ");
   p_takePoints = (int)ExtraiNumero(p, "take de ");
   p_trailingStopPoints = (int)ExtraiNumero(p, "trailing stop de ");
   if(p_trailingStopPoints == 0) p_trailingStopPoints = (int)ExtraiNumero(p, "trailing de ");

   p_maxTrades = (int)ExtraiNumero(p, "máximo ");
   if(p_maxTrades == 0) p_maxTrades = 3;

   p_startHour = (int)ExtraiNumero(p, "depois das ");
   p_newsVetoMinutes = (int)ExtraiNumero(p, "operar ");
   if(p_newsVetoMinutes == 0) p_newsVetoMinutes = 20;

   p_martingale = (StringFind(p, "martingale") >= 0);
   p_hedge = (StringFind(p, "hedge") >= 0);

   if(StringFind(p, "move stop para entrada") >= 0) {
      p_breakEvenPoints = (int)ExtraiNumero(p, "atingir +");
      p_breakEvenLock = (int)ExtraiNumero(p, "entrada +");
   }

   // Frequency/Timeframe
   string freqTxt = "";
   if(StringFind(p, "cada ") >= 0) {
      int pos = StringFind(p, "cada ");
      freqTxt = StringSubstr(p, pos + 5, 5);
      p_frequency = PeriodoTexto(freqTxt);
   }

   // Rule Extraction
   for(int i=0; i<nSeg; i++) {
      string s = StringToLower(segments[i]);
      ENUM_TIMEFRAMES rtf = p_frequency;

      if(StringFind(s, "média de ") >= 0) {
         int per = (int)ExtraiNumero(s, "média de ");
         AddRule(RULE_MA_CROSS, rtf, per);
      }
      if(StringFind(s, "rsi (") >= 0) {
         int per = (int)ExtraiNumero(s, "rsi (");
         double up = 70, dn = 30;
         bool is_c = (StringFind(s, "subir acima") >= 0 || StringFind(s, "cair abaixo") >= 0);
         if(StringFind(s, "acima de ") >= 0) up = ExtraiNumero(s, "acima de ");
         if(StringFind(s, "abaixo de ") >= 0) dn = ExtraiNumero(s, "abaixo de ");
         AddRule(RULE_RSI, rtf, per, 0, up, dn, "", is_c);
      }
      if(StringFind(s, "bollinger") >= 0) {
         AddRule(RULE_BB, rtf, 20, 0, 2.0);
      }
      if(StringFind(s, "estocástico") >= 0) {
         AddRule(RULE_STOCH, rtf, 5, 3);
      }
   }

   Print("MT-LiveExecutor: Prompt Interpretado. Regras: ", nRules, " | Risco: ", p_riskPercent, "%");
}

// ---------- CONFLUENCE ENGINE ----------

Signal AvaliaTudo() {
   if(nRules == 0) return NONE;

   int buyVotes = 0;
   int sellVotes = 0;
   int activeCount = 0;

   for(int i=0; i<nRules; i++) {
      if(!rules[i].active) continue;
      activeCount++;

      Signal s = NONE;
      switch(rules[i].type) {
         case RULE_MA_CROSS:    s = CheckMA(rules[i], 1); break;
         case RULE_RSI:         s = CheckRSI(rules[i], 1); break;
         case RULE_STOCH:       s = CheckStoch(rules[i], 1); break;
         case RULE_BB:          s = CheckBB(rules[i], 1); break;
         case RULE_DAILY_BREAK: s = CheckDailyBreak(1); break;
         case RULE_DELTA:       s = CheckDelta(60, 300); break;
         case RULE_VOLUME:      s = CheckVolume(rules[i], 1); break;
         case RULE_AMA:         s = CheckAMA(rules[i], 1); break;
         case RULE_BAR_PATTERN: s = CheckBarPattern(rules[i].tf, 1); break;
         case RULE_RS_RELATIVE: s = CheckRSRelative(rules[i], 1); break;
      }

      if(s == BUY) buyVotes++;
      else if(s == SELL) sellVotes++;
   }

   // Unanimous (AND) confluence
   if(buyVotes == activeCount && activeCount > 0) return BUY;
   if(sellVotes == activeCount && activeCount > 0) return SELL;

   return NONE;
}

// ---------- RISK MANAGEMENT ----------

double NV(double v) {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double res = MathFloor(v / step) * step;
   double minV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   return MathMax(minV, MathMin(maxV, res));
}

double CalculaLote(double riscoPercent) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riscoAbs = capital * riscoPercent / 100.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   int slPoints = (p_stopPoints > 0) ? p_stopPoints : 300;
   double slDistance = slPoints * _Point;

   if(slDistance == 0 || tickValue == 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double lote = riscoAbs / (slPoints * (tickValue / (tickSize / _Point)));
   lote = NV(lote);

   // Martingale
   if(p_martingale) {
      if(HistorySelect(TimeCurrent() - 86400, TimeCurrent())) {
         int total = HistoryDealsTotal();
         for(int i = total - 1; i >= 0; i--) {
            ulong ticket = HistoryDealGetTicket(i);
            if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol) {
               double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
               if(profit < 0) lote *= 2.0;
               break;
            }
         }
      }
   }

   return NV(lote);
}

// ---------- EXECUTION ENGINE ----------

double NS(double price) {
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   return MathRound(price / tickSize) * tickSize;
}

void EnviaOrdem(Signal s) {
   if(s == NONE) return;

   // Check Max Trades
   int totalPositions = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol) totalPositions++;
   }
   if(totalPositions >= p_maxTrades) return;

   // Hedge Logic: Close opposite if not allowed
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
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

   double minBuffer = (stopsLevel + dynamicSafetyPoints + 2) * _Point;

   double sl = 0, tp = 0;
   if(s == BUY) {
      double entry = ask;
      if(p_stopPoints > 0) sl = entry - MathMax(p_stopPoints * _Point, minBuffer);
      if(p_takePoints > 0) tp = entry + p_takePoints * _Point;
      trade.Buy(lote, _Symbol, entry, NS(sl), NS(tp), "MT-LiveExecutor: " + IntegerToString(nRules) + " rules");
   } else {
      double entry = bid;
      if(p_stopPoints > 0) sl = entry + MathMax(p_stopPoints * _Point, minBuffer);
      if(p_takePoints > 0) tp = entry - p_takePoints * _Point;
      trade.Sell(lote, _Symbol, entry, NS(sl), NS(tp), "MT-LiveExecutor: " + IntegerToString(nRules) + " rules");
   }
}

// ---------- POSITION MANAGEMENT ----------

void SynchronizeClusterSL(double newSL, ENUM_POSITION_TYPE type) {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.PositionType() == type) {
         if(MathAbs(posInfo.StopLoss() - newSL) > _Point) {
            trade.PositionModify(posInfo.Ticket(), NS(newSL), posInfo.TakeProfit());
         }
      }
   }
}

void GerenciaPosicoes() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(!posInfo.SelectByIndex(i) || posInfo.Symbol() != _Symbol) continue;

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double openPrice = posInfo.PriceOpen();
      double currentSL = posInfo.StopLoss();

      // Break-even
      if(p_breakEvenPoints > 0) {
         if(posInfo.PositionType() == POSITION_TYPE_BUY) {
            if(bid >= openPrice + p_breakEvenPoints * _Point && (currentSL < openPrice || currentSL == 0)) {
               trade.PositionModify(posInfo.Ticket(), NS(openPrice + p_breakEvenLock * _Point), posInfo.TakeProfit());
            }
         } else {
            if(ask <= openPrice - p_breakEvenPoints * _Point && (currentSL > openPrice || currentSL == 0)) {
               trade.PositionModify(posInfo.Ticket(), NS(openPrice - p_breakEvenLock * _Point), posInfo.TakeProfit());
            }
         }
      }

      // Trailing Stop
      if(p_trailingStopPoints > 0) {
         if(posInfo.PositionType() == POSITION_TYPE_BUY) {
            if(bid > openPrice + p_trailingStopPoints * _Point) {
               double targetSL = bid - p_trailingStopPoints * _Point;
               if(targetSL > currentSL + 10 * _Point || currentSL == 0) {
                  trade.PositionModify(posInfo.Ticket(), NS(targetSL), posInfo.TakeProfit());
               }
            }
         } else {
            if(ask < openPrice - p_trailingStopPoints * _Point) {
               double targetSL = ask + p_trailingStopPoints * _Point;
               if(targetSL < currentSL - 10 * _Point || currentSL == 0) {
                  trade.PositionModify(posInfo.Ticket(), NS(targetSL), posInfo.TakeProfit());
               }
            }
         }
      }
   }
}

void OnTradeTransaction(const MqlTradeTransaction& trans, const MqlTradeRequest& request, const MqlTradeResult& result) {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD) {
      if(HistoryDealSelect(trans.deal)) {
         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_IN) {
            // Find the most recent position SL to sync others
            if(posInfo.SelectByTicket(trans.position)) {
               SynchronizeClusterSL(posInfo.StopLoss(), posInfo.PositionType());
            }
         }
      }
   }
}

// ---------- AI OPTIMIZER ----------

void AIOptimizer() {
   if(!HistorySelect(0, TimeCurrent())) return;

   int total = HistoryDealsTotal();
   int wins = 0, losses = 0;
   double grossProfit = 0, grossLoss = 0;
   double maxDrawdown = 0, peakBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   for(int i = 0; i < total; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT) continue;

      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT) +
                      HistoryDealGetDouble(ticket, DEAL_COMMISSION) +
                      HistoryDealGetDouble(ticket, DEAL_SWAP);

      if(profit > 0) {
         wins++;
         grossProfit += profit;
      } else {
         losses++;
         grossLoss += MathAbs(profit);
      }

      double balance = AccountInfoDouble(ACCOUNT_BALANCE); // Simplification for drawdown
      if(balance > peakBalance) peakBalance = balance;
      double dd = peakBalance - balance;
      if(dd > maxDrawdown) maxDrawdown = dd;
   }

   double winRate = (wins + losses > 0) ? (double)wins / (wins + losses) * 100.0 : 0;
   double profitFactor = (grossLoss > 0) ? grossProfit / grossLoss : grossProfit;

   // Heuristic Risk Adjustment based on ATR
   if(atrHandle != INVALID_HANDLE) {
      double atr[1];
      if(CopyBuffer(atrHandle, 0, 0, 1, atr) > 0) {
         if(atr[0] > iATR(_Symbol, PERIOD_D1, 14, 1) * 1.5) {
            // High Volatility -> Reduce Risk
            // p_riskPercent *= 0.8;
         }
      }
   }

   // Decay safety points
   if(dynamicSafetyPoints > 0) dynamicSafetyPoints -= 1.0;

   Print("AI Optimizer: WR: ", DoubleToString(winRate, 1), "% | PF: ", DoubleToString(profitFactor, 2), " | DD: ", DoubleToString(maxDrawdown, 2));
}

// ---------- NEWS VETO ----------

bool AguardaNoticias() {
   int handle = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      string content = FileReadString(handle);
      FileClose(handle);
      if(content == "1") return true; // News Veto Active
   }
   return false;
}

// ---------- STATE PERSISTENCE ----------

void GravaCSV() {
   int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV | FILE_ANSI);
   if(handle != INVALID_HANDLE) {
      FileWrite(handle, "Ticket", "Symbol", "Price", "SL", "TP", "Time", "Reason");
      for(int i = 0; i < PositionsTotal(); i++) {
         if(posInfo.SelectByIndex(i)) {
            FileWrite(handle,
               posInfo.Ticket(),
               posInfo.Symbol(),
               posInfo.PriceOpen(),
               posInfo.StopLoss(),
               posInfo.TakeProfit(),
               TimeToString(posInfo.Time()),
               posInfo.Comment()
            );
         }
      }
      FileClose(handle);
   }
}

// ---------- LIFECYCLE HANDLERS ----------

int OnInit() {
   trade.SetExpertMagicNumber(123456);
   EventSetTimer(1);
   atrHandle = iATR(_Symbol, PERIOD_D1, 14);

   // Initial Load
   int handle = FileOpen("MT_LiveExecutor_Prompt.txt", FILE_READ | FILE_TXT);
   if(handle != INVALID_HANDLE) {
      string prompt = FileReadString(handle);
      FileClose(handle);
      InterpretaPrompt(prompt);
   }

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   EventKillTimer();
   for(int i=0; i<nRules; i++) {
      if(rules[i].handle != INVALID_HANDLE) IndicatorRelease(rules[i].handle);
      if(rules[i].p3_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p3_handle);
   }
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
}

void OnTimer() {
   // Check for strategy update
   if(GlobalVariableCheck("MT_Executor_Prompt_Update")) {
      if(GlobalVariableGet("MT_Executor_Prompt_Update") > 0) {
         int handle = FileOpen("MT_LiveExecutor_Prompt.txt", FILE_READ | FILE_TXT);
         if(handle != INVALID_HANDLE) {
            string prompt = FileReadString(handle);
            FileClose(handle);
            InterpretaPrompt(prompt);
            GlobalVariableSet("MT_Executor_Prompt_Update", 0);
         }
      }
   }

   AIOptimizer();
   GravaCSV();
}

void OnTick() {
   // 1. Operational Constraints
   if(TimeHour(TimeCurrent()) < p_startHour) return;
   if(AguardaNoticias()) return;

   // 2. Position Management
   GerenciaPosicoes();

   // 3. Signal Evaluation
   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar != lastBarTime) {
      Signal s = AvaliaTudo();
      if(s != NONE) {
         EnviaOrdem(s);
         lastBarTime = currentBar;
      }
   }
}
