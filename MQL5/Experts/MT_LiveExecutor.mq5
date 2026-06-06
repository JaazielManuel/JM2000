//=========================  MT-LiveExecutor  =========================
// MetaTrader 5 Live Executor Agent
// Interprets natural language strategy prompts and executes them in real-time.
//========================================================================

#property copyright "Copyright 2024, MT-LiveExecutor"
#property link      "https://github.com/MT-LiveExecutor"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// --- Defines
#define EA_MAGIC 123456
#define MAX_RULES 20

// --- Enums
enum Signal {BUY=1, SELL=-1, NONE=0};

// --- Structs
struct Rule {
   bool     active;
   int      type;    // 1: MA Cross, 2: RSI, 3: Stoch, 4: BB, 5: DailyBreak, 6: Delta, 7: Volume, 8: AMA, 9: Bar2, 10: Relative
   int      intent;  // 1 for BUY logic, -1 for SELL logic
   int      tf;
   int      p1, p2, p3;
   double   d1, d2;
   string   s1;
   int      h1, h2; // Indicator handles

   void Reset() {
      if(h1 != INVALID_HANDLE && h1 != 0) IndicatorRelease(h1);
      if(h2 != INVALID_HANDLE && h2 != 0) IndicatorRelease(h2);
      active = false;
      type = 0;
      intent = 0;
      tf = 0;
      p1 = 0; p2 = 0; p3 = 0;
      d1 = 0; d2 = 0;
      s1 = "";
      h1 = INVALID_HANDLE;
      h2 = INVALID_HANDLE;
   }
};

// --- Global Variables
Rule rules[MAX_RULES];
int nRules = 0;
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symbolInfo;

double p_risk = 1.0;
double p_stopLoss = 300; // points
double p_takeProfit = 500; // points
int    p_maxTrades = 3;
string p_startTime = "10:00";
int    p_newsVeto = 20; // minutes
double p_beStart = 0;
double p_bePlus = 0;
double p_trailingStop = 0;
double p_trailingStep = 10;
bool   p_martingale = false;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

string last_prompt = "";
datetime last_file_check = 0;

// ========================================================================
// MQL5 EVENT HANDLERS
// ========================================================================

int OnInit() {
   trade.SetExpertMagicNumber(EA_MAGIC);
   symbolInfo.Name(_Symbol);

   EventSetTimer(1); // Check for new prompt every second

   ResetStrategy();
   InterpretaPrompt(""); // Initial check

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   EventKillTimer();
   ResetStrategy();
}

void OnTick() {
   static datetime last_bar = 0;
   datetime current_bar = iTime(_Symbol, p_frequency, 0);

   // Position management on every tick
   GerenciaPosicoes();

   // State persistence every 5 seconds
   static datetime last_csv = 0;
   if(TimeCurrent() - last_csv >= 5) {
      GravaCSV();
      last_csv = TimeCurrent();
   }

   // Signal evaluation on new bar
   if(current_bar != last_bar) {
      if(IsTimeAllowed() && !AguardaNoticias()) {
         Signal sig = AvaliaTudo();
         if(sig != NONE) {
            double lot = CalculaLote(p_risk);
            double sl = 0, tp = 0;
            double price = (sig == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

            if(sig == BUY) {
               sl = price - p_stopLoss * _Point;
               tp = price + p_takeProfit * _Point;
            } else {
               sl = price + p_stopLoss * _Point;
               tp = price - p_takeProfit * _Point;
            }

            if(PositionsTotal() < p_maxTrades) {
               EnviaOrdem((sig == BUY ? "BUY" : "SELL"), price, sl, tp, lot);
            }
         }
      }
      last_bar = current_bar;
   }
}

void OnTimer() {
   // Check for prompt updates
   int handle = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      string content = FileReadString(handle);
      FileClose(handle);

      if(content != last_prompt && StringLen(content) > 5) {
         GravaLog("New prompt detected: " + content);
         InterpretaPrompt(content);
         last_prompt = content;
      }
   }

   // AIOptimizer placeholder
   static datetime lastAI = 0;
   if(TimeCurrent() - lastAI >= 3600) {
      AIOptimizer();
      lastAI = TimeCurrent();
   }
}

