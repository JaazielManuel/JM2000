//+------------------------------------------------------------------+
//|                                              MT_LiveExecutor.mq5 |
//|                                  Copyright 2024, MT-LiveExecutor |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MT-LiveExecutor"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

// --- Includes ---
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// --- Defines ---
#define EA_MAGIC 123456
#define MAX_RULES 20

// --- Enums ---
enum Signal {BUY=1, SELL=-1, NONE=0};

// --- Structs ---
struct Rule {
   bool     active;
   int      type;    // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: DailyBreak, 6: Delta, 7: Volume, 8: AMA, 9: Bar2Pattern, 10: RSRelative
   int      tf;
   int      p1, p2, p3;
   double   d1, d2;
   string   s1;
   int      handle;
   int      handle2;
   string   oper;   // ">", "<", "cross_above", "cross_below"
};

// --- Globals ---
Rule g_buyRules[MAX_RULES];
Rule g_sellRules[MAX_RULES];
int g_nBuyRules = 0;
int g_nSellRules = 0;

CTrade g_trade;
CPositionInfo g_pos;

// Strategy Parameters
int    p_maxTrades = 1;
double p_riskPercent = 1.0;
int    p_stopPoints = 300;
int    p_takePoints = 500;
int    p_breakeven = 0;
int    p_breakevenEntry = 0;
int    p_trailingStop = 0;
int    p_startHour = 0;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
bool   p_newsVeto = false;

// Statistics
int    g_wins = 0;
int    g_losses = 0;
double g_totalProfit = 0;
double g_peakEquity = 0;
double g_maxDrawdown = 0;

// Time Control
datetime g_lastBar = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(EA_MAGIC);
   EventSetTimer(3600); // Hourly stats
   g_peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   // Initial prompt check
   CheckPromptFile();

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   CalculaStats();
   ResetStrategy();
   EventKillTimer();
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   CheckPromptFile();

   if(p_newsVeto && AguardaNoticias()) return;

   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar != g_lastBar)
   {
      g_lastBar = currentBar;

      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(dt.hour >= p_startHour)
      {
         Signal s = AvaliaTudo();
         if(s != NONE && CountOpenPositions() < p_maxTrades)
         {
            executaSignal(s, p_riskPercent);
         }
      }
   }

   GerenciaPosicoes();
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
{
   CalculaStats();
}

//+------------------------------------------------------------------+
//| NLP / Parser Functions                                           |
//+------------------------------------------------------------------+

void InterpretaPrompt(string prompt)
{
   ResetStrategy();
   string normalized = prompt;
   StringToLower(normalized);
   StringReplace(normalized, " e ", ".");
   StringReplace(normalized, " e o ", ".");
   StringReplace(normalized, " e a ", ".");
   StringReplace(normalized, "|", ".");
   StringReplace(normalized, "\n", ".");

   string segments[];
   StringSplit(normalized, '.', segments);

   int currentIntent = NONE;

   for(int i=0; i<ArraySize(segments); i++)
   {
      string seg = segments[i];
      StringTrimLeft(seg);
      StringTrimRight(seg);
      if(seg == "") continue;

      if(StringFind(seg, "compra") >= 0) currentIntent = BUY;
      if(StringFind(seg, "vende") >= 0) currentIntent = SELL;

      // Global parameters
      if(StringFind(seg, "stop de") >= 0) p_stopPoints = (int)ExtraiNumero(seg, StringFind(seg, "stop de"));
      if(StringFind(seg, "take de") >= 0) p_takePoints = (int)ExtraiNumero(seg, StringFind(seg, "take de"));
      if(StringFind(seg, "risco de") >= 0) p_riskPercent = ExtraiNumero(seg, StringFind(seg, "risco de"));
      if(StringFind(seg, "máximo") >= 0 && StringFind(seg, "trades") >= 0) p_maxTrades = (int)ExtraiNumero(seg, StringFind(seg, "máximo"));

      int hourPos = StringFind(seg, "depois das");
      if(hourPos < 0) hourPos = StringFind(seg, "após as");
      if(hourPos >= 0) p_startHour = (int)ExtraiNumero(seg, hourPos);

      if(StringFind(seg, "minutos") >= 0 && StringFind(seg, "cada") >= 0)
      {
         int freq = (int)ExtraiNumero(seg, StringFind(seg, "cada"));
         if(freq == 1) p_frequency = PERIOD_M1;
         else if(freq == 5) p_frequency = PERIOD_M5;
         else if(freq == 15) p_frequency = PERIOD_M15;
         else if(freq == 30) p_frequency = PERIOD_M30;
         else if(freq == 60) p_frequency = PERIOD_H1;
      }

      if(StringFind(seg, "notícias") >= 0) p_newsVeto = true;

      if(StringFind(seg, "move stop para entrada") >= 0 || StringFind(seg, "breakeven") >= 0)
      {
         p_breakeven = (int)ExtraiNumero(seg, StringFind(seg, "atingir"));
         int entPos = StringFind(seg, "entrada");
         if(entPos >= 0) p_breakevenEntry = (int)ExtraiNumero(seg, entPos);
      }

      if(StringFind(seg, "trailing") >= 0 || StringFind(seg, "rastreio") >= 0)
      {
         p_trailingStop = (int)ExtraiNumero(seg, 0);
      }

      // Indicator Rules
      if(currentIntent != NONE)
      {
         AddRuleSpecific(seg, currentIntent);
      }
   }

   GravaLog("Estratégia atualizada: " + prompt);
}

