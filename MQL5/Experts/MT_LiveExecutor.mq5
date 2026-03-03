//+------------------------------------------------------------------+
//|                                              MT_LiveExecutor.mq5 |
//|                                  Copyright 2024, Bolt Optimizer  |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Bolt Optimizer"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// ---------- 1. BIBLIOTECA COMPLETA DE ENTRADAS (MT5-KNOWLEDGE-CORE) ----------
enum Signal {BUY=1, SELL=-1, NONE=0};

// Forward declaration of Rule struct
struct Rule{
   bool     active;
   int      tf;
   int      p1,p2;
   double   d1,d2;
   string   s1;
   int      h1, h2; // Cached handles
   Signal   (*func)(int, int);
};

Rule rules[30];
int nRules=0;

// 1.1 MÉDIAS & CRUZAMENTOS (Preço vs Média ou MA vs MA)
Signal CruzamentoMA(int idx, int shift)
{
   Rule r = rules[idx];
   if(rules[idx].h1 == INVALID_HANDLE) rules[idx].h1 = iMA(NULL, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_EMA, PRICE_CLOSE);

   double buf_f[2];
   if(CopyBuffer(rules[idx].h1, 0, shift, 2, buf_f) < 2) return NONE;
   double f = buf_f[0], fp = buf_f[1];

   if(r.p2 == 0) // Preço vs Média
   {
      double p = iClose(NULL, (ENUM_TIMEFRAMES)r.tf, shift);
      double pp = iClose(NULL, (ENUM_TIMEFRAMES)r.tf, shift+1);
      if(pp < fp && p > f) return BUY;
      if(pp > fp && p < f) return SELL;
   }
   else // MA vs MA
   {
      if(rules[idx].h2 == INVALID_HANDLE) rules[idx].h2 = iMA(NULL, (ENUM_TIMEFRAMES)r.tf, r.p2, 0, MODE_EMA, PRICE_CLOSE);
      double buf_s[2];
      if(CopyBuffer(rules[idx].h2, 0, shift, 2, buf_s) < 2) return NONE;
      double s = buf_s[0], sp = buf_s[1];
      if(fp < sp && f > s) return BUY;
      if(fp > sp && f < s) return SELL;
   }
   return NONE;
}

