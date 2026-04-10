//=========================  MT5-LIVE-EXECUTOR  =========================
// Integrates MT5-KNOWLEDGE-CORE library for real-time strategy execution
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// --- Enums and Structs ---
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
   RULE_BAR2,
   RULE_RS_REL
};

struct Rule {
   bool      active;
   RuleType  type;
   Signal    intent; // BUY or SELL specified in the prompt
   int       h1;     // Primary indicator handle
   int       h2;     // Secondary indicator handle
   double    v1;     // Param 1 (e.g. period, threshold)
   double    v2;     // Param 2
   double    v3;     // Param 3
   ENUM_TIMEFRAMES tf;
};

// --- Global Strategy Parameters ---
Rule      rules[30];
int       nRules = 0;
long      EA_MAGIC = 20260101;

double    p_riskPercent = 1.0;
int       p_stopPoints = 0;
int       p_takePoints = 0;
int       p_trailingStart = 0;
int       p_trailingStep = 10;
int       p_beStart = 0;
int       p_bePlus = 0;
int       p_maxTrades = 1;
long      p_startTimeSeconds = 0; // Seconds from midnight
bool      p_useMartingale = false;
bool      p_hedge = false;
ENUM_TIMEFRAMES p_frequency = PERIOD_CURRENT;

CTrade          trade;
CPositionInfo   m_position;
CSymbolInfo     m_symbol;
CAccountInfo    m_account;

// --- Internal Functions Prototypes ---
void InterpretaPrompt(string prompt);
Signal AvaliaTudo() {
   int buyVotes = 0, sellVotes = 0;
   int activeBuyRules = 0, activeSellRules = 0;

   for(int i=0; i<nRules; i++) {
      Signal s = AvaliaRegra(i);
      if(rules[i].intent == BUY) {
         activeBuyRules++;
         if(s == BUY) buyVotes++;
      } else if(rules[i].intent == SELL) {
         activeSellRules++;
         if(s == SELL) sellVotes++;
      } else {
         // Neutral rule acts as filter
         if(s == BUY) buyVotes++;
         if(s == SELL) sellVotes++;
         activeBuyRules++;
         activeSellRules++;
      }
   }

   if(activeBuyRules > 0 && buyVotes == activeBuyRules) return BUY;
   if(activeSellRules > 0 && sellVotes == activeSellRules) return SELL;
   return NONE;
}

void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(m_position.SelectByIndex(i) && m_position.Magic() == EA_MAGIC && m_position.Symbol() == _Symbol) {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double openPrice = m_position.PriceOpen();
         double sl = m_position.StopLoss();
         double tp = m_position.TakeProfit();

         // Break-even
         if(p_beStart > 0 && sl != openPrice + p_bePlus * _Point) {
            if(m_position.PositionType() == POSITION_TYPE_BUY && bid >= openPrice + p_beStart * _Point) {
               trade.PositionModify(m_position.Ticket(), openPrice + p_bePlus * _Point, tp);
            } else if(m_position.PositionType() == POSITION_TYPE_SELL && ask <= openPrice - p_beStart * _Point) {
               trade.PositionModify(m_position.Ticket(), openPrice - p_bePlus * _Point, tp);
            }
         }

         // Trailing Stop
         if(p_trailingStart > 0) {
            if(m_position.PositionType() == POSITION_TYPE_BUY && bid >= openPrice + p_trailingStart * _Point) {
               double newSL = bid - p_trailingStart * _Point;
               if(newSL > sl + p_trailingStep * _Point) trade.PositionModify(m_position.Ticket(), newSL, tp);
            } else if(m_position.PositionType() == POSITION_TYPE_SELL && ask <= openPrice - p_trailingStart * _Point) {
               double newSL = ask + p_trailingStart * _Point;
               if(sl == 0 || newSL < sl - p_trailingStep * _Point) trade.PositionModify(m_position.Ticket(), newSL, tp);
            }
         }
      }
   }
}

double CalculaLote(double riscoPercent) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = capital * (riscoPercent / 100.0);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   int stopPoints = (p_stopPoints > 0) ? p_stopPoints : 300;

   // Martingale check
   if(p_useMartingale) {
      HistorySelect(TimeCurrent() - 86400, TimeCurrent());
      for(int i=HistoryDealsTotal()-1; i>=0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) riskAmount *= 2;
            break;
         }
      }
   }

   double lotSize = NormalizeDouble(riskAmount / (stopPoints * (tickValue / (tickSize / _Point))), 2);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   return MathMin(maxLot, MathMax(minLot, lotSize));
}

