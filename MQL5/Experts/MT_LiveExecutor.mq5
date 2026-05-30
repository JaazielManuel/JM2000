//=========================  MT-LiveExecutor  =========================
// MQL5 Script/EA for Natural Language Strategy Execution
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// --- Defines ---
#define EA_MAGIC 123456
#define STATE_FILE "MT_LiveExecutor_State.csv"
#define LOG_FILE   "MT_LiveExecutor_Log.txt"
#define PROMPT_FILE "prompt.txt"
#define NEWS_VETO_FILE "news_veto.txt"
#define CALENDAR_FILE "calendar.txt"

// --- Enums ---
enum Signal { BUY = 1, SELL = -1, NONE = 0 };

// --- Structs ---
struct Rule {
   int      type;       // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: DailyBreak, 6: Delta, 7: Volume, 8: AMA, 9: Pattern, 10: Relative
   int      intent;     // BUY or SELL
   int      tf;         // Timeframe
   int      p1, p2, p3; // Parameters (period, etc)
   double   d1, d2;     // Parameters (thresholds, etc)
   string   s1;         // Symbol for relative force
   int      handle1;    // Indicator handle 1
   int      handle2;    // Indicator handle 2

   void Reset() {
      if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease(handle1);
      if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease(handle2);
      type = 0; intent = 0; tf = 0; p1 = 0; p2 = 0; p3 = 0; d1 = 0; d2 = 0; s1 = ""; handle1 = INVALID_HANDLE; handle2 = INVALID_HANDLE;
   }
};

// --- Globals ---
Rule     g_rules[20];
int      g_nRules = 0;
CTrade   g_trade;
CPositionInfo g_pos;
CSymbolInfo g_symbol;

// Strategy Parameters (parsed from prompt)
int      g_frequency = PERIOD_M15;
double   g_riskPercent = 1.0;
int      g_stopLoss = 300; // in points
int      g_takeProfit = 500; // in points
int      g_maxTrades = 3;
string   g_startTime = "00:00";
int      g_beStart = 0;
int      g_bePlus = 0;
int      g_trailingStop = 0;
int      g_trailingStep = 0;
int      g_newsVetoBuffer = 20; // minutes

// State Management
datetime g_lastPromptTime = 0;
datetime g_lastAI = 0;
datetime g_lastCSV = 0;

// --- Event Handlers ---

int OnInit() {
   g_trade.SetExpertMagicNumber(EA_MAGIC);
   g_symbol.Name(_Symbol);

   // Set timer for prompt monitoring and AI Optimization
   EventSetTimer(1);

   GravaLog("MT-LiveExecutor Iniciado.");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   EventKillTimer();
   for(int i=0; i<20; i++) g_rules[i].Reset();
   GravaLog("MT-LiveExecutor Encerrado.");
}

void OnTick() {
   // 1. Manage positions (Breakeven, Trailing)
   GerenciaPosicoes();

   // 2. Persist state every 5 seconds
   if(TimeCurrent() - g_lastCSV >= 5) {
      GravaCSV();
      g_lastCSV = TimeCurrent();
   }

   // 3. New bar detection for entry signals
   static datetime lastBar = 0;
   datetime currentBar = iTime(_Symbol, (ENUM_TIMEFRAMES)g_frequency, 0);
   if(currentBar == lastBar) return;
   lastBar = currentBar;

   // 4. Time and News filters
   if(!IsTimeAllowed() || AguardaNoticias()) return;

   // 5. Evaluate signals and execute
   Signal s = AvaliaTudo();
   if(s != NONE && PositionsTotal() < g_maxTrades) {
      EnviaOrdem(s);
   }
}

