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
enum Signal { BUY = 1, SELL = -1, NONE = 0 };

//--- structs
struct Rule {
    bool     active;
    int      type;       // Indicator type (1-10)
    ENUM_TIMEFRAMES tf;
    int      p1, p2, p3; // Parameters
    double   d1, d2;     // Double parameters (levels)
    string   s1;         // String parameter (bench symbol)
    int      handle;     // Indicator handle
    char     op;         // Relational operator ('>', '<')
    bool     isCross;    // Cross vs Stay
    int      intent;     // BUY or SELL intent

    void Reset() {
        active = false;
        type = 0;
        tf = PERIOD_CURRENT;
        p1 = p2 = p3 = 0;
        d1 = d2 = 0;
        s1 = "";
        handle = INVALID_HANDLE;
        op = ' ';
        isCross = false;
        intent = 0;
    }
};

//--- globals
CTrade         trade;
CPositionInfo  m_position;
Rule           buyRules[MAX_RULES];
Rule           sellRules[MAX_RULES];
int            nBuyRules = 0;
int            nSellRules = 0;

// Strategy Parameters
int            p_stopLoss = 0;
int            p_takeProfit = 0;
double         p_risk = 1.0;
int            p_maxTrades = 3;
int            p_startHour = 0;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
int            p_breakeven = 0;
int            p_breakevenStep = 0;
int            p_trailingStop = 0;
int            p_trailingStep = 0;
bool           p_martingale = false;
int            p_newsVetoPre = 0;
int            p_newsVetoPost = 0;

datetime       lastBarTime = 0;

//--- Forward declarations
void InterpretaPrompt(string prompt);
Signal AvaliaTudo();
void EnviaOrdem(Signal s, double preco, double sl, double tp, double lote);
void GerenciaPosicoes();
bool AguardaNoticias();
void GravaLog(string texto);
double CalculaLote(double riscoPercent);
void ResetStrategy();
int PeriodoTexto(string nome);
double ExtraiNumero(string txt, string keyword, int startPos);
void AddRule(string segment, int intent);
double GetBufferValue(int handle, int buffer, int shift);

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(EA_MAGIC);
   EventSetTimer(3600); // For hourly stats
   ResetStrategy();

   // Initial prompt check
   if(FileIsExist("prompt.txt", FILE_COMMON))
   {
      int h = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON);
      if(h != INVALID_HANDLE)
      {
         string prompt = FileReadString(h);
         FileClose(h);
         FileDelete("prompt.txt", FILE_COMMON);
         InterpretaPrompt(prompt);
      }
   }

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ResetStrategy();
   EventKillTimer();
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check for new prompt
   if(FileIsExist("prompt.txt", FILE_COMMON))
   {
      int h = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON);
      if(h != INVALID_HANDLE)
      {
         string prompt = FileReadString(h);
         FileClose(h);
         FileDelete("prompt.txt", FILE_COMMON);
         ResetStrategy();
         InterpretaPrompt(prompt);
      }
   }

   GerenciaPosicoes();

   // Frequency control
   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar == lastBarTime) return;
   lastBarTime = currentBar;

   // Time filter
   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.hour < p_startHour) return;

   // News filter
   if(AguardaNoticias()) return;

   // Signal evaluation
   Signal s = AvaliaTudo();
   if(s != NONE)
   {
      // Check max trades
      int open = 0;
      for(int i=PositionsTotal()-1; i>=0; i--)
         if(m_position.SelectByIndex(i))
            if(m_position.Magic() == EA_MAGIC && m_position.Symbol() == _Symbol)
               open++;

      if(open < p_maxTrades)
      {
         double lote = CalculaLote(p_risk);
         EnviaOrdem(s, 0, 0, 0, lote);
      }
   }
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
{
   // CalculaStats(); // Implementation later
}

