//=========================  MT_LiveExecutor.mq5  =========================
// MT-LiveExecutor: Advanced NLP Trading Engine for MetaTrader 5
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// --- Enums ---
enum Signal { BUY=1, SELL=-1, NONE=0 };

// --- Structs ---
struct Rule {
   int      type;       // 1:MA, 2:RSI, 3:Stoch, 4:BB, 5:DailyBreak, 6:Delta, 7:Vol, 8:AMA, 9:Bar2, 10:RS, 11:AI
   bool     active;
   ENUM_TIMEFRAMES tf;
   int      p1, p2, p3;
   double   d1, d2;
   string   s1;
   int      intent;     // BUY, SELL or NONE (for filters)
   int      handle1, handle2;

   void Reset() {
      active = false;
      type = 0;
      tf = PERIOD_CURRENT;
      p1=p2=p3=0;
      d1=d2=0;
      s1="";
      intent = NONE;
      if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease(handle1);
      if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease(handle2);
      handle1 = handle2 = INVALID_HANDLE;
   }
};

// --- Global Constants & Variables ---
const int EA_MAGIC = 123456;
Rule rules[20];
int nRules = 0;

// Strategy Parameters (parsed from prompt)
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
int      p_maxTrades = 3;
string   p_startTime = "00:00";
double   p_riskPercent = 1.0;
int      p_stopPoints = 300;
int      p_takePoints = 500;
int      p_beStart = 0;
int      p_bePlus = 0;
int      p_trailingStart = 0;
int      p_trailingStep = 10;
bool     p_martingale = false;

// State Variables
datetime last_bar_time = 0;
CTrade trade;

// --- Forward Declarations ---
void InterpretaPrompt(string prompt);
Signal AvaliaTudo();
void GerenciaPosicoes();
void GravaCSV();
void GravaLog(string texto);
bool AguardaNoticias();
void CalculaEstatisticas();
void AIOptimizer();
double CalculaLote(double risco);
void EnviaOrdem(Signal s, string reason);
void ResetStrategy();

// --- Core Implementations ---
double CalculaLote(double riscoPercent) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = capital * riscoPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(p_stopPoints == 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double lot = riskAmount / (p_stopPoints * (tickValue / (tickSize / _Point)));
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / step) * step;

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return lot;
}

void EnviaOrdem(Signal s, string reason) {
   if(PositionsTotal() >= p_maxTrades) return;

   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0, tp = 0;

   if(p_stopPoints > 0) sl = (s == BUY) ? price - p_stopPoints * _Point : price + p_stopPoints * _Point;
   if(p_takePoints > 0) tp = (s == BUY) ? price + p_takePoints * _Point : price - p_takePoints * _Point;

   double lote = CalculaLote(p_riskPercent);

   // Margin Check
   double margin;
   if(!OrderCalcMargin((s == BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL), _Symbol, lote, price, margin)) {
      GravaLog("Margin check failed");
      return;
   }
   if(margin > AccountInfoDouble(ACCOUNT_FREEMARGIN)) {
      GravaLog("Insufficient margin");
      return;
   }

   bool res = false;
   if(s == BUY) res = trade.Buy(lote, _Symbol, price, sl, tp, reason);
   else res = trade.Sell(lote, _Symbol, price, sl, tp, reason);

   if(!res) GravaLog("Order error: " + IntegerToString(trade.ResultRetcode()) + " - " + trade.ResultComment());
   else {
      string msg = "Order sent: " + reason + " " + (s == BUY ? "BUY" : "SELL") + " " + DoubleToString(lote, 2) + " " + _Symbol;
      GravaLog(msg);
      SendNotification(msg);
   }
}