void OnTimer() {
   // 1. Monitor prompt file for updates
   string prompt = "";
   long lastMod = FileGetInteger(PROMPT_FILE, FILE_MODIFY_DATE, FILE_COMMON);
   if(lastMod > (long)g_lastPromptTime) {
      g_lastPromptTime = (datetime)lastMod;
      int h = FileOpen(PROMPT_FILE, FILE_READ|FILE_TXT|FILE_COMMON);
      if(h != INVALID_HANDLE) {
         prompt = FileReadString(h);
         FileClose(h);
         if(prompt != "") {
            InterpretaPrompt(prompt);
         }
      }
   }

   // 2. AI Optimizer (Hourly)
   if(TimeCurrent() - g_lastAI >= 3600) {
      AIOptimizer();
      g_lastAI = TimeCurrent();
   }
}

// --- NLP Parser ---

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   string work = prompt;
   StringToLower(work);
   StringReplace(work, " e ", ".");

   // Global parameters extraction
   int cursor = 0;
   if(StringFind(work, "stop de") >= 0) {
      cursor = StringFind(work, "stop de") + 7;
      g_stopLoss = (int)ExtraiNumero(work, cursor);
   }
   if(StringFind(work, "take de") >= 0) {
      cursor = StringFind(work, "take de") + 7;
      g_takeProfit = (int)ExtraiNumero(work, cursor);
   }
   if(StringFind(work, "risco de") >= 0) {
      cursor = StringFind(work, "risco de") + 8;
      g_riskPercent = ExtraiNumero(work, cursor);
   }
   if(StringFind(work, "máximo") >= 0) {
      cursor = StringFind(work, "máximo") + 6;
      g_maxTrades = (int)ExtraiNumero(work, cursor);
   }
   if(StringFind(work, "notícias") >= 0) {
      cursor = StringFind(work, "notícias") - 3;
      if(cursor < 0) cursor = 0;
      g_newsVetoBuffer = (int)ExtraiNumero(work, cursor);
   }

   // Timeframe detection
   g_frequency = PeriodoTexto(work);

   // Start time
   if(StringFind(work, "depois das") >= 0 || StringFind(work, "início") >= 0 || StringFind(work, "começar") >= 0) {
      int pos = StringFind(work, "depois das");
      if(pos < 0) pos = StringFind(work, "início");
      if(pos < 0) pos = StringFind(work, "começar");

      // Heuristic for HH:MM or HHh
      int h_pos = StringFind(work, "h", pos);
      if(h_pos > 0 && h_pos < pos + 20) {
         int hh = (int)StringToInteger(StringSubstr(work, h_pos-2, 2));
         g_startTime = StringFormat("%02d:00", hh);
      }
   }

   // Breakeven and Trailing
   if(StringFind(work, "atingir") >= 0) {
      cursor = StringFind(work, "atingir") + 7;
      g_beStart = (int)ExtraiNumero(work, cursor);
      if(StringFind(work, "entrada", cursor) >= 0) {
         cursor = StringFind(work, "entrada", cursor) + 7;
         g_bePlus = (int)ExtraiNumero(work, cursor);
      }
   }
   if(StringFind(work, "trailing") >= 0) {
      cursor = StringFind(work, "trailing") + 8;
      g_trailingStop = (int)ExtraiNumero(work, cursor);
      g_trailingStep = (int)ExtraiNumero(work, cursor);
   }

   // Split logic into segments
   string segments[];
   ushort sep = StringGetCharacter(".", 0);
   int nSegments = StringSplit(work, sep, segments);

   int currentIntent = (int)NONE;
   for(int i=0; i<nSegments; i++) {
      string seg = segments[i];
      StringTrimLeft(seg);
      StringTrimRight(seg);
      if(seg == "") continue;

      if(StringFind(seg, "compra") >= 0) currentIntent = (int)BUY;
      else if(StringFind(seg, "vende") >= 0) currentIntent = (int)SELL;

      if(currentIntent != (int)NONE) {
         AddRule(seg, currentIntent);
      }
   }

   GravaLog("Estratégia interpretada: " + prompt);
}

