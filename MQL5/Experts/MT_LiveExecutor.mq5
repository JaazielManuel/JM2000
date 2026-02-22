//+------------------------------------------------------------------+
//|                                             MT_LiveExecutor.mq5  |
//|                                  Copyright 2026, Jules AI        |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Jules AI"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>
#include <UniversalTrailing.mqh>

// ---------- DEFINIÇÕES E GLOBAIS ----------
enum ENUM_SIGNAL { SIGNAL_BUY = 1, SIGNAL_SELL = -1, SIGNAL_NONE = 0 };

typedef ENUM_SIGNAL (*SignalFunc)(int h1, int h2, int p1, int p2, double d1, double d2, uint tf, int shift);

struct Rule {
   bool       active;
   SignalFunc func;
   int        h1, h2; // Handles persistentes
   int        p1, p2, p3;
   double     d1, d2;
   uint       tf;
   string     desc;
};

// Configurações da Estratégia
struct StrategySettings {
   int      stop_pts;
   int      take_pts;
   double   risk_perc;
   int      max_trades;
   int      be_act;
   int      be_offset;
   int      news_min;
   int      start_h;
   int      interval_m;
   datetime last_trade_time;
};

Rule             rules[20];
int              nRules = 0;
StrategySettings settings;
CTrade           trade;
CUniversalTrailing trailing;
CSymbolInfo      symbol;

// Parâmetros de Entrada
input string   StrategyPrompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Não operar 20 min antes ou depois de notícias de alto impacto. Máximo 3 trades simultâneos. Ao atingir +30 pontos, move stop para entrada +5 pontos.";
input long     MagicNumber = 123456;

//+------------------------------------------------------------------+
//| Interpretação do Prompt (Natural Language Parser)                |
//+------------------------------------------------------------------+
void ReleaseAllHandles() {
   for(int i=0; i<nRules; i++) {
      if(rules[i].h1 != INVALID_HANDLE) IndicatorRelease(rules[i].h1);
      if(rules[i].h2 != INVALID_HANDLE) IndicatorRelease(rules[i].h2);
      rules[i].h1 = INVALID_HANDLE;
      rules[i].h2 = INVALID_HANDLE;
   }
}