//+------------------------------------------------------------------+
//| Reset Strategy Rules                                             |
//+------------------------------------------------------------------+
void ResetStrategy()
{
   for(int i=0; i<MAX_RULES; i++)
   {
      if(buyRules[i].handle != INVALID_HANDLE) IndicatorRelease(buyRules[i].handle);
      if(sellRules[i].handle != INVALID_HANDLE) IndicatorRelease(sellRules[i].handle);
      buyRules[i].Reset();
      sellRules[i].Reset();
   }
   nBuyRules = 0;
   nSellRules = 0;

   p_stopLoss = 0;
   p_takeProfit = 0;
   p_risk = 1.0;
   p_maxTrades = 3;
   p_startHour = 0;
   p_frequency = PERIOD_M15;
   p_breakeven = 0;
   p_breakevenStep = 0;
   p_trailingStop = 0;
   p_trailingStep = 0;
   p_martingale = false;
   p_newsVetoPre = 0;
   p_newsVetoPost = 0;
}

//+------------------------------------------------------------------+
//| Extract number after keyword                                     |
//+------------------------------------------------------------------+
double ExtraiNumero(string txt, string keyword, int startPos)
{
   int pos = StringFind(txt, keyword, startPos);
   if(pos < 0) return 0;
   pos += StringLen(keyword);

   string res = "";
   bool foundDigit = false;
   for(int i=pos; i<StringLen(txt); i++)
   {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.')
      {
         res += CharToString((char)c);
         foundDigit = true;
      }
      else if(foundDigit) break;
   }
   return StringToDouble(res);
}

//+------------------------------------------------------------------+
//| Convert text to Period                                           |
//+------------------------------------------------------------------+
int PeriodoTexto(string nome)
{
   if(StringFind(nome, "m15") >= 0) return PERIOD_M15;
   if(StringFind(nome, "m1") >= 0)  return PERIOD_M1;
   if(StringFind(nome, "m5") >= 0)  return PERIOD_M5;
   if(StringFind(nome, "m30") >= 0) return PERIOD_M30;
   if(StringFind(nome, "h1") >= 0)  return PERIOD_H1;
   if(StringFind(nome, "h4") >= 0)  return PERIOD_H4;
   if(StringFind(nome, "d1") >= 0)  return PERIOD_D1;
   return PERIOD_CURRENT;
}

