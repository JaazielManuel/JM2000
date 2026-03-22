//+------------------------------------------------------------------+
//|                                              MT_LiveExecutor.mq5 |
//|                                  Copyright 2026, Profit Master   |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Profit Master"
#property link      "https://www.mql5.com"
#property version   "8.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// --- Enums ---
enum Signal { BUY=1, SELL=-1, NONE=0 };

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
   RULE_RS_RELATIVE
};

// --- Structs ---
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

// --- Global Variables ---
Rule rules[30];
int nRules = 0;
CTrade trade;
CPositionInfo pos;
CSymbolInfo sym;
CAccountInfo acc;

// Global strategy parameters
double p_riskPercent = 1.0;
int p_stopPoints = 300;
int p_takePoints = 500;
int p_breakevenPoints = 300;
int p_breakevenPlus = 50;
int p_trailingStopPoints = 0;
int p_maxTrades = 3;
int p_frequency = PERIOD_M15;
int p_startHour = 10;
int p_newsVetoMins = 20;
bool p_martingale = false;
bool p_hedge = true;
bool p_notifications = false;

datetime lastBarTime = 0;
int dynamicSafetyPoints = 0;
datetime lastSafetyDecay = 0;
int atrHandle = INVALID_HANDLE;

// Forward declarations
void InterpretaPrompt(string prompt);
Signal AvaliaTudo();
double CalculaLote(double risco);
void EnviaOrdem(Signal s);
void GerenciaPosicoes();
bool AguardaNoticias();
void SynchronizeClusterSL(double newSL, ENUM_POSITION_TYPE type);
double CalculateValidSL(double price, int points, ENUM_POSITION_TYPE type);
double NS(double price) { return NormalizeDouble(price, _Digits); }
double NV(double vol) {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   return NormalizeDouble(MathFloor(vol/step+0.000001)*step, 2);
}

//+------------------------------------------------------------------+
// --- Helper Functions ---
double ExtraiNumero(string texto, string palavraChave) {
   int pos = StringFind(texto, palavraChave);
   if(pos < 0) return -1;
   int start = pos + StringLen(palavraChave);
   string sub = StringSubstr(texto, start);
   string res = "";
   for(int i=0; i<StringLen(sub); i++) {
      ushort c = StringGetCharacter(sub, i);
      if((c >= '0' && c <= '9') || c == '.') res += CharToString((char)c);
      else if(StringLen(res) > 0) break;
   }
   return StringToDouble(res);
}