void InterpretaPrompt(string prompt) {
   ReleaseAllHandles();
   nRules = 0;
   string originalPrompt = prompt;
   StringToLower(prompt);
   Print("--------------------------------------------------");
   Print("Interpretando Estratégia: ", prompt);

   // Reset settings
   settings.stop_pts = 300; // default 30 pips
   settings.take_pts = 500; // default 50 pips
   settings.risk_perc = 1.0;
   settings.max_trades = 3;
   settings.be_act = 0;
   settings.be_offset = 0;
   settings.news_min = 20;
   settings.start_h = 0;
   settings.interval_m = 0;

   // 1. Extração de Parâmetros Numéricos
   if(StringFind(prompt, "stop de") >= 0) {
      settings.stop_pts = ExtractInt(prompt, "stop de");
   }
   if(StringFind(prompt, "take de") >= 0) {
      settings.take_pts = ExtractInt(prompt, "take de");
   }
   if(StringFind(prompt, "risco de") >= 0) {
      settings.risk_perc = ExtractDouble(prompt, "risco de");
   }
   if(StringFind(prompt, "máximo") >= 0) {
      settings.max_trades = ExtractInt(prompt, "máximo");
   }
   if(StringFind(prompt, "atingir +") >= 0) {
      settings.be_act = ExtractInt(prompt, "atingir +");
      if(StringFind(prompt, "entrada +") >= 0)
         settings.be_offset = ExtractInt(prompt, "entrada +");
   }
   if(StringFind(prompt, "depois das") >= 0) {
      settings.start_h = ExtractInt(prompt, "depois das");
   }
   if(StringFind(prompt, "a cada") >= 0) {
      settings.interval_m = ExtractInt(prompt, "a cada");
   }

   // 2. Mapeamento de Regras de Indicadores
   uint tf = GetTFFromText(prompt);

   if((StringFind(prompt, "média") >= 0 || StringFind(prompt, "ma") >= 0) && StringFind(prompt, "rsi") >= 0) {
      int pMA = ExtractInt(prompt, "média de"); if(pMA==0) pMA = ExtractInt(prompt, "ma "); if(pMA==0) pMA=20;
      int pRSI = ExtractInt(prompt, "rsi"); if(pRSI==0) pRSI=14;
      double d1 = 55, d2 = 45;
      if(StringFind(prompt, "acima de") >= 0) d1 = ExtractDouble(prompt, "acima de");
      else if(StringFind(prompt, "superior a") >= 0) d1 = ExtractDouble(prompt, "superior a");

      if(StringFind(prompt, "abaixo de") >= 0) d2 = ExtractDouble(prompt, "abaixo de");
      else if(StringFind(prompt, "inferior a") >= 0) d2 = ExtractDouble(prompt, "inferior a");

      rules[nRules].active = true;
      rules[nRules].func = &MACrossRSITrend;
      rules[nRules].h1 = iMA(_Symbol, (ENUM_TIMEFRAMES)tf, pMA, 0, MODE_EMA, PRICE_CLOSE);
      rules[nRules].h2 = iRSI(_Symbol, (ENUM_TIMEFRAMES)tf, pRSI, PRICE_CLOSE);
      rules[nRules].d1 = d1;
      rules[nRules].d2 = d2;
      rules[nRules].tf = tf;
      rules[nRules].desc = "MA + RSI Trend";
      nRules++;
   }
   else if(StringFind(prompt, "média") >= 0) {
      int p1 = ExtractInt(prompt, "média de"); if(p1==0) p1=9;
      int p2 = 21; // Could add logic to find a second MA period
      rules[nRules].active = true;
      rules[nRules].func = &CruzamentoMA;
      rules[nRules].h1 = iMA(_Symbol, (ENUM_TIMEFRAMES)tf, p1, 0, MODE_EMA, PRICE_CLOSE);
      rules[nRules].h2 = iMA(_Symbol, (ENUM_TIMEFRAMES)tf, p2, 0, MODE_EMA, PRICE_CLOSE);
      rules[nRules].tf = tf;
      rules[nRules].desc = "Cruzamento MA " + (string)p1 + "/" + (string)p2;
      nRules++;
   }

   if(StringFind(prompt, "estocástico") >= 0 || StringFind(prompt, "stochastic") >= 0) {
      rules[nRules].active = true;
      rules[nRules].func = &StochCross;
      rules[nRules].h1 = iStochastic(_Symbol, (ENUM_TIMEFRAMES)tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
      rules[nRules].tf = tf;
      rules[nRules].desc = "Stochastic Cross";
      nRules++;
   }

   if(StringFind(prompt, "bollinger") >= 0) {
      rules[nRules].active = true;
      rules[nRules].func = &BBounce;
      rules[nRules].h1 = iBands(_Symbol, (ENUM_TIMEFRAMES)tf, 20, 0, 2.0, PRICE_CLOSE);
      rules[nRules].tf = tf;
      rules[nRules].desc = "Bollinger Bounce";
      nRules++;
   }

   if(StringFind(prompt, "breakout diário") >= 0) {
      rules[nRules].active = true;
      rules[nRules].func = &DailyBreak;
      rules[nRules].tf = tf;
      rules[nRules].desc = "Daily Breakout";
      nRules++;
   }

   if(StringFind(prompt, "ama") >= 0 || StringFind(prompt, "adaptativa") >= 0) {
      rules[nRules].active = true;
      rules[nRules].func = &AMA;
      rules[nRules].h1 = iAMA(_Symbol, (ENUM_TIMEFRAMES)tf, 10, 2, 30, 0, PRICE_CLOSE);
      rules[nRules].tf = tf;
      rules[nRules].desc = "Kaufman AMA";
      nRules++;
   }

   if(StringFind(prompt, "volume") >= 0) {
      rules[nRules].active = true;
      rules[nRules].func = &VolumeCycle;
      rules[nRules].tf = tf;
      rules[nRules].desc = "Volume Cycle";
      nRules++;
   }

   if(StringFind(prompt, "força relativa") >= 0) {
      rules[nRules].active = true;
      rules[nRules].func = &RSRelative;
      rules[nRules].h1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)tf, 14, PRICE_CLOSE);
      rules[nRules].h2 = iRSI("US30", (ENUM_TIMEFRAMES)tf, 14, PRICE_CLOSE);
      rules[nRules].tf = tf;
      rules[nRules].desc = "RS Relative";
      nRules++;
   }

   Print("Configurações: SL:", settings.stop_pts, " TP:", settings.take_pts, " Risco:", settings.risk_perc, "% BE:", settings.be_act, "+", settings.be_offset);
   Print("Horário: >", settings.start_h, "h Intervalo:", settings.interval_m, "min");
   Print("Regras Ativas: ", nRules);
}

