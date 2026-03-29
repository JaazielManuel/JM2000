//+------------------------------------------------------------------+
//|                                              MT_LiveExecutor.mq5 |
//|                                  Copyright 2024, MT-LiveExecutor |
//|                                       https://www.metatrader.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MT-LiveExecutor"
#property link      "https://www.metatrader.com"
#property version   "9.50"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

//+------------------------------------------------------------------+
//| ENUMS AND STRUCTURES                                             |
//+------------------------------------------------------------------+
enum Signal { BUY = 1, SELL = -1, NONE = 0 };

enum RuleType {
   RULE_MA_CROSS,
   RULE_RSI,
   RULE_STOCH,
   RULE_BB,
   RULE_DAILY_BREAK,
   RULE_DELTA,
   RULE_VOLUME,
   RULE_AMA,
   RULE_BAR_PATTERN
};

struct Rule {
   bool      active;
   RuleType  type;
   Signal    intent; // BUY, SELL or NONE (confluence)
   ENUM_TIMEFRAMES tf;
   int       p1, p2, p3;
   double    d1, d2;
   int       p1_handle, p2_handle, p3_handle;
   bool      is_cross;
   string    description;
};

//+------------------------------------------------------------------+
//| GLOBAL PARAMETERS                                                |
//+------------------------------------------------------------------+
Rule rules[30];
int nRules = 0;

input string InpPrompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Não operar 20 min antes ou depois de notícias de alto impacto. Máximo 3 trades simultâneos. Ao atingir +30 pontos, move stop para entrada +5 pontos.";

// Parsed parameters
double p_risk = 1.0;
int    p_stopPoints = 0;
int    p_takePoints = 0;
int    p_beTrigger = 0;
int    p_bePoints = 0;
int    p_trailingStop = 0;
int    p_maxTrades = 3;
int    p_newsVetoMins = 0;
datetime p_startTime = 0;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
bool   p_martingale = false;
bool   p_hedge = false;
bool   p_notifications = true;

// Operational state
CTrade trade;
datetime lastBarTime = 0;
int dynamicSafetyPoints = 0;
datetime lastSafetyDecay = 0;
int atrHandle = INVALID_HANDLE;
const int EA_MAGIC = 20260101;

//+------------------------------------------------------------------+
//| PROTOTYPES                                                       |
//+------------------------------------------------------------------+
void InterpretaPrompt(string prompt);
Signal AvaliaTudo();
double CalculaLote(double risco);
void EnviaOrdem(Signal s);
void GerenciaPosicoes();
bool AguardaNoticias();
void GravaCSV();
void AIOptimizer();
void ResetStrategy();
int PeriodoTexto(string nome);
double ExtractNumber(string txt, string keyword);
string ExtractTime(string txt, string keyword);

//+------------------------------------------------------------------+
//| PROMPT PARSER (NLP)                                              |
//+------------------------------------------------------------------+

void ResetStrategy() {
   for(int i=0; i<30; i++) {
      if(rules[i].p1_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p1_handle);
      if(rules[i].p2_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p2_handle);
      if(rules[i].p3_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p3_handle);
      rules[i].active = false;
   }
   nRules = 0;
}

double ExtractNumber(string txt, string keyword) {
   int pos = StringFind(txt, keyword);
   if(pos < 0) return 0;
   string sub = StringSubstr(txt, pos + StringLen(keyword));
   string num = "";
   for(int i=0; i<StringLen(sub); i++) {
      ushort c = StringGetCharacter(sub, i);
      if((c >= '0' && c <= '9') || c == '.') num += CharToString((uchar)c);
      else if(StringLen(num) > 0) break;
   }
   return StringToDouble(num);
}

string ExtractTime(string txt, string keyword) {
   int pos = StringFind(txt, keyword);
   if(pos < 0) return "";
   string sub = StringSubstr(txt, pos + StringLen(keyword));
   StringReplace(sub, "h", ":");
   string timeStr = "";
   for(int i=0; i<StringLen(sub); i++) {
      ushort c = StringGetCharacter(sub, i);
      if((c >= '0' && c <= '9') || c == ':') timeStr += CharToString((uchar)c);
      else if(StringLen(timeStr) > 0) break;
   }
   if(StringFind(timeStr, ":") < 0) timeStr += ":00";
   return timeStr;
}

