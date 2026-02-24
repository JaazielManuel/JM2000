//=========================  MT5-KNOWLEDGE-CORE  =========================
// MT-LiveExecutor - Real-time Strategy Interpreter
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// --- Inputs ---
input string InpPrompt = ""; // Descrição da estratégia em português

// ---------- 1. BIBLIOTECA COMPLETA DE ENTRADAS ----------
enum Signal {BUY=1, SELL=-1, NONE=0};

// 1.1 MÉDIAS & CRUZAMENTOS
Signal CruzamentoMA(int handle, int shift=1)
{
   if(handle == INVALID_HANDLE) return NONE;
   double ma_arr[], price_arr[];
   ArraySetAsSeries(ma_arr, true);
   ArraySetAsSeries(price_arr, true);

   if(CopyBuffer(handle, 0, shift, 2, ma_arr) <= 0) return NONE;
   if(CopyClose(_Symbol, PERIOD_CURRENT, shift, 2, price_arr) <= 0) return NONE;

   double ma = ma_arr[0];
   double ma_p = ma_arr[1];
   double p = price_arr[0];
   double p_p = price_arr[1];

   if(p_p < ma_p && p > ma) return BUY;
   if(p_p > ma_p && p < ma) return SELL;
   return NONE;
}

// 1.2 RSI
Signal RSIThreshold(int handle, double over, double under, bool trend=false, int shift=0)
{
   if(handle == INVALID_HANDLE) return NONE;
   double v_arr[];
   ArraySetAsSeries(v_arr, true);
   if(CopyBuffer(handle, 0, shift, 1, v_arr) <= 0) return NONE;

   double v = v_arr[0];
   if(trend)
   {
      if(v > over) return BUY;
      if(v < under) return SELL;
   }
   else
   {
      if(v > over) return SELL;
      if(v < under) return BUY;
   }
   return NONE;
}

// 1.3 ESTOCÁSTICO (Simplified for now)
Signal StochCross(uint tf=PERIOD_CURRENT,int k=5,int d=3,int slowing=3,int shift=0)
{
   double k_arr[], d_arr[];
   ArraySetAsSeries(k_arr, true);
   ArraySetAsSeries(d_arr, true);
   int h = iStochastic(_Symbol, (ENUM_TIMEFRAMES)tf, k, d, slowing, MODE_SMA, STO_LOWHIGH);

   if(CopyBuffer(h, 0, shift, 2, k_arr) <= 0) return NONE;
   if(CopyBuffer(h, 1, shift, 2, d_arr) <= 0) return NONE;

   if(k_arr[1] < d_arr[1] && k_arr[0] > d_arr[0]) return BUY;
   if(k_arr[1] > d_arr[1] && k_arr[0] < d_arr[0]) return SELL;
   return NONE;
}

// 1.4 BOLLINGER BOUNCE (Simplified for MQL5)
Signal BBounce(int period=20,double desv=2,uint tf=PERIOD_CURRENT,int shift=0)
{
   double upper[], lower[], middle[];
   ArraySetAsSeries(upper, true);
   ArraySetAsSeries(lower, true);
   int h = iBands(_Symbol, (ENUM_TIMEFRAMES)tf, period, 0, desv, PRICE_CLOSE);

   if(CopyBuffer(h, 1, shift, 1, upper) <= 0) return NONE;
   if(CopyBuffer(h, 2, shift, 1, lower) <= 0) return NONE;

   double close = iClose(_Symbol, (ENUM_TIMEFRAMES)tf, shift);
   if(close < lower[0]) return BUY;
   if(close > upper[0]) return SELL;
   return NONE;
}

// 1.5 BREAKOUT DIÁRIO
Signal DailyBreak(int shift=0)
{
   double hi = iHigh(_Symbol, PERIOD_D1, 1);
   double lo = iLow(_Symbol, PERIOD_D1, 1);
   double close = iClose(_Symbol, PERIOD_CURRENT, shift);

   if(close > hi) return BUY;
   if(close < lo) return SELL;
   return NONE;
}