//+------------------------------------------------------------------+
//| Eventos Principais                                               |
//+------------------------------------------------------------------+
int OnInit() {
   InterpretaPrompt(StrategyPrompt);
   trade.SetExpertMagicNumber(MagicNumber);
   trailing.Init(MagicNumber, _Symbol);

   // Se o prompt diz "move stop", configuramos o trailing
   if(settings.be_act > 0) {
      trailing.SetBreakeven(settings.be_act, settings.be_offset);
   }

   symbol.Name(_Symbol);
   return INIT_SUCCEEDED;
}

int CountPositions() {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket)) {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol)
            count++;
      }
   }
   return count;
}

void OnTick() {
   static string lastPrompt = "";
   static datetime lastIntervalBar = 0;

   if(StrategyPrompt != lastPrompt) {
      InterpretaPrompt(StrategyPrompt);
      lastPrompt = StrategyPrompt;
      lastIntervalBar = 0;
   }

   if(!IsWithinTradingHours()) return;
   if(IsNewsVetoed()) return;

   AIOptimizer();
   GerenciaPosicoes();

   // Verifica se pode abrir novo trade
   if(CountPositions() < settings.max_trades) {
      // Verifica alinhamento de barra (A cada X minutos)
      if(settings.interval_m > 0) {
         ENUM_TIMEFRAMES tfInterval = (settings.interval_m >= 60) ? PERIOD_H1 : (settings.interval_m >= 15) ? PERIOD_M15 : PERIOD_M5;
         datetime currentBar = iTime(_Symbol, tfInterval, 0);
         if(currentBar == lastIntervalBar) return;
         lastIntervalBar = currentBar;
      }

      ENUM_SIGNAL s = AvaliaCondicoes();
      if(s != SIGNAL_NONE) {
         double lote = CalculaLote(settings.risk_perc);
         EnviaOrdem(s, lote);
         settings.last_trade_time = TimeCurrent();
      }
   }
}

//+------------------------------------------------------------------+
//| Gestão e Auxiliares                                              |
//+------------------------------------------------------------------+
void GerenciaPosicoes() {
   trailing.Process();

   // Lógica de Trailing/BE Adicional se necessário
   // (O CUniversalTrailing já cuida da maior parte)
}

bool IsWithinTradingHours() {
   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.hour < settings.start_h) return false;
   return true;
}

bool IsNewsVetoed() {
   if(settings.news_min <= 0) return false;

   MqlCalendarValue values[];
   datetime from = TimeCurrent() - settings.news_min * 60;
   datetime to = TimeCurrent() + settings.news_min * 60;

   if(CalendarValueHistory(values, from, to, NULL, NULL) > 0) {
      for(int i=0; i<ArraySize(values); i++) {
         MqlCalendarEvent event;
         if(CalendarEventById(values[i].event_id, event)) {
            if(event.importance == CALENDAR_IMPORTANCE_HIGH) {
               Print("News Filter: Operação vetada devido a notícia de alto impacto.");
               return true;
            }
         }
      }
   }
   return false;
}

