//+------------------------------------------------------------------+
//|                                              MT_LiveExecutor.mq5 |
//|                                  Copyright 2024, MT-LiveExecutor |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MT-LiveExecutor"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

//--- defines
#define EA_MAGIC 123456
#define MAX_RULES 20

//--- enums
enum Signal {BUY=1, SELL=-1, NONE=0};

enum RuleType {
   RT_MA,         // Moving Average
   RT_RSI,        // RSI
   RT_STOCH,      // Stochastic
   RT_BB,         // Bollinger Bands
   RT_DAILYBREAK, // Daily Breakout
   RT_VOL,        // Volume
   RT_BAR2,       // 2-Bar Pattern
   RT_DELTA,      // Delta Aggression
   RT_AI,         // AI Signal
   RT_RS          // Relative Strength
};

//--- structs
struct Rule {
   bool      active;
   RuleType  type;
   Signal    intent;     // BUY or SELL context for this rule
   ENUM_TIMEFRAMES tf;
   int       p1, p2, p3;
   double    d1, d2;
   string    s1;
   int       handle1, handle2;

   void Reset() {
      if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease(handle1);
      if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease(handle2);
      active = false;
      type = RT_MA;
      intent = NONE;
      tf = PERIOD_CURRENT;
      p1 = 0; p2 = 0; p3 = 0;
      d1 = 0; d2 = 0;
      s1 = "";
      handle1 = INVALID_HANDLE;
      handle2 = INVALID_HANDLE;
   }
};

//--- globals
Rule     rules[MAX_RULES];
int      nRules = 0;
CTrade   m_trade;
CPositionInfo m_pos;

// Strategy parameters
double   p_riskPercent = 1.0;
int      p_stopPoints = 300;
int      p_takePoints = 500;
int      p_maxTrades = 3;
double   p_beStart = 0;
double   p_bePlus = 0;
double   p_trailingStop = 0;
double   p_trailingStep = 0;
string   p_startTime = "00:00";
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
bool     p_useMartingale = false;
int      p_newsVetoMinutes = 20;

datetime lastPromptUpdate = 0;
datetime lastBarTime = 0;
datetime lastAI = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   m_trade.SetExpertMagicNumber(EA_MAGIC);
   EventSetTimer(1);
   lastPromptUpdate = 0;
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   for(int i=0; i<MAX_RULES; i++) rules[i].Reset();
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   GerenciaPosicoes();

   static datetime lastCSV = 0;
   if(TimeCurrent() - lastCSV > 5) {
      GravaCSV();
      lastCSV = TimeCurrent();
   }

   if(!IsTimeAllowed() || AguardaNoticias()) return;

   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar != lastBarTime) {
      Signal sig = AvaliaTudo();
      if(sig == BUY) EnviaOrdem("BUY", CalculaLote(p_riskPercent));
      else if(sig == SELL) EnviaOrdem("SELL", CalculaLote(p_riskPercent));
      lastBarTime = currentBar;
   }
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
{
   // 1. Check for prompt updates
   if(FileIsExist("prompt.txt")) {
      datetime mod = (datetime)FileGetInteger("prompt.txt", FILE_MODIFY_DATE);
      if(mod > lastPromptUpdate) {
         int handle = FileOpen("prompt.txt", FILE_READ | FILE_TXT);
         if(handle != INVALID_HANDLE) {
            string prompt = FileReadString(handle);
            FileClose(handle);
            InterpretaPrompt(prompt);
            lastPromptUpdate = mod;
         }
      }
   }

   // 2. Hourly Optimizer
   if(TimeCurrent() - lastAI > 3600) {
      AIOptimizer();
      lastAI = TimeCurrent();
   }
}

void AIOptimizer()
{
   HistorySelect(TimeCurrent() - 86400 * 7, TimeCurrent());
   int total = HistoryDealsTotal();
   int wins = 0, count = 0;
   for(int i=total-1; i>=0 && count < 10; i--) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
         if(HistoryDealGetDouble(ticket, DEAL_PROFIT) > 0) wins++;
         count++;
      }
   }
   if(count >= 5 && (double)wins/count < 0.4) {
      p_riskPercent *= 0.8;
      GravaLog("AI: Winrate baixo (" + DoubleToString((double)wins/count, 2) + "). Risco reduzido.");
   }
}

