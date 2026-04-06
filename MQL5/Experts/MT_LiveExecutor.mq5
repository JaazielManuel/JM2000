//=========================  MT5-LIVE-EXECUTOR  =========================
// Módulo Único de Execução de Estratégias por NLP em Português
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// ---------- DEFINIÇÕES GLOBAIS ----------
#define EA_MAGIC 20260101

enum Signal {BUY=1, SELL=-1, NONE=0};

enum RuleType {
   RULE_MA_CROSS,
   RULE_RSI,
   RULE_STOCH,
   RULE_BB,
   RULE_DAILY_BREAK,
   RULE_DELTA,
   RULE_VOLUME,
   RULE_AMA,
   RULE_BAR2,
   RULE_RS_RELATIVE,
   RULE_UNKNOWN
};

struct Rule {
   bool      active;
   RuleType  type;
   ENUM_TIMEFRAMES tf;
   int       p1, p2, p3;
   double    d1, d2;
   string    s1;
   Signal    intent; // BUY ou SELL para o qual esta regra contribui
   int       handle1, handle2;
};

// Variáveis Globais de Operação
Rule rules[30];
int nRules = 0;

double p_riskPercent = 1.0;
int    p_stopPoints = 300;
int    p_takePoints = 500;
int    p_trailingStopPoints = 0;
int    p_breakEvenPoints = 0;
int    p_breakEvenLock = 50;
bool   p_useMartingale = false;
bool   p_hedge = true;
int    p_maxSimultaneous = 3;
int    p_startTimeSeconds = 0; // Segundos desde a meia-noite

int    dynamicSafetyPoints = 0;
datetime lastSafetyDecay = 0;
datetime lastBarTime = 0;
datetime lastCSVWrite = 0;

CTrade trade;

// Forward declarations
void ResetStrategy()
{
   for(int i=0; i<nRules; i++)
   {
      if(rules[i].handle1 != INVALID_HANDLE) IndicatorRelease(rules[i].handle1);
      if(rules[i].handle2 != INVALID_HANDLE) IndicatorRelease(rules[i].handle2);
   }
   nRules = 0;
   p_riskPercent = 1.0;
   p_stopPoints = 300;
   p_takePoints = 500;
   p_trailingStopPoints = 0;
   p_breakEvenPoints = 0;
   p_useMartingale = false;
   p_hedge = true;
   p_maxSimultaneous = 3;
   p_startTimeSeconds = 0;
}

