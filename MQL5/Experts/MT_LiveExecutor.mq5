//+------------------------------------------------------------------+
//|                                             MT_LiveExecutor.mq5 |
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

// --- Definitions
#define EA_MAGIC 123456
#define MAX_RULES 20

// --- Rule Types
#define RT_MA          1
#define RT_RSI         2
#define RT_STOCH       3
#define RT_BB          4
#define RT_DAILYBREAK  5
#define RT_DELTA       6
#define RT_VOL         7
#define RT_AMA         8
#define RT_BAR2        9
#define RT_RS          10
#define RT_AI          11

// --- Enums
enum Signal {BUY=1, SELL=-1, NONE=0};

// --- Structs
struct Rule
{
   bool     active;
   int      type;
   int      intent; // BUY or SELL
   ENUM_TIMEFRAMES tf;
   int      p1, p2, p3;
   double   d1, d2;
   string   s1;
   int      handle1, handle2;

   void Reset()
   {
      if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease(handle1);
      if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease(handle2);
      active = false;
      type = 0;
      intent = 0;
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

double p_riskPercent = 1.0;
int    p_stopPoints = 300;
int    p_takePoints = 500;
int    p_maxTrades = 3;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
string p_startTime = "00:00";
int    p_beStart = 0;
int    p_bePlus = 0;
int    p_trailingStop = 0;
int    p_trailingStep = 0;
bool   p_useMartingale = false;

CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symInfo;

string logFileName = "MT_LiveExecutor_Log.txt";
string stateFileName = "MT_LiveExecutor_State.csv";
string promptFileName = "prompt.txt";
datetime lastPromptUpdate = 0;
datetime lastStateUpdate = 0;
datetime lastAIUpdate = 0;

// --- Function Prototypes
void InterpretaPrompt(string prompt);
void AddRule(string segment, int intent);
Signal AvaliaTudo();
Signal AvaliaRegra(Rule &r);
void EnviaOrdem(Signal s);
void GerenciaPosicoes();
double CalculaLote();
bool AguardaNoticias();
bool IsTimeAllowed();
void GravaLog(string text);
void GravaCSV();
int PeriodoTexto(string text);
double ExtraiNumero(string text, int &pos);
double ExtraiValorApos(string prompt, string keyword);
double GetBufferValue(int handle, int buffer, int shift);
void ResetStrategy();
void AIOptimizer();
double CalculaStats(string sym, long magic);

// --- NLP Parser Implementation
void InterpretaPrompt(string prompt)
{
   string work = prompt;
   StringToLower(work);
   ResetStrategy();
   GravaLog("Interpretando: " + prompt);

   // Extract Global Parameters
   double v;
   v = ExtraiValorApos(work, "risco"); if(v > 0) p_riskPercent = v;
   v = ExtraiValorApos(work, "stop");  if(v > 0) p_stopPoints = (int)v;
   v = ExtraiValorApos(work, "take");  if(v > 0) p_takePoints = (int)v;
   v = ExtraiValorApos(work, "máximo");if(v > 0) p_maxTrades = (int)v;

   if(StringFind(work, "martingale") >= 0) p_useMartingale = true;

   // Timeframe/Frequency
   if(StringFind(work, "15 min") >= 0 || StringFind(work, "15min") >= 0) p_frequency = PERIOD_M15;
   else if(StringFind(work, "5 min") >= 0 || StringFind(work, "5min") >= 0) p_frequency = PERIOD_M5;
   else if(StringFind(work, "1 min") >= 0 || StringFind(work, "1min") >= 0) p_frequency = PERIOD_M1;
   else if(StringFind(work, "h1") >= 0) p_frequency = PERIOD_H1;

   // Start Time
   int startPos = StringFind(work, "depois das");
   if(startPos < 0) startPos = StringFind(work, "início");
   if(startPos < 0) startPos = StringFind(work, "começar");

   if(startPos >= 0)
   {
      int hPos = StringFind(work, "h", startPos);
      if(hPos > 0)
      {
         int endP = 0;
         double hh = ExtraiNumero(StringSubstr(work, startPos), endP);
         string shh = IntegerToString((int)hh);
         if(StringLen(shh) == 1) shh = "0" + shh;
         p_startTime = shh + ":00";
      }
   }

   // Breakeven/Trailing
   v = ExtraiValorApos(work, "atingir"); if(v > 0) p_beStart = (int)v;
   v = ExtraiValorApos(work, "entrada"); if(v > 0) p_bePlus = (int)v;
   v = ExtraiValorApos(work, "trailing"); if(v > 0) { p_trailingStop = (int)v; p_trailingStep = 10; }

   // Split rules by segments
   string segments[];
   ushort sep = StringGetCharacter(".", 0);
   int nSeg = StringSplit(work, sep, segments);
   if(nSeg <= 1) { // Try splitting by 'compra' or 'vende'
      // This is more complex in MQL5, let's just use the whole string if no dots
      ArrayResize(segments, 1);
      segments[0] = work;
   }

   int currentIntent = NONE;
   for(int i=0; i<ArraySize(segments); i++)
   {
      string seg = segments[i];
      if(StringFind(seg, "compra") >= 0) currentIntent = BUY;
      else if(StringFind(seg, "vende") >= 0) currentIntent = SELL;

      if(currentIntent != NONE) AddRule(seg, currentIntent);
   }
}

void AddRule(string segment, int intent)
{
   string work = segment;

   // MA
   int pMA = StringFind(work, "média");
   if(pMA >= 0)
   {
      if(nRules >= MAX_RULES) return;
      Rule r; r.Reset();
      r.type = RT_MA; r.intent = intent;
      r.tf = (ENUM_TIMEFRAMES)PeriodoTexto(work); if(r.tf == PERIOD_CURRENT) r.tf = p_frequency;
      int pos = pMA + 5;
      r.p1 = (int)ExtraiNumero(work, pos);
      if(r.p1 == 0) r.p1 = 20;
      r.handle1 = iMA(_Symbol, r.tf, r.p1, 0, MODE_SMA, PRICE_CLOSE);

      int pMA2 = StringFind(work, "média", pos);
      if(pMA2 >= 0)
      {
         r.p2 = (int)ExtraiNumero(work, pos);
         r.handle2 = iMA(_Symbol, r.tf, r.p2, 0, MODE_SMA, PRICE_CLOSE);
      }
      if(r.handle1 != INVALID_HANDLE) { r.active = true; rules[nRules++] = r; }
   }

   // RSI
   int pRSI = StringFind(work, "rsi");
   if(pRSI >= 0)
   {
      if(nRules >= MAX_RULES) return;
      Rule r; r.Reset();
      r.type = RT_RSI; r.intent = intent;
      r.tf = (ENUM_TIMEFRAMES)PeriodoTexto(work); if(r.tf == PERIOD_CURRENT) r.tf = p_frequency;
      int pos = pRSI + 3;
      double n1 = ExtraiNumero(work, pos);
      double n2 = ExtraiNumero(work, pos);
      if(n2 == 0) {
         if(n1 >= 40) { r.p1 = 14; r.d1 = n1; }
         else { r.p1 = (int)n1; r.d1 = (intent == BUY ? 30 : 70); }
      } else {
         r.p1 = (int)n1; r.d1 = n2;
      }
      r.handle1 = iRSI(_Symbol, r.tf, r.p1, PRICE_CLOSE);
      if(r.handle1 != INVALID_HANDLE) { r.active = true; rules[nRules++] = r; }
   }

   // Stoch
   if(StringFind(work, "estocástico") >= 0 || StringFind(work, "stoch") >= 0)
   {
      if(nRules >= MAX_RULES) return;
      Rule r; r.Reset();
      r.type = RT_STOCH; r.intent = intent;
      r.tf = (ENUM_TIMEFRAMES)PeriodoTexto(work); if(r.tf == PERIOD_CURRENT) r.tf = p_frequency;
      r.p1 = 5; r.p2 = 3; r.p3 = 3;
      r.handle1 = iStochastic(_Symbol, r.tf, r.p1, r.p2, r.p3, MODE_SMA, STO_LOWHIGH);
      if(r.handle1 != INVALID_HANDLE) { r.active = true; rules[nRules++] = r; }
   }

   // BB
   if(StringFind(work, "bollinger") >= 0 || StringFind(work, "bb") >= 0)
   {
      if(nRules >= MAX_RULES) return;
      Rule r; r.Reset();
      r.type = RT_BB; r.intent = intent;
      r.tf = (ENUM_TIMEFRAMES)PeriodoTexto(work); if(r.tf == PERIOD_CURRENT) r.tf = p_frequency;
      r.p1 = 20; r.d1 = 2.0;
      r.handle1 = iBands(_Symbol, r.tf, r.p1, 0, r.d1, PRICE_CLOSE);
      if(r.handle1 != INVALID_HANDLE) { r.active = true; rules[nRules++] = r; }
   }

   // Daily Break
   if(StringFind(work, "break") >= 0 || StringFind(work, "máxima") >= 0 || StringFind(work, "mínima") >= 0)
   {
      if(nRules >= MAX_RULES) return;
      Rule r; r.Reset();
      r.type = RT_DAILYBREAK; r.intent = intent;
      r.tf = PERIOD_D1; r.active = true; rules[nRules++] = r;
   }

   // AI
   if(StringFind(work, "ia") >= 0 || StringFind(work, "inteligência") >= 0)
   {
      if(nRules >= MAX_RULES) return;
      Rule r; r.Reset();
      r.type = RT_AI; r.intent = intent;
      r.tf = p_frequency;
      r.handle1 = iATR(_Symbol, r.tf, 14);
      if(r.handle1 != INVALID_HANDLE) { r.active = true; rules[nRules++] = r; }
   }
}

double ExtraiNumero(string text, int &pos)
{
   string res = "";
   bool found = false;
   int i;
   for(i = pos; i < StringLen(text); i++)
   {
      ushort c = StringGetCharacter(text, i);
      if((c >= '0' && c <= '9') || c == '.' || c == ',')
      {
         if(c == ',') c = '.';
         res += ShortToString(c);
         found = true;
      }
      else if(found) break;
   }
   pos = i;
   return StringToDouble(res);
}

double ExtraiValorApos(string prompt, string keyword)
{
   int p = StringFind(prompt, keyword);
   if(p < 0) return 0;
   int pos = p + StringLen(keyword);
   return ExtraiNumero(prompt, pos);
}

int PeriodoTexto(string text)
{
   if(StringFind(text, "m15") >= 0) return PERIOD_M15;
   if(StringFind(text, "m5") >= 0 && StringFind(text, "m15") < 0) return PERIOD_M5;
   if(StringFind(text, "m1") >= 0 && StringFind(text, "m15") < 0) return PERIOD_M1;
   if(StringFind(text, "h1") >= 0) return PERIOD_H1;
   if(StringFind(text, "d1") >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

void ResetStrategy()
{
   for(int i=0; i<MAX_RULES; i++) rules[i].Reset();
   nRules = 0;
}

// --- Signal Evaluation and Trading Logic Implementation
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
   if(r.type == RT_MA)
   {
      double ma1_0 = GetBufferValue(r.handle1, 0, 1);
      double ma1_1 = GetBufferValue(r.handle1, 0, 2);

      if(r.handle2 != INVALID_HANDLE)
      {
         double ma2_0 = GetBufferValue(r.handle2, 0, 1);
         double ma2_1 = GetBufferValue(r.handle2, 0, 2);
         if(ma1_1 < ma2_1 && ma1_0 > ma2_0) return BUY;
         if(ma1_1 > ma2_1 && ma1_0 < ma2_0) return SELL;
      }
      else
      {
         double close0 = iClose(_Symbol, r.tf, 1);
         double close1 = iClose(_Symbol, r.tf, 2);
         if(close1 < ma1_1 && close0 > ma1_0) return BUY;
         if(close1 > ma1_1 && close0 < ma1_0) return SELL;
      }
   }
   else if(r.type == RT_RSI)
   {
      double rsi0 = GetBufferValue(r.handle1, 0, 1);
      double rsi1 = GetBufferValue(r.handle1, 0, 2);
      if(r.intent == BUY && rsi1 < r.d1 && rsi0 >= r.d1) return BUY;
      if(r.intent == SELL && rsi1 > r.d1 && rsi0 <= r.d1) return SELL;
   }
   else if(r.type == RT_STOCH)
   {
      double k0 = GetBufferValue(r.handle1, 0, 1);
      double d0 = GetBufferValue(r.handle1, 1, 1);
      double k1 = GetBufferValue(r.handle1, 0, 2);
      double d1 = GetBufferValue(r.handle1, 1, 2);
      if(k1 < d1 && k0 > d0) return BUY;
      if(k1 > d1 && k0 < d0) return SELL;
   }
   else if(r.type == RT_BB)
   {
      double close = iClose(_Symbol, r.tf, 1);
      double lower = GetBufferValue(r.handle1, 2, 1);
      double upper = GetBufferValue(r.handle1, 1, 1);
      if(close < lower) return BUY;
      if(close > upper) return SELL;
   }
   else if(r.type == RT_DAILYBREAK)
   {
      double hi = iHigh(_Symbol, PERIOD_D1, 1);
      double lo = iLow(_Symbol, PERIOD_D1, 1);
      double close = iClose(_Symbol, PERIOD_M1, 0);
      if(close > hi) return BUY;
      if(close < lo) return SELL;
   }
   else if(r.type == RT_AI)
   {
      double atr = GetBufferValue(r.handle1, 0, 1);
      double body = MathAbs(iClose(_Symbol, r.tf, 1) - iOpen(_Symbol, r.tf, 1));
      if(body > 1.5 * atr)
      {
         if(iClose(_Symbol, r.tf, 1) > iOpen(_Symbol, r.tf, 1)) return BUY;
         else return SELL;
      }
   }

   return NONE;
}

void EnviaOrdem(Signal s)
{
   if(s == NONE) return;
   if(PositionsTotal() >= p_maxTrades) return;

   double lote = CalculaLote();
   if(lote <= 0) return;

   double sl = 0, tp = 0;
   double price = 0;

   symInfo.Name(_Symbol);
   symInfo.RefreshRates();

   if(s == BUY)
   {
      price = symInfo.Ask();
      if(p_stopPoints > 0) sl = price - p_stopPoints * _Point;
      if(p_takePoints > 0) tp = price + p_takePoints * _Point;

      for(int i=0; i<3; i++)
      {
         if(trade.Buy(lote, _Symbol, price, sl, tp, "MT-LiveExecutor"))
         {
            GravaLog("Compra executada: " + DoubleToString(lote, 2) + " SL: " + DoubleToString(sl, _Digits) + " TP: " + DoubleToString(tp, _Digits));
            SendNotification("MT-LiveExecutor: Compra em " + _Symbol);
            break;
         }
         int retcode = trade.ResultRetcode();
         if(retcode != TRADE_RETCODE_REQUOTES && retcode != TRADE_RETCODE_OFFQUOTES) break;
         symInfo.RefreshRates();
         price = symInfo.Ask();
      }
   }
   else if(s == SELL)
   {
      price = symInfo.Bid();
      if(p_stopPoints > 0) sl = price + p_stopPoints * _Point;
      if(p_takePoints > 0) tp = price - p_takePoints * _Point;

      for(int i=0; i<3; i++)
      {
         if(trade.Sell(lote, _Symbol, price, sl, tp, "MT-LiveExecutor"))
         {
            GravaLog("Venda executada: " + DoubleToString(lote, 2) + " SL: " + DoubleToString(sl, _Digits) + " TP: " + DoubleToString(tp, _Digits));
            SendNotification("MT-LiveExecutor: Venda em " + _Symbol);
            break;
         }
         int retcode = trade.ResultRetcode();
         if(retcode != TRADE_RETCODE_REQUOTES && retcode != TRADE_RETCODE_OFFQUOTES) break;
         symInfo.RefreshRates();
         price = symInfo.Bid();
      }
   }
}

double CalculaLote()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = equity * (p_riskPercent / 100.0);

   if(p_stopPoints <= 0) return 0.01;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickSize == 0) return 0.01;

   double lot = riskAmount / (p_stopPoints * (tickValue / (tickSize / _Point)));

   if(p_useMartingale)
   {
      HistorySelect(TimeCurrent() - 86400*7, TimeCurrent());
      int total = HistoryDealsTotal();
      for(int i=total-1; i>=0; i--)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC)
         {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            if(profit < 0) lot *= 2.0;
            break;
         }
      }
   }

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / stepLot) * stepLot;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return NormalizeDouble(lot, 2);
}