int MinutesToTimeframe(int mins) {
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
   string n = nome; StringToLower(n);
   if(StringFind(n, "m1") >= 0) return PERIOD_M1;
   if(StringFind(n, "m5") >= 0) return PERIOD_M5;
   if(StringFind(n, "m15") >= 0) return PERIOD_M15;
   if(StringFind(n, "m30") >= 0) return PERIOD_M30;
   if(StringFind(n, "h1") >= 0) return PERIOD_H1;
   if(StringFind(n, "h4") >= 0) return PERIOD_H4;
   if(StringFind(n, "d1") >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

void AddRule(RuleType type, int tf, int p1=0, int p2=0, int p3=0, double d1=-1, double d2=-1, string s1="", bool cross=false) {
   for(int i=0; i<nRules; i++) {
      if(rules[i].type == type) {
         rules[i].tf = tf;
         if(p1 > 0) rules[i].p1 = p1;
         if(p2 > 0) rules[i].p2 = p2;
         if(p3 > 0) rules[i].p3 = p3;
         if(d1 >= 0) rules[i].d1 = d1;
         if(d2 >= 0) rules[i].d2 = d2;
         if(s1 != "") rules[i].s1 = s1;
         rules[i].is_cross = cross;
         return;
      }
   }
   if(nRules < 30) {
      rules[nRules].active = true;
      rules[nRules].type = type;
      rules[nRules].tf = tf;
      rules[nRules].p1 = p1; rules[nRules].p2 = p2; rules[nRules].p3 = p3;
      rules[nRules].d1 = (d1 >= 0) ? d1 : 70;
      rules[nRules].d2 = (d2 >= 0) ? d2 : 30;
      rules[nRules].s1 = s1;
      rules[nRules].is_cross = cross;
      rules[nRules].p1_handle = INVALID_HANDLE;
      rules[nRules].p2_handle = INVALID_HANDLE;
      rules[nRules].p3_handle = INVALID_HANDLE;
      nRules++;
   }
}

// --- NLP Parser ---
void InterpretaPrompt(string prompt) {
   string p = prompt; StringToLower(p);

   string clean = p;
   StringReplace(clean, ". ", " ");
   StringReplace(clean, ", ", " ");

   if(StringFind(clean, "cada ") >= 0) p_frequency = MinutesToTimeframe((int)ExtraiNumero(clean, "cada "));
   if(StringFind(clean, "depois das ") >= 0) p_startHour = (int)ExtraiNumero(clean, "depois das ");
   if(StringFind(clean, "stop de ") >= 0) p_stopPoints = (int)ExtraiNumero(clean, "stop de ");
   if(StringFind(clean, "take de ") >= 0) p_takePoints = (int)ExtraiNumero(clean, "take de ");
   if(StringFind(clean, "risco de ") >= 0) p_riskPercent = ExtraiNumero(clean, "risco de ");
   if(StringFind(clean, "máximo ") >= 0 && StringFind(clean, "trades") >= 0) p_maxTrades = (int)ExtraiNumero(clean, "máximo ");
   if(StringFind(clean, "notícias") >= 0) p_newsVetoMins = (int)ExtraiNumero(clean, "operar ");

   if(StringFind(clean, "trailing stop") >= 0) p_trailingStopPoints = (int)ExtraiNumero(clean, "trailing de ");
   if(StringFind(clean, "atingir +") >= 0) {
      p_breakevenPoints = (int)ExtraiNumero(clean, "atingir +");
      p_breakevenPlus = (int)ExtraiNumero(clean, "entrada +");
   }
   if(StringFind(clean, "martingale") >= 0) p_martingale = true;
   if(StringFind(clean, "hedge") >= 0) p_hedge = true;
   if(StringFind(clean, "notificações") >= 0) p_notifications = true;

   for(int i=0; i<nRules; i++) {
      if(rules[i].p1_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p1_handle);
      if(rules[i].p2_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p2_handle);
      if(rules[i].p3_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p3_handle);
      rules[i].p1_handle = INVALID_HANDLE;
      rules[i].p2_handle = INVALID_HANDLE;
      rules[i].p3_handle = INVALID_HANDLE;
   }
   nRules = 0;
   lastBarTime = 0;

   string parts[];
   ushort sep = StringGetCharacter("|", 0);
   string splitStr = clean;
   StringReplace(splitStr, " e ", "|");
   StringReplace(splitStr, " + ", "|");
   StringSplit(splitStr, sep, parts);

   string currentContext = "";
   for(int i=0; i<ArraySize(parts); i++) {
      string s = parts[i];
      if(StringFind(s, "média") >= 0) currentContext = "ma";
      if(StringFind(s, "rsi") >= 0) currentContext = "rsi";
      if(StringFind(s, "estocástico") >= 0) currentContext = "stoch";
      if(StringFind(s, "bollinger") >= 0) currentContext = "bb";

      if(currentContext == "ma") {
         int per = (int)ExtraiNumero(s, "média de ");
         if(per <= 0) per = (int)ExtraiNumero(s, "média ");
         if(per <= 0) per = 20;
         bool cross = (StringFind(s, "cruzar") >= 0);
         AddRule(RULE_MA_CROSS, p_frequency, per, 0, 0, -1, -1, "", cross);
      }
      else if(currentContext == "rsi") {
         int per = (int)ExtraiNumero(s, "rsi (");
         if(per < 0) per = (int)ExtraiNumero(s, "rsi ");
         if(per < 0) per = 14;
         double over = -1, under = -1;
         if(StringFind(s, "acima de ") >= 0) over = ExtraiNumero(s, "acima de ");
         if(StringFind(s, "abaixo de ") >= 0) under = ExtraiNumero(s, "abaixo de ");
         AddRule(RULE_RSI_THRESHOLD, p_frequency, per, 0, 0, over, under, "", (StringFind(s, "subir") >= 0 || StringFind(s, "cair") >= 0));
      }
      else if(currentContext == "stoch") AddRule(RULE_STOCH_CROSS, p_frequency, 5, 3, 3);
      else if(currentContext == "bb") AddRule(RULE_BB_BOUNCE, p_frequency, 20, 0, 0, 2.0);
   }

   for(int i=0; i<nRules; i++) {
      if(rules[i].type == RULE_MA_CROSS) rules[i].p1_handle = iMA(_Symbol, (ENUM_TIMEFRAMES)rules[i].tf, rules[i].p1, 0, MODE_SMA, PRICE_CLOSE);
      if(rules[i].type == RULE_RSI_THRESHOLD) rules[i].p1_handle = iRSI(_Symbol, (ENUM_TIMEFRAMES)rules[i].tf, rules[i].p1, PRICE_CLOSE);
      if(rules[i].type == RULE_STOCH_CROSS) rules[i].p1_handle = iStochastic(_Symbol, (ENUM_TIMEFRAMES)rules[i].tf, rules[i].p1, rules[i].p2, rules[i].p3, MODE_SMA, STO_LOWHIGH);
      if(rules[i].type == RULE_BB_BOUNCE) rules[i].p1_handle = iBands(_Symbol, (ENUM_TIMEFRAMES)rules[i].tf, rules[i].p1, 0, rules[i].d1, PRICE_CLOSE);
   }
}

// --- Technical Indicators (Implementation) ---
Signal CheckMA(Rule &r, int shift=1) {
   double ma[2], close[2];
   if(CopyBuffer(r.p1_handle, 0, shift, 2, ma) < 2) return NONE;
   if(CopyClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift, 2, close) < 2) return NONE;

   if(r.is_cross) {
      if(close[1] <= ma[1] && close[0] > ma[0]) return BUY;
      if(close[1] >= ma[1] && close[0] < ma[0]) return SELL;
   } else {
      if(close[0] > ma[0]) return BUY;
      if(close[0] < ma[0]) return SELL;
   }
   return NONE;
}

Signal CheckRSI(Rule &r, int shift=1) {
   double rsi[2];
   if(CopyBuffer(r.p1_handle, 0, shift, 2, rsi) < 2) return NONE;

   if(r.is_cross) {
      if(rsi[1] <= r.d2 && rsi[0] > r.d2) return BUY;
      if(rsi[1] >= r.d1 && rsi[0] < r.d1) return SELL;
   } else {
      if(rsi[0] < r.d2) return BUY;
      if(rsi[0] > r.d1) return SELL;
   }
   return NONE;
}

Signal CheckStoch(Rule &r, int shift=1) {
   double k[2], d[2];
   if(CopyBuffer(r.p1_handle, 0, shift, 2, k) < 2) return NONE;
   if(CopyBuffer(r.p1_handle, 1, shift, 2, d) < 2) return NONE;

   if(k[1] <= d[1] && k[0] > d[0]) return BUY;
   if(k[1] >= d[1] && k[0] < d[0]) return SELL;
   return NONE;
}

Signal CheckBB(Rule &r, int shift=1) {
   double up[1], lo[1], close[1];
   if(CopyBuffer(r.p1_handle, 1, shift, 1, up) < 1) return NONE;
   if(CopyBuffer(r.p1_handle, 2, shift, 1, lo) < 1) return NONE;
   if(CopyClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift, 1, close) < 1) return NONE;

   if(close[0] < lo[0]) return BUY;
   if(close[0] > up[0]) return SELL;
   return NONE;
}