void GerenciaPosicoes() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      string symbol = PositionGetSymbol(i);
      if(symbol != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != EA_MAGIC) continue;

      ulong ticket = PositionGetInteger(POSITION_TICKET);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double currentPrice = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      // Break-even
      if(p_beStart > 0) {
         double profitPoints = (type == POSITION_TYPE_BUY) ? (currentPrice - openPrice) / _Point : (openPrice - currentPrice) / _Point;
         if(profitPoints >= p_beStart) {
            double targetSL = (type == POSITION_TYPE_BUY) ? openPrice + p_bePlus * _Point : openPrice - p_bePlus * _Point;
            if((type == POSITION_TYPE_BUY && currentSL < targetSL) || (type == POSITION_TYPE_SELL && (currentSL > targetSL || currentSL == 0))) {
               trade.PositionModify(ticket, targetSL, PositionGetDouble(POSITION_TP));
            }
         }
      }

      // Trailing Stop
      if(p_trailingStart > 0) {
         double profitPoints = (type == POSITION_TYPE_BUY) ? (currentPrice - openPrice) / _Point : (openPrice - currentPrice) / _Point;
         if(profitPoints >= p_trailingStart) {
            double targetSL = (type == POSITION_TYPE_BUY) ? currentPrice - p_trailingStart * _Point : currentPrice + p_trailingStart * _Point;
            if(MathAbs(targetSL - currentSL) >= p_trailingStep * _Point) {
               if((type == POSITION_TYPE_BUY && targetSL > currentSL) || (type == POSITION_TYPE_SELL && (targetSL < currentSL || currentSL == 0))) {
                  trade.PositionModify(ticket, targetSL, PositionGetDouble(POSITION_TP));
               }
            }
         }
      }
   }
}

void GravaLog(string texto) {
   int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE|FILE_READ|FILE_TXT|FILE_ANSI);
   if(handle != INVALID_HANDLE) {
      FileSeek(handle, 0, SEEK_END);
      FileWrite(handle, TimeToString(TimeCurrent()) + ": " + texto);
      FileClose(handle);
   }
   Print(texto);
}

void GravaCSV() {
   int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(handle != INVALID_HANDLE) {
      FileWrite(handle, "Ticket", "Symbol", "Type", "Volume", "PriceOpen", "Time", "SL", "TP", "Profit", "Reason");
      for(int i=0; i<PositionsTotal(); i++) {
         if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
            FileWrite(handle,
               PositionGetInteger(POSITION_TICKET),
               PositionGetSymbol(i),
               PositionGetInteger(POSITION_TYPE),
               PositionGetDouble(POSITION_VOLUME),
               PositionGetDouble(POSITION_PRICE_OPEN),
               PositionGetInteger(POSITION_TIME),
               PositionGetDouble(POSITION_SL),
               PositionGetDouble(POSITION_TP),
               PositionGetDouble(POSITION_PROFIT),
               PositionGetString(POSITION_COMMENT)
            );
         }
      }
      FileClose(handle);
   }
}

// Utility NLP Functions
double ExtraiNumero(string txt, string keyword) {
   int pos = StringFind(txt, keyword);
   if(pos < 0) return 0;
   pos += StringLen(keyword);
   return ExtraiNumero(txt, pos);
}

double ExtraiNumero(string txt, int &pos) {
   string res = "";
   bool found = false;
   for(int i=pos; i<StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.') {
         res += ShortToString(c);
         found = true;
      } else if(found) {
         pos = i;
         break;
      }
   }
   return StringToDouble(res);
}

double ExtraiValorApos(string txt, string keyword) {
   return ExtraiNumero(txt, keyword);
}

string ExtractTime(string txt) {
   // Simplified HH:MM extraction for "10h" or "10:30"
   int pos = StringFind(txt, " h");
   if(pos < 0) pos = StringFind(txt, "h");
   if(pos > 0) {
      int start = pos - 1;
      while(start >= 0 && ((StringGetCharacter(txt, start) >= '0' && StringGetCharacter(txt, start) <= '9') || StringGetCharacter(txt, start) == ':')) {
         start--;
      }
      string t = StringSubstr(txt, start + 1, pos - start - 1);
      if(StringFind(t, ":") < 0) t += ":00";
      return t;
   }
   return "00:00";
}

