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
#include <Indicators\Indicators.mqh>

// --- Defines
#define MAX_RULES 20
#define LOG_FILE "MT_LiveExecutor_Log.txt"
#define STATE_FILE "MT_LiveExecutor_State.csv"
#define PROMPT_FILE "prompt.txt"
#define NEWS_VETO_FILE "news_veto.txt"
#define CALENDAR_FILE "calendar.txt"

// --- Enums
enum Signal { BUY = 1, SELL = -1, NONE = 0 };
enum RuleType { RT_MA, RT_RSI, RT_STOCH, RT_BB, RT_DAILYBREAK, RT_DELTA, RT_VOL, RT_AMA, RT_BAR2, RT_RELATIVE, RT_AI };

// --- Structs
struct Rule
{
   bool        active;
   RuleType    type;
   Signal      intent;
   ENUM_TIMEFRAMES tf;
   int         p1, p2, p3;
   double      d1, d2;
   string      s1;
   int         handle1, handle2;

   void Reset()
   {
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

// --- Globals
Rule rules[MAX_RULES];
int nRules = 0;
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symInfo;
CAccountInfo accInfo;

// Strategy Parameters
double p_riskPercent = 1.0;
int p_stopPoints = 300;
int p_takePoints = 500;
int p_maxTrades = 3;
string p_startTime = "10:00";
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
bool p_useMartingale = false;
int p_beStart = 0;
int p_bePlus = 0;
int p_trailingStop = 0;
int p_trailingStep = 0;
int p_newsVetoBuffer = 20;

datetime lastPromptUpdate = 0;
datetime lastBar = 0;
datetime lastAI = 0;
datetime lastCSVUpdate = 0;

// --- Event Handlers
int OnInit()
{
   EventSetTimer(1);
   symInfo.Name(_Symbol);
   trade.SetExpertMagicNumber(123456);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   for(int i=0; i<MAX_RULES; i++) rules[i].Reset();
}

void OnTick()
{
   // Position management on every tick
   GerenciaPosicoes();

   // State persistence throttled to 5 seconds
   if(TimeCurrent() - lastCSVUpdate >= 5)
   {
      GravaCSV();
      lastCSVUpdate = TimeCurrent();
   }

   // Signal evaluation on new bar
   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar != lastBar)
   {
      Signal s = AvaliaTudo();
      if(s != NONE) EnviaOrdem(s);
      lastBar = currentBar;
   }
}

void OnTimer()
{
   // Check for prompt updates
   long lastMod = FileGetInteger(PROMPT_FILE, FILE_MODIFY_DATE);
   if(lastMod > lastPromptUpdate)
   {
      InterpretaPrompt();
      lastPromptUpdate = (datetime)lastMod;
   }

   // AIOptimizer hourly
   if(TimeCurrent() - lastAI >= 3600)
   {
      AIOptimizer();
      lastAI = TimeCurrent();
   }
}

// --- NLP / Parser Functions
void InterpretaPrompt()
{
   ResetStrategy();
   int handle = FileOpen(PROMPT_FILE, FILE_READ|FILE_TXT|FILE_ANSI);
   if(handle == INVALID_HANDLE) return;

   string prompt = "";
   while(!FileIsEnding(handle)) prompt += FileReadString(handle);
   FileClose(handle);

   string work = prompt;
   StringToLower(work);

   // Global params
   p_riskPercent = ExtraiValorApos(work, "risco", p_riskPercent);
   p_stopPoints = (int)ExtraiValorApos(work, "stop", p_stopPoints);
   p_takePoints = (int)ExtraiValorApos(work, "take", p_takePoints);
   p_maxTrades = (int)ExtraiValorApos(work, "máximo", p_maxTrades);

   if(StringFind(work, "martingale") >= 0) p_useMartingale = true;

   p_beStart = (int)ExtraiValorApos(work, "atingir", p_beStart);
   p_bePlus = (int)ExtraiValorApos(work, "entrada", p_bePlus);

   int trailPos = StringFind(work, "trailing");
   if(trailPos >= 0)
   {
      int cursor = trailPos + 8;
      p_trailingStop = (int)ExtraiNumero(work, cursor);
      p_trailingStep = (int)ExtraiNumero(work, cursor);
      if(p_trailingStep == 0) p_trailingStep = 10;
   }

   // Timeframe
   if(StringFind(work, "15 min") >= 0) p_frequency = PERIOD_M15;
   else if(StringFind(work, "5 min") >= 0) p_frequency = PERIOD_M5;
   else if(StringFind(work, "1 min") >= 0) p_frequency = PERIOD_M1;
   else if(StringFind(work, "1h") >= 0) p_frequency = PERIOD_H1;

   // Start time
   int startPos = StringFind(work, "depois das");
   if(startPos >= 0)
   {
      int cursor = startPos + 10;
      int h = (int)ExtraiNumero(work, cursor);
      p_startTime = IntegerToString(h) + ":00";
   }

   // Split into segments by "."
   string segments[];
   StringSplit(work, '.', segments);
   Signal currentIntent = NONE;

   for(int i=0; i<ArraySize(segments); i++)
   {
      string seg = segments[i];
      if(StringFind(seg, "compra") >= 0) currentIntent = BUY;
      else if(StringFind(seg, "vende") >= 0) currentIntent = SELL;

      if(currentIntent != NONE) AddRule(seg, currentIntent);
   }

   GravaLog("Estratégia atualizada: " + IntegerToString(nRules) + " regras.");
}

void AddRule(string txt, Signal intent)
{
   if(StringFind(txt, "média") >= 0)
   {
      if(nRules >= MAX_RULES) return;
      Rule r; r.Reset();
      r.intent = intent;
      r.tf = p_frequency;
      r.type = RT_MA;
      int pos = StringFind(txt, "média");
      int cursor = pos + 5;
      r.p1 = (int)ExtraiNumero(txt, cursor);
      if(r.p1 == 0) r.p1 = 20;
      r.handle1 = iMA(_Symbol, r.tf, r.p1, 0, MODE_SMA, PRICE_CLOSE);
      if(r.handle1 != INVALID_HANDLE) { rules[nRules] = r; rules[nRules].active = true; nRules++; }
   }

   if(StringFind(txt, "rsi") >= 0)
   {
      if(nRules >= MAX_RULES) return;
      Rule r; r.Reset();
      r.intent = intent;
      r.tf = p_frequency;
      r.type = RT_RSI;
      int pos = StringFind(txt, "rsi");
      int cursor = pos + 3;
      r.p1 = (int)ExtraiNumero(txt, cursor);
      if(r.p1 == 0) r.p1 = 14;
      r.d1 = ExtraiNumero(txt, cursor);
      if(r.d1 == 0) r.d1 = (intent == BUY) ? 30 : 70;
      r.handle1 = iRSI(_Symbol, r.tf, r.p1, PRICE_CLOSE);
      if(r.handle1 != INVALID_HANDLE) { rules[nRules] = r; rules[nRules].active = true; nRules++; }
   }

   if(StringFind(txt, "estocástico") >= 0 || StringFind(txt, "stoch") >= 0)
   {
      if(nRules >= MAX_RULES) return;
      Rule r; r.Reset();
      r.intent = intent;
      r.tf = p_frequency;
      r.type = RT_STOCH;
      int pos = StringFind(txt, "stoch");
      if(pos < 0) pos = StringFind(txt, "estocástico");
      int cursor = pos + 5;
      r.p1 = (int)ExtraiNumero(txt, cursor); if(r.p1 == 0) r.p1 = 5;
      r.p2 = (int)ExtraiNumero(txt, cursor); if(r.p2 == 0) r.p2 = 3;
      r.p3 = (int)ExtraiNumero(txt, cursor); if(r.p3 == 0) r.p3 = 3;
      r.handle1 = iStochastic(_Symbol, r.tf, r.p1, r.p2, r.p3, MODE_SMA, STO_LOWHIGH);
      if(r.handle1 != INVALID_HANDLE) { rules[nRules] = r; rules[nRules].active = true; nRules++; }
   }

   if(StringFind(txt, "bollinger") >= 0 || StringFind(txt, "bb") >= 0)
   {
      if(nRules >= MAX_RULES) return;
      Rule r; r.Reset();
      r.intent = intent;
      r.tf = p_frequency;
      r.type = RT_BB;
      int pos = StringFind(txt, "bb");
      if(pos < 0) pos = StringFind(txt, "bollinger");
      int cursor = pos + 2;
      r.p1 = (int)ExtraiNumero(txt, cursor); if(r.p1 == 0) r.p1 = 20;
      r.d1 = ExtraiNumero(txt, cursor); if(r.d1 == 0) r.d1 = 2.0;
      r.handle1 = iBands(_Symbol, r.tf, r.p1, 0, r.d1, PRICE_CLOSE);
      if(r.handle1 != INVALID_HANDLE) { rules[nRules] = r; rules[nRules].active = true; nRules++; }
   }

   if(StringFind(txt, "diário") >= 0 || StringFind(txt, "daily") >= 0)
   {
      if(nRules >= MAX_RULES) return;
      Rule r; r.Reset();
      r.intent = intent;
      r.type = RT_DAILYBREAK;
      rules[nRules] = r; rules[nRules].active = true; nRules++;
   }

   if(StringFind(txt, "volume") >= 0)
   {
      if(nRules >= MAX_RULES) return;
      Rule r; r.Reset();
      r.intent = intent;
      r.tf = p_frequency;
      r.type = RT_VOL;
      int pos = StringFind(txt, "volume");
      int cursor = pos + 6;
      r.p1 = (int)ExtraiNumero(txt, cursor); if(r.p1 == 0) r.p1 = 12;
      rules[nRules] = r; rules[nRules].active = true; nRules++;
   }
}

double ExtraiValorApos(string txt, string keyword, double defaultVal)
{
   int pos = StringFind(txt, keyword);
   if(pos < 0) return defaultVal;
   int cursor = pos + StringLen(keyword);
   double val = ExtraiNumero(txt, cursor);
   return (val > 0) ? val : defaultVal;
}

double ExtraiNumero(string txt, int &cursor)
{
   string numStr = "";
   bool found = false;
   for(int i=cursor; i<StringLen(txt); i++)
   {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.' || c == ',')
      {
         if(c == ',') c = '.';
         numStr += ShortToString(c);
         found = true;
      }
      else if(found)
      {
         cursor = i;
         break;
      }
   }
   return StringToDouble(numStr);
}

void ResetStrategy()
{
   for(int i=0; i<MAX_RULES; i++) rules[i].Reset();
   nRules = 0;
}

// --- Signal / Rule Evaluation Logic
Signal AvaliaTudo()
{
   if(!IsTimeAllowed()) return NONE;
   if(AguardaNoticias()) return NONE;

   int buyVotes = 0;
   int sellVotes = 0;
   int buyRules = 0;
   int sellRules = 0;

   for(int i=0; i<nRules; i++)
   {
      if(!rules[i].active) continue;
      Signal s = AvaliaRegra(rules[i]);

      if(rules[i].intent == BUY)
      {
         buyRules++;
         if(s == BUY) buyVotes++;
      }
      else if(rules[i].intent == SELL)
      {
         sellRules++;
         if(s == SELL) sellVotes++;
      }
   }

   if(buyRules > 0 && buyVotes == buyRules) return BUY;
   if(sellRules > 0 && sellVotes == sellRules) return SELL;

   return NONE;
}

Signal AvaliaRegra(Rule &r)
{
   double val1_b1, val1_b2; // Buffer 1 at bar 1 and bar 2
   double val2_b1, val2_b2; // Buffer 2 or Price at bar 1 and bar 2

   switch(r.type)
   {
      case RT_MA:
         val1_b1 = GetBufferValue(r.handle1, 0, 1);
         val1_b2 = GetBufferValue(r.handle1, 0, 2);
         val2_b1 = iClose(_Symbol, r.tf, 1);
         val2_b2 = iClose(_Symbol, r.tf, 2);
         // Crossing logic: Price was below and is now above
         if(r.intent == BUY && val2_b2 <= val1_b2 && val2_b1 > val1_b1) return BUY;
         if(r.intent == SELL && val2_b2 >= val1_b2 && val2_b1 < val1_b1) return SELL;
         break;

      case RT_RSI:
         val1_b1 = GetBufferValue(r.handle1, 0, 1);
         val1_b2 = GetBufferValue(r.handle1, 0, 2);
         if(r.intent == BUY && val1_b2 <= r.d1 && val1_b1 > r.d1) return BUY;
         if(r.intent == SELL && val1_b2 >= r.d1 && val1_b1 < r.d1) return SELL;
         break;

      case RT_STOCH:
         val1_b1 = GetBufferValue(r.handle1, 0, 1); // %K
         val1_b2 = GetBufferValue(r.handle1, 0, 2);
         val2_b1 = GetBufferValue(r.handle1, 1, 1); // %D
         val2_b2 = GetBufferValue(r.handle1, 1, 2);
         if(r.intent == BUY && val1_b2 <= val2_b2 && val1_b1 > val2_b1) return BUY;
         if(r.intent == SELL && val1_b2 >= val2_b2 && val1_b1 < val2_b1) return SELL;
         break;

      case RT_BB:
         val1_b1 = GetBufferValue(r.handle1, 2, 1); // Lower
         val1_b2 = GetBufferValue(r.handle1, 1, 1); // Upper
         val2_b1 = iClose(_Symbol, r.tf, 1);
         if(r.intent == BUY && val2_b1 < val1_b1) return BUY;
         if(r.intent == SELL && val2_b1 > val1_b2) return SELL;
         break;

      case RT_DAILYBREAK:
         val1_b1 = iHigh(_Symbol, PERIOD_D1, 1); // Prev Day High
         val1_b2 = iLow(_Symbol, PERIOD_D1, 1);  // Prev Day Low
         val2_b1 = iClose(_Symbol, r.tf, 1);
         if(r.intent == BUY && val2_b1 > val1_b1) return BUY;
         if(r.intent == SELL && val2_b1 < val1_b2) return SELL;
         break;

      case RT_VOL:
         double vol[]; ArraySetAsSeries(vol, true);
         if(CopyVolume(_Symbol, r.tf, 1, r.p1, vol) >= r.p1)
         {
            double maxVol = 0;
            for(int i=1; i<r.p1; i++) if(vol[i] > maxVol) maxVol = vol[i];
            if(vol[0] > maxVol) return (r.intent == BUY) ? BUY : SELL;
         }
         break;
   }
   return NONE;
}

double GetBufferValue(int handle, int buffer, int shift)
{
   double arr[];
   ArraySetAsSeries(arr, true);
   if(CopyBuffer(handle, buffer, shift, 1, arr) > 0) return arr[0];
   return 0;
}

bool AguardaNoticias()
{
   // Check simple veto file
   int handle = FileOpen(NEWS_VETO_FILE, FILE_READ|FILE_TXT|FILE_ANSI);
   if(handle != INVALID_HANDLE)
   {
      string content = FileReadString(handle);
      FileClose(handle);
      StringToUpper(content);
      if(StringFind(content, "VETO") >= 0) return true;
   }

   // Check calendar for upcoming high-impact events
   handle = FileOpen(CALENDAR_FILE, FILE_READ|FILE_TXT|FILE_ANSI);
   if(handle != INVALID_HANDLE)
   {
      while(!FileIsEnding(handle))
      {
         string line = FileReadString(handle);
         if(StringFind(line, "[HIGH]") >= 0)
         {
            // Simple logic: if line contains current HH:MM, veto
            MqlDateTime dt;
            TimeToStruct(TimeCurrent(), dt);
            string now = StringFormat("%02d:%02d", dt.hour, dt.min);
            if(StringFind(line, now) >= 0) { FileClose(handle); return true; }
         }
      }
      FileClose(handle);
   }

   return false;
}

bool IsTimeAllowed()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string now = StringFormat("%02d:%02d", dt.hour, dt.min);
   return (now >= p_startTime);
}