// 1.2 RSI (Crossover or Level)
Signal RSIThreshold(int idx, int shift)
{
   Rule r = rules[idx];
   if(rules[idx].h1 == INVALID_HANDLE) rules[idx].h1 = iRSI(NULL, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
   double v_buf[2];
   if(CopyBuffer(rules[idx].h1, 0, shift, 2, v_buf) < 2) return NONE;
   double v = v_buf[1], vp = v_buf[0];

   // Mode: "subir acima" or "cair abaixo" (crossover)
   if(vp < r.d1 && v > r.d1) return BUY;
   if(vp > r.d2 && v < r.d2) return SELL;

   return NONE;
}

// 1.3 ESTOCÁSTICO
Signal StochCross(int idx, int shift)
{
   Rule r = rules[idx];
   if(rules[idx].h1 == INVALID_HANDLE) rules[idx].h1 = iStochastic(NULL, (ENUM_TIMEFRAMES)r.tf, r.p1, r.p2, (int)r.d1, MODE_SMA, STO_LOWHIGH);
   double k_buf[2], d_buf[2];
   if(CopyBuffer(rules[idx].h1, 0, shift, 2, k_buf) < 2) return NONE;
   if(CopyBuffer(rules[idx].h1, 1, shift, 2, d_buf) < 2) return NONE;

   if(k_buf[1] < d_buf[1] && k_buf[0] > d_buf[0]) return BUY;
   if(k_buf[1] > d_buf[1] && k_buf[0] < d_buf[0]) return SELL;
   return NONE;
}

// 1.4 BOLLINGER BOUNCE
Signal BBounce(int idx, int shift)
{
   Rule r = rules[idx];
   if(rules[idx].h1 == INVALID_HANDLE) rules[idx].h1 = iBands(NULL, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, r.d1, PRICE_CLOSE);
   double upper_buf[1], lower_buf[1];
   if(CopyBuffer(rules[idx].h1, 1, shift, 1, upper_buf) < 1) return NONE;
   if(CopyBuffer(rules[idx].h1, 2, shift, 1, lower_buf) < 1) return NONE;

   double close = iClose(NULL, (ENUM_TIMEFRAMES)r.tf, shift);
   if(close < lower_buf[0]) return BUY;
   if(close > upper_buf[0]) return SELL;
   return NONE;
}

// 1.5 BREAKOUT DIÁRIO
Signal DailyBreak(int idx, int shift)
{
   MqlRates rates[2];
   if(CopyRates(NULL, PERIOD_D1, 0, 2, rates) < 2) return NONE;
   double hi = rates[0].high, lo = rates[0].low;
   double close = iClose(NULL, PERIOD_M1, shift);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(close > hi + tick_size) return BUY;
   if(close < lo - tick_size) return SELL;
   return NONE;
}

// 1.6 MICROESTRUTURA: DELTA DE AGRESSÃO
Signal DeltaAggression(int idx, int shift)
{
   Rule r = rules[idx];
   MqlTick arr[];
   int n=CopyTicksRange(_Symbol,arr,COPY_TICKS_TRADE, TimeCurrent()-r.p1,TimeCurrent());
   long buy=0,sell=0;
   for(int i=0;i<n;i++) if(arr[i].flags&TICK_FLAG_BUY) buy++; else if(arr[i].flags&TICK_FLAG_SELL) sell++;
   if(buy-sell > r.p2) return BUY;
   if(sell-buy > r.p2) return SELL;
   return NONE;
}

// 1.7 CICLO DE VOLUME (Williams)
Signal VolumeCycle(int idx, int shift)
{
   Rule r = rules[idx];
   long vol[]; ArraySetAsSeries(vol,true);
   if(CopyVolume(_Symbol,(ENUM_TIMEFRAMES)r.tf,shift,r.p1,vol) < r.p1) return NONE;
   int high_idx = ArrayMaximum(vol), low_idx = ArrayMinimum(vol);
   if(vol[0] == vol[high_idx]) return SELL;
   if(vol[0] == vol[low_idx]) return BUY;
   return NONE;
}

// 1.8 MÉDIA MÓVEL ADAPTATIVA (Kaufman)
Signal AMA(int idx, int shift)
{
   Rule r = rules[idx];
   if(rules[idx].h1 == INVALID_HANDLE) rules[idx].h1 = iAMA(NULL, (ENUM_TIMEFRAMES)r.tf, r.p1, r.p2, (int)r.d1, 0, PRICE_CLOSE);
   double buf[2];
   if(CopyBuffer(rules[idx].h1, 0, shift, 2, buf) < 2) return NONE;
   if(buf[1] < buf[0]) return BUY;
   if(buf[1] > buf[0]) return SELL;
   return NONE;
}

// 1.9 PADRÃO DE 2 BARRAS
Signal Bar2Pattern(int idx, int shift)
{
   Rule r = rules[idx];
   double h0=iHigh(NULL,(ENUM_TIMEFRAMES)r.tf,shift), l0=iLow(NULL,(ENUM_TIMEFRAMES)r.tf,shift);
   double h1=iHigh(NULL,(ENUM_TIMEFRAMES)r.tf,shift+1), l1=iLow(NULL,(ENUM_TIMEFRAMES)r.tf,shift+1);
   if(h0<h1 && l0>l1) return (iClose(NULL,(ENUM_TIMEFRAMES)r.tf,shift)>iOpen(NULL,(ENUM_TIMEFRAMES)r.tf,shift))? BUY : SELL;
   if(h0>h1 && l0<l1) return (iClose(NULL,(ENUM_TIMEFRAMES)r.tf,shift)>iOpen(NULL,(ENUM_TIMEFRAMES)r.tf,shift))? SELL: BUY;
   return NONE;
}

// 1.10 FORÇA RELATIVA
Signal RSRelative(int idx, int shift)
{
   Rule r = rules[idx];
   if(rules[idx].h1 == INVALID_HANDLE) rules[idx].h1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
   if(rules[idx].h2 == INVALID_HANDLE) rules[idx].h2 = iRSI(r.s1, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
   double v1[1], v2[1];
   if(CopyBuffer(rules[idx].h1, 0, shift, 1, v1) < 1) return NONE;
   if(CopyBuffer(rules[idx].h2, 0, shift, 1, v2) < 1) return NONE;
   if(v1[0] > v2[0] + 5) return BUY;
   if(v1[0] < v2[0] - 5) return SELL;
   return NONE;
}

void ReleaseHandles()
{
   for(int i=0; i<30; i++)
   {
      if(rules[i].h1 != INVALID_HANDLE) { IndicatorRelease(rules[i].h1); rules[i].h1 = INVALID_HANDLE; }
      if(rules[i].h2 != INVALID_HANDLE) { IndicatorRelease(rules[i].h2); rules[i].h2 = INVALID_HANDLE; }
   }
}

// Global strategy parameters
double g_risk = 1.0;
int g_stop_pts = 30;
int g_take_pts = 50;
int g_be_trigger = 30;
int g_be_plus = 5;
int g_max_trades = 3;
int g_news_veto_min = 20;
int g_start_hour = 0;
int g_interval_min = 0;
datetime g_last_bar_time = 0;
datetime g_last_news_check = 0;
bool g_news_active = false;

void GravaLog(string texto)
{
   string log_msg = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + ": " + texto;
   Print(log_msg);

   int handle = FileOpen("MT_LiveExecutor_Log.csv", FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON);
   if(handle != INVALID_HANDLE)
   {
      FileSeek(handle, 0, SEEK_END);
      FileWrite(handle, TimeToString(TimeCurrent()), texto);
      FileClose(handle);
   }
}

// Helper to extract numbers from string
double ExtraiNumero(string txt, string prefix)
{
   int pos = StringFind(txt, prefix);
   if(pos < 0) return 0;
   string sub = StringSubstr(txt, pos + StringLen(prefix));
   return StringToDouble(sub);
}

int PeriodoTexto(string nome)
{
   string n = nome; StringToLower(n);
   if(n=="m1")  return PERIOD_M1;
   if(n=="m5")  return PERIOD_M5;
   if(n=="m15") return PERIOD_M15;
   if(n=="m30") return PERIOD_M30;
   if(n=="h1")  return PERIOD_H1;
   if(n=="h4")  return PERIOD_H4;
   if(n=="d1")  return PERIOD_D1;
   return PERIOD_CURRENT;
}

void InterpretaPrompt(string prompt)
{
   string p = prompt; StringToLower(p);

   ReleaseHandles();
   nRules = 0;
   ZeroMemory(rules);
   for(int i=0; i<30; i++) { rules[i].h1 = INVALID_HANDLE; rules[i].h2 = INVALID_HANDLE; }

   // Defaults
   g_interval_min = 0;
   g_start_hour = 0;

   // Parse Risk
   if(StringFind(p, "risco") >= 0) g_risk = ExtraiNumero(p, "risco ");

   // Parse Stop/Take
   if(StringFind(p, "stop") >= 0) g_stop_pts = (int)ExtraiNumero(p, "stop ");
   if(StringFind(p, "take") >= 0) g_take_pts = (int)ExtraiNumero(p, "take ");

   // Parse Max Trades
   if(StringFind(p, "máximo") >= 0) g_max_trades = (int)ExtraiNumero(p, "máximo ");
   else if(StringFind(p, "maximo") >= 0) g_max_trades = (int)ExtraiNumero(p, "maximo ");

   // Parse Time Filters
   if(StringFind(p, "depois das") >= 0) g_start_hour = (int)ExtraiNumero(p, "depois das ");
   if(StringFind(p, "cada") >= 0) g_interval_min = (int)ExtraiNumero(p, "cada ");

   // Parse Break-even
   if(StringFind(p, "be +") >= 0)
   {
      g_be_trigger = (int)ExtraiNumero(p, "be +");
      g_be_plus = (int)ExtraiNumero(p, "move +");
   }

   // Parse Rules
   if(StringFind(p, "média") >= 0 || StringFind(p, "media") >= 0)
   {
      rules[nRules].active = true;
      rules[nRules].p1 = (int)ExtraiNumero(p, "média de ");
      if(rules[nRules].p1 == 0) rules[nRules].p1 = (int)ExtraiNumero(p, "media de ");
      if(rules[nRules].p1 == 0) rules[nRules].p1 = 20; // default
      rules[nRules].p2 = 0; // Price vs MA default
      rules[nRules].tf = (g_interval_min > 0) ? PeriodoTexto("m"+IntegerToString(g_interval_min)) : PERIOD_CURRENT;
      rules[nRules].func = &CruzamentoMA;
      nRules++;
   }

   if(StringFind(p, "rsi") >= 0)
   {
      rules[nRules].active = true;
      rules[nRules].p1 = (int)ExtraiNumero(p, "rsi(");
      if(rules[nRules].p1 == 0) rules[nRules].p1 = (int)ExtraiNumero(p, "rsi ");
      if(rules[nRules].p1 == 0) rules[nRules].p1 = 14;
      rules[nRules].d1 = ExtraiNumero(p, "acima de ");
      if(rules[nRules].d1 == 0) rules[nRules].d1 = 55;
      rules[nRules].d2 = ExtraiNumero(p, "abaixo de ");
      if(rules[nRules].d2 == 0) rules[nRules].d2 = 45;
      rules[nRules].tf = (g_interval_min > 0) ? PeriodoTexto("m"+IntegerToString(g_interval_min)) : PERIOD_CURRENT;
      rules[nRules].func = &RSIThreshold;
      nRules++;
   }

   GravaLog("Prompt interpretado: " + prompt);
}

Signal AvaliaTudo()
{
   if(nRules == 0) return NONE;

   int buy_votes = 0;
   int sell_votes = 0;
   int total_active = 0;

   for(int i=0; i<nRules; i++)
   {
      if(rules[i].active)
      {
         total_active++;
         Signal s = rules[i].func(i, 0);
         if(s == BUY) buy_votes++;
         else if(s == SELL) sell_votes++;
      }
   }

   if(total_active == 0) return NONE;

   // Logic: Unanimous
   if(buy_votes == total_active) return BUY;
   if(sell_votes == total_active) return SELL;

   return NONE;
}

CTrade g_trade;

double CalculaLote(double risco_perc, int stop_pts)
{
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_abs = capital * (risco_perc / 100.0);
   double tick_val = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(stop_pts <= 0 || tick_val <= 0 || tick_size <= 0) return 0.01;

   double points_val = (stop_pts * _Point);
   double lot = risk_abs / (points_val * (tick_val / tick_size));

   double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / step_lot) * step_lot;
   if(lot < min_lot) lot = min_lot;
   if(lot > max_lot) lot = max_lot;

   return NormalizeDouble(lot, 2);
}

void EnviaOrdem(Signal s, double lote, int sl_pts, int tp_pts)
{
   if(s == NONE) return;
   if(PositionsTotal() >= g_max_trades) return;

   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = (s == BUY) ? (price - sl_pts * _Point) : (price + sl_pts * _Point);
   double tp = (s == BUY) ? (price + tp_pts * _Point) : (price - tp_pts * _Point);

   bool res = false;
   if(s == BUY) res = g_trade.Buy(lote, _Symbol, price, sl, tp, "MT-LiveExecutor BUY");
   else res = g_trade.Sell(lote, _Symbol, price, sl, tp, "MT-LiveExecutor SELL");

   if(res) GravaLog("Ordem enviada com sucesso: " + EnumToString(s));
   else GravaLog("Erro ao enviar ordem: " + IntegerToString(g_trade.ResultRetcode()));
}

void GerenciaPosicoes()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

         double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
         double cur_price = PositionGetDouble(POSITION_PRICE_CURRENT);
         double cur_sl = PositionGetDouble(POSITION_SL);
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

         if(g_be_trigger > 0)
         {
            double profit_pts = 0;
            if(type == POSITION_TYPE_BUY) profit_pts = (cur_price - open_price) / _Point;
            else profit_pts = (open_price - cur_price) / _Point;

            if(profit_pts >= g_be_trigger)
            {
               double target_sl = (type == POSITION_TYPE_BUY) ? (open_price + g_be_plus * _Point) : (open_price - g_be_plus * _Point);
               bool should_mod = false;
               if(type == POSITION_TYPE_BUY && (cur_sl < target_sl || cur_sl == 0)) should_mod = true;
               else if(type == POSITION_TYPE_SELL && (cur_sl > target_sl || cur_sl == 0)) should_mod = true;

               if(should_mod)
               {
                  if(g_trade.PositionModify(ticket, target_sl, PositionGetDouble(POSITION_TP)))
                     GravaLog("Break-even acionado para ticket " + IntegerToString(ticket));
               }
            }
         }
      }
   }
}