void AddRule(RuleType type, ENUM_TIMEFRAMES tf, int p1, int p2, double d1, Signal intent, string s1="")
{
   // Tenta atualizar regra existente
   for(int i=0; i<nRules; i++)
   {
      if(rules[i].type == type && rules[i].tf == tf && rules[i].intent == intent)
      {
         rules[i].p1 = p1; rules[i].p2 = p2; rules[i].d1 = d1; rules[i].s1 = s1;
         return;
      }
   }

   if(nRules >= 30) return;

   Rule r;
   r.active = true;
   r.type = type;
   r.tf = tf;
   r.p1 = p1; r.p2 = p2; r.d1 = d1;
   r.intent = intent;
   r.s1 = s1;
   r.handle1 = INVALID_HANDLE;
   r.handle2 = INVALID_HANDLE;

   if(type == RULE_MA_CROSS) {
      r.handle1 = iMA(_Symbol, tf, p1, 0, MODE_EMA, PRICE_CLOSE);
      if(p2 > 0) r.handle2 = iMA(_Symbol, tf, p2, 0, MODE_EMA, PRICE_CLOSE);
   } else if(type == RULE_RSI) {
      r.handle1 = iRSI(_Symbol, tf, p1, PRICE_CLOSE);
   } else if(type == RULE_STOCH) {
      r.handle1 = iStochastic(_Symbol, tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
   } else if(type == RULE_BB) {
      r.handle1 = iBands(_Symbol, tf, 20, 0, 2.0, PRICE_CLOSE);
   } else if(type == RULE_AMA) {
      r.handle1 = iAMA(_Symbol, tf, 10, 2, 30, 0, PRICE_CLOSE);
   }

   rules[nRules++] = r;
}

void InterpretaPrompt(string prompt)
{
   ResetStrategy();
   string p = prompt;
   StringToLower(p);
   StringReplace(p, ",", ".");

   string segments[];
   StringSplit(p, '.', segments);

   Signal currentIntent = NONE;

   for(int i=0; i<ArraySize(segments); i++)
   {
      string s = segments[i];
      if(StringFind(s, "compra") >= 0) currentIntent = BUY;
      else if(StringFind(s, "vende") >= 0) currentIntent = SELL;

      // Filtros de Operação
      if(StringFind(s, "risco") >= 0) p_riskPercent = ExtractNumber(s, "risco");
      if(StringFind(s, "stop") >= 0 && StringFind(s, "move") < 0) p_stopPoints = (int)ExtractNumber(s, "stop");
      if(StringFind(s, "take") >= 0) p_takePoints = (int)ExtractNumber(s, "take");
      if(StringFind(s, "martingale") >= 0) p_useMartingale = true;
      if(StringFind(s, "máximo") >= 0) p_maxSimultaneous = (int)ExtractNumber(s, "máximo");

      // Gestão
      if(StringFind(s, "move stop") >= 0) {
         p_breakEvenPoints = (int)ExtractNumber(s, "atingir");
         p_breakEvenLock = (int)ExtractNumber(s, "entrada +");
      }
      if(StringFind(s, "trailing") >= 0) p_trailingStopPoints = (int)ExtractNumber(s, "trailing");

      // Horário
      if(StringFind(s, "depois das") >= 0) {
         string t = ExtractTime(s);
         p_startTimeSeconds = (int)StringToTime(t) % 86400;
      }

      // Indicadores
      ENUM_TIMEFRAMES tf = PeriodoTexto(s);

      if(StringFind(s, "média") >= 0) {
         int per1 = (int)ExtractNumber(s, "média");
         if(per1 <= 0) per1 = 20;
         int per2 = -1;
         // Tenta achar segunda média
         int slash = StringFind(s, "/");
         if(slash > 0) per2 = (int)StringToInteger(StringSubstr(s, slash+1));

         AddRule(RULE_MA_CROSS, tf, per1, per2, 0, currentIntent);
      }

      if(StringFind(s, "rsi") >= 0) {
         int per = (int)ExtractNumber(s, "rsi");
         if(per <= 0 || per > 100) per = 14;
         double threshold = ExtractNumber(s, "acima") > 0 ? ExtractNumber(s, "acima") : ExtractNumber(s, "abaixo");
         string context = (StringFind(s, "acima") >= 0) ? "acima" : "abaixo";
         AddRule(RULE_RSI, tf, per, -1, threshold, currentIntent, context);
      }

      if(StringFind(s, "ama") >= 0 || StringFind(s, "adaptativa") >= 0) AddRule(RULE_AMA, tf, 10, -1, 0, currentIntent);
      if(StringFind(s, "volume") >= 0) AddRule(RULE_VOLUME, tf, 10, -1, 0, currentIntent);
      if(StringFind(s, "padrão") >= 0 && StringFind(s, "barras") >= 0) AddRule(RULE_BAR2, tf, 0, -1, 0, currentIntent);
      if(StringFind(s, "delta") >= 0) AddRule(RULE_DELTA, tf, 60, -1, 0, currentIntent);
      if(StringFind(s, "rompimento") >= 0 && StringFind(s, "diário") >= 0) AddRule(RULE_DAILY_BREAK, PERIOD_D1, 0, -1, 0, currentIntent);
   }
}
void GerenciaPosicoes()
{
   CPositionInfo pos;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      if(pos.SelectByIndex(i) && pos.Magic() == EA_MAGIC && pos.Symbol() == _Symbol)
      {
         double profitPoints = (pos.Type() == POSITION_TYPE_BUY) ? (SymbolInfoDouble(_Symbol, SYMBOL_BID) - pos.PriceOpen()) / _Point
                                                                : (pos.PriceOpen() - SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / _Point;

         // Break-even
         if(p_breakEvenPoints > 0 && profitPoints >= p_breakEvenPoints)
         {
            double newSL = (pos.Type() == POSITION_TYPE_BUY) ? pos.PriceOpen() + p_breakEvenLock * _Point
                                                             : pos.PriceOpen() - p_breakEvenLock * _Point;
            if((pos.Type() == POSITION_TYPE_BUY && (pos.StopLoss() < newSL || pos.StopLoss() == 0)) ||
               (pos.Type() == POSITION_TYPE_SELL && (pos.StopLoss() > newSL || pos.StopLoss() == 0)))
               trade.PositionModify(pos.Ticket(), newSL, pos.TakeProfit());
         }

         // Trailing Stop
         if(p_trailingStopPoints > 0 && profitPoints >= p_trailingStopPoints)
         {
            double newSL = (pos.Type() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) - p_trailingStopPoints * _Point
                                                             : SymbolInfoDouble(_Symbol, SYMBOL_ASK) + p_trailingStopPoints * _Point;
            if((pos.Type() == POSITION_TYPE_BUY && pos.StopLoss() < newSL) ||
               (pos.Type() == POSITION_TYPE_SELL && (pos.StopLoss() > newSL || pos.StopLoss() == 0)))
               trade.PositionModify(pos.Ticket(), newSL, pos.TakeProfit());
         }
      }
   }
}

bool AguardaNoticias()
{
   if(!FileIsExist("news_veto.txt")) return false;
   int h = FileOpen("news_veto.txt", FILE_READ | FILE_TXT);
   if(h == INVALID_HANDLE) return false;
   string content = FileReadString(h);
   FileClose(h);
   if(content == "1") return true;
   return false;
}

void GravaLog(string text)
{
   int h = FileOpen("MT_LiveExecutor_Log.txt", FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h != INVALID_HANDLE)
   {
      FileSeek(h, 0, SEEK_END);
      FileWriteString(h, TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + ": " + text + "\r\n");
      FileClose(h);
   }
   Print(text);
}

void GravaCSV()
{
   if(TimeCurrent() - lastCSVWrite < 5) return;
   lastCSVWrite = TimeCurrent();
   int h = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV);
   if(h != INVALID_HANDLE) {
      FileWrite(h, "Ticket", "Type", "OpenPrice", "SL", "TP");
      CPositionInfo pos;
      for(int i=0; i<PositionsTotal(); i++) {
         if(pos.SelectByIndex(i) && pos.Magic() == EA_MAGIC)
            FileWrite(h, pos.Ticket(), pos.Type(), pos.PriceOpen(), pos.StopLoss(), pos.TakeProfit());
      }
      FileClose(h);
   }
}