ENUM_TIMEFRAMES MinutesToTimeframe(int mins) {
   if(mins <= 1) return PERIOD_M1;
   if(mins <= 5) return PERIOD_M5;
   if(mins <= 15) return PERIOD_M15;
   if(mins <= 30) return PERIOD_M30;
   if(mins <= 60) return PERIOD_H1;
   if(mins <= 240) return PERIOD_H4;
   if(mins <= 1440) return PERIOD_D1;
   return PERIOD_CURRENT;
}

int PeriodoTexto(string nome) {
   if(StringFind(nome, "m15") >= 0) return PERIOD_M15;
   if(StringFind(nome, "m30") >= 0) return PERIOD_M30;
   if(StringFind(nome, "m1") >= 0)  return PERIOD_M1;
   if(StringFind(nome, "m5") >= 0)  return PERIOD_M5;
   if(StringFind(nome, "h1") >= 0)  return PERIOD_H1;
   if(StringFind(nome, "h4") >= 0)  return PERIOD_H4;
   if(StringFind(nome, "d1") >= 0)  return PERIOD_D1;
   return PERIOD_CURRENT;
}

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   StringToLower(prompt);

   // Split prompt into segments
   string segments[];
   string workingPrompt = prompt;
   StringReplace(workingPrompt, " e ", "|");
   StringReplace(workingPrompt, " + ", "|");
   StringReplace(workingPrompt, ".", "|");
   StringSplit(workingPrompt, '|', segments);

   Signal currentIntent = NONE;
   for(int i=0; i<ArraySize(segments); i++) {
      if(nRules >= 30) break;
      string s = segments[i];
      StringTrimLeft(s); StringTrimRight(s);

      if(StringFind(s, "compra") >= 0) currentIntent = BUY;
      else if(StringFind(s, "vende") >= 0) currentIntent = SELL;

      // 1. Moving Average
      if(StringFind(s, "média") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = RULE_MA_CROSS;
         rules[nRules].intent = currentIntent;
         rules[nRules].p1 = (int)ExtractNumber(s, "média de ");
         if(rules[nRules].p1 == 0) rules[nRules].p1 = 20;
         rules[nRules].tf = (ENUM_TIMEFRAMES)PeriodoTexto(s);
         rules[nRules].is_cross = (StringFind(s, "cruzar") >= 0);
         rules[nRules].p1_handle = iMA(_Symbol, rules[nRules].tf, rules[nRules].p1, 0, MODE_SMA, PRICE_CLOSE);
         nRules++;
      }

      // 2. RSI
      if(StringFind(s, "rsi") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = RULE_RSI;
         rules[nRules].intent = currentIntent;
         rules[nRules].p1 = (int)ExtractNumber(s, "rsi (");
         if(rules[nRules].p1 == 0) rules[nRules].p1 = (int)ExtractNumber(s, "rsi ");
         if(rules[nRules].p1 == 0) rules[nRules].p1 = 14;
         rules[nRules].d1 = ExtractNumber(s, "acima de ");
         rules[nRules].d2 = ExtractNumber(s, "abaixo de ");
         rules[nRules].tf = (ENUM_TIMEFRAMES)PeriodoTexto(s);
         rules[nRules].is_cross = (StringFind(s, "subir") >= 0 || StringFind(s, "cair") >= 0);
         rules[nRules].p1_handle = iRSI(_Symbol, rules[nRules].tf, rules[nRules].p1, PRICE_CLOSE);
         nRules++;
      }

      // 3. Stochastic
      if(StringFind(s, "estocástico") >= 0 || StringFind(s, "stoch") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = RULE_STOCH;
         rules[nRules].intent = currentIntent;
         rules[nRules].p1 = (int)ExtractNumber(s, "k="); if(rules[nRules].p1 == 0) rules[nRules].p1 = 5;
         rules[nRules].p2 = (int)ExtractNumber(s, "d="); if(rules[nRules].p2 == 0) rules[nRules].p2 = 3;
         rules[nRules].p3 = (int)ExtractNumber(s, "slowing="); if(rules[nRules].p3 == 0) rules[nRules].p3 = 3;
         rules[nRules].tf = (ENUM_TIMEFRAMES)PeriodoTexto(s);
         rules[nRules].p1_handle = iStochastic(_Symbol, rules[nRules].tf, rules[nRules].p1, rules[nRules].p2, rules[nRules].p3, MODE_SMA, STO_LOWHIGH);
         nRules++;
      }

      // 4. Bollinger Bands
      if(StringFind(s, "bollinger") >= 0 || StringFind(s, "bb") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = RULE_BB;
         rules[nRules].intent = currentIntent;
         rules[nRules].p1 = (int)ExtractNumber(s, "período "); if(rules[nRules].p1 == 0) rules[nRules].p1 = 20;
         rules[nRules].d1 = ExtractNumber(s, "desvio "); if(rules[nRules].d1 == 0) rules[nRules].d1 = 2.0;
         rules[nRules].tf = (ENUM_TIMEFRAMES)PeriodoTexto(s);
         rules[nRules].p1_handle = iBands(_Symbol, rules[nRules].tf, rules[nRules].p1, 0, rules[nRules].d1, PRICE_CLOSE);
         nRules++;
      }

      // 5. AMA
      if(StringFind(s, "ama") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = RULE_AMA;
         rules[nRules].intent = currentIntent;
         rules[nRules].p1 = (int)ExtractNumber(s, "ama "); if(rules[nRules].p1 == 0) rules[nRules].p1 = 10;
         rules[nRules].tf = (ENUM_TIMEFRAMES)PeriodoTexto(s);
         rules[nRules].p1_handle = iAMA(_Symbol, rules[nRules].tf, rules[nRules].p1, 2, 30, 0, PRICE_CLOSE);
         nRules++;
      }
   }

   // Operational Parameters
   p_risk = ExtractNumber(prompt, "risco de "); if(p_risk == 0) p_risk = 1.0;
   p_stopPoints = (int)ExtractNumber(prompt, "stop de ");
   p_takePoints = (int)ExtractNumber(prompt, "take de ");
   p_beTrigger = (int)ExtractNumber(prompt, "atingir +");
   p_bePoints = (int)ExtractNumber(prompt, "entrada +");
   p_trailingStop = (int)ExtractNumber(prompt, "trailing de ");
   p_maxTrades = (int)ExtractNumber(prompt, "máximo "); if(p_maxTrades == 0) p_maxTrades = 3;
   p_newsVetoMins = (int)ExtractNumber(prompt, "operar ");

   int freqMins = (int)ExtractNumber(prompt, "a cada ");
   if(freqMins > 0) p_frequency = MinutesToTimeframe(freqMins);

   string timeStr = ExtractTime(prompt, "depois das ");
   if(timeStr != "") p_startTime = StringToTime(TimeToString(TimeCurrent(), TIME_DATE) + " " + timeStr);

   lastBarTime = 0; // Force immediate re-evaluation if bar closed
}