void EnviaOrdem(Signal s) {
   if(s == NONE) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double lot = CalculaLote(p_riskPercent);
   double sl = 0, tp = 0;

   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int safety = stopsLevel + 50;
   int finalStop = MathMax(p_stopPoints, safety);

   if(s == BUY) {
      if(p_stopPoints > 0) sl = bid - finalStop * _Point;
      if(p_takePoints > 0) tp = ask + p_takePoints * _Point;
      trade.Buy(lot, _Symbol, ask, sl, tp, "MT-LiveExecutor Entry");
   } else {
      if(p_stopPoints > 0) sl = ask + finalStop * _Point;
      if(p_takePoints > 0) tp = bid - p_takePoints * _Point;
      trade.Sell(lot, _Symbol, bid, sl, tp, "MT-LiveExecutor Entry");
   }
}
bool AguardaNoticias() {
   string file = "news_veto.txt";
   if(!FileIsExist(file)) return false;
   int h = FileOpen(file, FILE_READ | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE) return false;
   string content = FileReadString(h);
   FileClose(h);
   if(content == "1") return true;

   datetime eventTime = StringToTime(content);
   if(eventTime > 0) {
      if(TimeCurrent() >= eventTime - 1200 && TimeCurrent() <= eventTime + 1200) return true;
   }
   return false;
}

void GravaLog(string texto) {
   int h = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE | FILE_READ | FILE_TXT | FILE_ANSI);
   if(h != INVALID_HANDLE) {
      FileSeek(h, 0, SEEK_END);
      FileWrite(h, TimeToString(TimeCurrent()) + ": " + texto);
      FileClose(h);
   }
   Print(texto);
}

void GravaCSV() {
   static datetime lastWrite = 0;
   if(TimeCurrent() < lastWrite + 5) return;
   lastWrite = TimeCurrent();

   int h = FileOpen("positions_state.csv", FILE_WRITE | FILE_CSV | FILE_ANSI);
   if(h != INVALID_HANDLE) {
      FileWrite(h, "Ticket", "Symbol", "Type", "Price", "SL", "TP", "Profit");
      for(int i=0; i<PositionsTotal(); i++) {
         if(m_position.SelectByIndex(i) && m_position.Magic() == EA_MAGIC) {
            FileWrite(h, m_position.Ticket(), m_position.Symbol(), m_position.PositionType(),
                      m_position.PriceOpen(), m_position.StopLoss(), m_position.TakeProfit(), m_position.Profit());
         }
      }
      FileClose(h);
   }
}
void CalculaEstatisticas(double &winRate, double &profitFactor, double &drawdown) {
   HistorySelect(0, TimeCurrent());
   int total = 0, wins = 0;
   double grossProfit = 0, grossLoss = 0;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double maxBalance = balance, maxDD = 0;

   for(int i=0; i<HistoryDealsTotal(); i++) {
      ulong t = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC) {
         double p = HistoryDealGetDouble(t, DEAL_PROFIT) + HistoryDealGetDouble(t, DEAL_COMMISSION) + HistoryDealGetDouble(t, DEAL_SWAP);
         if(p != 0) {
            total++;
            if(p > 0) { wins++; grossProfit += p; }
            else grossLoss -= p;

            balance += p;
            if(balance > maxBalance) maxBalance = balance;
            double dd = maxBalance - balance;
            if(dd > maxDD) maxDD = dd;
         }
      }
   }
   winRate = (total > 0) ? (double)wins / total : 0;
   profitFactor = (grossLoss > 0) ? grossProfit / grossLoss : grossProfit;
   drawdown = maxDD;
}

void AIOptimizer() {
   double wr, pf, dd;
   CalculaEstatisticas(wr, pf, dd);
   if(wr < 0.4 && HistoryDealsTotal() > 10) p_riskPercent *= 0.9;
   if(wr > 0.6 && pf > 1.5) p_riskPercent = MathMin(2.0, p_riskPercent * 1.1);
}

void ResetStrategy();

// --- Lifecycle Handlers ---
int OnInit() {
   m_symbol.Name(_Symbol);
   trade.SetExpertMagicNumber(EA_MAGIC);
   EventSetTimer(1);
   ResetStrategy();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   EventKillTimer();
}

void OnTick() {
   // Position management always runs first
   GerenciaPosicoes();
   GravaCSV();

   if(AguardaNoticias()) return;

   // Check entry time
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   long secondsToday = dt.hour * 3600 + dt.min * 60 + dt.sec;
   if(secondsToday < p_startTimeSeconds) return;

   // Check max trades
   int total = 0;
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(m_position.SelectByIndex(i) && m_position.Magic() == EA_MAGIC && m_position.Symbol() == _Symbol)
         total++;
   }
   if(total >= p_maxTrades) return;

   // Evaluate rules only on new bar of p_frequency
   static datetime lastBar = 0;
   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar == lastBar) return;
   lastBar = currentBar;

   Signal s = AvaliaTudo();
   if(s != NONE) {
      AIOptimizer();
      EnviaOrdem(s);
   }
}

