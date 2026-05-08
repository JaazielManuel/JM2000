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

//--- Enums
enum Signal {BUY=1, SELL=-1, NONE=0};

//--- Constants
#define EA_MAGIC 123456
#define MAX_RULES 20

//--- Rule Type Enums
#define RT_MA 1
#define RT_RSI 2
#define RT_STOCH 3
#define RT_BB 4
#define RT_DAILYBREAK 5
#define RT_DELTA 6
#define RT_VOL 7
#define RT_AMA 8
#define RT_BAR2 9
#define RT_RS 10
#define RT_AI_PRED 11

//--- Structs
struct Rule
{
   int      type;       // RT_*
   Signal   intent;     // BUY or SELL
   int      tf;         // Timeframe
   double   p1, p2, p3; // Parameters
   int      handle1;    // Indicator handle 1
   int      handle2;    // Indicator handle 2
   bool     active;

   void Reset()
   {
      if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease(handle1);
      if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease(handle2);
      type = 0;
      intent = NONE;
      tf = PERIOD_CURRENT;
      p1 = 0; p2 = 0; p3 = 0;
      handle1 = INVALID_HANDLE;
      handle2 = INVALID_HANDLE;
      active = false;
   }
};

//--- Global Variables
Rule     g_rules[MAX_RULES];
int      g_nRules = 0;
CTrade   g_trade;
double   p_riskPercent = 1.0;
int      p_stopPoints = 0;
int      p_takePoints = 0;
int      p_maxTrades = 3;
int      p_beStart = 0;
int      p_bePlus = 0;
int      p_trailingStop = 0;
int      p_trailingStep = 0;
string   p_startTime = "00:00";
int      p_newsVetoBefore = 0;
int      p_newsVetoAfter = 0;
bool     p_useMartingale = false;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

datetime g_lastPromptMod = 0;
string   g_lastPrompt = "";

//--- Helper functions for NLP
double ExtraiNumero(string texto, int &startPos)
{
   string numStr = "";
   bool found = false;
   int len = StringLen(texto);
   for(int i = startPos; i < len; i++)
   {
      ushort c = StringGetCharacter(texto, i);
      if((c >= '0' && c <= '9') || c == '.')
      {
         numStr += StringSubstr(texto, i, 1);
         found = true;
      }
      else if(found)
      {
         startPos = i;
         return StringToDouble(numStr);
      }
   }
   startPos = len;
   return found ? StringToDouble(numStr) : 0;
}

double ExtraiValorApos(string texto, string chave)
{
   int pos = StringFind(texto, chave);
   if(pos < 0) return 0;
   pos += StringLen(chave);
   int start = pos;
   return ExtraiNumero(texto, start);
}