//+------------------------------------------------------------------+
//| INDICATOR EVALUATION                                             |
//+------------------------------------------------------------------+

Signal CheckMA(Rule &r) {
   double ma[2];
   double close[2];
   if(CopyBuffer(r.p1_handle, 0, 1, 2, ma) < 2) return NONE;
   if(CopyClose(_Symbol, r.tf, 1, 2, close) < 2) return NONE;

   // Index 0 is older bar (e.g., shift 2), Index 1 is newer bar (e.g., shift 1)
   if(r.is_cross) {
      if(close[0] <= ma[0] && close[1] > ma[1]) return BUY;
      if(close[0] >= ma[0] && close[1] < ma[1]) return SELL;
   } else {
      if(close[1] > ma[1]) return BUY;
      if(close[1] < ma[1]) return SELL;
   }
   return NONE;
}

Signal CheckRSI(Rule &r) {
   double rsi[2];
   if(CopyBuffer(r.p1_handle, 0, 1, 2, rsi) < 2) return NONE;

   if(r.is_cross) {
      if(r.d1 > 0 && rsi[0] <= r.d1 && rsi[1] > r.d1) return BUY;
      if(r.d2 > 0 && rsi[0] >= r.d2 && rsi[1] < r.d2) return SELL;
   } else {
      if(r.d1 > 0 && rsi[1] > r.d1) return BUY;
      if(r.d2 > 0 && rsi[1] < r.d2) return SELL;
   }
   return NONE;
}