ENUM_TIMEFRAMES PeriodoTexto(string nome) {
   StringToLower(nome);
   if(StringFind(nome, "15 min") >= 0 || StringFind(nome, "m15") >= 0) return PERIOD_M15;
   if(StringFind(nome, "5 min") >= 0 || StringFind(nome, "m5") >= 0) return PERIOD_M5;
   if(StringFind(nome, "1 min") >= 0 || StringFind(nome, "m1") >= 0) return PERIOD_M1;
   if(StringFind(nome, "1 hora") >= 0 || StringFind(nome, "h1") >= 0) return PERIOD_H1;
   if(StringFind(nome, "diário") >= 0 || StringFind(nome, "d1") >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   string lowerPrompt = prompt;
   StringToLower(lowerPrompt);

   // Global parameters
   p_frequency = PeriodoTexto(lowerPrompt);
   p_riskPercent = ExtraiValorApos(lowerPrompt, "risco de ");
   if(p_riskPercent == 0) p_riskPercent = 1.0;

   p_stopPoints = (int)ExtraiValorApos(lowerPrompt, "stop de ");
   p_takePoints = (int)ExtraiValorApos(lowerPrompt, "take de ");

   p_startTime = ExtractTime(lowerPrompt);

   p_beStart = (int)ExtraiValorApos(lowerPrompt, "atingir +");
   p_bePlus = (int)ExtraiValorApos(lowerPrompt, "entrada +");

   // Split rules by " e ", ".", or ","
   string segments[];
   string sep = "|";
   string workPrompt = lowerPrompt;
   StringReplace(workPrompt, " e ", sep);
   StringReplace(workPrompt, ".", sep);
   StringReplace(workPrompt, ",", sep);
   ushort u_sep = StringGetCharacter(sep, 0);
   int nSegments = StringSplit(workPrompt, u_sep, segments);

   int currentIntent = NONE;
   for(int i=0; i<nSegments && nRules < 20; i++) {
      string s = segments[i];
      StringTrimLeft(s); StringTrimRight(s);
      if(s == "") continue;

      if(StringFind(s, "compra") >= 0) currentIntent = BUY;
      else if(StringFind(s, "vende") >= 0) currentIntent = SELL;

      Rule r;
      r.Reset();
      r.tf = PeriodoTexto(s);
      if(r.tf == PERIOD_CURRENT) r.tf = p_frequency;
      r.intent = currentIntent;

      if(StringFind(s, "média") >= 0 || StringFind(s, " ma ") >= 0) {
         r.type = 1; // MA
         int pos = 0;
         r.p1 = (int)ExtraiNumero(s, pos);
         r.p2 = (int)ExtraiNumero(s, pos); // Potential second MA
         r.active = true;
      }
      else if(StringFind(s, "rsi") >= 0) {
         r.type = 2; // RSI
         int pos = 0;
         double v1 = ExtraiNumero(s, pos);
         double v2 = ExtraiNumero(s, pos);
         if(v1 < 40) { r.p1 = (int)v1; r.d1 = v2; }
         else { r.p1 = 14; r.d1 = v1; }
         r.active = true;
      }
      else if(StringFind(s, "estocástico") >= 0 || StringFind(s, "stoch") >= 0) {
         r.type = 3; // Stoch
         r.p1 = 5; r.p2 = 3; r.p3 = 3;
         r.active = true;
      }
      else if(StringFind(s, "bollinger") >= 0 || StringFind(s, "bb") >= 0) {
         r.type = 4; // BB
         r.p1 = 20; r.d1 = 2.0;
         r.active = true;
      }
      else if(StringFind(s, "rompimento diário") >= 0) {
         r.type = 5; // DailyBreak
         r.active = true;
      }
      else if(StringFind(s, "volume") >= 0) {
         r.type = 7; // Vol
         r.p1 = 12;
         r.active = true;
      }

      if(r.active) {
         rules[nRules] = r;
         nRules++;
      }
   }
}

// Indicator Signal Functions
double GetBufferValue(int handle, int buffer, int shift) {
   double val[1];
   if(CopyBuffer(handle, buffer, shift, 1, val) < 0) return 0;
   return val[0];
}

Signal AvaliaRegra(Rule &r) {
   if(!r.active) return NONE;

   // Initialize handles if not already done
   if(r.handle1 == INVALID_HANDLE || r.handle1 == 0) {
      if(r.type == 1) r.handle1 = iMA(_Symbol, r.tf, r.p1, 0, MODE_SMA, PRICE_CLOSE);
      if(r.type == 2) r.handle1 = iRSI(_Symbol, r.tf, r.p1, PRICE_CLOSE);
      if(r.type == 3) r.handle1 = iStochastic(_Symbol, r.tf, r.p1, r.p2, r.p3, MODE_SMA, STO_LOWHIGH);
      if(r.type == 4) r.handle1 = iBands(_Symbol, r.tf, r.p1, 0, r.d1, PRICE_CLOSE);
   }

   if(r.type == 1) { // MA Crossover or Price vs MA
      double ma1 = GetBufferValue(r.handle1, 0, 1);
      double ma2 = GetBufferValue(r.handle1, 0, 2);
      double price1 = iClose(_Symbol, r.tf, 1);
      double price2 = iClose(_Symbol, r.tf, 2);

      if(price2 < ma2 && price1 > ma1) return BUY;
      if(price2 > ma2 && price1 < ma1) return SELL;
   }
   else if(r.type == 2) { // RSI Threshold
      double rsi1 = GetBufferValue(r.handle1, 0, 1);
      double rsi2 = GetBufferValue(r.handle1, 0, 2);

      if(r.intent == BUY && rsi2 < r.d1 && rsi1 > r.d1) return BUY;
      if(r.intent == SELL && rsi2 > r.d1 && rsi1 < r.d1) return SELL;
   }
   else if(r.type == 3) { // Stoch Cross
      double k1 = GetBufferValue(r.handle1, 0, 1);
      double d1 = GetBufferValue(r.handle1, 1, 1);
      double k2 = GetBufferValue(r.handle1, 0, 2);
      double d2 = GetBufferValue(r.handle1, 1, 2);

      if(k2 < d2 && k1 > d1) return BUY;
      if(k2 > d2 && k1 < d1) return SELL;
   }
   else if(r.type == 4) { // BB Bounce
      double lower = GetBufferValue(r.handle1, 2, 1);
      double upper = GetBufferValue(r.handle1, 1, 1);
      double close = iClose(_Symbol, r.tf, 1);

      if(close < lower) return BUY;
      if(close > upper) return SELL;
   }
   else if(r.type == 5) { // DailyBreak
      double hi = iHigh(_Symbol, PERIOD_D1, 1);
      double lo = iLow(_Symbol, PERIOD_D1, 1);
      double close = iClose(_Symbol, PERIOD_M1, 1);

      if(close > hi) return BUY;
      if(close < lo) return SELL;
   }
   else if(r.type == 7) { // Vol Cycle
      long vol1 = iVolume(_Symbol, r.tf, 1);
      long vol2 = iVolume(_Symbol, r.tf, 2);
      if(vol1 > vol2 * 1.5) return (iClose(_Symbol, r.tf, 1) > iOpen(_Symbol, r.tf, 1)) ? BUY : SELL;
   }

   return NONE;
}

Signal AvaliaTudo() {
   int buyLeg = 0, sellLeg = 0;
   int buyRules = 0, sellRules = 0;

   for(int i=0; i<nRules; i++) {
      Signal s = AvaliaRegra(rules[i]);
      if(rules[i].intent == BUY || rules[i].intent == NONE) {
         buyRules++;
         if(s == BUY) buyLeg++;
      }
      if(rules[i].intent == SELL || rules[i].intent == NONE) {
         sellRules++;
         if(s == SELL) sellLeg++;
      }
   }

   if(buyRules > 0 && buyLeg == buyRules) return BUY;
   if(sellRules > 0 && sellLeg == sellRules) return SELL;

   return NONE;
}

// --- Initialization ---
int OnInit() {
   trade.SetExpertMagicNumber(EA_MAGIC);
   EventSetTimer(1);
   ResetStrategy();
   return(INIT_SUCCEEDED);
}

// --- Deinitialization ---
void OnDeinit(const int reason) {
   EventKillTimer();
   ResetStrategy();
}

// --- Main Loop ---
void OnTick() {
   // Position management and state persistence on every tick
   GerenciaPosicoes();
   GravaCSV();

   // Signal evaluation and order entry at the start of a new bar
   datetime current_bar = iTime(_Symbol, p_frequency, 0);
   if(current_bar != last_bar_time) {
      last_bar_time = current_bar;

      // Time filter
      if(TimeToString(TimeCurrent(), TIME_MINUTES) < p_startTime) return;

      // News filter
      if(AguardaNoticias()) return;

      Signal s = AvaliaTudo();
      if(s != NONE) {
         EnviaOrdem(s, "Signal Triggered");
      }
   }
}

// --- Timer for Runtime Updates ---
void OnTimer() {
   static datetime last_check = 0;
   static datetime last_file_time = 0;

   if(TimeCurrent() - last_check >= 1) { // Every second
      last_check = TimeCurrent();

      // Check for prompt.txt update
      if(FileIsExist("prompt.txt")) {
         datetime file_time = (datetime)FileGetInteger("prompt.txt", FILE_MODIFY_DATE);
         if(file_time != last_file_time) {
            last_file_time = file_time;
            int handle = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_ANSI);
            if(handle != INVALID_HANDLE) {
               string prompt = FileReadString(handle);
               FileClose(handle);
               if(prompt != "") {
                  InterpretaPrompt(prompt);
                  GravaLog("Strategy updated from prompt.txt");
               }
            }
         }
      }
   }

   // Hourly Optimizer
   static datetime last_opt = 0;
   if(TimeCurrent() - last_opt >= 3600) {
      last_opt = TimeCurrent();
      AIOptimizer();
      CalculaEstatisticas();
   }
}