void GerenciaPosicoes()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) != EA_MAGIC) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

         double currentPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double sl = PositionGetDouble(POSITION_SL);
         double tp = PositionGetDouble(POSITION_TP);
         long type = PositionGetInteger(POSITION_TYPE);

         double profitPoints = (type == POSITION_TYPE_BUY) ? (currentPrice - openPrice) / _Point : (openPrice - currentPrice) / _Point;

         // Breakeven
         if(p_beStart > 0 && profitPoints >= p_beStart)
         {
            double newSL = (type == POSITION_TYPE_BUY) ? openPrice + p_bePlus * _Point : openPrice - p_bePlus * _Point;
            if((type == POSITION_TYPE_BUY && (sl < newSL || sl == 0)) || (type == POSITION_TYPE_SELL && (sl > newSL || sl == 0)))
            {
               trade.PositionModify(ticket, newSL, tp);
               GravaLog("Breakeven acionado para ticket " + IntegerToString(ticket));
            }
         }

         // Trailing Stop
         if(p_trailingStop > 0 && profitPoints >= p_trailingStop)
         {
            double newSL = (type == POSITION_TYPE_BUY) ? currentPrice - p_trailingStop * _Point : currentPrice + p_trailingStop * _Point;
            if((type == POSITION_TYPE_BUY && newSL > sl + p_trailingStep * _Point) || (type == POSITION_TYPE_SELL && (newSL < sl - p_trailingStep * _Point || sl == 0)))
            {
               trade.PositionModify(ticket, newSL, tp);
            }
         }
      }
   }
}