void GravaCSV()
{
   int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV);
   if(handle == INVALID_HANDLE) return;

   FileWrite(handle, "Ticket", "Type", "Lots", "Symbol", "OpenPrice", "SL", "TP", "Profit");
   for(int i=0; i<PositionsTotal(); i++) {
      if(m_pos.SelectByIndex(i) && m_pos.Magic() == EA_MAGIC) {
         FileWrite(handle, m_pos.Ticket(), m_pos.PositionType(), m_pos.Volume(), m_pos.Symbol(), m_pos.PriceOpen(), m_pos.StopLoss(), m_pos.TakeProfit(), m_pos.Profit());
      }
   }
   FileClose(handle);
}

void GravaLog(string texto)
{
   int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_READ | FILE_WRITE | FILE_TXT);
   if(handle != INVALID_HANDLE) {
      FileSeek(handle, 0, SEEK_END);
      FileWrite(handle, TimeToString(TimeCurrent()) + ": " + texto);
      FileClose(handle);
   }
   Print("MT-LiveExecutor: " + texto);
}

//+------------------------------------------------------------------+
//| NLP Parser                                                       |
//+------------------------------------------------------------------+
void InterpretaPrompt(string prompt)
{
   string work = prompt;
   StringToLower(work);

   // Reset existing rules
   for(int i=0; i<MAX_RULES; i++) rules[i].Reset();
   nRules = 0;

   // 1. Parse Strategy-Wide Parameters
   if(StringFind(work, "risco de") >= 0) {
      double val = ExtraiValorApos(work, "risco de");
      if(val > 0) p_riskPercent = val;
   }
   if(StringFind(work, "stop de") >= 0) {
      double val = ExtraiValorApos(work, "stop de");
      if(val > 0) p_stopPoints = (int)val;
   }
   if(StringFind(work, "take de") >= 0) {
      double val = ExtraiValorApos(work, "take de");
      if(val > 0) p_takePoints = (int)val;
   }
   if(StringFind(work, "máximo") >= 0) {
      double val = ExtraiValorApos(work, "máximo");
      if(val > 0) p_maxTrades = (int)val;
   }
   if(StringFind(work, "atingir") >= 0) {
      p_beStart = ExtraiValorApos(work, "atingir");
      p_bePlus = ExtraiValorApos(work, "entrada +");
   }
   if(StringFind(work, "trailing") >= 0) {
      p_trailingStop = ExtraiValorApos(work, "trailing");
      p_trailingStep = 10; // Default step
   }
   if(StringFind(work, "depois das") >= 0 || StringFind(work, "início") >= 0) {
      int h=0, m=0;
      if(StringFind(work, "depois das") >= 0) ExtraiHora(work, "depois das", h, m);
      else ExtraiHora(work, "início", h, m);
      p_startTime = StringFormat("%02d:%02d", h, m);
   }
   if(StringFind(work, "cada") >= 0) {
      p_frequency = ExtraiTimeframe(work, "cada");
   }
   if(StringFind(work, "martingale") >= 0) p_useMartingale = true;
   if(StringFind(work, "notícias") >= 0) {
      double val = ExtraiValorApos(work, "notícias");
      if(val > 0) p_newsVetoMinutes = (int)val;
   }

   // 2. Split rules into segments by intent (Compra/Venda)
   string segments[];
   StringSplit(work, '.', segments);
   Signal currentIntent = NONE;

   for(int i=0; i<ArraySize(segments) && nRules < MAX_RULES; i++) {
      string seg = segments[i];
      if(StringFind(seg, "compra") >= 0) currentIntent = BUY;
      else if(StringFind(seg, "vende") >= 0) currentIntent = SELL;

      if(currentIntent == NONE) continue;

      // MA Rule
      if(StringFind(seg, "média") >= 0) {
         rules[nRules].active = True;
         rules[nRules].type = RT_MA;
         rules[nRules].intent = currentIntent;
         rules[nRules].tf = ExtraiTimeframe(seg, "no");
         if(rules[nRules].tf == PERIOD_CURRENT) rules[nRules].tf = p_frequency;
         rules[nRules].p1 = (int)ExtraiValorApos(seg, "média de");
         if(rules[nRules].p1 == 0) rules[nRules].p1 = 20; // Default
         rules[nRules].handle1 = iMA(_Symbol, rules[nRules].tf, rules[nRules].p1, 0, MODE_EMA, PRICE_CLOSE);
         if(rules[nRules].handle1 != INVALID_HANDLE) nRules++;
      }

      // RSI Rule
      if(StringFind(seg, "rsi") >= 0 && nRules < MAX_RULES) {
         rules[nRules].active = True;
         rules[nRules].type = RT_RSI;
         rules[nRules].intent = currentIntent;
         rules[nRules].tf = ExtraiTimeframe(seg, "no");
         if(rules[nRules].tf == PERIOD_CURRENT) rules[nRules].tf = p_frequency;

         int cursor = StringFind(seg, "rsi");
         rules[nRules].p1 = (int)ExtraiNumero(seg, cursor); // Period
         if(rules[nRules].p1 == 0) rules[nRules].p1 = 14;

         double threshold = ExtraiNumero(seg, cursor); // Threshold
         if(threshold == 0) threshold = (currentIntent == BUY) ? 55 : 45;
         rules[nRules].d1 = threshold;

         rules[nRules].handle1 = iRSI(_Symbol, rules[nRules].tf, rules[nRules].p1, PRICE_CLOSE);
         if(rules[nRules].handle1 != INVALID_HANDLE) nRules++;
      }

      // Stoch Rule
      if(StringFind(seg, "estocástico") >= 0 && nRules < MAX_RULES) {
         rules[nRules].active = True;
         rules[nRules].type = RT_STOCH;
         rules[nRules].intent = currentIntent;
         rules[nRules].tf = ExtraiTimeframe(seg, "no");
         if(rules[nRules].tf == PERIOD_CURRENT) rules[nRules].tf = p_frequency;

         int cursor = StringFind(seg, "estocástico");
         rules[nRules].p1 = (int)ExtraiNumero(seg, cursor); // K
         if(rules[nRules].p1 == 0) rules[nRules].p1 = 5;
         rules[nRules].p2 = (int)ExtraiNumero(seg, cursor); // D
         if(rules[nRules].p2 == 0) rules[nRules].p2 = 3;
         rules[nRules].p3 = (int)ExtraiNumero(seg, cursor); // Slowing
         if(rules[nRules].p3 == 0) rules[nRules].p3 = 3;

         rules[nRules].handle1 = iStochastic(_Symbol, rules[nRules].tf, rules[nRules].p1, rules[nRules].p2, rules[nRules].p3, MODE_SMA, STO_LOWHIGH);
         if(rules[nRules].handle1 != INVALID_HANDLE) nRules++;
      }

      // BB Rule
      if(StringFind(seg, "bollinger") >= 0 && nRules < MAX_RULES) {
         rules[nRules].active = True;
         rules[nRules].type = RT_BB;
         rules[nRules].intent = currentIntent;
         rules[nRules].tf = ExtraiTimeframe(seg, "no");
         if(rules[nRules].tf == PERIOD_CURRENT) rules[nRules].tf = p_frequency;

         int cursor = StringFind(seg, "bollinger");
         rules[nRules].p1 = (int)ExtraiNumero(seg, cursor); // Period
         if(rules[nRules].p1 == 0) rules[nRules].p1 = 20;
         rules[nRules].d1 = ExtraiNumero(seg, cursor); // Deviation
         if(rules[nRules].d1 == 0) rules[nRules].d1 = 2.0;

         rules[nRules].handle1 = iBands(_Symbol, rules[nRules].tf, rules[nRules].p1, 0, rules[nRules].d1, PRICE_CLOSE);
         if(rules[nRules].handle1 != INVALID_HANDLE) nRules++;
      }

      // Daily Breakout
      if(StringFind(seg, "romper") >= 0 && StringFind(seg, "dia") >= 0 && nRules < MAX_RULES) {
         rules[nRules].active = True;
         rules[nRules].type = RT_DAILYBREAK;
         rules[nRules].intent = currentIntent;
         nRules++;
      }
   }

   GravaLog("Estratégia interpretada: " + IntegerToString(nRules) + " regras ativas.");
}