void AddRule(string txt, int intent) {
   if(g_nRules >= 20) return;

   bool added = false;
   int cursor = 0;

   // 1. Moving Average
   if(StringFind(txt, "média") >= 0) {
      cursor = StringFind(txt, "média") + 5;
      int period = (int)ExtraiNumero(txt, cursor);
      if(period == 0) period = 20;

      g_rules[g_nRules].type = 1;
      g_rules[g_nRules].intent = intent;
      g_rules[g_nRules].tf = PeriodoTexto(txt);
      g_rules[g_nRules].p1 = period;
      g_rules[g_nRules].handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)g_rules[g_nRules].tf, period, 0, MODE_SMA, PRICE_CLOSE);

      if(g_rules[g_nRules].handle1 != INVALID_HANDLE) {
         g_nRules++;
         added = true;
      }
   }

   // 2. RSI
   if(StringFind(txt, "rsi") >= 0) {
      cursor = StringFind(txt, "rsi") + 3;
      double n1 = ExtraiNumero(txt, cursor);
      double n2 = ExtraiNumero(txt, cursor);

      int period = 14;
      double threshold = 50;

      if(n2 != 0) { period = (int)n1; threshold = n2; }
      else if(n1 >= 40) { threshold = n1; }
      else if(n1 > 0) { period = (int)n1; }

      g_rules[g_nRules].type = 2;
      g_rules[g_nRules].intent = intent;
      g_rules[g_nRules].tf = PeriodoTexto(txt);
      g_rules[g_nRules].p1 = period;
      g_rules[g_nRules].d1 = threshold;
      g_rules[g_nRules].handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)g_rules[g_nRules].tf, period, PRICE_CLOSE);

      if(g_rules[g_nRules].handle1 != INVALID_HANDLE) {
         g_nRules++;
         added = true;
      }
   }

   // 3. Stochastic
   if(StringFind(txt, "estocástico") >= 0 || StringFind(txt, "stoch") >= 0) {
      g_rules[g_nRules].type = 3;
      g_rules[g_nRules].intent = intent;
      g_rules[g_nRules].tf = PeriodoTexto(txt);
      g_rules[g_nRules].handle1 = iStochastic(_Symbol, (ENUM_TIMEFRAMES)g_rules[g_nRules].tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
      if(g_rules[g_nRules].handle1 != INVALID_HANDLE) {
         g_nRules++;
         added = true;
      }
   }

   // 4. Bollinger Bands
   if(StringFind(txt, "bollinger") >= 0 || StringFind(txt, "bandas") >= 0) {
      g_rules[g_nRules].type = 4;
      g_rules[g_nRules].intent = intent;
      g_rules[g_nRules].tf = PeriodoTexto(txt);
      g_rules[g_nRules].handle1 = iBands(_Symbol, (ENUM_TIMEFRAMES)g_rules[g_nRules].tf, 20, 0, 2.0, PRICE_CLOSE);
      if(g_rules[g_nRules].handle1 != INVALID_HANDLE) {
         g_nRules++;
         added = true;
      }
   }

   // 10. Relative Force
   if(StringFind(txt, "força relativa") >= 0 || StringFind(txt, "comparado") >= 0) {
      g_rules[g_nRules].type = 10;
      g_rules[g_nRules].intent = intent;
      g_rules[g_nRules].tf = PeriodoTexto(txt);
      g_rules[g_nRules].s1 = "US30"; // Default benchmark
      g_rules[g_nRules].handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)g_rules[g_nRules].tf, 14, PRICE_CLOSE);
      g_rules[g_nRules].handle2 = iRSI(g_rules[g_nRules].s1, (ENUM_TIMEFRAMES)g_rules[g_nRules].tf, 14, PRICE_CLOSE);
      if(g_rules[g_nRules].handle1 != INVALID_HANDLE && g_rules[g_nRules].handle2 != INVALID_HANDLE) {
         g_nRules++;
         added = true;
      }
   }
}