void ResetStrategy() {
   for(int i=0; i<20; i++) rules[i].Reset();
   nRules = 0;
   p_frequency = PERIOD_M15;
   p_maxTrades = 3;
   p_startTime = "00:00";
   p_riskPercent = 1.0;
   p_stopPoints = 300;
   p_takePoints = 500;
   p_beStart = 0;
   p_bePlus = 0;
   p_trailingStart = 0;
   p_trailingStep = 10;
   p_martingale = false;
}

bool AguardaNoticias() {
   int handle = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_ANSI);
   if(handle == INVALID_HANDLE) return false;

   string content = FileReadString(handle);
   FileClose(handle);

   if(content == "1") return true;

   datetime newsTime = StringToTime(content);
   if(newsTime > 0) {
      if(TimeCurrent() >= newsTime - 1200 && TimeCurrent() <= newsTime + 1200) return true;
   }

   return false;
}

void CalculaEstatisticas() {
   HistorySelect(0, TimeCurrent());
   int total = HistoryDealsTotal();
   int wins = 0, losses = 0;
   double profit = 0;

   for(int i=0; i<total; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != EA_MAGIC) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

      double p = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      profit += p;
      if(p > 0) wins++;
      else if(p < 0) losses++;
   }

   double winRate = (wins + losses > 0) ? (double)wins / (wins + losses) : 0;
   string msg = "Stats: Profit=" + DoubleToString(profit, 2) + " WinRate=" + DoubleToString(winRate * 100, 1) + "%";
   GravaLog(msg);
   if(winRate < 0.4 && wins + losses >= 10) SendNotification("Warning: WinRate is low: " + DoubleToString(winRate * 100, 1) + "%");
}

void AIOptimizer() {
   // Heuristic risk adjustment
   HistorySelect(TimeCurrent() - 86400, TimeCurrent());
   int total = 0, wins = 0;
   for(int i=0; i<HistoryDealsTotal(); i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC && HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT) {
         total++;
         if(HistoryDealGetDouble(ticket, DEAL_PROFIT) > 0) wins++;
      }
   }

   if(total >= 10) {
      double wr = (double)wins / total;
      if(wr < 0.4) p_riskPercent = MathMax(0.5, p_riskPercent - 0.1);
      else if(wr > 0.6) p_riskPercent = MathMin(2.0, p_riskPercent + 0.1);
   }
}