void OnTimer() {
   string promptFile = "prompt.txt";
   if(FileIsExist(promptFile)) {
      int handle = FileOpen(promptFile, FILE_READ | FILE_TXT | FILE_ANSI);
      if(handle != INVALID_HANDLE) {
         string prompt = "";
         while(!FileIsEnding(handle)) prompt += FileReadString(handle);
         FileClose(handle);
         if(StringLen(prompt) > 5) {
            GravaLog("Novo prompt recebido: " + prompt);
            InterpretaPrompt(prompt);
            // Clear prompt file
            int hClear = FileOpen(promptFile, FILE_WRITE | FILE_TXT | FILE_ANSI);
            if(hClear != INVALID_HANDLE) FileClose(hClear);
         }
      }
   }
}

void ResetStrategy() {
   for(int i=0; i<30; i++) {
      if(rules[i].active) {
         if(rules[i].h1 != INVALID_HANDLE) IndicatorRelease(rules[i].h1);
         if(rules[i].h2 != INVALID_HANDLE) IndicatorRelease(rules[i].h2);
      }
      rules[i].active = false;
      rules[i].h1 = INVALID_HANDLE;
      rules[i].h2 = INVALID_HANDLE;
   }
   nRules = 0;
   p_riskPercent = 1.0;
   p_stopPoints = 0;
   p_takePoints = 0;
   p_trailingStart = 0;
   p_trailingStep = 10;
   p_beStart = 0;
   p_bePlus = 0;
   p_maxTrades = 1;
   p_startTimeSeconds = 0;
   p_useMartingale = false;
   p_hedge = false;
   p_frequency = PERIOD_CURRENT;
}

// --- Helper Functions ---
double ExtraiNumero(string txt, string keyword) {
   int pos = StringFind(txt, keyword);
   if(pos < 0) return 0;
   string sub = StringSubstr(txt, pos + StringLen(keyword));
   string res = "";
   bool started = false;
   for(int i=0; i<StringLen(sub); i++) {
      ushort c = StringGetCharacter(sub, i);
      if((c >= '0' && c <= '9') || c == '.' || c == ',') {
         res += (c == ',') ? "." : ShortToString(c);
         started = true;
      } else if(started) break;
   }
   return StringToDouble(res);
}