// 1.6 MICROESTRUTURA: DELTA DE AGRESSÃO
Signal DeltaAggression(int seconds=60,int deltaTrigger=300)
{
   MqlTick arr[];
   int n = CopyTicksRange(_Symbol, arr, COPY_TICKS_TRADE, TimeCurrent() - seconds, TimeCurrent());
   long buy = 0, sell = 0;
   for(int i = 0; i < n; i++)
   {
      if((arr[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++;
      else if((arr[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sell++;
   }
   long delta = buy - sell;
   if(delta > deltaTrigger) return BUY;
   if(delta < -deltaTrigger) return SELL;
   return NONE;
}

// 1.7 CICLO DE VOLUME
Signal VolumeCycle(int len=12,uint tf=PERIOD_CURRENT,int shift=0)
{
   long vol[];
   ArraySetAsSeries(vol, true);
   if(CopyTickVolume(_Symbol, (ENUM_TIMEFRAMES)tf, shift, len, vol) <= 0) return NONE;

   int max_idx = ArrayMaximum(vol);
   int min_idx = ArrayMinimum(vol);
   if(max_idx == 0) return SELL;
   if(min_idx == 0) return BUY;
   return NONE;
}

// 1.8 MÉDIA MÓVEL ADAPTATIVA (Kaufman)
Signal AMA(int len=10,int fast=2,int slow=30,uint tf=PERIOD_CURRENT,int shift=0)
{
   double ama_arr[];
   ArraySetAsSeries(ama_arr, true);
   int h = iAMA(_Symbol, (ENUM_TIMEFRAMES)tf, len, fast, slow, 0, PRICE_CLOSE);
   if(CopyBuffer(h, 0, shift, 2, ama_arr) <= 0) return NONE;

   if(ama_arr[1] < ama_arr[0]) return BUY;
   if(ama_arr[1] > ama_arr[0]) return SELL;
   return NONE;
}

// 1.9 PADRÃO DE 2 BARRAS (inside / outside)
Signal Bar2Pattern(uint tf=PERIOD_CURRENT,int shift=0)
{
   double h0 = iHigh(_Symbol, (ENUM_TIMEFRAMES)tf, shift);
   double l0 = iLow(_Symbol, (ENUM_TIMEFRAMES)tf, shift);
   double h1 = iHigh(_Symbol, (ENUM_TIMEFRAMES)tf, shift+1);
   double l1 = iLow(_Symbol, (ENUM_TIMEFRAMES)tf, shift+1);
   double c0 = iClose(_Symbol, (ENUM_TIMEFRAMES)tf, shift);
   double o0 = iOpen(_Symbol, (ENUM_TIMEFRAMES)tf, shift);

   if(h0 < h1 && l0 > l1) return (c0 > o0) ? BUY : SELL;
   if(h0 > h1 && l0 < l1) return (c0 > o0) ? SELL : BUY;
   return NONE;
}

// 1.10 FORÇA RELATIVA ENTRE ATIVOS
Signal RSRelative(string bench="US30",int len=14,uint tf=PERIOD_CURRENT,int shift=0)
{
   double r1_arr[], r2_arr[];
   int h1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)tf, len, PRICE_CLOSE);
   int h2 = iRSI(bench, (ENUM_TIMEFRAMES)tf, len, PRICE_CLOSE);

   if(CopyBuffer(h1, 0, shift, 1, r1_arr) <= 0) return NONE;
   if(CopyBuffer(h2, 0, shift, 1, r2_arr) <= 0) return NONE;

   if(r1_arr[0] > r2_arr[0] + 5) return BUY;
   if(r1_arr[0] < r2_arr[0] - 5) return SELL;
   return NONE;
}

// ---------- 2. MOTOR DE INTERPRETAÇÃO DE PROMPT ----------
struct Rule{
   bool     active;
   int      tf;
   int      p1,p2,p3;
   double   d1,d2;
   string   s1;
   int      type;
   bool     is_exit;
   int      h1, h2; // Indicator handles
   bool     trend_mode;
};
Rule rules[20]; int nRules=0;

struct StrategyParams {
   int      timeframe;
   int      start_hour;
   int      stop_points;
   int      take_points;
   double   risk_percent;
   int      news_buffer_mins;
   int      max_trades;
   int      be_trigger;
   int      be_offset;
};
StrategyParams globalParams;

// Rule types
#define RULE_MA 1
#define RULE_RSI 2
#define RULE_STOCH 3
#define RULE_BB 4

void AddRule(string txt)
{
   StringToLower(txt);
   if(nRules >= 20) return;

   // Parsing Médias
   if(StringFind(txt,"média")>=0 || StringFind(txt,"ma")>=0)
   {
      rules[nRules].active=true;
      rules[nRules].type=RULE_MA;
      rules[nRules].tf=globalParams.timeframe;
      rules[nRules].p1=ExtraiNumero(txt, "períodos");
      if(rules[nRules].p1 == 0) rules[nRules].p1 = ExtraiNumero(txt, "ma");
      if(rules[nRules].p1 == 0) rules[nRules].p1 = 20; // Default

      rules[nRules].h1 = iMA(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, rules[nRules].p1, 0, MODE_EMA, PRICE_CLOSE);
      nRules++;
   }

   // Parsing RSI
   if(StringFind(txt,"rsi")>=0)
   {
      rules[nRules].active=true;
      rules[nRules].type=RULE_RSI;
      rules[nRules].tf=globalParams.timeframe;
      rules[nRules].p1=ExtraiNumero(txt, "rsi");
      if(rules[nRules].p1 == 0) rules[nRules].p1 = 14; // Default

      rules[nRules].d1=ExtraiNumeroDouble(txt, "acima de");
      if(rules[nRules].d1 == 0) rules[nRules].d1=ExtraiNumeroDouble(txt, "superior a");

      rules[nRules].d2=ExtraiNumeroDouble(txt, "abaixo de");
      if(rules[nRules].d2 == 0) rules[nRules].d2=ExtraiNumeroDouble(txt, "inferior a");

      // Detecção de modo tendência
      if(StringFind(txt, "subir acima") >= 0 || StringFind(txt, "cair abaixo") >= 0 ||
         StringFind(txt, "acima de") >= 0 || StringFind(txt, "abaixo de") >= 0)
         rules[nRules].trend_mode = true;
      else
         rules[nRules].trend_mode = false;

      rules[nRules].h1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, rules[nRules].p1, PRICE_CLOSE);
      nRules++;
   }
}

void LimpaRegras()
{
   for(int i=0; i<nRules; i++)
   {
      if(rules[i].h1 != INVALID_HANDLE) IndicatorRelease(rules[i].h1);
      if(rules[i].h2 != INVALID_HANDLE) IndicatorRelease(rules[i].h2);
   }
   ZeroMemory(rules);
   nRules = 0;
}

void InterpretaPrompt(string prompt)
{
   StringToLower(prompt);
   LimpaRegras();
   ZeroMemory(globalParams);

   // Timeframe
   if(StringFind(prompt,"1 minuto")>=0 || StringFind(prompt,"m1")>=0) globalParams.timeframe = PERIOD_M1;
   else if(StringFind(prompt,"5 minutos")>=0 || StringFind(prompt,"m5")>=0) globalParams.timeframe = PERIOD_M5;
   else if(StringFind(prompt,"15 minutos")>=0 || StringFind(prompt,"m15")>=0) globalParams.timeframe = PERIOD_M15;
   else if(StringFind(prompt,"1 hora")>=0 || StringFind(prompt,"h1")>=0) globalParams.timeframe = PERIOD_H1;
   else globalParams.timeframe = PERIOD_CURRENT;

   // Parameters
   globalParams.start_hour = (int)ExtraiNumero(prompt, "depois das");
   globalParams.stop_points = (int)ExtraiNumero(prompt, "stop de");
   globalParams.take_points = (int)ExtraiNumero(prompt, "take de");
   globalParams.risk_percent = ExtraiNumeroDouble(prompt, "risco de");
   globalParams.news_buffer_mins = (int)ExtraiNumero(prompt, "notícias");
   globalParams.max_trades = (int)ExtraiNumero(prompt, "máximo");

   // Breakeven
   if(StringFind(prompt,"move stop para entrada") >= 0)
   {
      globalParams.be_trigger = (int)ExtraiNumero(prompt, "atingir +");
      globalParams.be_offset = (int)ExtraiNumero(prompt, "entrada +");
   }

   // Split prompt by sentences/parts to add rules
   string parts[];
   int n = StringSplit(prompt, '.', parts);
   for(int i=0; i<n; i++)
   {
      if(StringFind(parts[i], "compra") >= 0 || StringFind(parts[i], "vende") >= 0)
      {
         AddRule(parts[i]);
      }
   }
}

int ExtraiNumero(string txt, string chave)
{
   int pos = StringFind(txt, chave);
   if(pos < 0) return 0;

   // Tenta encontrar número DEPOIS da chave
   string sub = StringSubstr(txt, pos + StringLen(chave));
   string num_str = "";
   bool started = false;
   for(int i=0; i<StringLen(sub); i++)
   {
      ushort c = StringGetCharacter(sub, i);
      if(c >= '0' && c <= '9') { num_str += CharToString((uchar)c); started = true; }
      else if(started) break;
      else if(c != ' ' && c != '(' && c != ')' && c != ':') continue;
   }
   if(num_str != "") return (int)StringToInteger(num_str);

   // Tenta encontrar número ANTES da chave
   sub = StringSubstr(txt, 0, pos);
   num_str = "";
   started = false;
   for(int i=StringLen(sub)-1; i>=0; i--)
   {
      ushort c = StringGetCharacter(sub, i);
      if(c >= '0' && c <= '9') { num_str = CharToString((uchar)c) + num_str; started = true; }
      else if(started) break;
      else if(c != ' ' && c != '(' && c != ')' && c != ':') continue;
   }

   return (int)StringToInteger(num_str);
}

double ExtraiNumeroDouble(string txt, string chave)
{
   int pos = StringFind(txt, chave);
   if(pos < 0) return 0;

   // Tenta encontrar número DEPOIS da chave
   string sub = StringSubstr(txt, pos + StringLen(chave));
   string num_str = "";
   bool started = false;
   for(int i=0; i<StringLen(sub); i++)
   {
      ushort c = StringGetCharacter(sub, i);
      if((c >= '0' && c <= '9') || c == '.') { num_str += CharToString((uchar)c); started = true; }
      else if(started) break;
      else if(c != ' ' && c != '(' && c != ')' && c != ':') continue;
   }
   if(num_str != "") return StringToDouble(num_str);

   // Tenta encontrar número ANTES da chave
   sub = StringSubstr(txt, 0, pos);
   num_str = "";
   started = false;
   for(int i=StringLen(sub)-1; i>=0; i--)
   {
      ushort c = StringGetCharacter(sub, i);
      if((c >= '0' && c <= '9') || c == '.') { num_str = CharToString((uchar)c) + num_str; started = true; }
      else if(started) break;
      else if(c != ' ' && c != '(' && c != ')' && c != ':') continue;
   }

   return StringToDouble(num_str);
}

int PeriodoTexto(string nome)
{
   nome = StringSubstr(nome, 0);
   StringToLower(nome);
   if(nome=="m1")  return PERIOD_M1;
   if(nome=="m5")  return PERIOD_M5;
   if(nome=="m15") return PERIOD_M15;
   if(nome=="h1")  return PERIOD_H1;
   if(nome=="d1")  return PERIOD_D1;
   return PERIOD_CURRENT;
}

// ---------- 3. DECISÃO FINAL ----------
Signal AvaliaTudo()
{
   int voto = 0;
   for(int i = 0; i < nRules; i++)
   {
      if(rules[i].active)
      {
         Signal res = NONE;
         switch(rules[i].type)
         {
            case RULE_MA: res = CruzamentoMA(rules[i].h1); break;
            case RULE_RSI: res = RSIThreshold(rules[i].h1, rules[i].d1, rules[i].d2, rules[i].trend_mode); break;
         }
         voto += res;
      }
   }
   if(voto > 0)  return BUY;
   if(voto < 0)  return SELL;
   return NONE;
}

bool AvaliaCondicoes(Signal &s)
{
   s = AvaliaTudo();
   if(s == NONE) return false;

   // Time filter
   MqlDateTime dt;
   TimeCurrent(dt);
   if(globalParams.start_hour > 0 && dt.hour < globalParams.start_hour) return false;

   // News filter
   if(AguardaNoticias()) return false;

   // Max trades
   if(globalParams.max_trades > 0 && PositionsTotal() >= globalParams.max_trades) return false;

   return true;
}

// ---------- 4. EXECUTOR DE ORDEM ----------
CTrade trade;
CPositionInfo posInfo;

void EnviaOrdem(Signal s, double lote)
{
   if(s == NONE) return;

   double sl = 0, tp = 0;
   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(globalParams.stop_points > 0)
   {
      sl = (s == BUY) ? price - globalParams.stop_points * _Point : price + globalParams.stop_points * _Point;
   }
   if(globalParams.take_points > 0)
   {
      tp = (s == BUY) ? price + globalParams.take_points * _Point : price - globalParams.take_points * _Point;
   }

   string comment = "MT-LiveExecutor: " + InpPrompt;
   bool res = false;
   if(s == BUY) res = trade.Buy(lote, _Symbol, price, sl, tp, comment);
   else res = trade.Sell(lote, _Symbol, price, sl, tp, comment);

   if(!res)
   {
      uint retcode = trade.ResultRetcode();
      GravaLog(StringFormat("ERRO ao enviar ordem: %d - %s", retcode, trade.ResultComment()));
   }
   else
   {
      GravaLog(StringFormat("Ordem enviada: %s, Lote: %.2f, SL: %.5f, TP: %.5f", (s==BUY?"COMPRA":"VENDA"), lote, sl, tp));
   }
}

void GerenciaPosicoes()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Symbol() == _Symbol)
         {
            // Breakeven logic
            if(globalParams.be_trigger > 0)
            {
               double profit_pts = 0;
               if(posInfo.PositionType() == POSITION_TYPE_BUY)
                  profit_pts = (SymbolInfoDouble(_Symbol, SYMBOL_BID) - posInfo.PriceOpen()) / _Point;
               else
                  profit_pts = (posInfo.PriceOpen() - SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / _Point;

               if(profit_pts >= globalParams.be_trigger)
               {
                  double new_sl = 0;
                  if(posInfo.PositionType() == POSITION_TYPE_BUY)
                     new_sl = posInfo.PriceOpen() + globalParams.be_offset * _Point;
                  else
                     new_sl = posInfo.PriceOpen() - globalParams.be_offset * _Point;

                  // Only modify if SL is not already better
                  if(posInfo.StopLoss() == 0 ||
                     (posInfo.PositionType() == POSITION_TYPE_BUY && new_sl > posInfo.StopLoss()) ||
                     (posInfo.PositionType() == POSITION_TYPE_SELL && (new_sl < posInfo.StopLoss() || posInfo.StopLoss() == 0)))
                  {
                     trade.PositionModify(posInfo.Ticket(), new_sl, posInfo.TakeProfit());
                     GravaLog(StringFormat("Breakeven atingido para ticket %d. Novo SL: %.5f", posInfo.Ticket(), new_sl));
                  }
               }
            }
         }
      }
   }
}