double ExtraiNumero(string txt, int &cursor) {
   string res = "";
   bool found = false;
   for(int i = cursor; i < StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.' || c == ',') {
         if(c == ',') c = '.';
         res += ShortToString(c);
         found = true;
      } else if(found) {
         cursor = i;
         break;
      }
   }
   return StringToDouble(res);
}

int PeriodoTexto(string txt) {
   if(StringFind(txt, "m15") >= 0) return PERIOD_M15;
   if(StringFind(txt, "m1") >= 0 && StringFind(txt, "m15") < 0)  return PERIOD_M1;
   if(StringFind(txt, "m5") >= 0 && StringFind(txt, "m15") < 0)  return PERIOD_M5;
   if(StringFind(txt, "h1") >= 0)  return PERIOD_H1;
   if(StringFind(txt, "d1") >= 0)  return PERIOD_D1;
   return g_frequency;
}

void ResetStrategy() {
   for(int i=0; i<20; i++) g_rules[i].Reset();
   g_nRules = 0;
}

// --- Signal Evaluation ---

Signal AvaliaTudo() {
   int buyCount = 0;
   int sellCount = 0;
   int buyRules = 0;
   int sellRules = 0;

   for(int i=0; i<g_nRules; i++) {
      Signal s = AvaliaRegra(g_rules[i]);
      if(g_rules[i].intent == BUY) {
         buyRules++;
         if(s == BUY) buyCount++;
      } else if(g_rules[i].intent == SELL) {
         sellRules++;
         if(s == SELL) sellCount++;
      }
   }

   if(buyRules > 0 && buyCount == buyRules) return BUY;
   if(sellRules > 0 && sellCount == sellRules) return SELL;

   return NONE;
}

Signal AvaliaRegra(Rule &r) {
   double b1 = GetBufferValue(r.handle1, 0, 1);
   double b2 = GetBufferValue(r.handle1, 0, 2);

   switch(r.type) {
      case 1: // Moving Average
      {
         double close1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         double close2 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
         if(r.intent == BUY && close2 < b2 && close1 > b1) return BUY;
         if(r.intent == SELL && close2 > b2 && close1 < b1) return SELL;
         break;
      }
      case 2: // RSI
      {
         if(r.intent == BUY && b2 < r.d1 && b1 > r.d1) return BUY;
         if(r.intent == SELL && b2 > r.d1 && b1 < r.d1) return SELL;
         break;
      }
      case 3: // Stochastic
      {
         double d1 = GetBufferValue(r.handle1, 1, 1);
         double d2 = GetBufferValue(r.handle1, 1, 2);
         if(r.intent == BUY && b2 < d2 && b1 > d1) return BUY;
         if(r.intent == SELL && b2 > d2 && b1 < d1) return SELL;
         break;
      }
      case 4: // Bollinger Bands
      {
         double upper = GetBufferValue(r.handle1, 1, 1);
         double lower = GetBufferValue(r.handle1, 2, 1);
         double close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         if(r.intent == BUY && close < lower) return BUY;
         if(r.intent == SELL && close > upper) return SELL;
         break;
      }
      case 10: // Relative Force
      {
         double bench_rsi = GetBufferValue(r.handle2, 0, 1);
         if(r.intent == BUY && b1 > bench_rsi + 5) return BUY;
         if(r.intent == SELL && b1 < bench_rsi - 5) return SELL;
         break;
      }
   }
   return NONE;
}

double GetBufferValue(int handle, int buffer, int shift) {
   double arr[];
   ArraySetAsSeries(arr, true);
   if(CopyBuffer(handle, buffer, shift, 1, arr) > 0) return arr[0];
   return 0;
}

// --- Trade Execution ---