//--- NLP Utils
double ExtraiValorApos(string text, string keyword) {
   int pos = StringFind(text, keyword);
   if(pos < 0) return 0;
   int cursor = pos + StringLen(keyword);
   return ExtraiNumero(text, cursor);
}

double ExtraiNumero(string text, int &cursor) {
   string res = "";
   bool found = false;
   int i = cursor;
   while(i < StringLen(text)) {
      ushort c = StringGetCharacter(text, i);
      if((c >= '0' && c <= '9') || c == '.' || c == ',') {
         if(c == ',') c = '.';
         res += ShortToString(c);
         found = true;
      } else if(found) {
         cursor = i;
         break;
      }
      i++;
   }
   if(!found) cursor = i;
   return StringToDouble(res);
}

void ExtraiHora(string text, string keyword, int &h, int &m) {
   int pos = StringFind(text, keyword);
   int cursor = pos + StringLen(keyword);
   h = (int)ExtraiNumero(text, cursor);
   int hPos = StringFind(text, "h", pos);
   if(hPos >= 0) {
      int mCursor = hPos + 1;
      m = (int)ExtraiNumero(text, mCursor);
   }
}

ENUM_TIMEFRAMES ExtraiTimeframe(string text, string keyword) {
   int pos = StringFind(text, keyword);
   if(pos < 0) return PERIOD_CURRENT;
   if(StringFind(text, "m15", pos) >= 0) return PERIOD_M15;
   if(StringFind(text, "m5", pos) >= 0) return PERIOD_M5;
   if(StringFind(text, "m1", pos) >= 0) return PERIOD_M1;
   if(StringFind(text, "h1", pos) >= 0) return PERIOD_H1;
   if(StringFind(text, "d1", pos) >= 0) return PERIOD_D1;
   if(StringFind(text, "minutos", pos) >= 0) {
      int cursor = pos;
      int val = (int)ExtraiNumero(text, cursor);
      if(val == 15) return PERIOD_M15;
      if(val == 5) return PERIOD_M5;
      if(val == 1) return PERIOD_M1;
   }
   return PERIOD_CURRENT;
}