double CalculaLote(double riscoPercent)
{
   if(riscoPercent <= 0) return 0.01;

   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riscoAbs = capital * riscoPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   double stop = (globalParams.stop_points > 0) ? globalParams.stop_points * _Point : 100 * _Point;
   double lot = (riscoAbs * tickSize) / (stop * tickValue);

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / stepLot) * stepLot;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return NormalizeDouble(lot, 2);
}

bool AguardaNoticias()
{
   if(globalParams.news_buffer_mins <= 0) return false;

   MqlCalendarValue values[];
   datetime from = TimeCurrent() - globalParams.news_buffer_mins * 60;
   datetime to = TimeCurrent() + globalParams.news_buffer_mins * 60;

   if(CalendarValueHistory(values, from, to) > 0)
   {
      for(int i = 0; i < ArraySize(values); i++)
      {
         MqlCalendarEvent event;
         if(CalendarEventById(values[i].event_id, event))
         {
            if(event.importance == CALENDAR_IMPORTANCE_HIGH) return true;
         }
      }
   }
   return false;
}

void GravaLog(string texto)
{
   string filename = "Logs\\MT_LiveExecutor_Log.csv";
   int handle = FileOpen(filename, FILE_WRITE|FILE_READ|FILE_CSV|FILE_ANSI|FILE_COMMON, ';');
   if(handle != INVALID_HANDLE)
   {
      FileSeek(handle, 0, SEEK_END);
      FileWrite(handle, TimeToString(TimeCurrent()), texto);
      FileClose(handle);
   }
   Print("Log: ", texto);
}