void CalculaEstatisticas()
{
   double profit = 0, loss = 0;
   int win = 0, total = 0;

   HistorySelect(TimeCurrent() - 86400 * 30, TimeCurrent());
   for(int i=0; i<HistoryDealsTotal(); i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC)
      {
         double p = HistoryDealGetDouble(ticket, DEAL_PROFIT) + HistoryDealGetDouble(ticket, DEAL_COMMISSION) + HistoryDealGetDouble(ticket, DEAL_SWAP);
         if(p != 0) {
            total++;
            if(p > 0) { win++; profit += p; }
            else loss -= p;
         }
      }
   }

   double winRate = (total > 0) ? (double)win / total * 100.0 : 0;
   double profitFactor = (loss > 0) ? profit / loss : profit;

   string stats = StringFormat("WinRate: %.2f%% | PF: %.2f | Trades: %d", winRate, profitFactor, total);
   GlobalVariableSet("MT_Executor_WinRate", winRate);
   GlobalVariableSet("MT_Executor_PF", profitFactor);

   static datetime lastStatLog = 0;
   if(TimeCurrent() - lastStatLog >= 3600)
   {
      GravaLog("ESTATÍSTICAS: " + stats);
      lastStatLog = TimeCurrent();
   }
}

double CalculaLote(double riscoPercent)
{
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = capital * (riscoPercent / 100.0);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   double lot = NormalizeDouble(riskAmount / (p_stopPoints * (tickValue / (tickSize / _Point))), 2);

   if(p_useMartingale)
   {
      HistorySelect(TimeCurrent() - 86400, TimeCurrent());
      for(int i=HistoryDealsTotal()-1; i>=0; i--)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC)
         {
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) lot *= 2.0;
            break;
         }
      }
   }
   return MathMax(lot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
}