ENUM_TIMEFRAMES PeriodoTexto(string txt)
{
   if(StringFind(txt, "m1") >= 0 && StringFind(txt, "m15") < 0) return PERIOD_M1;
   if(StringFind(txt, "m5") >= 0 && StringFind(txt, "m15") < 0) return PERIOD_M5;
   if(StringFind(txt, "m15") >= 0) return PERIOD_M15;
   if(StringFind(txt, "m30") >= 0) return PERIOD_M30;
   if(StringFind(txt, "h1") >= 0) return PERIOD_H1;
   if(StringFind(txt, "h4") >= 0) return PERIOD_H4;
   if(StringFind(txt, "d1") >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

void ResetStrategy()
{
   for(int i = 0; i < MAX_RULES; i++) g_rules[i].Reset();
   g_nRules = 0;
   g_trade.SetExpertMagicNumber(EA_MAGIC);
}

void InterpretaPrompt(string prompt)
{
   ResetStrategy();
   string work = prompt;
   StringToLower(work);

   // Global parameters
   double risk = ExtraiValorApos(work, "risco de");
   if(risk > 0) p_riskPercent = risk;

   double stop = ExtraiValorApos(work, "stop de");
   if(stop > 0) p_stopPoints = (int)stop;

   double take = ExtraiValorApos(work, "take de");
   if(take > 0) p_takePoints = (int)take;

   double maxT = ExtraiValorApos(work, "máximo");
   if(maxT > 0) p_maxTrades = (int)maxT;

   if(StringFind(work, "martingale") >= 0) p_useMartingale = true;

   p_beStart = (int)ExtraiValorApos(work, "atingir +");
   p_bePlus = (int)ExtraiValorApos(work, "entrada +");

   p_trailingStop = (int)ExtraiValorApos(work, "trailing stop");
   p_trailingStep = (int)ExtraiValorApos(work, "passo");

   int startT = StringFind(work, "depois das");
   if(startT >= 0) p_startTime = StringSubstr(work, startT + 11, 5);

   // Frequency
   p_frequency = PeriodoTexto(work);
   if(p_frequency == PERIOD_CURRENT) p_frequency = PERIOD_M15;

   // Rules split
   string segments[];
   string sep = "|";
   string temp = work;
   StringReplace(temp, " e ", sep);
   StringReplace(temp, ".", sep);
   StringReplace(temp, ",", sep);
   ushort u_sep = StringGetCharacter(sep, 0);
   int nSeg = StringSplit(temp, u_sep, segments);

   Signal currentIntent = NONE;
   for(int i = 0; i < nSeg && g_nRules < MAX_RULES; i++)
   {
      string s = segments[i];
      if(StringFind(s, "compra") >= 0) currentIntent = BUY;
      else if(StringFind(s, "vende") >= 0) currentIntent = SELL;

      if(currentIntent == NONE) continue;

      Rule r;
      r.intent = currentIntent;
      r.tf = PeriodoTexto(s);
      if(r.tf == PERIOD_CURRENT) r.tf = p_frequency;

      if(StringFind(s, " ma ") >= 0 || StringFind(s, "média") >= 0)
      {
         r.type = RT_MA;
         int start = 0;
         r.p1 = ExtraiNumero(s, start); // period 1
         r.p2 = ExtraiNumero(s, start); // period 2 (optional cross)
         if(r.p1 > 0)
         {
            r.handle1 = iMA(NULL, (ENUM_TIMEFRAMES)r.tf, (int)r.p1, 0, MODE_SMA, PRICE_CLOSE);
            if(r.p2 > 0) r.handle2 = iMA(NULL, (ENUM_TIMEFRAMES)r.tf, (int)r.p2, 0, MODE_SMA, PRICE_CLOSE);
            r.active = true;
            g_rules[g_nRules++] = r;
         }
      }
      else if(StringFind(s, "rsi") >= 0)
      {
         r.type = RT_RSI;
         int start = 0;
         double v1 = ExtraiNumero(s, start);
         double v2 = ExtraiNumero(s, start);
         if(v2 > 0) { r.p1 = v1; r.p2 = v2; } // period, threshold
         else { r.p1 = 14; r.p2 = v1; }
         r.handle1 = iRSI(NULL, (ENUM_TIMEFRAMES)r.tf, (int)r.p1, PRICE_CLOSE);
         r.active = true;
         g_rules[g_nRules++] = r;
      }
      else if(StringFind(s, "estocástico") >= 0 || StringFind(s, "stoch") >= 0)
      {
         r.type = RT_STOCH;
         r.handle1 = iStochastic(NULL, (ENUM_TIMEFRAMES)r.tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
         r.active = true;
         g_rules[g_nRules++] = r;
      }
      else if(StringFind(s, "bollinger") >= 0 || StringFind(s, "bb") >= 0)
      {
         r.type = RT_BB;
         r.handle1 = iBands(NULL, (ENUM_TIMEFRAMES)r.tf, 20, 0, 2.0, PRICE_CLOSE);
         r.active = true;
         g_rules[g_nRules++] = r;
      }
      else if(StringFind(s, "rompimento diário") >= 0)
      {
         r.type = RT_DAILYBREAK;
         r.active = true;
         g_rules[g_nRules++] = r;
      }
      else if(StringFind(s, "delta") >= 0)
      {
         r.type = RT_DELTA;
         int start = 0;
         r.p1 = 60; // default 60s
         r.p2 = ExtraiNumero(s, start); // threshold
         r.active = true;
         g_rules[g_nRules++] = r;
      }
      else if(StringFind(s, "volume") >= 0)
      {
         r.type = RT_VOL;
         r.active = true;
         g_rules[g_nRules++] = r;
      }
      else if(StringFind(s, "ama") >= 0 || StringFind(s, "adaptativa") >= 0)
      {
         r.type = RT_AMA;
         r.handle1 = iAMA(NULL, (ENUM_TIMEFRAMES)r.tf, 10, 2, 30, PRICE_CLOSE);
         r.active = true;
         g_rules[g_nRules++] = r;
      }
      else if(StringFind(s, "padrão barras") >= 0)
      {
         r.type = RT_BAR2;
         r.active = true;
         g_rules[g_nRules++] = r;
      }
      else if(StringFind(s, "força relativa") >= 0)
      {
         r.type = RT_RS;
         r.handle1 = iRSI(NULL, (ENUM_TIMEFRAMES)r.tf, 14, PRICE_CLOSE);
         r.handle2 = iRSI("US30", (ENUM_TIMEFRAMES)r.tf, 14, PRICE_CLOSE);
         r.active = true;
         g_rules[g_nRules++] = r;
      }
      else if(StringFind(s, "previsão") >= 0 || StringFind(s, "ai") >= 0)
      {
         r.type = RT_AI_PRED;
         r.handle1 = iATR(NULL, (ENUM_TIMEFRAMES)r.tf, 14);
         r.active = true;
         g_rules[g_nRules++] = r;
      }
   }
}

//--- Evaluation Functions
double GetBufferValue(int handle, int buffer, int shift)
{
   double arr[];
   ArraySetAsSeries(arr, true);
   if(CopyBuffer(handle, buffer, shift, 1, arr) > 0) return arr[0];
   return 0;
}

Signal AvaliaRegra(Rule &r)
{
   if(!r.active) return NONE;

   switch(r.type)
   {
      case RT_MA:
      {
         double m1 = GetBufferValue(r.handle1, 0, 1);
         double m1_prev = GetBufferValue(r.handle1, 0, 2);
         if(r.handle2 != INVALID_HANDLE)
         {
            double m2 = GetBufferValue(r.handle2, 0, 1);
            double m2_prev = GetBufferValue(r.handle2, 0, 2);
            if(m1_prev < m2_prev && m1 > m2) return BUY;
            if(m1_prev > m2_prev && m1 < m2) return SELL;
         }
         else
         {
            double close = iClose(NULL, (ENUM_TIMEFRAMES)r.tf, 1);
            double close_prev = iClose(NULL, (ENUM_TIMEFRAMES)r.tf, 2);
            if(close_prev < m1_prev && close > m1) return BUY;
            if(close_prev > m1_prev && close < m1) return SELL;
         }
         break;
      }
      case RT_RSI:
      {
         double rsi = GetBufferValue(r.handle1, 0, 1);
         double rsi_prev = GetBufferValue(r.handle1, 0, 2);
         if(r.intent == BUY && rsi_prev < r.p2 && rsi > r.p2) return BUY;
         if(r.intent == SELL && rsi_prev > r.p2 && rsi < r.p2) return SELL;
         break;
      }
      case RT_STOCH:
      {
         double k = GetBufferValue(r.handle1, 0, 1);
         double d = GetBufferValue(r.handle1, 1, 1);
         double kp = GetBufferValue(r.handle1, 0, 2);
         double dp = GetBufferValue(r.handle1, 1, 2);
         if(kp < dp && k > d) return BUY;
         if(kp > dp && k < d) return SELL;
         break;
      }
      case RT_BB:
      {
         double close = iClose(NULL, (ENUM_TIMEFRAMES)r.tf, 0);
         double up = GetBufferValue(r.handle1, 1, 0);
         double lo = GetBufferValue(r.handle1, 2, 0);
         if(close < lo) return BUY;
         if(close > up) return SELL;
         break;
      }
      case RT_DAILYBREAK:
      {
         double hi = iHigh(NULL, PERIOD_D1, 1);
         double lo = iLow(NULL, PERIOD_D1, 1);
         double close = iClose(NULL, PERIOD_M1, 0);
         if(close > hi) return BUY;
         if(close < lo) return SELL;
         break;
      }
      case RT_DELTA:
      {
         MqlTick arr[];
         int n = CopyTicksRange(_Symbol, arr, COPY_TICKS_TRADE, TimeCurrent() - (int)r.p1, TimeCurrent());
         long buy = 0, sell = 0;
         for(int i = 0; i < n; i++)
         {
            if((arr[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++;
            else if((arr[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sell++;
         }
         long delta = buy - sell;
         if(delta > r.p2) return BUY;
         if(delta < -r.p2) return SELL;
         break;
      }
      case RT_VOL:
      {
         long v0 = iVolume(NULL, (ENUM_TIMEFRAMES)r.tf, 0);
         long v1 = iVolume(NULL, (ENUM_TIMEFRAMES)r.tf, 1);
         if(v0 > v1 * 1.5) return (iClose(NULL, (ENUM_TIMEFRAMES)r.tf, 0) > iOpen(NULL, (ENUM_TIMEFRAMES)r.tf, 0)) ? BUY : SELL;
         break;
      }
      case RT_AMA:
      {
         double ama = GetBufferValue(r.handle1, 0, 0);
         double p = GetBufferValue(r.handle1, 0, 1);
         if(ama > p) return BUY;
         if(ama < p) return SELL;
         break;
      }
      case RT_BAR2:
      {
         double h0 = iHigh(NULL, (ENUM_TIMEFRAMES)r.tf, 0);
         double l0 = iLow(NULL, (ENUM_TIMEFRAMES)r.tf, 0);
         double h1 = iHigh(NULL, (ENUM_TIMEFRAMES)r.tf, 1);
         double l1 = iLow(NULL, (ENUM_TIMEFRAMES)r.tf, 1);
         if(h0 < h1 && l0 > l1) return (iClose(NULL, (ENUM_TIMEFRAMES)r.tf, 0) > iOpen(NULL, (ENUM_TIMEFRAMES)r.tf, 0)) ? BUY : SELL;
         if(h0 > h1 && l0 < l1) return (iClose(NULL, (ENUM_TIMEFRAMES)r.tf, 0) > iOpen(NULL, (ENUM_TIMEFRAMES)r.tf, 0)) ? SELL : BUY;
         break;
      }
      case RT_RS:
      {
         double r1 = GetBufferValue(r.handle1, 0, 0);
         double r2 = GetBufferValue(r.handle2, 0, 0);
         if(r1 > r2 + 5) return BUY;
         if(r1 < r2 - 5) return SELL;
         break;
      }
      case RT_AI_PRED:
      {
         double atr = GetBufferValue(r.handle1, 0, 0);
         double body = MathAbs(iClose(NULL, (ENUM_TIMEFRAMES)r.tf, 0) - iOpen(NULL, (ENUM_TIMEFRAMES)r.tf, 0));
         if(body > atr * 1.5) return (iClose(NULL, (ENUM_TIMEFRAMES)r.tf, 0) > iOpen(NULL, (ENUM_TIMEFRAMES)r.tf, 0)) ? BUY : SELL;
         break;
      }
   }
   return NONE;
}

Signal AvaliaTudo()
{
   int buyVotes = 0, sellVotes = 0;
   int buyRules = 0, sellRules = 0;

   for(int i = 0; i < g_nRules; i++)
   {
      Signal s = AvaliaRegra(g_rules[i]);
      if(g_rules[i].intent == BUY)
      {
         buyRules++;
         if(s == BUY) buyVotes++;
      }
      else if(g_rules[i].intent == SELL)
      {
         sellRules++;
         if(s == SELL) sellVotes++;
      }
   }

   if(buyRules > 0 && buyVotes == buyRules) return BUY;
   if(sellRules > 0 && sellVotes == sellRules) return SELL;
   return NONE;
}

//--- Execution and Management
void GravaLog(string texto)
{
   int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE|FILE_READ|FILE_TXT|FILE_ANSI);
   if(handle != INVALID_HANDLE)
   {
      FileSeek(handle, 0, SEEK_END);
      FileWrite(handle, TimeToString(TimeCurrent()) + ": " + texto);
      FileClose(handle);
   }
   Print(texto);
}

void GravaCSV()
{
   int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(handle != INVALID_HANDLE)
   {
      FileWrite(handle, "Ticket", "Symbol", "Type", "Volume", "PriceOpen", "Time", "SL", "TP", "Profit", "Reason");
      for(int i = 0; i < PositionsTotal(); i++)
      {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC)
         {
            FileWrite(handle, ticket, PositionGetString(POSITION_SYMBOL), PositionGetInteger(POSITION_TYPE),
                      PositionGetDouble(POSITION_VOLUME), PositionGetDouble(POSITION_PRICE_OPEN),
                      TimeToString((datetime)PositionGetInteger(POSITION_TIME)),
                      PositionGetDouble(POSITION_SL), PositionGetDouble(POSITION_TP),
                      PositionGetDouble(POSITION_PROFIT), PositionGetString(POSITION_COMMENT));
         }
      }
      FileClose(handle);
   }
}

bool AguardaNoticias()
{
   if(FileIsExist("news_veto.txt"))
   {
      int h = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_ANSI);
      if(h != INVALID_HANDLE)
      {
         string content = FileReadString(h);
         FileClose(h);
         if(StringFind(content, "VETO=1") >= 0) return true;
      }
   }
   return false;
}

double CalculaLote(double riskPercent)
{
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAbs = capital * riskPercent / 100.0;
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   int sl = p_stopPoints;
   if(sl == 0) sl = 300; // default 30 points

   if(p_useMartingale)
   {
      HistorySelect(0, TimeCurrent());
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC)
         {
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) riskAbs *= 2.0;
            break;
         }
      }
   }

   double lote = riskAbs / (sl * (tickVal / (tickSize / _Point)));
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lote = MathFloor(lote / step) * step;
   double minLote = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLote = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lote < minLote) lote = minLote;
   if(lote > maxLote) lote = maxLote;
   return NormalizeDouble(lote, 2);
}

void EnviaOrdem(Signal s, string reason)
{
   if(AguardaNoticias()) return;

   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionSelectByTicket(PositionGetTicket(i)) && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) count++;
   }
   if(count >= p_maxTrades) return;

   double lote = CalculaLote(p_riskPercent);
   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0, tp = 0;

   if(s == BUY)
   {
      if(p_stopPoints > 0) sl = price - p_stopPoints * _Point;
      if(p_takePoints > 0) tp = price + p_takePoints * _Point;
   }
   else
   {
      if(p_stopPoints > 0) sl = price + p_stopPoints * _Point;
      if(p_takePoints > 0) tp = price - p_takePoints * _Point;
   }

   for(int i = 0; i < 3; i++)
   {
      if(g_trade.PositionOpen(_Symbol, (s == BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL), lote, price, sl, tp, reason))
      {
         GravaLog("Ordem enviada: " + EnumToString(s) + " Lote: " + DoubleToString(lote, 2) + " Motivo: " + reason);
         SendNotification("Trade Executado: " + _Symbol + " " + reason);
         break;
      }
      else
      {
         int err = GetLastError();
         GravaLog("Erro ao enviar ordem: " + (string)err);
         if(err == TRADE_RETCODE_REQUOTES || err == TRADE_RETCODE_OFFQUOTES)
         {
            Sleep(100);
            price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
         }
         else break;
      }
   }
}