void GravaLog(string texto) {
   string msg = TimeToString(TimeCurrent()) + " | " + texto;
   Print(msg);

   int handle = FileOpen("MT_LiveExecutor_Log.csv", FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI);
   if(handle != INVALID_HANDLE) {
      FileSeek(handle, 0, SEEK_END);
      FileWrite(handle, TimeToString(TimeCurrent()), texto);
      FileClose(handle);
   }
}

// Otimizador Heurístico (AI requirement)
void AIOptimizer() {
   static datetime lastAI = 0;
   if(TimeCurrent() - lastAI < 3600) return; // Roda a cada 1 hora
   lastAI = TimeCurrent();

   Print("AI Module: Analisando volatilidade e performance...");

   int atrHandle = iATR(_Symbol, PERIOD_H1, 14);
   double atr[1];
   if(CopyBuffer(atrHandle, 0, 0, 1, atr) > 0) {
      double volPts = atr[0] / _Point;
      int suggestedSL = (int)(volPts * 1.5);

      if(MathAbs(suggestedSL - settings.stop_pts) > settings.stop_pts * 0.2) {
         PrintFormat("AI Suggestion: Ajustar Stop Loss de %d para %d baseado na volatilidade atual.", settings.stop_pts, suggestedSL);
         // settings.stop_pts = suggestedSL; // Poderia auto-ajustar aqui
      }
   }
   IndicatorRelease(atrHandle);
}

int ExtractInt(string text, string key) {
   int pos = StringFind(text, key);
   if(pos < 0) return 0;
   string sub = StringSubstr(text, pos + StringLen(key));
   StringTrimLeft(sub);
   string res = "";
   for(int i=0; i<StringLen(sub); i++) {
      ushort c = StringGetCharacter(sub, i);
      if((c >= '0' && c <= '9') || (res == "" && c == '-')) res += ShortToString(c);
      else if(res != "") break;
   }
   return (int)StringToInteger(res);
}

double ExtractDouble(string text, string key) {
   int pos = StringFind(text, key);
   if(pos < 0) return 0.0;
   string sub = StringSubstr(text, pos + StringLen(key));
   StringTrimLeft(sub);
   string res = "";
   bool dec = false;
   for(int i=0; i<StringLen(sub); i++) {
      ushort c = StringGetCharacter(sub, i);
      if(c >= '0' && c <= '9') res += ShortToString(c);
      else if(c == '.' || c == ',') {
         if(dec) break;
         res += ".";
         dec = true;
      }
      else if(res != "") break;
   }
   return StringToDouble(res);
}

uint GetTFFromText(string prompt) {
   if(StringFind(prompt, "m1") >= 0) return PERIOD_M1;
   if(StringFind(prompt, "m5") >= 0) return PERIOD_M5;
   if(StringFind(prompt, "m15") >= 0) return PERIOD_M15;
   if(StringFind(prompt, "h1") >= 0) return PERIOD_H1;
   return PERIOD_CURRENT;
}

// ---------- 1. BIBLIOTECA DE ENTRADAS (MT5-KNOWLEDGE-CORE) ----------
ENUM_SIGNAL CruzamentoMA(int h1, int h2, int p1, int p2, double d1, double d2, uint tf, int shift) {
   double f[2], s[2];
   if(CopyBuffer(h1, 0, shift, 2, f) < 2 || CopyBuffer(h2, 0, shift, 2, s) < 2) return SIGNAL_NONE;
   if(f[1] <= s[1] && f[0] > s[0]) return SIGNAL_BUY;
   if(f[1] >= s[1] && f[0] < s[0]) return SIGNAL_SELL;
   return SIGNAL_NONE;
}

ENUM_SIGNAL RSIThreshold(int h1, int h2, int p1, int p2, double d1, double d2, uint tf, int shift) {
   double r[2];
   if(CopyBuffer(h1, 0, shift, 2, r) < 2) return SIGNAL_NONE;
   if(r[1] <= d1 && r[0] > d1) return SIGNAL_SELL; // Overbought cross down
   if(r[1] >= d2 && r[0] < d2) return SIGNAL_BUY;  // Oversold cross up
   return SIGNAL_NONE;
}