// ---------- 5. LOOP AO VIVO ----------
string lastPrompt = "";
datetime lastBarTime = 0;

int OnInit()
{
   if(InpPrompt != "")
   {
      InterpretaPrompt(InpPrompt);
      lastPrompt = InpPrompt;
      GravaLog("Estratégia inicializada: " + InpPrompt);
   }
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   LimpaRegras();
   GravaLog("Estratégia finalizada.");
}

void OnTick()
{
   // Detect real-time prompt adjustment
   if(InpPrompt != lastPrompt)
   {
      InterpretaPrompt(InpPrompt);
      lastPrompt = InpPrompt;
      lastBarTime = 0; // Reset bar time to allow immediate evaluation
      GravaLog("Estratégia atualizada em tempo real: " + InpPrompt);
   }

   if(nRules == 0) return;

   // Position Management (Every tick)
   GerenciaPosicoes();

   // Bar Control
   datetime currentBarTime = iTime(_Symbol, (ENUM_TIMEFRAMES)globalParams.timeframe, 0);
   if(currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;

   // Trade Execution (Every new bar)
   Signal s = NONE;
   if(AvaliaCondicoes(s))
   {
      double lote = CalculaLote(globalParams.risk_percent);
      EnviaOrdem(s, lote);
   }
}