// --- Core Trading Logic ---
Signal AvaliaTudo() {
   if(nRules == 0) return NONE;
   int buyVotes = 0, sellVotes = 0;
   for(int i=0; i<nRules; i++) {
      Signal s = NONE;
      if(rules[i].type == RULE_MA_CROSS) s = CheckMA(rules[i], 1);
      if(rules[i].type == RULE_RSI_THRESHOLD) s = CheckRSI(rules[i], 1);
      if(rules[i].type == RULE_STOCH_CROSS) s = CheckStoch(rules[i], 1);
      if(rules[i].type == RULE_BB_BOUNCE) s = CheckBB(rules[i], 1);

      if(s == BUY) buyVotes++;
      if(s == SELL) sellVotes++;
   }
   if(buyVotes == nRules) return BUY;
   if(sellVotes == nRules) return SELL;
   return NONE;
}

double CalculaLote(double riscoPercent) {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(p_martingale) {
      if(HistorySelect(TimeCurrent()-86400, TimeCurrent())) {
         int total = HistoryDealsTotal();
         for(int i=total-1; i>=0; i--) {
            ulong ticket = HistoryDealGetTicket(i);
            if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol) {
               double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
               if(profit < 0) return NV(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN) * 2);
               break;
            }
         }
      }
   }

   double riskAbs = balance * (riscoPercent / 100.0);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double slPoints = (p_stopPoints > 0) ? p_stopPoints : 300;

   double lot = riskAbs / (slPoints * (tickValue / (tickSize / _Point)));
   return NV(lot);
}

