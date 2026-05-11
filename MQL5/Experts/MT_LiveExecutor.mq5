//=========================  MT5-KNOWLEDGE-CORE  =========================
// MT-LiveExecutor - Live Trading Agent
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

//--- Constants
#define EA_MAGIC 123456
#define MAX_RULES 20

//--- Signal Enums
enum ENUM_SIGNAL { SIGNAL_NONE=0, SIGNAL_BUY=1, SIGNAL_SELL=-1 };

//--- Rule Structure
struct Rule
{
   int            type;       // 1:MA, 2:RSI, 3:Stoch, 4:BB, 5:DailyBreak, 6:Delta, 7:Vol, 8:AMA, 9:Bar2, 10:RS, 11:AI
   int            intent;     // 1:BUY, -1:SELL
   int            tf;         // Timeframe
   int            p1, p2, p3; // Integer params (periods, etc.)
   double         d1, d2;     // Double params (thresholds, etc.)
   string         s1;         // String params (benchmark symbol, etc.)
   int            handle1;    // Indicator handle 1
   int            handle2;    // Indicator handle 2

   void Reset()
   {
      if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease(handle1);
      if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease(handle2);
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

//--- Global Strategy Parameters
Rule     rules[MAX_RULES];
int      nRules = 0;
int      currentIntent = 0;

double   p_riskPercent  = 1.0;
int      p_maxTrades    = 3;
string   p_startTime    = "00:00";
int      p_frequency    = PERIOD_M15;
int      p_stopPoints   = 300;
int      p_takePoints   = 500;
int      p_beStart      = 0;
int      p_bePlus       = 0;
int      p_trailingStop = 0;
int      p_trailingStep = 0;
bool     p_useMartingale = false;

datetime lastPromptUpdate = 0;
CTrade   trade;

//--- Helper Functions Declarations
int      PeriodoTexto(string nome);
double   ExtraiValorApos(string texto, string chave);
double   ExtraiNumero(string texto, int &pos);
double   GetBufferValue(int handle, int buffer, int shift);
bool     IsTimeAllowed();
void     GravaLog(string texto);
void     GravaCSV();
void     ResetStrategy();
void     InterpretaPrompt(string prompt);
int      AvaliaRegra(Rule &r);
int      AvaliaTudo();
double   CalculaLote(double risco);
void     EnviaOrdem(int tipo, double lote, string reason);
void     GerenciaPosicoes();
bool     AguardaNoticias();
void     AIOptimizer();
int      AISignal(Rule &r);

//--- Utility Functions Implementation

int PeriodoTexto(string nome)
{
   StringToLower(nome);
   if(StringFind(nome, "m15") >= 0) return PERIOD_M15;
   if(StringFind(nome, "m30") >= 0) return PERIOD_M30;
   if(StringFind(nome, "m1") >= 0)  return PERIOD_M1;
   if(StringFind(nome, "m5") >= 0)  return PERIOD_M5;
   if(StringFind(nome, "h1") >= 0)  return PERIOD_H1;
   if(StringFind(nome, "h4") >= 0)  return PERIOD_H4;
   if(StringFind(nome, "d1") >= 0)  return PERIOD_D1;

   if(StringFind(nome, "15 min") >= 0) return PERIOD_M15;
   if(StringFind(nome, "5 min") >= 0)  return PERIOD_M5;
   if(StringFind(nome, "1 min") >= 0)  return PERIOD_M1;

   return PERIOD_CURRENT;
}

double ExtraiValorApos(string texto, string chave)
{
   int pos = StringFind(texto, chave);
   if(pos < 0) return -1;
   pos += StringLen(chave);
   return ExtraiNumero(texto, pos);
}

double ExtraiNumero(string texto, int &pos)
{
   string res = "";
   bool found = false;
   int len = StringLen(texto);
   for(int i = pos; i < len; i++)
   {
      ushort c = StringGetCharacter(texto, i);
      if((c >= '0' && c <= '9') || c == '.')
      {
         res += ShortToString(c);
         found = true;
      }
      else if(found)
      {
         pos = i;
         break;
      }
      if(i == len - 1) pos = len;
   }
   return (res == "") ? 0 : StringToDouble(res);
}

double GetBufferValue(int handle, int buffer, int shift)
{
   double val[1];
   if(CopyBuffer(handle, buffer, shift, 1, val) > 0) return val[0];
   return 0;
}

bool IsTimeAllowed()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string now = StringFormat("%02d:%02d", dt.hour, dt.min);
   return (now >= p_startTime);
}

void GravaLog(string texto)
{
   int h = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE|FILE_READ|FILE_TXT|FILE_ANSI);
   if(h != INVALID_HANDLE)
   {
      FileSeek(h, 0, SEEK_END);
      FileWrite(h, TimeToString(TimeCurrent()) + ": " + texto);
      FileClose(h);
   }
   Print(texto);
}