// --- Utility Functions and Event Handlers Implementation
void GravaLog(string text)
{
   int handle = FileOpen(logFileName, FILE_WRITE|FILE_READ|FILE_TXT|FILE_ANSI);
   if(handle != INVALID_HANDLE)
   {
      FileSeek(handle, 0, SEEK_END);
      FileWrite(handle, TimeToString(TimeCurrent()) + ": " + text);
      FileClose(handle);
   }
   Print(text);
}

void GravaCSV()
{
   int handle = FileOpen(stateFileName, FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(handle != INVALID_HANDLE)
   {
      FileWrite(handle, "Ticket", "Symbol", "Type", "OpenPrice", "SL", "TP", "Profit");
      for(int i=0; i<PositionsTotal(); i++)
      {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelectByTicket(ticket))
         {
            if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC)
            {
               FileWrite(handle, ticket, PositionGetString(POSITION_SYMBOL), PositionGetInteger(POSITION_TYPE),
                         PositionGetDouble(POSITION_PRICE_OPEN), PositionGetDouble(POSITION_SL),
                         PositionGetDouble(POSITION_TP), PositionGetDouble(POSITION_PROFIT));
            }
         }
      }
      FileClose(handle);
   }
}

bool AguardaNoticias()
{
   if(FileIsExist("news_veto.txt"))
   {
      int handle = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_ANSI);
      if(handle != INVALID_HANDLE)
      {
         string content = FileReadString(handle);
         FileClose(handle);
         if(content == "1") return true;
      }
   }
   return false;
}