void EnviaOrdem(Signal s) {
   if(s == NONE) return;
   if(AguardaNoticias()) return;

   int count = 0;
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(pos.SelectByIndex(i) && pos.Symbol() == _Symbol) {
         if(!p_hedge) {
            if((s == BUY && pos.PositionType() == POSITION_TYPE_SELL) ||
               (s == SELL && pos.PositionType() == POSITION_TYPE_BUY)) {
               trade.PositionClose(pos.Ticket());
            } else {
               count++;
            }
         } else {
            count++;
         }
      }
   }

   if(count >= p_maxTrades) return;

   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = CalculateValidSL(price, p_stopPoints, (s == BUY ? POSITION_TYPE_BUY : POSITION_TYPE_SELL));
   double tp = (s == BUY) ? NS(price + p_takePoints * _Point) : NS(price - p_takePoints * _Point);
   double lot = CalculaLote(p_riskPercent);

   if(s == BUY) trade.Buy(lot, _Symbol, price, sl, tp, "MT-LiveExecutor");
   else trade.Sell(lot, _Symbol, price, sl, tp, "MT-LiveExecutor");
}

// --- Position Management ---
void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(pos.SelectByIndex(i) && pos.Symbol() == _Symbol) {
         double openPrice = pos.PriceOpen();
         double currentPrice = (pos.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double sl = pos.StopLoss();
         double profitPoints = (pos.PositionType() == POSITION_TYPE_BUY) ? (currentPrice - openPrice) / _Point : (openPrice - currentPrice) / _Point;

         if(p_breakevenPoints > 0 && profitPoints >= p_breakevenPoints) {
            double targetSL = (pos.PositionType() == POSITION_TYPE_BUY) ? NS(openPrice + p_breakevenPlus * _Point) : NS(openPrice - p_breakevenPlus * _Point);
            bool update = (pos.PositionType() == POSITION_TYPE_BUY) ? (sl < targetSL) : (sl > targetSL || sl == 0);
            if(update) {
               trade.PositionModify(pos.Ticket(), targetSL, pos.TakeProfit());
               SynchronizeClusterSL(targetSL, pos.PositionType());
            }
         }

         if(p_trailingStopPoints > 0 && profitPoints >= p_trailingStopPoints) {
            double targetSL = (pos.PositionType() == POSITION_TYPE_BUY) ? NS(currentPrice - p_trailingStopPoints * _Point) : NS(currentPrice + p_trailingStopPoints * _Point);
            bool update = (pos.PositionType() == POSITION_TYPE_BUY) ? (sl < targetSL) : (sl > targetSL || sl == 0);
            if(update) {
               trade.PositionModify(pos.Ticket(), targetSL, pos.TakeProfit());
            }
         }
      }
   }
}

void SynchronizeClusterSL(double newSL, ENUM_POSITION_TYPE type) {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(pos.SelectByIndex(i) && pos.Symbol() == _Symbol && pos.PositionType() == type) {
         if(MathAbs(pos.StopLoss() - newSL) > _Point) {
            trade.PositionModify(pos.Ticket(), newSL, pos.TakeProfit());
         }
      }
   }
}

double CalculateValidSL(double price, int points, ENUM_POSITION_TYPE type) {
   if(points <= 0) return 0;
   double brokerMin = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + dynamicSafetyPoints + 2;
   double dist = MathMax(points, brokerMin) * _Point;

   if(type == POSITION_TYPE_BUY) {
      double sl = price - dist;
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(sl > bid - brokerMin * _Point) sl = bid - brokerMin * _Point;
      return NS(sl);
   } else {
      double sl = price + dist;
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(sl < ask + brokerMin * _Point) sl = ask + brokerMin * _Point;
      return NS(sl);
   }
}