ENUM_SIGNAL MACrossRSITrend(int h1, int h2, int p1, int p2, double d1, double d2, uint tf, int shift) {
   double ma[2], rsi[2], close[2];
   if(CopyBuffer(h1, 0, shift, 2, ma) < 2 || CopyBuffer(h2, 0, shift, 2, rsi) < 2) return SIGNAL_NONE;
   if(CopyClose(_Symbol, (ENUM_TIMEFRAMES)tf, shift, 2, close) < 2) return SIGNAL_NONE;

   bool buy = (close[1] <= ma[1] && close[0] > ma[0]) && rsi[0] > d1;
   bool sell = (close[1] >= ma[1] && close[0] < ma[0]) && rsi[0] < d2;

   if(buy) return SIGNAL_BUY;
   if(sell) return SIGNAL_SELL;
   return SIGNAL_NONE;
}

ENUM_SIGNAL StochCross(int h1, int h2, int p1, int p2, double d1, double d2, uint tf, int shift) {
   double k[2], d[2];
   // h1 is stochastic handle. Buffer 0 is K, Buffer 1 is D.
   if(CopyBuffer(h1, 0, shift, 2, k) < 2 || CopyBuffer(h1, 1, shift, 2, d) < 2) return SIGNAL_NONE;
   if(k[1] <= d[1] && k[0] > d[0]) return SIGNAL_BUY;
   if(k[1] >= d[1] && k[0] < d[0]) return SIGNAL_SELL;
   return SIGNAL_NONE;
}

ENUM_SIGNAL BBounce(int h1, int h2, int p1, int p2, double d1, double d2, uint tf, int shift) {
   double mid[1], up[1], low[1], close[1];
   if(CopyBuffer(h1, 0, shift, 1, mid) < 1 || CopyBuffer(h1, 1, shift, 1, up) < 1 || CopyBuffer(h1, 2, shift, 1, low) < 1) return SIGNAL_NONE;
   CopyClose(_Symbol, (ENUM_TIMEFRAMES)tf, shift, 1, close);
   if(close[0] < low[0]) return SIGNAL_BUY;
   if(close[0] > up[0]) return SIGNAL_SELL;
   return SIGNAL_NONE;
}

ENUM_SIGNAL DailyBreak(int h1, int h2, int p1, int p2, double d1, double d2, uint tf, int shift) {
   double hi[1], lo[1], close[1];
   if(CopyHigh(_Symbol, PERIOD_D1, 1, 1, hi) < 1 || CopyLow(_Symbol, PERIOD_D1, 1, 1, lo) < 1) return SIGNAL_NONE;
   CopyClose(_Symbol, (ENUM_TIMEFRAMES)tf, shift, 1, close);
   if(close[0] > hi[0]) return SIGNAL_BUY;
   if(close[0] < lo[0]) return SIGNAL_SELL;
   return SIGNAL_NONE;
}

ENUM_SIGNAL DeltaAggression(int h1, int h2, int p1, int p2, double d1, double d2, uint tf, int shift) {
   MqlTick arr[];
   int n = CopyTicksRange(_Symbol, arr, COPY_TICKS_TRADE, TimeCurrent() - 60, TimeCurrent());
   long buy = 0, sell = 0;
   for(int i=0; i<n; i++) if(arr[i].flags & TICK_FLAG_BUY) buy++; else if(arr[i].flags & TICK_FLAG_SELL) sell++;
   long delta = buy - sell;
   if(delta > 300) return SIGNAL_BUY;
   if(delta < -300) return SIGNAL_SELL;
   return SIGNAL_NONE;
}

ENUM_SIGNAL Bar2Pattern(int h1, int h2, int p1, int p2, double d1, double d2, uint tf, int shift) {
   double h[2], l[2], o[1], c[1];
   CopyHigh(_Symbol, (ENUM_TIMEFRAMES)tf, shift, 2, h);
   CopyLow(_Symbol, (ENUM_TIMEFRAMES)tf, shift, 2, l);
   CopyOpen(_Symbol, (ENUM_TIMEFRAMES)tf, shift, 1, o);
   CopyClose(_Symbol, (ENUM_TIMEFRAMES)tf, shift, 1, c);
   if(h[0] < h[1] && l[0] > l[1]) return (c[0] > o[0]) ? SIGNAL_BUY : SIGNAL_SELL;
   return SIGNAL_NONE;
}