bool IsTimeAllowed()
{
   datetime now = TimeCurrent();
   string currentTime = TimeToString(now, TIME_MINUTES);
   if(currentTime < p_startTime) return false;
   return true;
}

double GetBufferValue(int handle, int buffer, int shift)
{
   double val[];
   ArraySetAsSeries(val, true);
   if(CopyBuffer(handle, buffer, shift, 1, val) > 0) return val[0];
   return 0;
}

void AIOptimizer()
{
   double winRate = CalculaStats(_Symbol, EA_MAGIC);
   if(winRate < 40.0)
   {
      p_riskPercent *= 0.9;
      GravaLog("AIOptimizer: Win rate baixo (" + DoubleToString(winRate, 1) + "%). Reduzindo risco para " + DoubleToString(p_riskPercent, 2) + "%");
   }
}

double CalculaStats(string sym, long magic)
{
   HistorySelect(TimeCurrent() - 86400 * 30, TimeCurrent());
   int total = HistoryDealsTotal();
   int win = 0, loss = 0;
   for(int i=0; i<total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) == sym && HistoryDealGetInteger(ticket, DEAL_MAGIC) == magic)
      {
         double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         if(profit > 0) win++;
         else if(profit < 0) loss++;
      }
   }
   if(win + loss == 0) return 100.0;
   return (win * 100.0) / (win + loss);
}