Signal CheckStoch(Rule &r) {
   double k[2], d[2];
   if(CopyBuffer(r.p1_handle, 0, 1, 2, k) < 2) return NONE;
   if(CopyBuffer(r.p1_handle, 1, 1, 2, d) < 2) return NONE;

   if(k[0] <= d[0] && k[1] > d[1]) return BUY;
   if(k[0] >= d[0] && k[1] < d[1]) return SELL;
   return NONE;
}

Signal CheckBB(Rule &r) {
   double upper[1], lower[1], close[1];
   if(CopyBuffer(r.p1_handle, 1, 1, 1, upper) < 1) return NONE;
   if(CopyBuffer(r.p1_handle, 2, 1, 1, lower) < 1) return NONE;
   if(CopyClose(_Symbol, r.tf, 1, 1, close) < 1) return NONE;

   if(close[0] < lower[0]) return BUY;
   if(close[0] > upper[0]) return SELL;
   return NONE;
}

Signal CheckAMA(Rule &r) {
   double ama[2];
   if(CopyBuffer(r.p1_handle, 0, 1, 2, ama) < 2) return NONE;

   if(ama[1] > ama[0]) return BUY;
   if(ama[1] < ama[0]) return SELL;
   return NONE;
}

Signal AvaliaTudo() {
   int activeRules = 0;
   int buyLegRules = 0, buyLegVotes = 0;
   int sellLegRules = 0, sellLegVotes = 0;
   int neutralLegRules = 0, neutralLegVotes = 0;

   for(int i=0; i<nRules; i++) {
      if(!rules[i].active) continue;
      activeRules++;
      Signal s = NONE;

      switch(rules[i].type) {
         case RULE_MA_CROSS: s = CheckMA(rules[i]); break;
         case RULE_RSI:      s = CheckRSI(rules[i]); break;
         case RULE_STOCH:    s = CheckStoch(rules[i]); break;
         case RULE_BB:       s = CheckBB(rules[i]); break;
         case RULE_AMA:      s = CheckAMA(rules[i]); break;
         default: break;
      }

      if(rules[i].intent == BUY) {
         buyLegRules++;
         if(s == BUY) buyLegVotes++;
      } else if(rules[i].intent == SELL) {
         sellLegRules++;
         if(s == SELL) sellLegVotes++;
      } else {
         neutralLegRules++;
         if(s == BUY) neutralLegVotes++;
         else if(s == SELL) neutralLegVotes--;
      }
   }

   if(activeRules == 0) return NONE;

   // Buy condition: if a buy intent was expressed, all buy-leg rules must be true.
   // Else, if neutral rules provide a confluence.
   bool buyTrigger = (buyLegRules > 0 && buyLegVotes == buyLegRules);
   bool sellTrigger = (sellLegRules > 0 && sellLegVotes == sellLegRules);

   if(buyTrigger && !sellTrigger) return BUY;
   if(sellTrigger && !buyTrigger) return SELL;

   // Fallback: simple confluence of neutral rules
   if(neutralLegRules > 0) {
      if(neutralLegVotes == neutralLegRules) return BUY;
      if(neutralLegVotes == -neutralLegRules) return SELL;
   }

   return NONE;
}

//+------------------------------------------------------------------+
//| TRADE EXECUTION AND RISK                                         |
//+------------------------------------------------------------------+