ENUM_SIGNAL AMA(int h1, int h2, int p1, int p2, double d1, double d2, uint tf, int shift) {
   double a[2];
   if(CopyBuffer(h1, 0, shift, 2, a) < 2) return SIGNAL_NONE;
   if(a[1] > a[0]) return SIGNAL_BUY;
   if(a[1] < a[0]) return SIGNAL_SELL;
   return SIGNAL_NONE;
}

ENUM_SIGNAL VolumeCycle(int h1, int h2, int p1, int p2, double d1, double d2, uint tf, int shift) {
   long v[12];
   if(CopyVolume(_Symbol, (ENUM_TIMEFRAMES)tf, shift, 12, v) < 12) return SIGNAL_NONE;
   int maxIdx = ArrayMaximum(v);
   int minIdx = ArrayMinimum(v);
   if(0 == minIdx) return SIGNAL_BUY;
   if(0 == maxIdx) return SIGNAL_SELL;
   return SIGNAL_NONE;
}

ENUM_SIGNAL RSRelative(int h1, int h2, int p1, int p2, double d1, double d2, uint tf, int shift) {
   double r1[1], r2[1];
   if(CopyBuffer(h1, 0, shift, 1, r1) < 1 || CopyBuffer(h2, 0, shift, 1, r2) < 1) return SIGNAL_NONE;
   if(r1[0] > r2[0] + 5) return SIGNAL_BUY;
   if(r1[0] < r2[0] - 5) return SIGNAL_SELL;
   return SIGNAL_NONE;
}

// ---------- 2. MOTOR DE DECISÃO ----------
ENUM_SIGNAL AvaliaCondicoes() {
   if(nRules == 0) return SIGNAL_NONE;
   int voto = 0;
   for(int i=0; i<nRules; i++) {
      if(rules[i].active) {
         ENUM_SIGNAL s = rules[i].func(rules[i].h1, rules[i].h2, rules[i].p1, rules[i].p2, rules[i].d1, rules[i].d2, rules[i].tf, 1);
         voto += (int)s;
      }
   }
   if(voto > 0) return SIGNAL_BUY;
   if(voto < 0) return SIGNAL_SELL;
   return SIGNAL_NONE;
}

// ---------- 3. CÁLCULO DE LOTE E EXECUÇÃO ----------
double CalculaLote(double riscoPerc) {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * riscoPerc / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(settings.stop_pts <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   // A forma correta: Risco = (Distancia_em_pontos / tickSize) * tickValue * lotes
   // Logo: lotes = Risco / ( (Distancia_em_pontos / tickSize) * tickValue )
   double numTicks = (settings.stop_pts * _Point) / tickSize;
   if(numTicks <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double lot = riskMoney / (numTicks * tickValue);

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lot = NormalizeDouble(lot, 2);
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   return lot;
}

void EnviaOrdem(ENUM_SIGNAL tipo, double lote) {
   double price = (tipo == SIGNAL_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = (tipo == SIGNAL_BUY) ? price - settings.stop_pts * _Point : price + settings.stop_pts * _Point;
   double tp = (tipo == SIGNAL_BUY) ? price + settings.take_pts * _Point : price - settings.take_pts * _Point;

   string comment = "MT-LiveExecutor AI";
   bool res = false;
   if(tipo == SIGNAL_BUY) res = trade.Buy(lote, _Symbol, price, sl, tp, comment);
   else res = trade.Sell(lote, _Symbol, price, sl, tp, comment);

   if(res) {
      string msg = "Ordem Enviada: " + EnumToString(tipo) + " Lote: " + DoubleToString(lote, 2);
      GravaLog(msg);
      if(StringFind(StrategyPrompt, "alerta") >= 0) SendNotification(msg);
   } else {
      GravaLog("ERRO Trade: " + (string)trade.ResultRetcode() + " - " + trade.ResultRetcodeDescription());
   }
}