Signal AvaliaTudo()
{
   int buyVotos = 0, sellVotos = 0;
   int buyRules = 0, sellRules = 0;

   for(int i=0; i<nRules; i++)
   {
      Signal s = AvaliaRegra(rules[i]);
      if(rules[i].intent == BUY) {
         buyRules++;
         if(s == BUY) buyVotos++;
      } else if(rules[i].intent == SELL) {
         sellRules++;
         if(s == SELL) sellVotos++;
      }
   }

   if(buyRules > 0 && buyVotos == buyRules) return BUY;
   if(sellRules > 0 && sellVotos == sellRules) return SELL;
   return NONE;
}
Signal AvaliaRegra(Rule &r)
{
   if(!r.active) return NONE;
   double buf1[], buf2[];
   ArraySetAsSeries(buf1, true);
   ArraySetAsSeries(buf2, true);

   switch(r.type)
   {
      case RULE_MA_CROSS:
         if(CopyBuffer(r.handle1, 0, 0, 2, buf1) < 2) return NONE;
         if(r.handle2 != INVALID_HANDLE)
         {
            if(CopyBuffer(r.handle2, 0, 0, 2, buf2) < 2) return NONE;
            if(buf1[1] < buf2[1] && buf1[0] > buf2[0]) return BUY;
            if(buf1[1] > buf2[1] && buf1[0] < buf2[0]) return SELL;
         }
         else // Preço vs MA
         {
            double close0 = iClose(_Symbol, r.tf, 0);
            double close1 = iClose(_Symbol, r.tf, 1);
            if(close1 < buf1[1] && close0 > buf1[0]) return BUY;
            if(close1 > buf1[1] && close0 < buf1[0]) return SELL;
         }
         break;

      case RULE_RSI:
         if(CopyBuffer(r.handle1, 0, 0, 1, buf1) < 1) return NONE;
         if(r.intent == BUY) {
            if(StringFind(r.s1, "acima") >= 0 && buf1[0] > r.d1) return BUY;
            if(StringFind(r.s1, "abaixo") >= 0 && buf1[0] < r.d1) return BUY;
         } else if(r.intent == SELL) {
            if(StringFind(r.s1, "acima") >= 0 && buf1[0] > r.d1) return SELL;
            if(StringFind(r.s1, "abaixo") >= 0 && buf1[0] < r.d1) return SELL;
         }
         break;

      case RULE_STOCH:
         if(CopyBuffer(r.handle1, 0, 0, 2, buf1) < 2) return NONE; // %K
         if(CopyBuffer(r.handle1, 1, 0, 2, buf2) < 2) return NONE; // %D
         if(buf1[1] < buf2[1] && buf1[0] > buf2[0]) return BUY;
         if(buf1[1] > buf2[1] && buf1[0] < buf2[0]) return SELL;
         break;

      case RULE_BB:
         if(CopyBuffer(r.handle1, 1, 0, 1, buf1) < 1) return NONE; // Upper
         if(CopyBuffer(r.handle1, 2, 0, 1, buf2) < 1) return NONE; // Lower
         double close = iClose(_Symbol, r.tf, 0);
         if(close < buf2[0]) return BUY;
         if(close > buf1[0]) return SELL;
         break;

      case RULE_DAILY_BREAK:
         double hi = iHigh(_Symbol, PERIOD_D1, 1);
         double lo = iLow(_Symbol, PERIOD_D1, 1);
         double c = iClose(_Symbol, PERIOD_M1, 0);
         if(c > hi) return BUY;
         if(c < lo) return SELL;
         break;

      case RULE_AMA:
         if(CopyBuffer(r.handle1, 0, 0, 2, buf1) < 2) return NONE;
         if(buf1[1] < buf1[0]) return BUY;
         if(buf1[1] > buf1[0]) return SELL;
         break;

      case RULE_VOLUME:
         long vol[]; ArraySetAsSeries(vol, true);
         if(CopyVolume(_Symbol, r.tf, 0, 10, vol) < 10) return NONE;
         long maxV = vol[0], minV = vol[0];
         for(int i=1; i<10; i++) {
            if(vol[i] > maxV) maxV = vol[i];
            if(vol[i] < minV) minV = vol[i];
         }
         if(vol[0] == minV) return BUY;
         if(vol[0] == maxV) return SELL;
         break;

      case RULE_BAR2:
         double h0 = iHigh(_Symbol, r.tf, 0), l0 = iLow(_Symbol, r.tf, 0);
         double h1 = iHigh(_Symbol, r.tf, 1), l1 = iLow(_Symbol, r.tf, 1);
         bool bull = iClose(_Symbol, r.tf, 0) > iOpen(_Symbol, r.tf, 0);
         if(h0 < h1 && l0 > l1) return bull ? BUY : SELL; // Inside
         if(h0 > h1 && l0 < l1) return bull ? SELL : BUY; // Outside
         break;

      case RULE_DELTA:
         MqlTick ticks[];
         int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, TimeCurrent() - 60, TimeCurrent());
         long b = 0, s = 0;
         for(int i=0; i<n; i++) if(ticks[i].flags & TICK_FLAG_BUY) b++; else s++;
         if(b - s > 300) return BUY;
         if(s - b > 300) return SELL;
         break;
   }
   return NONE;
}