void AddRuleSpecific(string seg, int intent)
{
   // MA
   if(StringFind(seg, "média") >= 0)
   {
      Rule r;
      ZeroMemory(r);
      r.type = 1;
      r.tf = p_frequency;
      r.p1 = (int)ExtraiNumero(seg, StringFind(seg, "média"));
      if(r.p1 == 0)
      {
         // Try to find if it was defined in the other intent
         if(intent == SELL && g_nBuyRules > 0) r.p1 = g_buyRules[0].p1;
         else r.p1 = 20;
      }

      if(StringFind(seg, "cruzar acima") >= 0) r.oper = "cross_above";
      else if(StringFind(seg, "cruzar abaixo") >= 0) r.oper = "cross_below";
      else if(StringFind(seg, "acima") >= 0) r.oper = ">";
      else if(StringFind(seg, "abaixo") >= 0) r.oper = "<";

      r.handle = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_SMA, PRICE_CLOSE);
      r.active = true;

      if(intent == BUY && g_nBuyRules < MAX_RULES) g_buyRules[g_nBuyRules++] = r;
      if(intent == SELL && g_nSellRules < MAX_RULES) g_sellRules[g_nSellRules++] = r;
   }

   // RSI
   if(StringFind(seg, "rsi") >= 0)
   {
      Rule r;
      ZeroMemory(r);
      r.type = 2;
      r.tf = p_frequency;
      r.p1 = (int)ExtraiNumero(seg, StringFind(seg, "rsi"));
      if(r.p1 == 0) r.p1 = 14;

      int pos55 = StringFind(seg, "55");
      int pos45 = StringFind(seg, "45");
      int posAbove = StringFind(seg, "acima");
      int posBelow = StringFind(seg, "abaixo");
      int posSubir = StringFind(seg, "subir");
      int posCair = StringFind(seg, "cair");

      if(posAbove >= 0 || posSubir >= 0)
      {
         r.oper = ">";
         r.d1 = ExtraiNumero(seg, (pos55 >= 0) ? pos55 : (posAbove >= 0 ? posAbove : posSubir));
      }
      else if(posBelow >= 0 || posCair >= 0)
      {
         r.oper = "<";
         r.d1 = ExtraiNumero(seg, (pos45 >= 0) ? pos45 : (posBelow >= 0 ? posBelow : posCair));
      }

      if(r.d1 == 0) r.d1 = (intent == BUY) ? 55 : 45;

      r.handle = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
      r.active = true;

      if(intent == BUY && g_nBuyRules < MAX_RULES) g_buyRules[g_nBuyRules++] = r;
      if(intent == SELL && g_nSellRules < MAX_RULES) g_sellRules[g_nSellRules++] = r;
   }

   // Daily Breakout
   if(StringFind(seg, "breakout") >= 0)
   {
      Rule r;
      ZeroMemory(r);
      r.type = 5;
      r.active = true;
      if(intent == BUY && g_nBuyRules < MAX_RULES) g_buyRules[g_nBuyRules++] = r;
      if(intent == SELL && g_nSellRules < MAX_RULES) g_sellRules[g_nSellRules++] = r;
   }

   // Pattern
   if(StringFind(seg, "padrão") >= 0)
   {
      Rule r;
      ZeroMemory(r);
      r.type = 9;
      r.active = true;
      if(intent == BUY && g_nBuyRules < MAX_RULES) g_buyRules[g_nBuyRules++] = r;
      if(intent == SELL && g_nSellRules < MAX_RULES) g_sellRules[g_nSellRules++] = r;
   }
}

double ExtraiNumero(string txt, int startPos)
{
   string res = "";
   bool found = false;
   if(startPos < 0) startPos = 0;
   for(int i=startPos; i<StringLen(txt); i++)
   {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.' || c == '-' || c == '+')
      {
         res += ShortToString(c);
         found = true;
      }
      else if(found) break;
   }
   return StringToDouble(res);
}