void GravaCSV()
{
   int h = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(h != INVALID_HANDLE)
   {
      FileWrite(h, "Ticket", "Symbol", "Type", "Volume", "PriceOpen", "Time", "SL", "TP", "Profit", "Reason");
      for(int i = 0; i < PositionsTotal(); i++)
      {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelectByTicket(ticket))
         {
            if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC)
            {
               FileWrite(h, ticket,
                         PositionGetString(POSITION_SYMBOL),
                         PositionGetInteger(POSITION_TYPE),
                         PositionGetDouble(POSITION_VOLUME),
                         PositionGetDouble(POSITION_PRICE_OPEN),
                         TimeToString(PositionGetInteger(POSITION_TIME)),
                         PositionGetDouble(POSITION_SL),
                         PositionGetDouble(POSITION_TP),
                         PositionGetDouble(POSITION_PROFIT),
                         PositionGetString(POSITION_COMMENT));
            }
         }
      }
      FileClose(h);
   }
}

//--- NLP Parsing Logic

void ResetStrategy()
{
   for(int i = 0; i < nRules; i++) rules[i].Reset();
   nRules = 0;
   currentIntent = 0;
}

void InterpretaPrompt(string prompt)
{
   ResetStrategy();
   string work = prompt;
   StringToLower(work);

   // Parse Global Parameters
   double val;
   val = ExtraiValorApos(work, "risco de");
   if(val > 0) p_riskPercent = val;

   val = ExtraiValorApos(work, "máximo");
   if(val > 0) p_maxTrades = (int)val;

   int pos = StringFind(work, "depois das");
   if(pos >= 0)
   {
      pos += 10;
      int h = (int)ExtraiNumero(work, pos);
      p_startTime = StringFormat("%02d:00", h);
   }

   p_frequency = PeriodoTexto(work);

   val = ExtraiValorApos(work, "stop de");
   if(val > 0) p_stopPoints = (int)val;

   val = ExtraiValorApos(work, "take de");
   if(val > 0) p_takePoints = (int)val;

   val = ExtraiValorApos(work, "atingir +");
   if(val > 0) p_beStart = (int)val;

   val = ExtraiValorApos(work, "entrada +");
   if(val > 0) p_bePlus = (int)val;

   if(StringFind(work, "trailing") >= 0)
   {
      p_trailingStop = (int)ExtraiValorApos(work, "trailing");
      p_trailingStep = 10; // Default step
   }

   if(StringFind(work, "martingale") >= 0) p_useMartingale = true;

   // Split into segments for rules
   string segments[];
   string sep = "|";
   string tempWork = work;
   StringReplace(tempWork, " e ", sep);
   StringReplace(tempWork, ".", sep);
   StringReplace(tempWork, ",", sep);

   ushort u_sep = StringGetCharacter(sep, 0);
   int nSegs = StringSplit(tempWork, u_sep, segments);

   for(int i = 0; i < nSegs; i++)
   {
      string seg = segments[i];
      if(StringFind(seg, "compra") >= 0) currentIntent = 1;
      else if(StringFind(seg, "vende") >= 0) currentIntent = -1;

      if(currentIntent != 0 && nRules < MAX_RULES)
      {
         AddRule(seg);
      }
   }
}