double CalculaLote(double riscoPercent) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riscoAbs = capital * riscoPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   int stopPoints = p_stopPoints;
   if(stopPoints <= 0) stopPoints = 100; // Default safety

   double volume = riscoAbs / (stopPoints * (tickValue / (tickSize / _Point)));

   // Martingale - specifically for the current symbol and magic number
   if(p_martingale) {
      HistorySelect(TimeCurrent()-86400, TimeCurrent());
      for(int i=HistoryDealsTotal()-1; i>=0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) + HistoryDealGetDouble(ticket, DEAL_COMMISSION) + HistoryDealGetDouble(ticket, DEAL_SWAP) < 0) {
               volume *= 2.0;
            }
            break;
         }
      }
   }

   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   volume = MathFloor(volume/stepVol) * stepVol;
   return MathMin(maxVol, MathMax(minVol, volume));
}

bool IsPriceSafe(double price) {
   double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double safetyBuffer = (stopsLevel + dynamicSafetyPoints + 1) * _Point;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(MathAbs(price - bid) < safetyBuffer || MathAbs(price - ask) < safetyBuffer) return false;
   return true;
}

void EnviaOrdem(Signal s) {
   if(s == NONE) return;
   if(PositionsTotal() >= p_maxTrades) return;

   double lote = CalculaLote(p_risk);
   double sl = 0, tp = 0;
   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(s == BUY) {
      if(p_stopPoints > 0) sl = price - p_stopPoints * _Point;
      if(p_takePoints > 0) tp = price + p_takePoints * _Point;
      if(sl != 0 && !IsPriceSafe(sl)) sl = price - (SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + dynamicSafetyPoints + 1) * _Point;
      if(trade.Buy(lote, _Symbol, price, sl, tp, "MT-LiveExecutor")) {
         if(p_notifications) SendNotification("Compra executada em " + _Symbol + " a " + DoubleToString(price, _Digits));
      }
   } else {
      if(p_stopPoints > 0) sl = price + p_stopPoints * _Point;
      if(p_takePoints > 0) tp = price - p_takePoints * _Point;
      if(sl != 0 && !IsPriceSafe(sl)) sl = price + (SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + dynamicSafetyPoints + 1) * _Point;
      if(trade.Sell(lote, _Symbol, price, sl, tp, "MT-LiveExecutor")) {
         if(p_notifications) SendNotification("Venda executada em " + _Symbol + " a " + DoubleToString(price, _Digits));
      }
   }

   if(trade.ResultRetcode() != TRADE_RETCODE_DONE) {
      dynamicSafetyPoints = MathMin(100, dynamicSafetyPoints + 5);
   }
}

//+------------------------------------------------------------------+
//| POSITION MANAGEMENT AND AUXILIARY                                |
//+------------------------------------------------------------------+

void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double sl = PositionGetDouble(POSITION_SL);

         // Breakeven
         if(p_beTrigger > 0) {
            double profitPoints = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? (currentPrice - openPrice) / _Point : (openPrice - currentPrice) / _Point;
            if(profitPoints >= p_beTrigger) {
               double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? openPrice + p_bePoints * _Point : openPrice - p_bePoints * _Point;
               if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && (sl < newSL || sl == 0)) || (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (sl > newSL || sl == 0))) {
                  trade.PositionModify(ticket, NormalizeDouble(newSL, _Digits), PositionGetDouble(POSITION_TP));
               }
            }
         }

         // Trailing Stop
         if(p_trailingStop > 0) {
            double profitPoints = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? (currentPrice - openPrice) / _Point : (openPrice - currentPrice) / _Point;
            if(profitPoints > p_trailingStop) {
               double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? currentPrice - p_trailingStop * _Point : currentPrice + p_trailingStop * _Point;
               if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && (newSL > sl || sl == 0)) || (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (newSL < sl || sl == 0))) {
                  trade.PositionModify(ticket, NormalizeDouble(newSL, _Digits), PositionGetDouble(POSITION_TP));
               }
            }
         }
      }
   }
}