void EnviaOrdem(Signal s) {
   double lote = CalculaLote();
   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0, tp = 0;

   if(s == BUY) {
      if(g_stopLoss > 0) sl = price - g_stopLoss * _Point;
      if(g_takeProfit > 0) tp = price + g_takeProfit * _Point;
   } else {
      if(g_stopLoss > 0) sl = price + g_stopLoss * _Point;
      if(g_takeProfit > 0) tp = price - g_takeProfit * _Point;
   }

   // Normalize SL/TP
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   // Margin check
   double margin;
   if(!OrderCalcMargin((s == BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL), _Symbol, lote, price, margin)) {
      GravaLog("Erro ao calcular margem.");
      return;
   }
   if(margin > AccountInfoDouble(ACCOUNT_FREEMARGIN)) {
      GravaLog(StringFormat("Margem insuficiente. Necessário: %.2f, Disponível: %.2f", margin, AccountInfoDouble(ACCOUNT_FREEMARGIN)));
      return;
   }

   // Retry loop for execution
   for(int i=0; i<3; i++) {
      bool res = (s == BUY) ? g_trade.Buy(lote, _Symbol, price, sl, tp) : g_trade.Sell(lote, _Symbol, price, sl, tp);
      if(res) {
         uint ret = g_trade.ResultRetcode();
         if(ret == TRADE_RETCODE_DONE || ret == TRADE_RETCODE_PLACED) {
            string msg = StringFormat("%s executado: Lote %.2f, SL %d, TP %d", (s == BUY ? "COMPRA" : "VENDA"), lote, g_stopLoss, g_takeProfit);
            GravaLog(msg);
            SendNotification(msg);
            SendMail("MT-LiveExecutor Alerta", msg);
            break;
         } else if(ret == TRADE_RETCODE_REQUOTES || ret == TRADE_RETCODE_OFFQUOTES) {
            price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
            Sleep(100);
            continue;
         }
      }
      GravaLog("Erro na execução: " + g_trade.ResultComment());
      break;
   }
}

double CalculaLote() {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = equity * g_riskPercent / 100.0;
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(g_stopLoss <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double pointsInMoney = (g_stopLoss * _Point) / tickSize * tickVal;
   double volume = riskAmount / pointsInMoney;

   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   volume = MathFloor(volume / stepVol) * stepVol;
   if(volume < minVol) volume = minVol;
   if(volume > maxVol) volume = maxVol;

   return NormalizeDouble(volume, 2);
}
// --- Position Management ---

void GerenciaPosicoes() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(g_pos.SelectByIndex(i)) {
         if(g_pos.Magic() != EA_MAGIC || g_pos.Symbol() != _Symbol) continue;

         double currentPrice = (g_pos.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double openPrice = g_pos.PriceOpen();
         double currentSL = g_pos.StopLoss();

         // 1. Breakeven
         if(g_beStart > 0) {
            double profitPoints = (g_pos.PositionType() == POSITION_TYPE_BUY) ? (currentPrice - openPrice) / _Point : (openPrice - currentPrice) / _Point;
            if(profitPoints >= g_beStart) {
               double newSL = (g_pos.PositionType() == POSITION_TYPE_BUY) ? openPrice + g_bePlus * _Point : openPrice - g_bePlus * _Point;
               newSL = NormalizeDouble(newSL, _Digits);

               if((g_pos.PositionType() == POSITION_TYPE_BUY && (currentSL < newSL || currentSL == 0)) ||
                  (g_pos.PositionType() == POSITION_TYPE_SELL && (currentSL > newSL || currentSL == 0))) {
                  g_trade.PositionModify(g_pos.Ticket(), newSL, g_pos.TakeProfit());
                  GravaLog(StringFormat("Breakeven acionado para ticket %d", g_pos.Ticket()));
               }
            }
         }

         // 2. Trailing Stop
         if(g_trailingStop > 0) {
            double profitPoints = (g_pos.PositionType() == POSITION_TYPE_BUY) ? (currentPrice - openPrice) / _Point : (openPrice - currentPrice) / _Point;
            if(profitPoints >= g_trailingStop) {
               double newSL = (g_pos.PositionType() == POSITION_TYPE_BUY) ? currentPrice - g_trailingStop * _Point : currentPrice + g_trailingStop * _Point;
               newSL = NormalizeDouble(newSL, _Digits);

               if((g_pos.PositionType() == POSITION_TYPE_BUY && newSL > currentSL + g_trailingStep * _Point) ||
                  (g_pos.PositionType() == POSITION_TYPE_SELL && (newSL < currentSL - g_trailingStep * _Point || currentSL == 0))) {
                  g_trade.PositionModify(g_pos.Ticket(), newSL, g_pos.TakeProfit());
                  GravaLog(StringFormat("Trailing Stop ajustado para ticket %d", g_pos.Ticket()));
               }
            }
         }
      }
   }
}