// ========================================================================
// NLP / PARSER FUNCTIONS
// ========================================================================

void ResetStrategy() {
   for(int i=0; i<MAX_RULES; i++) rules[i].Reset();
   nRules = 0;
   p_risk = 1.0;
   p_stopLoss = 300;
   p_takeProfit = 500;
   p_maxTrades = 3;
   p_startTime = "10:00";
   p_newsVeto = 20;
   p_beStart = 0;
   p_bePlus = 0;
   p_trailingStop = 0;
   p_martingale = false;
}

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   if(prompt == "") return;

   string work = prompt;
   StringToLower(work);
   StringReplace(work, " e ", ".");

   string segments[];
   int total = StringSplit(work, '.', segments);

   int currentIntent = 0; // 0: Neutral, 1: BUY, -1: SELL

   for(int i=0; i<total; i++) {
      string seg = segments[i];
      StringTrimLeft(seg);
      StringTrimRight(seg);

      if(StringFind(seg, "compra") >= 0) currentIntent = 1;
      if(StringFind(seg, "vende") >= 0) currentIntent = -1;

      // Global params
      int cursor = 0;
      if(StringFind(seg, "risco") >= 0) p_risk = ExtraiNumero(seg, cursor);
      cursor = 0;
      if(StringFind(seg, "stop de") >= 0) p_stopLoss = ExtraiNumero(seg, cursor);
      cursor = 0;
      if(StringFind(seg, "take de") >= 0) p_takeProfit = ExtraiNumero(seg, cursor);
      cursor = 0;
      if(StringFind(seg, "máximo") >= 0) p_maxTrades = (int)ExtraiNumero(seg, cursor);
      cursor = 0;
      if(StringFind(seg, "atingir") >= 0) {
         p_beStart = ExtraiNumero(seg, cursor);
         if(StringFind(seg, "entrada") >= 0) p_bePlus = ExtraiNumero(seg, cursor);
      }
      cursor = 0;
      if(StringFind(seg, "trailing") >= 0) p_trailingStop = ExtraiNumero(seg, cursor);

      if(StringFind(seg, "martingale") >= 0) p_martingale = true;

      if(StringFind(seg, "depois das") >= 0 || StringFind(seg, "início") >= 0) {
         int h = 0, m = 0;
         // Simplified time extraction
         int pos = StringFind(seg, "h");
         if(pos > 0) {
            h = (int)StringToInteger(StringSubstr(seg, pos-2, 2));
         }
         p_startTime = StringFormat("%02d:00", h);
      }

      if(StringFind(seg, "notícias") >= 0) {
         int c2 = 0;
         p_newsVeto = (int)ExtraiNumero(seg, c2);
      }

      // Timeframe
      if(StringFind(seg, "minutos") >= 0 || StringFind(seg, "min") >= 0) {
         int c3 = 0;
         int m = (int)ExtraiNumero(seg, c3);
         if(m == 1) p_frequency = PERIOD_M1;
         else if(m == 5) p_frequency = PERIOD_M5;
         else if(m == 15) p_frequency = PERIOD_M15;
         else if(m == 30) p_frequency = PERIOD_M30;
      }

      // Indicators
      AddRule(seg, currentIntent);
   }

   GravaLog("Prompt interpreted. Rules: " + (string)nRules);
}