bool AguardaNoticias() {
   if(p_newsVetoMins == 0) return false;
   MqlCalendarValue values[];
   datetime from = TimeCurrent() - p_newsVetoMins * 60;
   datetime to = TimeCurrent() + p_newsVetoMins * 60;

   if(CalendarValueHistory(values, from, to)) {
      for(int i=0; i<ArraySize(values); i++) {
         MqlCalendarEvent event;
         if(CalendarEventById(values[i].event_id, event)) {
            if(event.importance == CALENDAR_IMPORTANCE_HIGH) return true;
         }
      }
   }
   return false;
}

void GravaCSV() {
   int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV | FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      FileWrite(handle, "Ticket", "Symbol", "Price", "SL", "TP", "Time", "Reason");
      for(int i=0; i<PositionsTotal(); i++) {
         if(PositionSelectByTicket(PositionGetTicket(i))) {
            FileWrite(handle, PositionGetInteger(POSITION_TICKET), PositionGetString(POSITION_SYMBOL), PositionGetDouble(POSITION_PRICE_OPEN), PositionGetDouble(POSITION_SL), PositionGetDouble(POSITION_TP), PositionGetInteger(POSITION_TIME), "MT-LiveExecutor Active");
         }
      }
      FileClose(handle);
   }
}

void AIOptimizer() {
   HistorySelect(TimeCurrent()-86400*30, TimeCurrent());
   int total = HistoryDealsTotal();
   int wins = 0, losses = 0;
   double profit = 0;

   for(int i=0; i<total; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      double p = HistoryDealGetDouble(ticket, DEAL_PROFIT) + HistoryDealGetDouble(ticket, DEAL_COMMISSION) + HistoryDealGetDouble(ticket, DEAL_SWAP);
      if(p > 0) wins++;
      else if(p < 0) losses++;
      profit += p;
   }

   double winRate = (wins + losses > 0) ? (double)wins / (wins + losses) : 0;
   if(winRate < 0.4 && (wins + losses) > 10) p_risk *= 0.8;

   // ATR optimization
   if(atrHandle == INVALID_HANDLE) atrHandle = iATR(_Symbol, PERIOD_CURRENT, 14);
   double atr[1];
   if(CopyBuffer(atrHandle, 0, 0, 1, atr) > 0) {
      if(p_stopPoints == 0) p_stopPoints = (int)(atr[0] * 1.5 / _Point);
   }
}

//+------------------------------------------------------------------+
//| LIFECYCLE HANDLERS                                               |
//+------------------------------------------------------------------+

int OnInit() {
   InterpretaPrompt(InpPrompt);
   EventSetTimer(60);
   trade.SetExpertMagicNumber(EA_MAGIC);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   ResetStrategy();
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   EventKillTimer();
}

void OnTick() {
   if(p_startTime > 0 && TimeCurrent() < p_startTime) return;
   if(AguardaNoticias()) return;

   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar != lastBarTime) {
      lastBarTime = currentBar; // Update immediately to prevent redundant polling
      Signal s = AvaliaTudo();
      if(s != NONE) {
         EnviaOrdem(s);
         GravaCSV();
      }
   }

   GerenciaPosicoes();

   // Safety decay
   if(TimeCurrent() - lastSafetyDecay > 60) {
      if(dynamicSafetyPoints > 0) dynamicSafetyPoints--;
      lastSafetyDecay = TimeCurrent();
   }
}

void OnTimer() {
   AIOptimizer();

   // Check for prompt updates via GlobalVariable or File
   if(GlobalVariableCheck("MT_Executor_Prompt_Update") && GlobalVariableGet("MT_Executor_Prompt_Update") > 0) {
      int handle = FileOpen("MT_LiveExecutor_Prompt.txt", FILE_READ | FILE_TXT | FILE_COMMON);
      if(handle != INVALID_HANDLE) {
         string newPrompt = FileReadString(handle);
         FileClose(handle);
         if(newPrompt != "") {
            InterpretaPrompt(newPrompt);
            GlobalVariableSet("MT_Executor_Prompt_Update", 0);
         }
      }
   }
}

void OnTradeTransaction(const MqlTradeTransaction& trans, const MqlTradeRequest& request, const MqlTradeResult& result) {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD) {
      if(HistoryDealSelect(trans.deal)) {
         long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_IN) {
            // New position added
            GravaCSV();
         }
      }
   }
}