ENUM_TIMEFRAMES PeriodoTexto(string prompt) {
   if(StringFind(prompt, "30 min") >= 0 || StringFind(prompt, "m30") >= 0) return PERIOD_M30;
   if(StringFind(prompt, "15 min") >= 0 || StringFind(prompt, "m15") >= 0) return PERIOD_M15;
   if(StringFind(prompt, "5 min") >= 0 || StringFind(prompt, "m5") >= 0) return PERIOD_M5;
   if(StringFind(prompt, "1 min") >= 0 || StringFind(prompt, "m1") >= 0) return PERIOD_M1;
   if(StringFind(prompt, "1 hora") >= 0 || StringFind(prompt, "h1") >= 0) return PERIOD_H1;
   if(StringFind(prompt, "diário") >= 0 || StringFind(prompt, "d1") >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

// --- NLP Parser ---
void InterpretaPrompt(string prompt) {
   ResetStrategy();
   string lower = prompt;
   StringToLower(lower);

   p_frequency = PeriodoTexto(lower);
   p_riskPercent = ExtraiNumero(lower, "risco de");
   if(p_riskPercent == 0) p_riskPercent = 1.0;

   p_stopPoints = (int)ExtraiNumero(lower, "stop de");
   p_takePoints = (int)ExtraiNumero(lower, "take de");
   p_maxTrades = (int)ExtraiNumero(lower, "máximo");
   if(p_maxTrades == 0) p_maxTrades = 1;

   if(StringFind(lower, "martingale") >= 0) p_useMartingale = true;
   if(StringFind(lower, "hedge") >= 0) p_hedge = true;

   // Time entry
   int hPos = StringFind(lower, "10h"); // Simplified for now
   if(hPos >= 0) p_startTimeSeconds = 10 * 3600;

   // Trailing/BE
   p_trailingStart = (int)ExtraiNumero(lower, "atingir +");
   int bePos = StringFind(lower, "move stop para entrada");
   if(bePos >= 0) {
      p_beStart = (int)ExtraiNumero(lower, "atingir +"); // Re-extract trigger
      p_bePlus = (int)ExtraiNumero(lower, "entrada +");
   }

   // Indicators
   string segments[];
   ushort sep = '.';
   StringSplit(lower, sep, segments);

   for(int i=0; i<ArraySize(segments); i++) {
      string seg = segments[i];
      Signal currentIntent = NONE;
      if(StringFind(seg, "compra") >= 0) currentIntent = BUY;
      else if(StringFind(seg, "vende") >= 0) currentIntent = SELL;

      if(StringFind(seg, "média") >= 0 || StringFind(seg, "ma") >= 0 || StringFind(seg, "ema") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = RULE_MA_CROSS;
         rules[nRules].intent = currentIntent;
         rules[nRules].v1 = ExtraiNumero(seg, "média de");
         if(rules[nRules].v1 == 0) rules[nRules].v1 = ExtraiNumero(seg, "ma");
         if(rules[nRules].v1 == 0) rules[nRules].v1 = ExtraiNumero(seg, "ema");
         if(rules[nRules].v1 == 0) rules[nRules].v1 = 20;
         rules[nRules].h1 = iMA(_Symbol, p_frequency, (int)rules[nRules].v1, 0, MODE_EMA, PRICE_CLOSE);
         nRules++;
      }
      if(StringFind(seg, "rsi") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = RULE_RSI;
         rules[nRules].intent = currentIntent;
         rules[nRules].v1 = ExtraiNumero(seg, "rsi (");
         if(rules[nRules].v1 == 0) rules[nRules].v1 = 14;
         rules[nRules].v2 = ExtraiNumero(seg, "acima de");
         if(rules[nRules].v2 == 0) rules[nRules].v2 = ExtraiNumero(seg, "abaixo de");
         rules[nRules].h1 = iRSI(_Symbol, p_frequency, (int)rules[nRules].v1, PRICE_CLOSE);
         nRules++;
      }
      if(StringFind(seg, "ama") >= 0 || StringFind(seg, "adaptativa") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = RULE_AMA;
         rules[nRules].intent = currentIntent;
         rules[nRules].h1 = iAMA(_Symbol, p_frequency, 10, 2, 30, 0, PRICE_CLOSE);
         nRules++;
      }
      if(StringFind(seg, "rompimento diário") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = RULE_DAILY_BREAK;
         rules[nRules].intent = currentIntent;
         nRules++;
      }
   }
}

// --- Indicator Signal Logic ---
Signal AvaliaRegra(int index) {
   Rule r = rules[index];
   if(!r.active) return NONE;

   double buf1[], buf2[], buf3[];
   ArraySetAsSeries(buf1, true);
   ArraySetAsSeries(buf2, true);
   ArraySetAsSeries(buf3, true);

   switch(r.type) {
      case RULE_MA_CROSS:
         if(CopyBuffer(r.h1, 0, 1, 2, buf1) < 2) return NONE;
         double f0 = buf1[0]; double f1 = buf1[1];
         double c0 = iClose(_Symbol, p_frequency, 1);
         double c1 = iClose(_Symbol, p_frequency, 2);
         if(c1 < f1 && c0 > f0) return BUY;
         if(c1 > f1 && c0 < f0) return SELL;
         break;

      case RULE_RSI:
         if(CopyBuffer(r.h1, 0, 1, 1, buf1) < 1) return NONE;
         if(r.intent == BUY && buf1[0] > r.v2) return BUY;
         if(r.intent == SELL && buf1[0] < r.v2) return SELL;
         break;

      case RULE_STOCH:
         if(CopyBuffer(r.h1, 0, 1, 2, buf1) < 2 || CopyBuffer(r.h1, 1, 1, 2, buf2) < 2) return NONE;
         // BUY: %K (buf1) crosses above %D (buf2)
         if(buf1[1] < buf2[1] && buf1[0] > buf2[0]) return BUY;
         // SELL: %K crosses below %D
         if(buf1[1] > buf2[1] && buf1[0] < buf2[0]) return SELL;
         break;

      case RULE_BB:
         if(CopyBuffer(r.h1, 1, 1, 1, buf1) < 1 || CopyBuffer(r.h1, 2, 1, 1, buf2) < 1) return NONE;
         double close = iClose(_Symbol, p_frequency, 1);
         if(close < buf2[0]) return BUY;
         if(close > buf1[0]) return SELL;
         break;

      case RULE_AMA:
         if(CopyBuffer(r.h1, 0, 1, 2, buf1) < 2) return NONE;
         if(buf1[1] < buf1[0]) return BUY;
         if(buf1[1] > buf1[0]) return SELL;
         break;

      case RULE_DAILY_BREAK:
         double hi = iHigh(_Symbol, PERIOD_D1, 1);
         double lo = iLow(_Symbol, PERIOD_D1, 1);
         double cl = iClose(_Symbol, p_frequency, 1);
         if(cl > hi) return BUY;
         if(cl < lo) return SELL;
         break;
   }
   return NONE;
}