void EnviaOrdem(Signal s)
{
   if(s == NONE) return;

   // Veto por notícias
   if(AguardaNoticias()) return;

   // Veto por horário
   if(TimeCurrent() % 86400 < p_startTimeSeconds) return;

   // Limite de simultâneos
   int currentTrades = 0;
   CPositionInfo pos;
   for(int i=0; i<PositionsTotal(); i++)
      if(pos.SelectByIndex(i) && pos.Magic() == EA_MAGIC) currentTrades++;

   if(currentTrades >= p_maxSimultaneous) return;

   // Hedge logic
   if(!p_hedge)
   {
      for(int i=PositionsTotal()-1; i>=0; i--)
      {
         if(pos.SelectByIndex(i) && pos.Magic() == EA_MAGIC && pos.Symbol() == _Symbol)
         {
            if((s == BUY && pos.Type() == POSITION_TYPE_SELL) || (s == SELL && pos.Type() == POSITION_TYPE_BUY))
               trade.PositionClose(pos.Ticket());
         }
      }
   }

   double lot = CalculaLote(p_riskPercent);
   double stopsLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double safetyFloor = stopsLevel + dynamicSafetyPoints + 1.0;

   double stopLossPoints = MathMax(p_stopPoints, safetyFloor);
   double takeProfitPoints = p_takePoints;

   if(s == BUY)
   {
      double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl = price - stopLossPoints * _Point;
      double tp = price + takeProfitPoints * _Point;
      trade.SetExpertMagicNumber(EA_MAGIC);
      if(!trade.Buy(lot, _Symbol, price, sl, tp)) {
         dynamicSafetyPoints = MathMin(dynamicSafetyPoints + 5, 100);
         GravaLog("ERRO COMPRA: " + trade.ResultRetcodeDescription());
      } else {
         GravaLog(StringFormat("COMPRA EXECUTADA: Lote %.2f, SL %.0f, TP %.0f", lot, stopLossPoints, takeProfitPoints));
      }
   }
   else if(s == SELL)
   {
      double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl = price + stopLossPoints * _Point;
      double tp = price - takeProfitPoints * _Point;
      trade.SetExpertMagicNumber(EA_MAGIC);
      if(!trade.Sell(lot, _Symbol, price, sl, tp)) {
         dynamicSafetyPoints = MathMin(dynamicSafetyPoints + 5, 100);
         GravaLog("ERRO VENDA: " + trade.ResultRetcodeDescription());
      } else {
         GravaLog(StringFormat("VENDA EXECUTADA: Lote %.2f, SL %.0f, TP %.0f", lot, stopLossPoints, takeProfitPoints));
      }
   }
}

