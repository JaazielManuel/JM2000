//+------------------------------------------------------------------+
//|                                              MT_LiveExecutor.mq5 |
//|                                  Copyright 2026, Jules (Agent)   |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Jules (Agent)"
#property link      "https://www.mql5.com"
#property version   "8.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// ---------- ENUMS & ESTRUTURAS ----------
enum Signal {BUY=1, SELL=-1, NONE=0};

enum RuleType {
   RULE_MA_CROSS,
   RULE_RSI_THRESHOLD,
   RULE_STOCH_CROSS,
   RULE_BB_BOUNCE,
   RULE_DAILY_BREAK,
   RULE_DELTA_AGG,
   RULE_VOL_CYCLE,
   RULE_AMA,
   RULE_BAR_PATTERN,
   RULE_RELATIVE_STRENGTH
};

struct Rule {
   bool      active;
   RuleType  type;
   int       tf;
   int       p1, p2, p3;
   double    d1, d2;
   string    s1;
   int       p1_handle;
   int       p2_handle;
   int       p3_handle;
   bool      is_cross;
};

// ---------- GLOBAIS ----------
Rule rules[30];
int nRules = 0;
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symbolInfo;
CAccountInfo accountInfo;

string currentPrompt = "";
datetime lastBarTime = 0;

// Parâmetros de Gestão
double p_riskPercent = 1.0;
int p_stopPoints = 300;
int p_takePoints = 500;
int p_bePoints = 300;
int p_beOffset = 50;
int p_trailingStopPoints = 0;
bool p_martingale = false;
bool p_hedge = false;
int p_maxTrades = 3;
int p_newsVetoMins = 20;
int p_startTimeHour = 0;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

int dynamicSafetyPoints = 0;
datetime lastSafetyDecay = 0;

int atrHandle = INVALID_HANDLE;

// ---------- INICIALIZAÇÃO ----------
int OnInit() {
   symbolInfo.Name(_Symbol);
   EventSetTimer(1);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   for(int i=0; i<nRules; i++) {
      if(rules[i].p1_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p1_handle);
      if(rules[i].p2_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p2_handle);
      if(rules[i].p3_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p3_handle);
   }
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   EventKillTimer();
}

// ---------- MT5-KNOWLEDGE-CORE INDICATORS ----------

// 1.1 CRUZAMENTO MÉDIAS MÓVEIS
Signal CheckMA(Rule &r, int shift=1) {
   double f1, f2, s1, s2;
   double bf[2], bs[2];
   if(CopyBuffer(r.p1_handle, 0, shift, 2, bf) < 2) return NONE;
   if(CopyBuffer(r.p2_handle, 0, shift, 2, bs) < 2) return NONE;
   f1 = bf[1]; f2 = bf[0]; // f1=atual, f2=anterior
   s1 = bs[1]; s2 = bs[0];
   if(f2 < s2 && f1 > s1) return BUY;
   if(f2 > s2 && f1 < s1) return SELL;
   return NONE;
}

// 1.2 RSI
Signal CheckRSI(Rule &r, int shift=1) {
   double val[2];
   if(CopyBuffer(r.p1_handle, 0, shift, 2, val) < 2) return NONE;
   double v1 = val[1];
   double v2 = val[0];
   if(r.is_cross) {
      if(v2 < r.d2 && v1 > r.d2) return BUY;
      if(v2 > r.d1 && v1 < r.d1) return SELL;
   } else {
      if(v1 < r.d2) return BUY;
      if(v1 > r.d1) return SELL;
   }
   return NONE;
}

// 1.3 ESTOCÁSTICO
Signal CheckStoch(Rule &r, int shift=1) {
   double k[2], d[2];
   if(CopyBuffer(r.p1_handle, 0, shift, 2, k) < 2) return NONE;
   if(CopyBuffer(r.p1_handle, 1, shift, 2, d) < 2) return NONE;
   if(k[0] < d[0] && k[1] > d[1]) return BUY;
   if(k[0] > d[0] && k[1] < d[1]) return SELL;
   return NONE;
}