bool AguardaNoticias()
{
   if(TimeCurrent() - g_last_news_check < 300) return g_news_active;
   g_last_news_check = TimeCurrent();
   g_news_active = false;
   MqlCalendarValue values[];
   datetime from = TimeCurrent() - g_news_veto_min * 60;
   datetime to = TimeCurrent() + g_news_veto_min * 60;
   if(CalendarValueHistory(values, from, to))
   {
      for(int i=0; i<ArraySize(values); i++)
      {
         MqlCalendarEvent event;
         if(CalendarEventById(values[i].event_id, event))
         {
            if(event.importance == CALENDAR_IMPORTANCE_HIGH)
            {
               g_news_active = true;
               GravaLog("Notícia de alto impacto detectada: " + event.name);
               break;
            }
         }
      }
   }
   return g_news_active;
}

// ---------- 5. LOOP AO VIVO ----------
input string InpPrompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Não operar 20 min antes ou depois de notícias de alto impacto. Máximo 3 trades simultâneos. Ao atingir +30 pontos, move stop para entrada +5 pontos.";

void OnTick()
{
   static string last_prompt = "";
   if(InpPrompt != last_prompt)
   {
      InterpretaPrompt(InpPrompt);
      last_prompt = InpPrompt;
   }

   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.hour < g_start_hour) return;

   if(AguardaNoticias()) return;

   bool new_bar = true;
   if(g_interval_min > 0)
   {
      ENUM_TIMEFRAMES tf = (ENUM_TIMEFRAMES)PeriodoTexto("m"+IntegerToString(g_interval_min));
      datetime cur_bar = iTime(_Symbol, tf, 0);
      if(cur_bar == g_last_bar_time) new_bar = false;
      else g_last_bar_time = cur_bar;
   }

   if(new_bar)
   {
      Signal s = AvaliaTudo();
      if(s != NONE)
      {
         double lote = CalculaLote(g_risk, g_stop_pts);
         EnviaOrdem(s, lote, g_stop_pts, g_take_pts);
      }
   }

   GerenciaPosicoes();
}

int OnInit()
{
   EventSetTimer(1);
   InterpretaPrompt(InpPrompt);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ReleaseHandles();
}