//+------------------------------------------------------------------+
//| Add Rule to Strategy                                             |
//+------------------------------------------------------------------+
void AddRule(string segment, int intent)
{
   Rule r;
   r.Reset();
   r.intent = intent;
   r.tf = (ENUM_TIMEFRAMES)PeriodoTexto(segment);

   if(StringFind(segment, "média") >= 0 || StringFind(segment, "ma") >= 0)
   {
      r.type = 1;
      r.p1 = (int)ExtraiNumero(segment, "média", 0);
      if(r.p1 == 0) r.p1 = (int)ExtraiNumero(segment, "ma", 0);
      if(r.p1 == 0) r.p1 = 20;
      r.isCross = (StringFind(segment, "cruzar") >= 0);
      r.active = true;
   }
   else if(StringFind(segment, "rsi") >= 0)
   {
      r.type = 2;
      r.p1 = (int)ExtraiNumero(segment, "rsi", 0);
      if(r.p1 == 0) r.p1 = 14;
      r.d1 = ExtraiNumero(segment, "acima", 0);
      if(r.d1 == 0) r.d1 = ExtraiNumero(segment, "abaixo", 0);
      if(r.d1 == 0) r.d1 = ExtraiNumero(segment, ">", 0);
      if(r.d1 == 0) r.d1 = ExtraiNumero(segment, "<", 0);

      if(StringFind(segment, "acima") >= 0 || StringFind(segment, ">") >= 0) r.op = '>';
      else if(StringFind(segment, "abaixo") >= 0 || StringFind(segment, "<") >= 0) r.op = '<';

      r.active = true;
   }
   else if(StringFind(segment, "estocástico") >= 0 || StringFind(segment, "stoch") >= 0)
   {
      r.type = 3;
      r.p1 = (int)ExtraiNumero(segment, "k", 0); if(r.p1 == 0) r.p1 = 5;
      r.p2 = (int)ExtraiNumero(segment, "d", 0); if(r.p2 == 0) r.p2 = 3;
      r.p3 = (int)ExtraiNumero(segment, "slowing", 0); if(r.p3 == 0) r.p3 = 3;
      r.active = true;
   }
   else if(StringFind(segment, "bollinger") >= 0 || StringFind(segment, "bb") >= 0)
   {
      r.type = 4;
      r.p1 = (int)ExtraiNumero(segment, "período", 0); if(r.p1 == 0) r.p1 = 20;
      r.d1 = ExtraiNumero(segment, "desv", 0); if(r.d1 == 0) r.d1 = 2.0;
      r.active = true;
   }
   else if(StringFind(segment, "breakout") >= 0)
   {
      r.type = 5;
      r.active = true;
   }
   else if(StringFind(segment, "delta") >= 0 || StringFind(segment, "agressão") >= 0)
   {
      r.type = 6;
      r.p1 = (int)ExtraiNumero(segment, "segundos", 0); if(r.p1 == 0) r.p1 = 60;
      r.p2 = (int)ExtraiNumero(segment, "trigger", 0); if(r.p2 == 0) r.p2 = 300;
      r.active = true;
   }
   else if(StringFind(segment, "volume") >= 0)
   {
      r.type = 7;
      r.p1 = (int)ExtraiNumero(segment, "período", 0); if(r.p1 == 0) r.p1 = 12;
      r.active = true;
   }
   else if(StringFind(segment, "ama") >= 0)
   {
      r.type = 8;
      r.p1 = (int)ExtraiNumero(segment, "período", 0); if(r.p1 == 0) r.p1 = 10;
      r.active = true;
   }
   else if(StringFind(segment, "padrão") >= 0)
   {
      r.type = 9;
      r.active = true;
   }
   else if(StringFind(segment, "força relativa") >= 0)
   {
      r.type = 10;
      r.s1 = "US30"; // Placeholder for benchmark
      r.active = true;
   }

   if(r.active)
   {
      if(intent == BUY && nBuyRules < MAX_RULES) buyRules[nBuyRules++] = r;
      if(intent == SELL && nSellRules < MAX_RULES) sellRules[nSellRules++] = r;
   }
}

//+------------------------------------------------------------------+
//| Interpreta Prompt                                                |
//+------------------------------------------------------------------+
void InterpretaPrompt(string prompt)
{
   string p = prompt;
   StringReplace(p, ",", ".");
   StringReplace(p, "|", ".");
   StringReplace(p, "\n", ".");

   // Global parameters
   p_stopLoss = (int)ExtraiNumero(p, "stop de", 0);
   p_takeProfit = (int)ExtraiNumero(p, "take de", 0);
   p_risk = ExtraiNumero(p, "risco de", 0);
   if(p_risk == 0) p_risk = 1.0;

   p_maxTrades = (int)ExtraiNumero(p, "máximo", 0);
   if(p_maxTrades == 0) p_maxTrades = 3;

   p_startHour = (int)ExtraiNumero(p, "depois das", 0);
   if(p_startHour == 0) p_startHour = (int)ExtraiNumero(p, "após as", 0);

   p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(p);

   if(StringFind(p, "martingale") >= 0) p_martingale = true;

   // Breakeven
   if(StringFind(p, "breakeven") >= 0 || StringFind(p, "move stop para entrada") >= 0)
   {
      p_breakeven = (int)ExtraiNumero(p, "ao atingir", 0);
      p_breakevenStep = (int)ExtraiNumero(p, "entrada +", StringFind(p, "entrada"));
   }

   // Trailing
   if(StringFind(p, "trailing") >= 0 || StringFind(p, "rastreio") >= 0)
   {
      p_trailingStop = (int)ExtraiNumero(p, "trailing", 0);
      if(p_trailingStop == 0) p_trailingStop = (int)ExtraiNumero(p, "rastreio", 0);
      p_trailingStep = 5; // Default
   }

   // News veto
   if(StringFind(p, "notícias") >= 0)
   {
      p_newsVetoPre = (int)ExtraiNumero(p, "antes", StringFind(p, "notícias"));
      p_newsVetoPost = (int)ExtraiNumero(p, "depois", StringFind(p, "notícias"));
   }

   // Rules segmentation
   string segments[];
   ushort sep = '.';
   int total = StringSplit(p, sep, segments);

   int currentIntent = 0;
   for(int i=0; i<total; i++)
   {
      string seg = segments[i];
      if(StringFind(seg, "compra") >= 0) currentIntent = BUY;
      else if(StringFind(seg, "vende") >= 0) currentIntent = SELL;

      if(currentIntent != 0) AddRule(seg, currentIntent);
   }
}