// 1.4 BOLLINGER BANDS
Signal CheckBB(Rule &r, int shift=1) {
   double mid[1], up[1], lo[1], close[1];
   if(CopyBuffer(r.p1_handle, 0, shift, 1, mid) < 1) return NONE;
   if(CopyBuffer(r.p1_handle, 1, shift, 1, up) < 1) return NONE;
   if(CopyBuffer(r.p1_handle, 2, shift, 1, lo) < 1) return NONE;
   double price = iCloseWrapper(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
   if(price < lo[0]) return BUY;
   if(price > up[0]) return SELL;
   return NONE;
}

// 1.5 BREAKOUT DIÁRIO
Signal CheckDailyBreak(Rule &r, int shift=1) {
   double hi = iHighWrapper(_Symbol, PERIOD_D1, 1);
   double lo = iLowWrapper(_Symbol, PERIOD_D1, 1);
   double price = iCloseWrapper(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
   if(price > hi) return BUY;
   if(price < lo) return SELL;
   return NONE;
}

// 1.6 DELTA DE AGRESSÃO (Simplificado para MQL5 Ticks)
Signal CheckDelta(Rule &r) {
   MqlTick ticks[];
   int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, TimeCurrent()-60, TimeCurrent());
   long buy=0, sell=0;
   for(int i=0; i<n; i++) {
      if((ticks[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++;
      else if((ticks[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sell++;
   }
   long delta = buy - sell;
   if(delta > r.p1) return BUY;
   if(delta < -r.p1) return SELL;
   return NONE;
}

// 1.7 CICLO DE VOLUME
Signal CheckVolCycle(Rule &r, int shift=0) {
   long vol[];
   if(CopyVolume(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift, r.p1, vol) < r.p1) return NONE;
   int maxIdx = ArrayMaximum(vol);
   int minIdx = ArrayMinimum(vol);
   if(0 == minIdx) return BUY;
   if(0 == maxIdx) return SELL;
   return NONE;
}

// 1.8 AMA (Kaufman)
Signal CheckAMA(Rule &r, int shift=1) {
   double val[2];
   if(CopyBuffer(r.p1_handle, 0, shift, 2, val) < 2) return NONE;
   if(val[1] > val[0]) return BUY;
   if(val[1] < val[0]) return SELL;
   return NONE;
}

// 1.9 BAR PATTERN (Inside/Outside)
Signal CheckBarPattern(Rule &r, int shift=1) {
   double h0 = iHighWrapper(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
   double l0 = iLowWrapper(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
   double h1 = iHighWrapper(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift+1);
   double l1 = iLowWrapper(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift+1);
   double c0 = iCloseWrapper(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
   double o0 = iOpenWrapper(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
   if(h0 < h1 && l0 > l1) return (c0 > o0) ? BUY : SELL; // Inside
   if(h0 > h1 && l0 < l1) return (c0 > o0) ? SELL : BUY; // Outside
   return NONE;
}

// 1.10 FORÇA RELATIVA
Signal CheckRelative(Rule &r, int shift=1) {
   double rsi1[1], rsi2[1];
   if(CopyBuffer(r.p1_handle, 0, shift, 1, rsi1) < 1) return NONE;
   if(CopyBuffer(r.p2_handle, 0, shift, 1, rsi2) < 1) return NONE;
   if(rsi1[0] > rsi2[0] + 5) return BUY;
   if(rsi1[0] < rsi2[0] - 5) return SELL;
   return NONE;
}

// ---------- WRAPPERS PARA MQL4 COMPATIBILIDADE ----------
double iCloseWrapper(string symbol, ENUM_TIMEFRAMES tf, int shift) {
   double res[]; if(CopyClose(symbol, tf, shift, 1, res) > 0) return res[0]; return 0;
}
double iOpenWrapper(string symbol, ENUM_TIMEFRAMES tf, int shift) {
   double res[]; if(CopyOpen(symbol, tf, shift, 1, res) > 0) return res[0]; return 0;
}
double iHighWrapper(string symbol, ENUM_TIMEFRAMES tf, int shift) {
   double res[]; if(CopyHigh(symbol, tf, shift, 1, res) > 0) return res[0]; return 0;
}
double iLowWrapper(string symbol, ENUM_TIMEFRAMES tf, int shift) {
   double res[]; if(CopyLow(symbol, tf, shift, 1, res) > 0) return res[0]; return 0;
}

// ---------- PARSER DE PROMPT ----------

void InterpretaPrompt(string prompt) {
   if(prompt == "" || prompt == currentPrompt) return;

   // Resetar regras e handles antigos
   for(int i=0; i<nRules; i++) {
      if(rules[i].p1_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p1_handle);
      if(rules[i].p2_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p2_handle);
      if(rules[i].p3_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p3_handle);
      rules[i].active = false;
   }
   nRules = 0;
   lastBarTime = 0;

   string p = prompt;
   StringToLower(p);

   // Extração de Parâmetros de Gestão
   p_riskPercent = ExtraiNumero(p, "risco de ", 1.0);
   p_stopPoints = (int)ExtraiNumero(p, "stop de ", 300);
   p_takePoints = (int)ExtraiNumero(p, "take de ", 500);
   p_bePoints = (int)ExtraiNumero(p, "atingir +", 300);
   p_beOffset = (int)ExtraiNumero(p, "entrada +", 5);
   p_trailingStopPoints = (int)ExtraiNumero(p, "trailing stop de ", 0);
   p_maxTrades = (int)ExtraiNumero(p, "máximo ", 3);
   p_newsVetoMins = (int)ExtraiNumero(p, "operar ", 20);
   p_startTimeHour = (int)ExtraiNumero(p, "depois das ", 0);

   int freq = (int)ExtraiNumero(p, "a cada ", 15);
   p_frequency = MinutesToTimeframe(freq);

   if(StringFind(p, "martingale") >= 0) p_martingale = true; else p_martingale = false;
   if(StringFind(p, "hedge") >= 0) p_hedge = true; else p_hedge = false;

   // Segmentar por conectivos ' e ', ' + ', ','
   string segments[];
   string sep = p;
   StringReplace(sep, " e ", "|");
   StringReplace(sep, " + ", "|");
   StringReplace(sep, ",", "|");
   ushort u_sep = StringGetCharacter("|", 0);
   StringSplit(sep, u_sep, segments);

   for(int i=0; i<ArraySize(segments); i++) {
      AddRule(segments[i]);
   }

   currentPrompt = prompt;
   Print("Estratégia Atualizada: ", currentPrompt);
}

void AddRule(string txt) {
   if(nRules >= 30) return;

   string t = txt;
   StringTrimLeft(t);
   StringTrimRight(t);

   // Média Móvel
   if(StringFind(t, "média de ") >= 0 || StringFind(t, "períodos") >= 0) {
      rules[nRules].active = true;
      rules[nRules].type = RULE_MA_CROSS;
      rules[nRules].p1 = (int)ExtraiNumero(t, "média de ", 20);
      rules[nRules].p2 = (int)ExtraiNumero(t, "/", 20); // Se houver cruzamento ex: 9/21
      if(rules[nRules].p2 == 20 && rules[nRules].p1 != 20) rules[nRules].p2 = rules[nRules].p1; // Fallback

      rules[nRules].tf = PERIOD_CURRENT;
      rules[nRules].p1_handle = iMA(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, rules[nRules].p1, 0, MODE_EMA, PRICE_CLOSE);
      rules[nRules].p2_handle = iMA(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, rules[nRules].p2, 0, MODE_EMA, PRICE_CLOSE);
      nRules++;
   }

   // RSI
   else if(StringFind(t, "rsi") >= 0) {
      rules[nRules].active = true;
      rules[nRules].type = RULE_RSI_THRESHOLD;
      rules[nRules].p1 = (int)ExtraiNumero(t, "rsi (", 14);
      rules[nRules].d1 = ExtraiNumero(t, "acima de ", 70);
      rules[nRules].d2 = ExtraiNumero(t, "abaixo de ", 30);
      if(StringFind(t, "subir") >= 0 || StringFind(t, "cair") >= 0 || StringFind(t, "cruzar") >= 0) rules[nRules].is_cross = true;

      rules[nRules].tf = PERIOD_CURRENT;
      rules[nRules].p1_handle = iRSI(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, rules[nRules].p1, PRICE_CLOSE);
      nRules++;
   }

   // Estocástico
   else if(StringFind(t, "estocástico") >= 0 || StringFind(t, "stoch") >= 0) {
      rules[nRules].active = true;
      rules[nRules].type = RULE_STOCH_CROSS;
      rules[nRules].tf = PERIOD_CURRENT;
      rules[nRules].p1_handle = iStochastic(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
      nRules++;
   }

   // Bollinger
   else if(StringFind(t, "bollinger") >= 0 || StringFind(t, "bb") >= 0) {
      rules[nRules].active = true;
      rules[nRules].type = RULE_BB_BOUNCE;
      rules[nRules].tf = PERIOD_CURRENT;
      rules[nRules].p1_handle = iBands(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, 20, 0, 2.0, PRICE_CLOSE);
      nRules++;
   }
}

double ExtraiNumero(string texto, string prefixo, double padrao) {
   int pos = StringFind(texto, prefixo);
   if(pos < 0) return padrao;

   string sub = StringSubstr(texto, pos + StringLen(prefixo));
   string res = "";
   for(int i=0; i<StringLen(sub); i++) {
      ushort c = StringGetCharacter(sub, i);
      if((c >= '0' && c <= '9') || c == '.') {
         res += CharToString((char)c);
      } else if (StringLen(res) > 0) break;
   }
   if(res == "") return padrao;
   return StringToDouble(res);
}

ENUM_TIMEFRAMES MinutesToTimeframe(int m) {
   if(m <= 1) return PERIOD_M1;
   if(m <= 5) return PERIOD_M5;
   if(m <= 15) return PERIOD_M15;
   if(m <= 30) return PERIOD_M30;
   if(m <= 60) return PERIOD_H1;
   if(m <= 240) return PERIOD_H4;
   return PERIOD_D1;
}

ENUM_TIMEFRAMES PeriodoTexto(string nome) {
   StringToLower(nome);
   if(nome == "m1") return PERIOD_M1;
   if(nome == "m5") return PERIOD_M5;
   if(nome == "m15") return PERIOD_M15;
   if(nome == "m30") return PERIOD_M30;
   if(nome == "h1") return PERIOD_H1;
   if(nome == "h4") return PERIOD_H4;
   if(nome == "d1") return PERIOD_D1;
   return PERIOD_CURRENT;
}

// ---------- DECISÃO E EXECUÇÃO ----------

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
         case RULE_MA_CROSS: s = CheckMA(rules[i]); break;
         case RULE_RSI_THRESHOLD: s = CheckRSI(rules[i]); break;
         case RULE_STOCH_CROSS: s = CheckStoch(rules[i]); break;
         case RULE_BB_BOUNCE: s = CheckBB(rules[i]); break;
         case RULE_DAILY_BREAK: s = CheckDailyBreak(rules[i]); break;
         case RULE_AMA: s = CheckAMA(rules[i]); break;
         case RULE_BAR_PATTERN: s = CheckBarPattern(rules[i]); break;
         case RULE_RELATIVE_STRENGTH: s = CheckRelative(rules[i]); break;
      }

      if(s == BUY) buyVotes++;
      if(s == SELL) sellVotes++;
   }

   // Confluência (AND): Todos os indicadores ativos devem concordar
   if(buyVotes == activeCount) return BUY;
   if(sellVotes == activeCount) return SELL;

   return NONE;
}

void EnviaOrdem(Signal s) {
   if(s == NONE) return;

   // Filtros Operacionais
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.hour < p_startTimeHour) return;
   if(AguardaNoticias()) return;
   if(PositionsTotal() >= p_maxTrades) return;

   // Hedge Check: Se não permitir hedge, fecha opostas
   if(!p_hedge) {
      for(int i=PositionsTotal()-1; i>=0; i--) {
         if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol) {
            if((s == BUY && posInfo.PositionType() == POSITION_TYPE_SELL) ||
               (s == SELL && posInfo.PositionType() == POSITION_TYPE_BUY)) {
               trade.PositionClose(posInfo.Ticket());
            }
         }
      }
   }

   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lote = CalculaLote(p_riskPercent);

   int safetyFloor = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + dynamicSafetyPoints + 2;
   int slPoints = MathMax(p_stopPoints, safetyFloor);
   int tpPoints = p_takePoints;

   double sl = (s == BUY) ? price - slPoints * _Point : price + slPoints * _Point;
   double tp = (s == BUY) ? price + tpPoints * _Point : price - tpPoints * _Point;

   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   if(s == BUY) trade.Buy(lote, _Symbol, price, sl, tp, "MT-LiveExecutor BUY");
   else trade.Sell(lote, _Symbol, price, sl, tp, "MT-LiveExecutor SELL");

   if(trade.ResultRetcode() == TRADE_RETCODE_DONE) {
      GravaLog("Ordem Enviada: " + EnumToString(s) + " Lote: " + DoubleToString(lote, 2));
      GravaCSV();
   } else {
      dynamicSafetyPoints = MathMin(dynamicSafetyPoints + 5, 100);
      GravaLog("Erro ao enviar ordem: " + IntegerToString(trade.ResultRetcode()));
   }
}

double CalculaLote(double riscoPercent) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riscoAbs = capital * riscoPercent / 100.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   int safetyFloor = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + dynamicSafetyPoints + 2;
   double stopDist = MathMax(p_stopPoints, safetyFloor) * _Point;

   if(stopDist == 0) return symbolInfo.LotsMin();

   double volume = riscoAbs / (stopDist * (tickValue / tickSize));

   // Martingale Support
   if(p_martingale) {
      HistorySelect(TimeCurrent()-86400, TimeCurrent());
      int total = HistoryDealsTotal();
      if(total > 0) {
         ulong ticket = HistoryDealGetTicket(total-1);
         if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) volume *= 2.0;
      }
   }

   return NormalizeVolume(volume);
}

double NormalizeVolume(double vol) {
   double min = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double res = MathFloor(vol / step) * step;
   if(res < min) res = min;
   if(res > max) res = max;
   return NormalizeDouble(res, 2);
}

// ---------- GESTÃO DE POSIÇÕES E SEGURANÇA ----------

void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol) {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double openPrice = posInfo.PriceOpen();
         double currentSL = posInfo.StopLoss();
         double currentTP = posInfo.TakeProfit();

         // Break-even
         if(p_bePoints > 0) {
            if(posInfo.PositionType() == POSITION_TYPE_BUY) {
               if(bid >= openPrice + p_bePoints * _Point && currentSL < openPrice) {
                  trade.PositionModify(posInfo.Ticket(), openPrice + p_beOffset * _Point, currentTP);
               }
            } else {
               if(ask <= openPrice - p_bePoints * _Point && (currentSL > openPrice || currentSL == 0)) {
                  trade.PositionModify(posInfo.Ticket(), openPrice - p_beOffset * _Point, currentTP);
               }
            }
         }

         // Trailing Stop
         if(p_trailingStopPoints > 0) {
            if(posInfo.PositionType() == POSITION_TYPE_BUY) {
               if(bid > openPrice + p_trailingStopPoints * _Point) {
                  double newSL = NormalizeDouble(bid - p_trailingStopPoints * _Point, _Digits);
                  if(newSL > currentSL + 10 * _Point) {
                     trade.PositionModify(posInfo.Ticket(), newSL, currentTP);
                  }
               }
            } else {
               if(ask < openPrice - p_trailingStopPoints * _Point) {
                  double newSL = NormalizeDouble(ask + p_trailingStopPoints * _Point, _Digits);
                  if(newSL < currentSL - 10 * _Point || currentSL == 0) {
                     trade.PositionModify(posInfo.Ticket(), newSL, currentTP);
                  }
               }
            }
         }
      }
   }
}

bool AguardaNoticias() {
   // Simulação de Veto por Notícias (lê de arquivo news_veto.txt)
   int handle = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      string content = FileReadString(handle);
      FileClose(handle);
      if(content == "1") return true;
   }
   return false;
}

void SynchronizeClusterSL() {
   // Unifica SL de posições do mesmo tipo no cluster
   double buySL = 0, sellSL = 0;
   for(int i=0; i<PositionsTotal(); i++) {
      if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol) {
         if(posInfo.PositionType() == POSITION_TYPE_BUY) buySL = posInfo.StopLoss();
         else sellSL = posInfo.StopLoss();
      }
   }

   for(int i=0; i<PositionsTotal(); i++) {
      if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol) {
         if(posInfo.PositionType() == POSITION_TYPE_BUY && posInfo.StopLoss() != buySL) {
            trade.PositionModify(posInfo.Ticket(), buySL, posInfo.TakeProfit());
         } else if(posInfo.PositionType() == POSITION_TYPE_SELL && posInfo.StopLoss() != sellSL) {
            trade.PositionModify(posInfo.Ticket(), sellSL, posInfo.TakeProfit());
         }
      }
   }
}