void AddRule(string txt, int intent) {
   if(nRules >= MAX_RULES) return;
   Rule r;
   r.Reset();
   r.intent = intent;

   static int lastMA = 20;
   static int lastRSI = 14;

   bool matched = false;

   if(StringFind(txt, "média") >= 0) {
      int c = StringFind(txt, "média") + 5;
      r.p1 = (int)ExtraiNumero(txt, c);
      if(r.p1 <= 0) r.p1 = lastMA;
      lastMA = r.p1;
      r.type = 1; // MA Cross logic placeholder
      r.h1 = iMA(_Symbol, p_frequency, r.p1, 0, MODE_SMA, PRICE_CLOSE);
      r.active = true;
      matched = true;
   }

   if(StringFind(txt, "rsi") >= 0) {
      int c = StringFind(txt, "rsi") + 3;
      r.p1 = (int)ExtraiNumero(txt, c);
      if(r.p1 <= 0) r.p1 = lastRSI;
      lastRSI = r.p1;
      r.d1 = ExtraiNumero(txt, c); // threshold
      r.type = 2;
      r.h1 = iRSI(_Symbol, p_frequency, r.p1, PRICE_CLOSE);
      r.active = true;
      matched = true;
   }

   if(StringFind(txt, "estocástico") >= 0) {
      int c = StringFind(txt, "estocástico") + 11;
      r.p1 = (int)ExtraiNumero(txt, c); // K
      r.p2 = (int)ExtraiNumero(txt, c); // D
      r.type = 3;
      r.h1 = iStochastic(_Symbol, p_frequency, r.p1, r.p2, 3, MODE_SMA, STO_LOWHIGH);
      r.active = true;
      matched = true;
   }

   if(StringFind(txt, "bollinger") >= 0 || StringFind(txt, "bandas") >= 0) {
      int c = StringFind(txt, "bollinger") + 9;
      r.p1 = (int)ExtraiNumero(txt, c); // period
      r.d1 = ExtraiNumero(txt, c); // dev
      r.type = 4;
      r.h1 = iBands(_Symbol, p_frequency, r.p1, 0, r.d1, PRICE_CLOSE);
      r.active = true;
      matched = true;
   }

   if(StringFind(txt, "breakout") >= 0 || StringFind(txt, "máxima") >= 0) {
      r.type = 5;
      r.active = true;
      matched = true;
   }

   if(StringFind(txt, "delta") >= 0 || StringFind(txt, "agressão") >= 0) {
      int c = StringFind(txt, "delta") + 5;
      r.p1 = (int)ExtraiNumero(txt, c); // seconds
      r.p2 = (int)ExtraiNumero(txt, c); // threshold
      r.type = 6;
      r.active = true;
      matched = true;
   }

   if(StringFind(txt, "volume") >= 0) {
      int c = StringFind(txt, "volume") + 6;
      r.p1 = (int)ExtraiNumero(txt, c); // period
      r.type = 7;
      r.active = true;
      matched = true;
   }

   if(StringFind(txt, "ama") >= 0 || StringFind(txt, "adaptativa") >= 0) {
      int c = StringFind(txt, "ama") + 3;
      r.p1 = (int)ExtraiNumero(txt, c); // period
      r.type = 8;
      r.h1 = iAMA(_Symbol, p_frequency, r.p1, 2, 30, 0, PRICE_CLOSE);
      r.active = true;
      matched = true;
   }

   if(StringFind(txt, "padrão") >= 0 || StringFind(txt, "barra") >= 0) {
      r.type = 9;
      r.active = true;
      matched = true;
   }

   if(StringFind(txt, "relativa") >= 0) {
      r.type = 10;
      r.s1 = "US30"; // benchmark
      r.h1 = iRSI(_Symbol, p_frequency, 14, PRICE_CLOSE);
      r.h2 = iRSI(r.s1, p_frequency, 14, PRICE_CLOSE);
      r.active = true;
      matched = true;
   }

   if(matched) {
      rules[nRules] = r;
      nRules++;
   }
}

double ExtraiNumero(string txt, int &cursor) {
   string res = "";
   bool found = false;
   for(int i=cursor; i<StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.' || c == ',') {
         if(c == ',') res += ".";
         else res += StringFormat("%c", c);
         found = true;
      } else if(found) {
         cursor = i;
         break;
      }
   }
   return StringToDouble(res);
}