// --- MQL5 Event Handlers
int OnInit()
{
   trade.SetExpertMagicNumber(EA_MAGIC);
   EventSetTimer(1);
   lastPromptUpdate = 0;
   GravaLog("MT-LiveExecutor Iniciado.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ResetStrategy();
   GravaLog("MT-LiveExecutor Finalizado.");
}

void OnTick()
{
   GerenciaPosicoes();

   static datetime lastBar = 0;
   datetime currentBar = iTime(_Symbol, p_frequency, 0);

   if(currentBar != lastBar)
   {
      Signal s = AvaliaTudo();
      if(s != NONE) EnviaOrdem(s);
      lastBar = currentBar;
   }

   if(TimeCurrent() - lastStateUpdate >= 5)
   {
      GravaCSV();
      lastStateUpdate = TimeCurrent();
   }
}

void OnTimer()
{
   // Check for prompt updates
   datetime modDate = (datetime)FileGetInteger(promptFileName, FILE_MODIFY_DATE);
   if(modDate > lastPromptUpdate)
   {
      int handle = FileOpen(promptFileName, FILE_READ|FILE_TXT|FILE_ANSI);
      if(handle != INVALID_HANDLE)
      {
         string prompt = FileReadString(handle);
         FileClose(handle);
         InterpretaPrompt(prompt);
         lastPromptUpdate = modDate;
      }
   }

   // AI Optimizer every hour
   if(TimeCurrent() - lastAIUpdate >= 3600)
   {
      AIOptimizer();
      lastAIUpdate = TimeCurrent();
   }
}