void DecaySafety() {
   if(TimeCurrent() - lastSafetyDecay >= 60) {
      if(dynamicSafetyPoints > 0) dynamicSafetyPoints--;
      lastSafetyDecay = TimeCurrent();
   }
}

void OnTradeTransaction(const MqlTradeTransaction& trans, const MqlTradeRequest& request, const MqlTradeResult& result) {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD) {
      SynchronizeClusterSL();
   }
}

// ---------- AI OPTIMIZER & PERFORMANCE ----------

void AIOptimizer() {
   double wr = CalculaWinRate();
   double pf = CalculaProfitFactor();
   double dd = CalculaDrawdown();

   // Heurística de Ajuste de Risco
   if(wr > 0.6 && pf > 1.5) p_riskPercent = MathMin(p_riskPercent * 1.1, 5.0);
   else if(wr < 0.4 || dd > 15.0) p_riskPercent = MathMax(p_riskPercent * 0.9, 0.5);

   // Otimização de SL via ATR (Simulado)
   if(atrHandle == INVALID_HANDLE) atrHandle = iATR(_Symbol, PERIOD_CURRENT, 14);
   double atr[1];
   if(CopyBuffer(atrHandle, 0, 0, 1, atr) > 0) {
      int newSL = (int)(atr[0] / _Point * 1.5);
      if(newSL > 100) p_stopPoints = newSL;
   }

   GravaLog("AI Optimizer: WR=" + DoubleToString(wr, 2) + " PF=" + DoubleToString(pf, 2) + " DD=" + DoubleToString(dd, 2) + "%");
}