// Lifecycle Handlers
int OnInit()
{
   EventSetTimer(1);
   trade.SetExpertMagicNumber(EA_MAGIC);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
}

void OnTick()
{
   GerenciaPosicoes();
   GravaCSV();
   CalculaEstatisticas();

   if(iTime(_Symbol, _Period, 0) != lastBarTime)
   {
      lastBarTime = iTime(_Symbol, _Period, 0);
      Signal s = AvaliaTudo();
      if(s != NONE) EnviaOrdem(s);
   }
}

void OnTimer()
{
   // Safety decay
   if(TimeCurrent() - lastSafetyDecay >= 60)
   {
      if(dynamicSafetyPoints > 0) dynamicSafetyPoints--;
      lastSafetyDecay = TimeCurrent();
   }

   // No-restart update mechanism
   if(GlobalVariableCheck("MT_Executor_Prompt_Update"))
   {
      if(GlobalVariableGet("MT_Executor_Prompt_Update") > 0)
      {
         int h = FileOpen("MT_LiveExecutor_Prompt.txt", FILE_READ | FILE_TXT);
         if(h != INVALID_HANDLE)
         {
            string prompt = FileReadString(h);
            FileClose(h);
            InterpretaPrompt(prompt);
         }
         GlobalVariableSet("MT_Executor_Prompt_Update", 0);
      }
   }
}

// Utilitários NLP
double ExtractNumber(string text, string keyword)
{
   string t = text;
   StringToLower(t);
   StringReplace(t, ",", ".");
   int pos = StringFind(t, keyword);
   if(pos < 0) return -1;

   string sub = StringSubstr(t, pos + StringLen(keyword));
   string res = "";
   bool start = false;
   for(int i=0; i<StringLen(sub); i++)
   {
      ushort c = StringGetCharacter(sub, i);
      if((c >= '0' && c <= '9') || c == '.') {
         res += StringSubstr(sub, i, 1);
         start = true;
      } else if(start) break;
   }
   return StringToDouble(res);
}

string ExtractTime(string text)
{
   string t = text;
   StringToLower(t);
   int pos = StringFind(t, "h");
   if(pos < 0) return "";

   // Formato "10h" -> "10:00"
   // Formato "10:30" -> "10:30"
   string sub = StringSubstr(t, pos-2, 5);
   StringReplace(sub, "h", ":00");
   return sub;
}

ENUM_TIMEFRAMES PeriodoTexto(string nome)
{
   string n = nome;
   StringToLower(n);
   if(StringFind(n, "m15") >= 0) return PERIOD_M15;
   if(StringFind(n, "m30") >= 0) return PERIOD_M30;
   if(StringFind(n, "m1") >= 0)  return PERIOD_M1;
   if(StringFind(n, "m5") >= 0)  return PERIOD_M5;
   if(StringFind(n, "h1") >= 0)  return PERIOD_H1;
   if(StringFind(n, "d1") >= 0)  return PERIOD_D1;
   if(StringFind(n, "minutos") >= 0) {
      if(StringFind(n, "15") >= 0) return PERIOD_M15;
      if(StringFind(n, "5") >= 0)  return PERIOD_M5;
      if(StringFind(n, "1") >= 0)  return PERIOD_M1;
   }
   return _Period;
}