void AddRule(string txt)
{
   // Moving Average
   if(StringFind(txt, "média") >= 0 || StringFind(txt, " ma ") >= 0)
   {
      rules[nRules].type = 1;
      rules[nRules].intent = currentIntent;
      rules[nRules].tf = PeriodoTexto(txt);
      if(rules[nRules].tf == PERIOD_CURRENT) rules[nRules].tf = p_frequency;

      int pos = 0;
      rules[nRules].p1 = (int)ExtraiNumero(txt, pos);
      if(rules[nRules].p1 == 0) rules[nRules].p1 = 20; // Default

      rules[nRules].p2 = (int)ExtraiNumero(txt, pos); // Second MA if exists

      if(rules[nRules].p2 > 0)
         rules[nRules].handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, rules[nRules].p1, 0, MODE_EMA, PRICE_CLOSE);
      else
         rules[nRules].handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, rules[nRules].p1, 0, MODE_EMA, PRICE_CLOSE);

      if(rules[nRules].p2 > 0)
         rules[nRules].handle2 = iMA(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, rules[nRules].p2, 0, MODE_EMA, PRICE_CLOSE);

      nRules++;
   }
   // RSI
   else if(StringFind(txt, "rsi") >= 0)
   {
      rules[nRules].type = 2;
      rules[nRules].intent = currentIntent;
      rules[nRules].tf = PeriodoTexto(txt);
      if(rules[nRules].tf == PERIOD_CURRENT) rules[nRules].tf = p_frequency;

      int pos = 0;
      int v1 = (int)ExtraiNumero(txt, pos);
      int v2 = (int)ExtraiNumero(txt, pos);

      if(v2 > 0) { rules[nRules].p1 = v1; rules[nRules].d1 = v2; }
      else if(v1 >= 40) { rules[nRules].p1 = 14; rules[nRules].d1 = v1; }
      else { rules[nRules].p1 = (v1 > 0) ? v1 : 14; rules[nRules].d1 = (currentIntent == 1) ? 55 : 45; }

      rules[nRules].handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, rules[nRules].p1, PRICE_CLOSE);
      nRules++;
   }
   // Stochastic
   else if(StringFind(txt, "estocástico") >= 0 || StringFind(txt, "stoch") >= 0)
   {
      rules[nRules].type = 3;
      rules[nRules].intent = currentIntent;
      rules[nRules].tf = PeriodoTexto(txt);
      rules[nRules].handle1 = iStochastic(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
      nRules++;
   }
   // Bollinger Bands
   else if(StringFind(txt, "bollinger") >= 0 || StringFind(txt, " bb ") >= 0)
   {
      rules[nRules].type = 4;
      rules[nRules].intent = currentIntent;
      rules[nRules].tf = PeriodoTexto(txt);
      rules[nRules].handle1 = iBands(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, 20, 0, 2.0, PRICE_CLOSE);
      nRules++;
   }
   // Daily Breakout
   else if(StringFind(txt, "rompimento diário") >= 0)
   {
      rules[nRules].type = 5;
      rules[nRules].intent = currentIntent;
      nRules++;
   }
   // Volume
   else if(StringFind(txt, "volume") >= 0)
   {
      rules[nRules].type = 7;
      rules[nRules].intent = currentIntent;
      rules[nRules].tf = PeriodoTexto(txt);
      nRules++;
   }
   // AMA
   else if(StringFind(txt, "ama") >= 0 || StringFind(txt, "adaptativa") >= 0)
   {
      rules[nRules].type = 8;
      rules[nRules].intent = currentIntent;
      rules[nRules].tf = PeriodoTexto(txt);
      rules[nRules].handle1 = iAMA(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, 10, 2, 30, 0, PRICE_CLOSE);
      nRules++;
   }
   // Bar Patterns
   else if(StringFind(txt, "padrão barras") >= 0 || StringFind(txt, "bar2") >= 0)
   {
      rules[nRules].type = 9;
      rules[nRules].intent = currentIntent;
      rules[nRules].tf = PeriodoTexto(txt);
      nRules++;
   }
}

//--- Signal Evaluation and Trade Execution Logic