// --- Trade / Position Management
void EnviaOrdem(Signal s)
{
   if(PositionsTotal() >= p_maxTrades) return;

   double lote = CalculaLote(p_riskPercent);
   double sl = 0, tp = 0;
   double price = 0;

   if(s == BUY)
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl = price - p_stopPoints * _Point;
      tp = price + p_takePoints * _Point;
      if(trade.Buy(lote, _Symbol, price, sl, tp))
         GravaLog("Compra enviada: " + DoubleToString(lote, 2) + " SL: " + DoubleToString(sl, _Digits));
   }
   else if(s == SELL)
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl = price + p_stopPoints * _Point;
      tp = price - p_takePoints * _Point;
      if(trade.Sell(lote, _Symbol, price, sl, tp))
         GravaLog("Venda enviada: " + DoubleToString(lote, 2) + " SL: " + DoubleToString(sl, _Digits));
   }
}

void GerenciaPosicoes()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

         double priceCurrent = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double priceOpen = PositionGetDouble(POSITION_PRICE_OPEN);
         double sl = PositionGetDouble(POSITION_SL);

         double profitPoints = MathAbs(priceCurrent - priceOpen) / _Point;

         // Break-even
         if(p_beStart > 0)
         {
            if(profitPoints >= p_beStart)
            {
               double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? priceOpen + p_bePlus * _Point : priceOpen - p_bePlus * _Point;
               if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && sl < newSL) || (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (sl > newSL || sl == 0)))
               {
                  trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
                  continue; // Skip trailing for this tick if BE adjusted
               }
            }
         }

         // Trailing Stop
         if(p_trailingStop > 0)
         {
            if(profitPoints >= p_trailingStop)
            {
               double newSL = 0;
               if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
               {
                  newSL = priceCurrent - p_trailingStop * _Point;
                  if(newSL > sl + p_trailingStep * _Point)
                     trade.PositionModify(ticket, NormalizeDouble(newSL, _Digits), PositionGetDouble(POSITION_TP));
               }
               else
               {
                  newSL = priceCurrent + p_trailingStop * _Point;
                  if(sl == 0 || newSL < sl - p_trailingStep * _Point)
                     trade.PositionModify(ticket, NormalizeDouble(newSL, _Digits), PositionGetDouble(POSITION_TP));
               }
            }
         }
      }
   }
}