double CalculaWinRate() {
   HistorySelect(TimeCurrent()-604800, TimeCurrent()); // Última semana
   int total = HistoryDealsTotal();
   int wins = 0, count = 0;
   for(int i=0; i<total; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT) {
         count++;
         if(HistoryDealGetDouble(ticket, DEAL_PROFIT) > 0) wins++;
      }
   }
   return (count > 0) ? (double)wins/count : 0;
}

double CalculaProfitFactor() {
   HistorySelect(TimeCurrent()-604800, TimeCurrent());
   double grossProfit = 0, grossLoss = 0;
   int total = HistoryDealsTotal();
   for(int i=0; i<total; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT) {
         double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT) + HistoryDealGetDouble(ticket, DEAL_COMMISSION) + HistoryDealGetDouble(ticket, DEAL_SWAP);
         if(profit > 0) grossProfit += profit;
         else grossLoss -= profit;
      }
   }
   return (grossLoss > 0) ? grossProfit / grossLoss : grossProfit;
}

double CalculaDrawdown() {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance == 0) return 0;
   return (balance - equity) / balance * 100.0;
}

// ---------- PERSISTÊNCIA E EVENTOS ----------

void OnTick() {
   DecaySafety();
   GerenciaPosicoes();

   // Execução baseada em candle
   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar != lastBarTime) {
      Signal s = AvaliaTudo();
      if(s != NONE) EnviaOrdem(s);
      lastBarTime = currentBar;
   }
}