int AvaliaRegra(Rule &r)
{
   if(r.type == 1) // MA
   {
      double ma1_curr = GetBufferValue(r.handle1, 0, 1);
      double ma1_prev = GetBufferValue(r.handle1, 0, 2);

      if(r.handle2 != INVALID_HANDLE) // MA vs MA
      {
         double ma2_curr = GetBufferValue(r.handle2, 0, 1);
         double ma2_prev = GetBufferValue(r.handle2, 0, 2);
         if(ma1_prev <= ma2_prev && ma1_curr > ma2_curr) return 1;
         if(ma1_prev >= ma2_prev && ma1_curr < ma2_curr) return -1;
      }
      else // Price vs MA
      {
         double close1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         double close2 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
         if(close2 <= ma1_prev && close1 > ma1_curr) return 1;
         if(close2 >= ma1_prev && close1 < ma1_curr) return -1;
      }
   }
   else if(r.type == 2) // RSI
   {
      double rsi1 = GetBufferValue(r.handle1, 0, 1);
      double rsi2 = GetBufferValue(r.handle1, 0, 2);
      if(rsi2 <= rsi1 && rsi1 > r.d1) return 1;
      if(rsi2 >= rsi1 && rsi1 < r.d1) return -1;
   }
   else if(r.type == 3) // Stoch
   {
      double k1 = GetBufferValue(r.handle1, 0, 1);
      double d1 = GetBufferValue(r.handle1, 1, 1);
      double k2 = GetBufferValue(r.handle1, 0, 2);
      double d2 = GetBufferValue(r.handle1, 1, 2);
      if(k2 <= d2 && k1 > d1) return 1;
      if(k2 >= d2 && k1 < d1) return -1;
   }
   else if(r.type == 4) // BB
   {
      double close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
      double upper = GetBufferValue(r.handle1, 1, 1);
      double lower = GetBufferValue(r.handle1, 2, 1);
      if(close < lower) return 1;
      if(close > upper) return -1;
   }
   else if(r.type == 5) // Daily Break
   {
      double hi = iHigh(_Symbol, PERIOD_D1, 1);
      double lo = iLow(_Symbol, PERIOD_D1, 1);
      double close = iClose(_Symbol, PERIOD_M1, 0);
      if(close > hi) return 1;
      if(close < lo) return -1;
   }
   else if(r.type == 7) // Volume
   {
      double v1 = (double)iVolume(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
      double v2 = (double)iVolume(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
      if(v1 > v2 * 1.5) return 1;
   }
   else if(r.type == 8) // AMA
   {
      double ama1 = GetBufferValue(r.handle1, 0, 1);
      double ama2 = GetBufferValue(r.handle1, 0, 2);
      if(ama1 > ama2) return 1;
      if(ama1 < ama2) return -1;
   }
   else if(r.type == 9) // Bar2
   {
      double h1 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
      double l1 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
      double h2 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
      double l2 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
      if(h1 < h2 && l1 > l2) return (iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1)) ? 1 : -1;
      if(h1 > h2 && l1 < l2) return (iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1)) ? -1 : 1;
   }
   return 0;
}

int AvaliaTudo()
{
   int buyVotos = 0, buyRules = 0;
   int sellVotos = 0, sellRules = 0;

   for(int i = 0; i < nRules; i++)
   {
      int res = AvaliaRegra(rules[i]);
      if(rules[i].intent == 1)
      {
         buyRules++;
         if(res == 1) buyVotos++;
      }
      else if(rules[i].intent == -1)
      {
         sellRules++;
         if(res == -1) sellVotos++;
      }
   }

   if(buyRules > 0 && buyVotos == buyRules) return 1;
   if(sellRules > 0 && sellVotos == sellRules) return -1;

   return 0;
}

double CalculaLote(double riscoPercent)
{
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = capital * riscoPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(p_stopPoints == 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double lote = riskAmount / (p_stopPoints * (tickValue / (tickSize / _Point)));

   if(p_useMartingale)
   {
      HistorySelect(TimeCurrent() - 86400 * 7, TimeCurrent());
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC)
         {
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) lote *= 2.0;
            break;
         }
      }
   }

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lote = MathFloor(lote / step) * step;
   return MathMax(MathMin(lote, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX)), SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
}

void EnviaOrdem(int tipo, double lote, string reason)
{
   double price = (tipo == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = (tipo == 1) ? price - p_stopPoints * _Point : price + p_stopPoints * _Point;
   double tp = (tipo == 1) ? price + p_takePoints * _Point : price - p_takePoints * _Point;

   if(p_stopPoints == 0) sl = 0;
   if(p_takePoints == 0) tp = 0;

   double margin;
   if(!OrderCalcMargin((ENUM_ORDER_TYPE)tipo, _Symbol, lote, price, margin)) return;
   if(margin > AccountInfoDouble(ACCOUNT_FREEMARGIN))
   {
      GravaLog("Margem insuficiente. Necessária: " + (string)margin + ", Disponível: " + (string)AccountInfoDouble(ACCOUNT_FREEMARGIN));
      return;
   }

   for(int i = 0; i < 3; i++)
   {
      bool res = (tipo == 1) ? trade.Buy(lote, _Symbol, price, sl, tp, reason) : trade.Sell(lote, _Symbol, price, sl, tp, reason);
      if(res)
      {
         uint retcode = trade.ResultRetcode();
         if(retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED)
         {
            GravaLog("Ordem enviada: " + reason);
            SendNotification("Trade Executado: " + reason);
            break;
         }
         else if(retcode == TRADE_RETCODE_REQUOTES || retcode == TRADE_RETCODE_OFFQUOTES)
         {
            price = (tipo == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
            continue;
         }
      }
   }
}

void GerenciaPosicoes()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC)
         {
            double open = PositionGetDouble(POSITION_PRICE_OPEN);
            double curr = PositionGetDouble(POSITION_PRICE_CURRENT);
            double sl = PositionGetDouble(POSITION_SL);
            int type = (int)PositionGetInteger(POSITION_TYPE);
            double profitPoints = (type == POSITION_TYPE_BUY) ? (curr - open) / _Point : (open - curr) / _Point;

            // Breakeven
            if(p_beStart > 0 && profitPoints >= p_beStart)
            {
               double newSL = (type == POSITION_TYPE_BUY) ? open + p_bePlus * _Point : open - p_bePlus * _Point;
               if((type == POSITION_TYPE_BUY && (sl < newSL || sl == 0)) || (type == POSITION_TYPE_SELL && (sl > newSL || sl == 0)))
               {
                  trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
               }
            }

            // Trailing Stop
            if(p_trailingStop > 0 && profitPoints >= p_trailingStop)
            {
               double newSL = (type == POSITION_TYPE_BUY) ? curr - p_trailingStop * _Point : curr + p_trailingStop * _Point;
               if((type == POSITION_TYPE_BUY && (newSL > sl + p_trailingStep * _Point)) || (type == POSITION_TYPE_SELL && (newSL < sl - p_trailingStep * _Point || sl == 0)))
               {
                  trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
               }
            }
         }
      }
   }
}