double CalculaLote(double riscoPercent)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = equity * (riscoPercent / 100.0);

   if(p_useMartingale)
   {
      if(HistorySelect(0, TimeCurrent()))
      {
         int total = HistoryDealsTotal();
         for(int i=total-1; i>=0; i--)
         {
            ulong ticket = HistoryDealGetTicket(i);
            if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == 123456)
            {
               if(HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT)
               {
                  if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) riskAmount *= 2.0;
                  break;
               }
            }
         }
      }
   }

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(p_stopPoints == 0) return 0.01;

   double lote = riskAmount / (p_stopPoints * (tickValue / (tickSize / _Point)));
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lote = MathFloor(lote / step) * step;

   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(lote < minVol) lote = minVol;
   if(lote > maxVol) lote = maxVol;

   return NormalizeDouble(lote, 2);
}

void GravaLog(string texto)
{
   int handle = FileOpen(LOG_FILE, FILE_WRITE|FILE_READ|FILE_TXT|FILE_ANSI);
   if(handle != INVALID_HANDLE)
   {
      FileSeek(handle, 0, SEEK_END);
      FileWriteString(handle, TimeToString(TimeCurrent()) + ": " + texto + "\r\n");
      FileClose(handle);
   }
   Print(texto);
}

void GravaCSV()
{
   int handle = FileOpen(STATE_FILE, FILE_WRITE|FILE_CSV|FILE_ANSI);
   if(handle != INVALID_HANDLE)
   {
      FileWrite(handle, "Ticket", "Symbol", "Type", "Lots", "Profit");
      for(int i=0; i<PositionsTotal(); i++)
      {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelectByTicket(ticket))
         {
            FileWrite(handle, ticket, PositionGetString(POSITION_SYMBOL), (long)PositionGetInteger(POSITION_TYPE), PositionGetDouble(POSITION_VOLUME), PositionGetDouble(POSITION_PROFIT));
         }
      }
      FileClose(handle);
   }
}

void AIOptimizer()
{
   double winRate = CalculaStats();
   if(winRate < 40.0 && winRate >= 0)
   {
      p_riskPercent *= 0.5;
      GravaLog("Otimizador IA: Win Rate baixo (" + DoubleToString(winRate, 1) + "%). Risco reduzido para " + DoubleToString(p_riskPercent, 2) + "%");
   }
}

double CalculaStats()
{
   if(!HistorySelect(0, TimeCurrent())) return -1;
   int deals = HistoryDealsTotal();
   int count = 0, wins = 0;

   for(int i=deals-1; i>=0 && count < 10; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == 123456)
      {
         if(HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT)
         {
            count++;
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) > 0) wins++;
         }
      }
   }
   return (count > 0) ? (wins * 100.0 / count) : -1;
}