// --- Utilities ---

bool IsTimeAllowed() {
   MqlDateTime now;
   TimeCurrent(now);
   string currentTime = StringFormat("%02d:%02d", now.hour, now.min);
   if(currentTime < g_startTime) return false;
   return true;
}

bool AguardaNoticias() {
   // 1. Binary veto from file
   int h = FileOpen(NEWS_VETO_FILE, FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      string val = FileReadString(h);
      FileClose(h);
      if(val == "1") return true;
   }

   // 2. Calendar scan for high-impact
   h = FileOpen(CALENDAR_FILE, FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      while(!FileIsEnding(h)) {
         string line = FileReadString(h);
         if(StringFind(line, "high-impact") >= 0) {
            // Very simplified: check if current time is near
            // In a real scenario, we would parse the time from the line.
            // For now, let's assume if it's there and recent, we veto.
            // (Mocking logic as per requirements)
         }
      }
      FileClose(h);
   }
   return false;
}

void GravaCSV() {
   int h = FileOpen(STATE_FILE, FILE_WRITE|FILE_CSV|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      FileWrite(h, "Ticket", "Symbol", "Type", "OpenPrice", "SL", "TP", "Profit");
      for(int i = 0; i < PositionsTotal(); i++) {
         if(g_pos.SelectByIndex(i)) {
            if(g_pos.Magic() == EA_MAGIC) {
               FileWrite(h, g_pos.Ticket(), g_pos.Symbol(), g_pos.PositionType(), g_pos.PriceOpen(), g_pos.StopLoss(), g_pos.TakeProfit(), g_pos.Profit());
            }
         }
      }
      FileClose(h);
   }
}

void GravaLog(string txt) {
   Print(txt);
   int h = FileOpen(LOG_FILE, FILE_READ|FILE_WRITE|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      FileSeek(h, 0, SEEK_END);
      FileWriteString(h, TimeToString(TimeCurrent()) + ": " + txt + "\r\n");
      FileClose(h);
   }
}

void AIOptimizer() {
   // Analyze win rate of last 10 deals
   if(!HistorySelect(TimeCurrent() - 86400 * 7, TimeCurrent())) return;

   int total = 0;
   int wins = 0;
   int count = HistoryDealsTotal();

   for(int i = count - 1; i >= 0 && total < 10; i--) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
         if(HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT) {
            total++;
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) > 0) wins++;
         }
      }
   }

   if(total >= 5) {
      double winRate = (double)wins / total;
      if(winRate < 0.4) {
         g_riskPercent *= 0.8; // Reduce risk
         GravaLog(StringFormat("AI Optimizer: Win rate baixo (%.2f). Risco reduzido para %.2f%%", winRate, g_riskPercent));
      }
   }
}

void CalculaStats() {
   // Implementation for monitoring strategy performance
   if(!HistorySelect(0, TimeCurrent())) return;
   double profit = 0;
   int wins = 0, losses = 0;
   int count = HistoryDealsTotal();
   for(int i=0; i<count; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
         double p = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         profit += p;
         if(p > 0) wins++; else if(p < 0) losses++;
      }
   }
   GravaLog(StringFormat("Stats: Lucro Total: %.2f, Wins: %d, Losses: %d", profit, wins, losses));
}