//+------------------------------------------------------------------+
//| Signal Evaluation                                                |
//+------------------------------------------------------------------+
Signal AvaliaTudo()
{
   int buyVotes = 0;
   int buyRules = 0;
   int sellVotes = 0;
   int sellRules = 0;

   for(int i=0; i<nRules; i++) {
      if(!rules[i].active) continue;

      Signal res = AvaliaRegra(rules[i]);

      if(rules[i].intent == BUY) {
         buyRules++;
         if(res == BUY) buyVotes++;
      } else if(rules[i].intent == SELL) {
         sellRules++;
         if(res == SELL) sellVotes++;
      }
   }

   // Confluence: All rules for a direction must agree
   if(buyRules > 0 && buyVotes == buyRules) return BUY;
   if(sellRules > 0 && sellVotes == sellRules) return SELL;

   return NONE;
}

Signal AvaliaRegra(Rule &r)
{
   if(!r.active) return NONE;

   switch(r.type) {
      case RT_MA: {
         double ma1 = GetBufferValue(r.handle1, 0, 1);
         double ma2 = GetBufferValue(r.handle1, 0, 2);
         double price1 = iClose(_Symbol, r.tf, 1);
         double price2 = iClose(_Symbol, r.tf, 2);

         if(price2 < ma2 && price1 > ma1) return BUY;
         if(price2 > ma2 && price1 < ma1) return SELL;
         break;
      }

      case RT_RSI: {
         double rsi1 = GetBufferValue(r.handle1, 0, 1);
         double rsi2 = GetBufferValue(r.handle1, 0, 2);

         if(r.intent == BUY && rsi2 < r.d1 && rsi1 > r.d1) return BUY;
         if(r.intent == SELL && rsi2 > r.d1 && rsi1 < r.d1) return SELL;
         break;
      }

      case RT_STOCH: {
         double k1 = GetBufferValue(r.handle1, 0, 1);
         double d1 = GetBufferValue(r.handle1, 1, 1);
         double k2 = GetBufferValue(r.handle1, 0, 2);
         double d2 = GetBufferValue(r.handle1, 1, 2);

         if(k2 < d2 && k1 > d1) return BUY;
         if(k2 > d2 && k1 < d1) return SELL;
         break;
      }

      case RT_BB: {
         double upper = GetBufferValue(r.handle1, 1, 1);
         double lower = GetBufferValue(r.handle1, 2, 1);
         double close = iClose(_Symbol, r.tf, 1);

         if(close < lower) return BUY;
         if(close > upper) return SELL;
         break;
      }

      case RT_DAILYBREAK: {
         double hi = iHigh(_Symbol, PERIOD_D1, 1);
         double lo = iLow(_Symbol, PERIOD_D1, 1);
         double close = iClose(_Symbol, r.tf, 0);

         if(close > hi) return BUY;
         if(close < lo) return SELL;
         break;
      }

      case RT_DELTA: {
         MqlTick ticks[];
         int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, TimeCurrent() - r.p1, TimeCurrent());
         long buyVol = 0, sellVol = 0;
         for(int i=0; i<n; i++) {
            if((ticks[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buyVol += (long)ticks[i].volume;
            else if((ticks[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sellVol += (long)ticks[i].volume;
         }
         long delta = buyVol - sellVol;
         if(delta > r.p2) return BUY;
         if(delta < -r.p2) return SELL;
         break;
      }

      case RT_AI: {
         double atr = GetBufferValue(r.handle1, 0, 1);
         double body = MathAbs(iClose(_Symbol, r.tf, 1) - iOpen(_Symbol, r.tf, 1));
         bool bullish = iClose(_Symbol, r.tf, 1) > iOpen(_Symbol, r.tf, 1);
         if(body > 1.5 * atr) return bullish ? BUY : SELL;
         break;
      }
   }

   return NONE;
}

double GetBufferValue(int handle, int buffer, int shift)
{
   double val[];
   ArraySetAsSeries(val, true);
   if(CopyBuffer(handle, buffer, shift, 1, val) > 0) return val[0];
   return 0;
}

//+------------------------------------------------------------------+
//| Order Execution                                                  |
//+------------------------------------------------------------------+
void EnviaOrdem(string tipo, double lote)
{
   if(PositionsTotal() >= p_maxTrades) return;

   double price = (tipo == "BUY") ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0, tp = 0;

   if(tipo == "BUY") {
      sl = (p_stopPoints > 0) ? price - p_stopPoints * _Point : 0;
      tp = (p_takePoints > 0) ? price + p_takePoints * _Point : 0;
      if(m_trade.Buy(lote, _Symbol, price, sl, tp, "MT-LiveExecutor Entry")) {
         GravaLog("Compra executada: " + DoubleToString(lote, 2) + " lotes.");
         SendNotification("MT-LiveExecutor: Compra executada.");
      }
   } else {
      sl = (p_stopPoints > 0) ? price + p_stopPoints * _Point : 0;
      tp = (p_takePoints > 0) ? price - p_takePoints * _Point : 0;
      if(m_trade.Sell(lote, _Symbol, price, sl, tp, "MT-LiveExecutor Entry")) {
         GravaLog("Venda executada: " + DoubleToString(lote, 2) + " lotes.");
         SendNotification("MT-LiveExecutor: Venda executada.");
      }
   }
}

double CalculaLote(double risco)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(p_stopPoints <= 0 || tickValue <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double riskAmount = balance * (risco / 100.0);
   double lot = riskAmount / (p_stopPoints * (tickValue / (tickSize / _Point)));

   if(p_useMartingale) {
      // Logic to check last trade and double if loss
      HistorySelect(TimeCurrent() - 86400, TimeCurrent());
      int total = HistoryDealsTotal();
      for(int i=total-1; i>=0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) lot *= 2.0;
            break;
         }
      }
   }

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / step) * step;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return lot;
}

void GerenciaPosicoes()
{
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(m_pos.SelectByIndex(i)) {
         if(m_pos.Symbol() == _Symbol && m_pos.Magic() == EA_MAGIC) {

            double openPrice = m_pos.PriceOpen();
            double currentPrice = (m_pos.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double currentSL = m_pos.StopLoss();
            double diffPoints = MathAbs(currentPrice - openPrice) / _Point;

            // Breakeven
            if(p_beStart > 0 && diffPoints >= p_beStart) {
               double newSL = (m_pos.PositionType() == POSITION_TYPE_BUY) ? openPrice + p_bePlus * _Point : openPrice - p_bePlus * _Point;
               if(currentSL == 0 || (m_pos.PositionType() == POSITION_TYPE_BUY && newSL > currentSL) || (m_pos.PositionType() == POSITION_TYPE_SELL && newSL < currentSL)) {
                  m_trade.PositionModify(m_pos.Ticket(), newSL, m_pos.TakeProfit());
               }
            }

            // Trailing Stop
            if(p_trailingStop > 0 && diffPoints >= p_trailingStop) {
               double newSL = (m_pos.PositionType() == POSITION_TYPE_BUY) ? currentPrice - p_trailingStop * _Point : currentPrice + p_trailingStop * _Point;
               if(currentSL == 0 || (m_pos.PositionType() == POSITION_TYPE_BUY && newSL > currentSL + p_trailingStep * _Point) || (m_pos.PositionType() == POSITION_TYPE_SELL && newSL < currentSL - p_trailingStep * _Point)) {
                  m_trade.PositionModify(m_pos.Ticket(), newSL, m_pos.TakeProfit());
               }
            }
         }
      }
   }
}

bool AguardaNoticias()
{
   if(!FileIsExist("news_veto.txt")) return false;
   int handle = FileOpen("news_veto.txt", FILE_READ | FILE_TXT);
   if(handle == INVALID_HANDLE) return false;
   string content = FileReadString(handle);
   FileClose(handle);
   return (content == "VETO");
}

bool IsTimeAllowed()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string currentTime = StringFormat("%02d:%02d", dt.hour, dt.min);
   return (currentTime >= p_startTime);
}