void OnTimer() {
   // No-Restart Update Mechanism
   if(GlobalVariableCheck("MT_Executor_Prompt_Update") && GlobalVariableGet("MT_Executor_Prompt_Update") > 0) {
      int handle = FileOpen("MT_LiveExecutor_Prompt.txt", FILE_READ | FILE_TXT);
      if(handle != INVALID_HANDLE) {
         string newPrompt = FileReadString(handle);
         FileClose(handle);
         InterpretaPrompt(newPrompt);
         GlobalVariableSet("MT_Executor_Prompt_Update", 0);
      }
   }

   // AI Optimizer periodically (every hour in a real scenario, here on timer for simplicity)
   static int aiCounter = 0;
   if(++aiCounter >= 3600) {
      AIOptimizer();
      aiCounter = 0;
   }
}

void GravaCSV() {
   int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV | FILE_ANSI);
   if(handle != INVALID_HANDLE) {
      FileWrite(handle, "Ticket", "Symbol", "Type", "OpenPrice", "SL", "TP", "Time");
      for(int i=0; i<PositionsTotal(); i++) {
         if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol) {
            FileWrite(handle, posInfo.Ticket(), posInfo.Symbol(), posInfo.PositionType(),
                      posInfo.PriceOpen(), posInfo.StopLoss(), posInfo.TakeProfit(), posInfo.Time());
         }
      }
      FileClose(handle);
   }
}

void GravaLog(string texto) {
   string msg = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + ": " + texto;
   Print(msg);
   int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_READ | FILE_WRITE | FILE_TXT);
   if(handle != INVALID_HANDLE) {
      FileSeek(handle, 0, SEEK_END);
      FileWriteString(handle, msg + "\r\n");
      FileClose(handle);
   }
}

datetime iTime(string symbol, ENUM_TIMEFRAMES tf, int shift) {
   datetime res[]; if(CopyTime(symbol, tf, shift, 1, res) > 0) return res[0]; return 0;
}