void ResetStrategy()
{
   for(int i=0; i<g_nBuyRules; i++) { if(g_buyRules[i].handle != INVALID_HANDLE) IndicatorRelease(g_buyRules[i].handle); }
   for(int i=0; i<g_nSellRules; i++) { if(g_sellRules[i].handle != INVALID_HANDLE) IndicatorRelease(g_sellRules[i].handle); }

   ZeroMemory(g_buyRules);
   ZeroMemory(g_sellRules);
   g_nBuyRules = 0;
   g_nSellRules = 0;

   p_maxTrades = 1;
   p_riskPercent = 1.0;
   p_stopPoints = 300;
   p_takePoints = 500;
   p_breakeven = 0;
   p_breakevenEntry = 0;
   p_trailingStop = 0;
   p_startHour = 0;
   p_frequency = PERIOD_M15;
   p_newsVeto = false;
}

//+------------------------------------------------------------------+
//| Signal Engine                                                    |
//+------------------------------------------------------------------+

Signal AvaliaTudo()
{
   bool buyMet = (g_nBuyRules > 0);
   for(int i=0; i<g_nBuyRules; i++)
   {
      if(!AvaliaRegra(g_buyRules[i], BUY)) { buyMet = false; break; }
   }

   bool sellMet = (g_nSellRules > 0);
   for(int i=0; i<g_nSellRules; i++)
   {
      if(!AvaliaRegra(g_sellRules[i], SELL)) { sellMet = false; break; }
   }

   if(buyMet) return BUY;
   if(sellMet) return SELL;
   return NONE;
}

bool AvaliaRegra(Rule &r, int intent)
{
   if(!r.active) return false;

   double val[];
   ArraySetAsSeries(val, true);

   if(r.type == 1) // MA
   {
      if(CopyBuffer(r.handle, 0, 0, 2, val) < 2) return false;
      double price = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
      double pricePrev = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);

      if(r.oper == "cross_above") return (pricePrev <= val[1] && price > val[0]);
      if(r.oper == "cross_below") return (pricePrev >= val[1] && price < val[0]);
      if(r.oper == ">") return (price > val[0]);
      if(r.oper == "<") return (price < val[0]);
   }

   if(r.type == 2) // RSI
   {
      if(CopyBuffer(r.handle, 0, 0, 1, val) < 1) return false;
      if(r.oper == ">") return (val[0] > r.d1);
      if(r.oper == "<") return (val[0] < r.d1);
   }

   if(r.type == 5) // Daily Breakout
   {
      double hi = iHigh(_Symbol, PERIOD_D1, 1);
      double lo = iLow(_Symbol, PERIOD_D1, 1);
      double close = iClose(_Symbol, PERIOD_M1, 0);
      if(intent == BUY) return (close > hi);
      if(intent == SELL) return (close < lo);
   }

   if(r.type == 9) // 2-Bar Pattern
   {
      double h0=iHigh(_Symbol,(ENUM_TIMEFRAMES)r.tf,0);
      double l0=iLow(_Symbol,(ENUM_TIMEFRAMES)r.tf,0);
      double h1=iHigh(_Symbol,(ENUM_TIMEFRAMES)r.tf,1);
      double l1=iLow(_Symbol,(ENUM_TIMEFRAMES)r.tf,1);
      bool isInside = (h0<h1 && l0>l1);
      bool isOutside = (h0>h1 && l0<l1);
      bool isBullish = (iClose(_Symbol,(ENUM_TIMEFRAMES)r.tf,0) > iOpen(_Symbol,(ENUM_TIMEFRAMES)r.tf,0));

      if(isInside) return (intent == BUY ? isBullish : !isBullish);
      if(isOutside) return (intent == BUY ? !isBullish : isBullish);
   }

   return false;
}

//+------------------------------------------------------------------+
//| Trade Management                                                 |
//+------------------------------------------------------------------+

void executaSignal(Signal s, double risco)
{
   double lote = CalculaLote(risco);
   double sl = 0, tp = 0;
   double price = 0;

   int retry = 3;
   while(retry > 0)
   {
      if(s == BUY)
      {
         price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         sl = (p_stopPoints > 0) ? price - p_stopPoints * _Point : 0;
         tp = (p_takePoints > 0) ? price + p_takePoints * _Point : 0;
         if(g_trade.Buy(lote, _Symbol, price, sl, tp, "MT-LiveExecutor BUY")) break;
      }
      else if(s == SELL)
      {
         price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         sl = (p_stopPoints > 0) ? price + p_stopPoints * _Point : 0;
         tp = (p_takePoints > 0) ? price - p_takePoints * _Point : 0;
         if(g_trade.Sell(lote, _Symbol, price, sl, tp, "MT-LiveExecutor SELL")) break;
      }

      if(g_trade.ResultRetcode() == TRADE_RETCODE_REQUOTES || g_trade.ResultRetcode() == TRADE_RETCODE_PRICE_OFF)
      {
         retry--;
         Sleep(100);
      }
      else break;
   }

   if(g_trade.ResultRetcode() == TRADE_RETCODE_DONE || g_trade.ResultRetcode() == TRADE_RETCODE_PLACED)
   {
      GravaEstadoCSV(g_trade.ResultOrder(), g_trade.ResultPrice(), sl, tp, (s == BUY ? "BUY" : "SELL") + " Signal");
   }
   else
   {
      GravaLog("Erro ao enviar ordem: " + IntegerToString(g_trade.ResultRetcode()) + " - " + g_trade.ResultRetcodeDescription());
   }
}