// ========================================================================
// SIGNAL / RULE EVALUATION
// ========================================================================

Signal AvaliaTudo() {
   if(nRules == 0) return NONE;

   bool buyConfluence = true;
   bool sellConfluence = true;
   int buyCount = 0, sellCount = 0;

   for(int i=0; i<nRules; i++) {
      if(!rules[i].active) continue;
      Signal s = AvaliaRegra(rules[i]);

      if(rules[i].intent == 1) {
         if(s != BUY) buyConfluence = false;
         buyCount++;
      } else if(rules[i].intent == -1) {
         if(s != SELL) sellConfluence = false;
         sellCount++;
      }
   }

   if(buyCount > 0 && buyConfluence) return BUY;
   if(sellCount > 0 && sellConfluence) return SELL;

   return NONE;
}

Signal AvaliaRegra(Rule &r) {
   if(r.type == 1) { // MA Cross/Price logic
      double ma1 = GetBufferValue(r.h1, 0, 1);
      double ma2 = GetBufferValue(r.h1, 0, 2);
      double c1 = iClose(_Symbol, p_frequency, 1);
      double c2 = iClose(_Symbol, p_frequency, 2);

      if(c2 < ma2 && c1 > ma1) return BUY;
      if(c2 > ma2 && c1 < ma1) return SELL;
   }

   if(r.type == 2) { // RSI Threshold logic
      double rsi = GetBufferValue(r.h1, 0, 1);
      if(r.intent == 1 && rsi > r.d1) return BUY;
      if(r.intent == -1 && rsi < r.d1) return SELL;
   }

   if(r.type == 3) { // Stoch Cross
      double k1 = GetBufferValue(r.h1, 0, 1);
      double d1 = GetBufferValue(r.h1, 1, 1);
      double k2 = GetBufferValue(r.h1, 0, 2);
      double d2 = GetBufferValue(r.h1, 1, 2);
      if(k2 < d2 && k1 > d1) return BUY;
      if(k2 > d2 && k1 < d1) return SELL;
   }

   if(r.type == 4) { // Bollinger Bounce
      double lower = GetBufferValue(r.h1, 2, 1);
      double upper = GetBufferValue(r.h1, 1, 1);
      double close = iClose(_Symbol, p_frequency, 1);
      if(close < lower) return BUY;
      if(close > upper) return SELL;
   }

   if(r.type == 5) { // Daily Breakout
      double hi = iHigh(_Symbol, PERIOD_D1, 1);
      double lo = iLow(_Symbol, PERIOD_D1, 1);
      double close = iClose(_Symbol, PERIOD_M1, 0);
      if(close > hi) return BUY;
      if(close < lo) return SELL;
   }

   if(r.type == 6) { // Delta Aggression
      MqlTick ticks[];
      int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, TimeCurrent() - r.p1, TimeCurrent());
      long buy = 0, sell = 0;
      for(int i=0; i<n; i++) {
         if((ticks[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++;
         else if((ticks[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sell++;
      }
      long delta = buy - sell;
      if(delta > r.p2) return BUY;
      if(delta < -r.p2) return SELL;
   }

   if(r.type == 7) { // Volume Cycle
      long vol[];
      CopyVolume(_Symbol, p_frequency, 1, r.p1, vol);
      int maxIdx = ArrayMaximum(vol);
      int minIdx = ArrayMinimum(vol);
      if(maxIdx == 0) return SELL;
      if(minIdx == 0) return BUY;
   }

   if(r.type == 8) { // AMA
      double ama1 = GetBufferValue(r.h1, 0, 1);
      double ama2 = GetBufferValue(r.h1, 0, 2);
      if(ama1 > ama2) return BUY;
      if(ama1 < ama2) return SELL;
   }

   if(r.type == 9) { // 2-Bar Patterns
      double h0 = iHigh(_Symbol, p_frequency, 1);
      double l0 = iLow(_Symbol, p_frequency, 1);
      double h1 = iHigh(_Symbol, p_frequency, 2);
      double l1 = iLow(_Symbol, p_frequency, 2);
      bool bullish = iClose(_Symbol, p_frequency, 1) > iOpen(_Symbol, p_frequency, 1);
      if(h0 < h1 && l0 > l1) return bullish ? BUY : SELL; // Inside
      if(h0 > h1 && l0 < l1) return bullish ? SELL : BUY; // Outside
   }

   if(r.type == 10) { // Relative RSI
      double r1 = GetBufferValue(r.h1, 0, 1);
      double r2 = GetBufferValue(r.h2, 0, 1);
      if(r1 > r2 + 5) return BUY;
      if(r1 < r2 - 5) return SELL;
   }

   return NONE;
}

double GetBufferValue(int handle, int buffer, int shift) {
   double arr[];
   ArraySetAsSeries(arr, true);
   if(CopyBuffer(handle, buffer, shift, 1, arr) > 0) return arr[0];
   return 0;
}

// ========================================================================
// TRADE / POSITION MANAGEMENT
// ========================================================================

void EnviaOrdem(string tipo, double preco, double sl, double tp, double lote) {
   bool res = false;
   int retries = 3;

   // Margin check
   double margin;
   ENUM_ORDER_TYPE ot = (tipo == "BUY" ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(!OrderCalcMargin(ot, _Symbol, lote, preco, margin)) {
      GravaLog("Error calculating margin");
      return;
   }
   if(margin > AccountInfoDouble(ACCOUNT_FREEMARGIN)) {
      GravaLog(StringFormat("Insufficient margin. Required: %.2f, Available: %.2f", margin, AccountInfoDouble(ACCOUNT_FREEMARGIN)));
      return;
   }

   while(retries > 0) {
      if(tipo == "BUY") res = trade.Buy(lote, _Symbol, preco, sl, tp, "MT-LiveExecutor Entry");
      else res = trade.Sell(lote, _Symbol, preco, sl, tp, "MT-LiveExecutor Entry");

      if(res) {
         uint code = trade.ResultRetcode();
         if(code == TRADE_RETCODE_DONE || code == TRADE_RETCODE_PLACED) {
            GravaLog(StringFormat("%s Executed: %.2f lots at %.5f", tipo, lote, trade.ResultPrice()));
            SendNotification("Trade Executed: " + tipo);
            break;
         } else if(code == TRADE_RETCODE_REQUOTES || code == TRADE_RETCODE_OFFQUOTES) {
            retries--;
            Sleep(100);
            preco = (tipo == "BUY" ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID));
         } else {
            GravaLog("Trade Error: " + (string)code);
            break;
         }
      } else {
         GravaLog("Trade Send Failed");
         break;
      }
   }
}

double CalculaLote(double riscoPercent) {
   if(p_martingale) {
      // Logic to check last trade and double risk if loss
      HistorySelect(TimeCurrent()-86400*7, TimeCurrent());
      int total = HistoryDealsTotal();
      for(int i=total-1; i>=0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            if(profit < 0) riscoPercent *= 2;
            break;
         }
      }
   }

   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riscoAbs = capital * riscoPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(p_stopLoss == 0) return 0.01;

   double lot = riscoAbs / ((p_stopLoss * _Point / tickSize) * tickValue);
   return NormalizeDouble(lot, 2);
}

void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) {
         if(PositionGetInteger(POSITION_MAGIC) != EA_MAGIC) continue;

         double profitPoints = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ?
                              (SymbolInfoDouble(_Symbol, SYMBOL_BID) - PositionGetDouble(POSITION_PRICE_OPEN)) / _Point :
                              (PositionGetDouble(POSITION_PRICE_OPEN) - SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / _Point;

         // Breakeven
         if(p_beStart > 0 && profitPoints >= p_beStart) {
            double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ?
                           PositionGetDouble(POSITION_PRICE_OPEN) + p_bePlus * _Point :
                           PositionGetDouble(POSITION_PRICE_OPEN) - p_bePlus * _Point;

            if(PositionGetDouble(POSITION_SL) != newSL) {
               trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
            }
         }

         // Trailing Stop
         if(p_trailingStop > 0 && profitPoints >= p_trailingStop) {
            double currentSL = PositionGetDouble(POSITION_SL);
            double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ?
                           SymbolInfoDouble(_Symbol, SYMBOL_BID) - p_trailingStop * _Point :
                           SymbolInfoDouble(_Symbol, SYMBOL_ASK) + p_trailingStop * _Point;

            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
               if(newSL > currentSL + p_trailingStep * _Point) trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
            } else {
               if(newSL < currentSL - p_trailingStep * _Point || currentSL == 0) trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
            }
         }
      }
   }
}

// ========================================================================
// UTILITIES / EXTERNAL
// ========================================================================

bool IsTimeAllowed() {
   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   string currentTime = StringFormat("%02d:%02d", dt.hour, dt.min);
   return (currentTime >= p_startTime);
}

bool AguardaNoticias() {
   // Check news_veto.txt
   int h = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      string v = FileReadString(h);
      FileClose(h);
      if(v == "1") return true;
   }

   // Check calendar.txt for High Impact
   h = FileOpen("calendar.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      datetime now = TimeCurrent();
      while(!FileIsEnding(h)) {
         string line = FileReadString(h);
         if(StringFind(line, "High") >= 0 || StringFind(line, "Alto") >= 0) {
            // Expecting format: YYYY.MM.DD HH:MM;Symbol;Impact;Title
            string parts[];
            if(StringSplit(line, ';', parts) >= 1) {
               datetime newsTime = StringToTime(parts[0]);
               if(MathAbs(now - newsTime) <= p_newsVeto * 60) {
                  FileClose(h);
                  return true;
               }
            }
         }
      }
      FileClose(h);
   }

   return false;
}