//+------------------------------------------------------------------+
//| Get Indicator Buffer Value                                       |
//+------------------------------------------------------------------+
double GetBufferValue(int handle, int buffer, int shift)
{
   double val[1];
   if(CopyBuffer(handle, buffer, shift, 1, val) < 0) return 0;
   return val[0];
}

//+------------------------------------------------------------------+
//| Evaluate single rule                                             |
//+------------------------------------------------------------------+
Signal AvaliaRegra(Rule &r)
{
   if(!r.active) return NONE;

   switch(r.type)
   {
      case 1: // MA
         if(r.handle == INVALID_HANDLE) r.handle = iMA(_Symbol, r.tf, r.p1, 0, MODE_EMA, PRICE_CLOSE);
         {
            double ma1 = GetBufferValue(r.handle, 0, 1);
            double ma2 = GetBufferValue(r.handle, 0, 2);
            double close1 = iClose(_Symbol, r.tf, 1);
            double close2 = iClose(_Symbol, r.tf, 2);
            if(r.isCross)
            {
               if(close2 < ma2 && close1 > ma1) return BUY;
               if(close2 > ma2 && close1 < ma1) return SELL;
            }
            else
            {
               if(close1 > ma1) return BUY;
               if(close1 < ma1) return SELL;
            }
         }
         break;

      case 2: // RSI
         if(r.handle == INVALID_HANDLE) r.handle = iRSI(_Symbol, r.tf, r.p1, PRICE_CLOSE);
         {
            double rsi = GetBufferValue(r.handle, 0, 1);
            if(r.op == '>') { if(rsi > r.d1) return (r.intent == SELL ? SELL : BUY); }
            if(r.op == '<') { if(rsi < r.d1) return (r.intent == BUY ? BUY : SELL); }
         }
         break;

      case 3: // Stoch
         if(r.handle == INVALID_HANDLE) r.handle = iStochastic(_Symbol, r.tf, r.p1, r.p2, r.p3, MODE_SMA, STO_LOWHIGH);
         {
            double k1 = GetBufferValue(r.handle, 0, 1);
            double d1 = GetBufferValue(r.handle, 1, 1);
            double k2 = GetBufferValue(r.handle, 0, 2);
            double d2 = GetBufferValue(r.handle, 1, 2);
            if(k2 < d2 && k1 > d1) return BUY;
            if(k2 > d2 && k1 < d1) return SELL;
         }
         break;

      case 4: // BB
         if(r.handle == INVALID_HANDLE) r.handle = iBands(_Symbol, r.tf, r.p1, 0, r.d1, PRICE_CLOSE);
         {
            double close = iClose(_Symbol, r.tf, 1);
            double up = GetBufferValue(r.handle, 1, 1);
            double lo = GetBufferValue(r.handle, 2, 1);
            if(close < lo) return BUY;
            if(close > up) return SELL;
         }
         break;

      case 5: // Daily Breakout
         {
            double hi = iHigh(_Symbol, PERIOD_D1, 1);
            double lo = iLow(_Symbol, PERIOD_D1, 1);
            double close = iClose(_Symbol, PERIOD_M1, 1);
            if(close > hi) return BUY;
            if(close < lo) return SELL;
         }
         break;

      case 6: // Delta Aggression (Simulation)
         {
            MqlTick ticks[];
            int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, TimeCurrent() - r.p1, TimeCurrent());
            long buyVol = 0, sellVol = 0;
            for(int i=0; i<n; i++)
               if((ticks[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buyVol++;
               else if((ticks[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sellVol++;

            long delta = buyVol - sellVol;
            if(delta > r.p2) return BUY;
            if(delta < -r.p2) return SELL;
         }
         break;

      case 7: // Volume Cycle
         {
            long vol[];
            CopyVolume(_Symbol, r.tf, 0, r.p1, vol);
            int maxIdx = ArrayMaximum(vol);
            int minIdx = ArrayMinimum(vol);
            if(maxIdx == 0) return SELL;
            if(minIdx == 0) return BUY;
         }
         break;

      case 8: // AMA
         if(r.handle == INVALID_HANDLE) r.handle = iAMA(_Symbol, r.tf, r.p1, 2, 30, 0, PRICE_CLOSE);
         {
            double ama1 = GetBufferValue(r.handle, 0, 1);
            double ama2 = GetBufferValue(r.handle, 0, 2);
            if(ama1 > ama2) return BUY;
            if(ama1 < ama2) return SELL;
         }
         break;

      case 9: // 2-Bar Patterns
         {
            double h0 = iHigh(_Symbol, r.tf, 1);
            double l0 = iLow(_Symbol, r.tf, 1);
            double h1 = iHigh(_Symbol, r.tf, 2);
            double l1 = iLow(_Symbol, r.tf, 2);
            double c0 = iClose(_Symbol, r.tf, 1);
            double o0 = iOpen(_Symbol, r.tf, 1);

            if(h0 < h1 && l0 > l1) return (c0 > o0 ? BUY : SELL); // Inside
            if(h0 > h1 && l0 < l1) return (c0 > o0 ? SELL : BUY); // Outside
         }
         break;

      case 10: // Relative Strength
         if(r.handle == INVALID_HANDLE) r.handle = iRSI(_Symbol, r.tf, 14, PRICE_CLOSE);
         {
            int hBench = iRSI(r.s1, r.tf, 14, PRICE_CLOSE);
            double rsi1 = GetBufferValue(r.handle, 0, 1);
            double rsiBench = GetBufferValue(hBench, 0, 1);
            IndicatorRelease(hBench);
            if(rsi1 > rsiBench + 5) return BUY;
            if(rsi1 < rsiBench - 5) return SELL;
         }
         break;
   }
   return NONE;
}

//+------------------------------------------------------------------+
//| Evaluate all rules (Confluence)                                  |
//+------------------------------------------------------------------+
Signal AvaliaTudo()
{
   int buyVotos = 0;
   for(int i=0; i<nBuyRules; i++)
      if(AvaliaRegra(buyRules[i]) == BUY) buyVotos++;

   int sellVotos = 0;
   for(int i=0; i<nSellRules; i++)
      if(AvaliaRegra(sellRules[i]) == SELL) sellVotos++;

   if(nBuyRules > 0 && buyVotos == nBuyRules) return BUY;
   if(nSellRules > 0 && sellVotos == nSellRules) return SELL;

   return NONE;
}

//+------------------------------------------------------------------+
//| Calculate Lot size with Risk and Martingale                      |
//+------------------------------------------------------------------+
double CalculaLote(double riscoPercent)
{
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riscoAbs = capital * riscoPercent / 100.0;

   if(p_martingale)
   {
      HistorySelect(0, TimeCurrent());
      int total = HistoryDealsTotal();
      for(int i=total-1; i>=0; i--)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC)
         {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            if(profit < 0) riscoAbs *= 2.0;
            break;
         }
      }
   }

   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double slPoints = (p_stopLoss > 0 ? p_stopLoss : 300);

   double lote = riscoAbs / (slPoints * _Point * (tickVal / tickSize));

   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lote = MathFloor(lote / stepVol) * stepVol;
   if(lote < minVol) lote = minVol;
   if(lote > maxVol) lote = maxVol;

   return NormalizeDouble(lote, 2);
}

//+------------------------------------------------------------------+
//| Send Order                                                       |
//+------------------------------------------------------------------+
void EnviaOrdem(Signal s, double preco, double sl, double tp, double lote)
{
   if(s == NONE) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double openPrice = (s == BUY ? ask : bid);
   double slPrice = 0, tpPrice = 0;

   if(p_stopLoss > 0)
      slPrice = (s == BUY ? openPrice - p_stopLoss * _Point : openPrice + p_stopLoss * _Point);
   if(p_takeProfit > 0)
      tpPrice = (s == BUY ? openPrice + p_takeProfit * _Point : openPrice - p_takeProfit * _Point);

   if(s == BUY) trade.Buy(lote, _Symbol, openPrice, slPrice, tpPrice);
   else trade.Sell(lote, _Symbol, openPrice, slPrice, tpPrice);

   if(trade.ResultRetcode() != TRADE_RETCODE_DONE)
      GravaLog("Erro ao enviar ordem: " + trade.ResultRetcodeDescription());
   else
      GravaLog("Ordem enviada com sucesso: " + EnumToString(s));
}

//+------------------------------------------------------------------+
//| Manage Open Positions (BE, Trailing)                             |
//+------------------------------------------------------------------+
void GerenciaPosicoes()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC && PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double currentPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK));
            double sl = PositionGetDouble(POSITION_SL);

            double profitPoints = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? (currentPrice - openPrice) : (openPrice - currentPrice)) / _Point;

            // Breakeven
            if(p_breakeven > 0 && profitPoints >= p_breakeven)
            {
               double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? openPrice + p_breakevenStep * _Point : openPrice - p_breakevenStep * _Point);
               if(sl == 0 || (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? newSL > sl : newSL < sl))
               {
                  trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
                  GravaLog("Breakeven ativado para ticket " + IntegerToString(ticket));
               }
            }

            // Trailing Stop
            if(p_trailingStop > 0 && profitPoints >= p_trailingStop)
            {
               double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? currentPrice - p_trailingStop * _Point : currentPrice + p_trailingStop * _Point);
               if(sl == 0 || (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? newSL > sl + p_trailingStep * _Point : newSL < sl - p_trailingStep * _Point))
               {
                  trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| News Veto Filter                                                 |
//+------------------------------------------------------------------+
bool AguardaNoticias()
{
   if(p_newsVetoPre == 0 && p_newsVetoPost == 0) return false;

   if(FileIsExist("calendar.txt", FILE_COMMON))
   {
      int h = FileOpen("calendar.txt", FILE_READ|FILE_TXT|FILE_COMMON);
      if(h != INVALID_HANDLE)
      {
         while(!FileIsEnding(h))
         {
            string line = FileReadString(h);
            string parts[];
            if(StringSplit(line, ';', parts) >= 3)
            {
               datetime newsTime = StringToTime(parts[0]);
               if(TimeCurrent() >= newsTime - p_newsVetoPre * 60 && TimeCurrent() <= newsTime + p_newsVetoPost * 60)
               {
                  FileClose(h);
                  return true;
               }
            }
         }
         FileClose(h);
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Log and Notification                                             |
//+------------------------------------------------------------------+
void GravaLog(string texto)
{
   Print(texto);
   SendNotification(texto);

   int h = FileOpen("log_trades.csv", FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON, ',');
   if(h != INVALID_HANDLE)
   {
      FileSeek(h, 0, SEEK_END);
      FileWrite(h, TimeToString(TimeCurrent()), _Symbol, texto);
      FileClose(h);
   }
}