double CalculaLote(double riscoPercent)
{
   double capital = AccountInfoDouble(ACCOUNT_BALANCE);
   double riscoAbs = capital * riscoPercent / 100.0;
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   double slPoints = p_stopPoints;
   if(slPoints <= 0) slPoints = 100;

   double lot = riscoAbs / (slPoints * _Point * (tickVal / tickSize));

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / step) * step;

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return lot;
}

void GerenciaPosicoes()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) != EA_MAGIC) continue;

         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profitPoints = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? (currentPrice - openPrice) / _Point : (openPrice - currentPrice) / _Point;

         // Breakeven
         if(p_breakeven > 0 && profitPoints >= p_breakeven)
         {
            double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? openPrice + p_breakevenEntry * _Point : openPrice - p_breakevenEntry * _Point;
            double currentSL = PositionGetDouble(POSITION_SL);

            bool modify = false;
            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && (currentSL < newSL || currentSL == 0)) modify = true;
            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (currentSL > newSL || currentSL == 0)) modify = true;

            if(modify)
            {
               g_trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
            }
         }

         // Trailing Stop
         if(p_trailingStop > 0 && profitPoints >= p_trailingStop)
         {
             double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? currentPrice - p_trailingStop * _Point : currentPrice + p_trailingStop * _Point;
             double currentSL = PositionGetDouble(POSITION_SL);

             bool modify = false;
             if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && currentSL < newSL) modify = true;
             if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (currentSL > newSL || currentSL == 0)) modify = true;

             if(modify)
             {
                g_trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
             }
         }
      }
   }
}

int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Utilities                                                        |
//+------------------------------------------------------------------+

void CheckPromptFile()
{
   string filename = "prompt.txt";
   if(FileIsExist(filename, FILE_COMMON))
   {
      int handle = FileOpen(filename, FILE_READ|FILE_TXT|FILE_COMMON);
      if(handle != INVALID_HANDLE)
      {
         string prompt = "";
         while(!FileIsEnding(handle)) prompt += FileReadString(handle);
         FileClose(handle);
         FileDelete(filename, FILE_COMMON);
         InterpretaPrompt(prompt);
      }
   }
}

bool AguardaNoticias()
{
   if(FileIsExist("news_veto.txt", FILE_COMMON))
   {
      int handle = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_COMMON);
      if(handle != INVALID_HANDLE)
      {
         string content = FileReadString(handle);
         FileClose(handle);
         if(StringFind(content, "VETO") >= 0) return true;
      }
   }
   return false;
}

void CalculaStats()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(equity > g_peakEquity) g_peakEquity = equity;
   double dd = (g_peakEquity > 0) ? (g_peakEquity - equity) / g_peakEquity * 100.0 : 0;
   if(dd > g_maxDrawdown) g_maxDrawdown = dd;

   GravaLog(StringFormat("Stats: Balance=%.2f, Equity=%.2f, MaxDD=%.2f%%", balance, equity, g_maxDrawdown));
}

void GravaLog(string texto)
{
   Print(texto);
   SendNotification(texto);
   SendMail("MT-LiveExecutor Alert", texto);
}

void GravaEstadoCSV(ulong ticket, double price, double sl, double tp, string reason)
{
   int handle = FileOpen("states.csv", FILE_WRITE|FILE_READ|FILE_CSV|FILE_COMMON);
   if(handle != INVALID_HANDLE)
   {
      FileSeek(handle, 0, SEEK_END);
      FileWrite(handle, ticket, price, sl, tp, TimeToString(TimeCurrent()), reason);
      FileClose(handle);
   }
}

// AI Simulation
double AIPredict()
{
   string filename = "signal_ai.txt";
   if(FileIsExist(filename, FILE_COMMON))
   {
      int handle = FileOpen(filename, FILE_READ|FILE_TXT|FILE_COMMON);
      if(handle != INVALID_HANDLE)
      {
         double val = StringToDouble(FileReadString(handle));
         FileClose(handle);
         return val;
      }
   }
   return 0;
}