void GravaLog(string texto) {
   int h = FileOpen("MT_LiveExecutor_Log.txt", FILE_READ|FILE_WRITE|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      FileSeek(h, 0, SEEK_END);
      FileWrite(h, TimeToString(TimeCurrent()) + ": " + texto);
      FileClose(h);
   }
   Print(texto);
}

void GravaCSV() {
   int h = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      FileWrite(h, "Ticket", "Symbol", "Type", "Lots", "Profit");
      for(int i=0; i<PositionsTotal(); i++) {
         if(PositionSelectByTicket(PositionGetTicket(i))) {
            if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
               FileWrite(h, PositionGetInteger(POSITION_TICKET),
                         PositionGetString(POSITION_SYMBOL),
                         PositionGetInteger(POSITION_TYPE),
                         PositionGetDouble(POSITION_VOLUME),
                         PositionGetDouble(POSITION_PROFIT));
            }
         }
      }
      FileClose(h);
   }
}

void CalculaStats() {
   HistorySelect(0, TimeCurrent());
   int total = HistoryDealsTotal();
   int wins = 0, losses = 0;
   double totalProfit = 0, totalLoss = 0;

   for(int i=0; i<total; i++) {
      ulong t = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC) {
         double p = HistoryDealGetDouble(t, DEAL_PROFIT);
         if(p > 0) { wins++; totalProfit += p; }
         if(p < 0) { losses++; totalLoss += MathAbs(p); }
      }
   }

   double winRate = (wins + losses > 0) ? (double)wins / (wins + losses) * 100 : 0;
   GravaLog(StringFormat("Stats: WinRate %.2f%%, Profit Factor %.2f", winRate, (totalLoss > 0 ? totalProfit / totalLoss : 0)));
}

void AIOptimizer() {
   // Placeholder for AI strategy adjustment
   GravaLog("Running AI Strategy Optimizer...");
}