void GerenciaPosicoes()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC)
      {
         double open = PositionGetDouble(POSITION_PRICE_OPEN);
         double cur = PositionGetDouble(POSITION_PRICE_CURRENT);
         double sl = PositionGetDouble(POSITION_SL);
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

         // Breakeven
         if(p_beStart > 0)
         {
            double diff = (type == POSITION_TYPE_BUY) ? (cur - open) : (open - cur);
            if(diff >= p_beStart * _Point)
            {
               double newSL = (type == POSITION_TYPE_BUY) ? (open + p_bePlus * _Point) : (open - p_bePlus * _Point);
               if((type == POSITION_TYPE_BUY && (sl < newSL || sl == 0)) || (type == POSITION_TYPE_SELL && (sl > newSL || sl == 0)))
               {
                  g_trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
               }
            }
         }

         // Trailing
         if(p_trailingStop > 0)
         {
            double diff = (type == POSITION_TYPE_BUY) ? (cur - open) : (open - cur);
            if(diff >= p_trailingStop * _Point)
            {
               double newSL = (type == POSITION_TYPE_BUY) ? (cur - p_trailingStop * _Point) : (cur + p_trailingStop * _Point);
               if((type == POSITION_TYPE_BUY && newSL > sl + p_trailingStep * _Point) || (type == POSITION_TYPE_SELL && (newSL < sl - p_trailingStep * _Point || sl == 0)))
               {
                  g_trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   EventSetTimer(1);
   g_trade.SetExpertMagicNumber(EA_MAGIC);
   ResetStrategy();
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   for(int i = 0; i < MAX_RULES; i++) g_rules[i].Reset();
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   GravaCSV();
   GerenciaPosicoes();

   static datetime lastBar = 0;
   datetime curBar = iTime(NULL, p_frequency, 0);
   if(curBar == lastBar) return;
   lastBar = curBar;

   // Check start time
   string curTime = TimeToString(TimeCurrent(), TIME_MINUTES);
   if(curTime < p_startTime) return;

   Signal s = AvaliaTudo();
   if(s != NONE) EnviaOrdem(s, "Estrategia NLP");
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Check for prompt updates
   datetime mod = (datetime)FileGetInteger("prompt.txt", FILE_MODIFY_DATE);
   if(mod > g_lastPromptMod)
   {
      g_lastPromptMod = mod;
      int h = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_ANSI);
      if(h != INVALID_HANDLE)
      {
         string prompt = FileReadString(h);
         FileClose(h);
         if(prompt != g_lastPrompt)
         {
            g_lastPrompt = prompt;
            InterpretaPrompt(prompt);
            GravaLog("Nova estrategia carregada: " + prompt);
         }
      }
   }
}
//+------------------------------------------------------------------+