//--- Event Handlers and Optimization Logic

bool AguardaNoticias()
{
   int h = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_ANSI);
   if(h != INVALID_HANDLE)
   {
      string content = FileReadString(h);
      FileClose(h);
      if(StringFind(content, "veto=true") >= 0) return true;
   }
   return false;
}

void AIOptimizer()
{
   static datetime lastOpt = 0;
   if(TimeCurrent() - lastOpt < 3600) return;
   lastOpt = TimeCurrent();

   HistorySelect(TimeCurrent() - 86400 * 30, TimeCurrent());
   int total = 0, wins = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0 && total < 10; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC)
      {
         total++;
         if(HistoryDealGetDouble(ticket, DEAL_PROFIT) > 0) wins++;
      }
   }

   if(total >= 5 && (double)wins/total < 0.4)
   {
      p_riskPercent *= 0.8;
      GravaLog("AI Optimizer: Reduzindo risco devido a baixo win rate (" + (string)((double)wins/total*100) + "%)");
   }
}

int AISignal(Rule &r)
{
   double atr = GetBufferValue(r.handle1, 0, 1);
   double body = MathAbs(iClose(_Symbol, PERIOD_CURRENT, 1) - iOpen(_Symbol, PERIOD_CURRENT, 1));
   if(body > 1.5 * atr)
   {
      return (iClose(_Symbol, PERIOD_CURRENT, 1) > iOpen(_Symbol, PERIOD_CURRENT, 1)) ? 1 : -1;
   }
   return 0;
}

int OnInit()
{
   trade.SetExpertMagicNumber(EA_MAGIC);
   EventSetTimer(1);
   GravaLog("MT-LiveExecutor Iniciado.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   ResetStrategy();
   EventKillTimer();
   GravaLog("MT-LiveExecutor Finalizado.");
}

void OnTimer()
{
   // Monitor prompt.txt for updates
   long currMod = FileGetInteger("prompt.txt", FILE_MODIFY_DATE);
   if(currMod > lastPromptUpdate)
   {
      lastPromptUpdate = (datetime)currMod;
      int h = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_ANSI);
      if(h != INVALID_HANDLE)
      {
         string prompt = FileReadString(h);
         FileClose(h);
         InterpretaPrompt(prompt);
         GravaLog("Nova estratégia carregada: " + prompt);
      }
   }

   AIOptimizer();
}

void OnTick()
{
   GravaCSV();
   GerenciaPosicoes();

   if(!IsTimeAllowed()) return;
   if(AguardaNoticias()) return;

   static datetime lastBar = 0;
   datetime currBar = iTime(_Symbol, (ENUM_TIMEFRAMES)p_frequency, 0);
   if(currBar == lastBar) return;
   lastBar = currBar;

   int signal = AvaliaTudo();
   if(signal != 0)
   {
      int count = 0;
      for(int i = 0; i < PositionsTotal(); i++)
      {
         if(PositionSelectByTicket(PositionGetTicket(i)))
         {
            if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) count++;
         }
      }

      if(count < p_maxTrades)
      {
         double lote = CalculaLote(p_riskPercent);
         EnviaOrdem(signal, lote, "Sinal NLP");
      }
   }
}