// --- Account & Performance Optimization (AIOptimizer) ---
void AIOptimizer() {
   if(!HistorySelect(0, TimeCurrent())) return;
   int total = HistoryDealsTotal();
   double profit = 0, loss = 0;
   int wins = 0, losses = 0;

   for(int i=0; i<total; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT) {
         double res = HistoryDealGetDouble(ticket, DEAL_PROFIT) + HistoryDealGetDouble(ticket, DEAL_COMMISSION) + HistoryDealGetDouble(ticket, DEAL_SWAP);
         if(res > 0) { profit += res; wins++; }
         else { loss += MathAbs(res); losses++; }
      }
   }

   double winRate = (wins + losses > 0) ? (double)wins / (wins + losses) : 0;

   if(winRate < 0.4 && p_riskPercent > 0.5) p_riskPercent -= 0.1;
   if(winRate > 0.6 && p_riskPercent < 2.0) p_riskPercent += 0.1;

   double atr[]; ArraySetAsSeries(atr, true);
   if(CopyBuffer(atrHandle, 0, 0, 1, atr) > 0) {
      if(atr[0] > 500 * _Point) dynamicSafetyPoints = (int)MathMin(100, dynamicSafetyPoints + 5);
   }
}

// --- News Veto ---
bool AguardaNoticias() {
   int handle = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(handle == INVALID_HANDLE) return false;
   string val = FileReadString(handle);
   FileClose(handle);
   return (val == "1");
}

// --- Event Handlers ---
int OnInit() {
   atrHandle = iATR(_Symbol, PERIOD_H1, 14);
   EventSetTimer(60);

   string initialPrompt = "cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 300 pontos, take de 500 pontos. Risco de 1.0 % do capital por trade. Não operar 20 min antes ou depois de notícias de alto impacto. Máximo 3 trades simultâneos. Ao atingir +300 pontos, move stop para entrada +50 pontos.";

   int fileHandle = FileOpen("MT_LiveExecutor_Prompt.txt", FILE_READ|FILE_TXT);
   if(fileHandle != INVALID_HANDLE) {
      initialPrompt = FileReadString(fileHandle);
      FileClose(fileHandle);
   }

   InterpretaPrompt(initialPrompt);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   EventKillTimer();
   IndicatorRelease(atrHandle);
   for(int i=0; i<nRules; i++) {
      if(rules[i].p1_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p1_handle);
      if(rules[i].p2_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p2_handle);
      if(rules[i].p3_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p3_handle);
   }
}

void OnTick() {
   GerenciaPosicoes();

   datetime currentBar = iTime(_Symbol, (ENUM_TIMEFRAMES)p_frequency, 0);
   if(currentBar != lastBarTime) {
      MqlDateTime dt; TimeCurrent(dt);
      if(dt.hour >= p_startHour) {
         Signal s = AvaliaTudo();
         if(s != NONE) EnviaOrdem(s);
      }
      lastBarTime = currentBar;
   }

   if(TimeCurrent() - lastSafetyDecay >= 60) {
      if(dynamicSafetyPoints > 0) dynamicSafetyPoints--;
      lastSafetyDecay = TimeCurrent();
   }
}

void OnTimer() {
   AIOptimizer();

   if(GlobalVariableGet("MT_Executor_Prompt_Update") > 0) {
      int handle = FileOpen("MT_LiveExecutor_Prompt.txt", FILE_READ|FILE_TXT);
      if(handle != INVALID_HANDLE) {
         string prompt = FileReadString(handle);
         FileClose(handle);
         InterpretaPrompt(prompt);
         GlobalVariableSet("MT_Executor_Prompt_Update", 0);
      }
   }
}

void OnTradeTransaction(const MqlTradeTransaction& trans, const MqlTradeRequest& request, const MqlTradeResult& result) {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD) {
      if(HistoryDealSelect(trans.deal)) {
         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_IN) {
            // New position entered
         }
      }
   }
}
