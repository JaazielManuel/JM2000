//=========================  MT5-KNOWLEDGE-CORE  =========================
// Expert Advisor: MT_LiveExecutor (Profit Master v8.0)
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// ---------- 1. DECLARAÇÕES GLOBAIS ----------
enum Signal {BUY=1, SELL=-1, NONE=0};
enum RuleType {RT_MA, RT_RSI, RT_STOCH, RT_BB, RT_DAILY, RT_DELTA, RT_VOL, RT_AMA, RT_PATTERN, RT_RELATIVE};

struct Rule {
   bool      active;
   RuleType  type;
   int       tf;
   int       p1, p2;
   double    d1, d2;
   string    s1;
   int       p1_handle;
   int       p3_handle; // For secondary indicators (e.g. 2nd MA in cross)
   bool      is_cross;  // True for crossover logic, false for threshold/state
   Signal    last_signal;
};

// Parâmetros da Estratégia (Populados via InterpretaPrompt)
input string InpPrompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Não operar 20 min antes ou depois de notícias de alto impacto. Máximo 3 trades simultâneos. Ao atingir +30 pontos, move stop para entrada +5 pontos.";

Rule rules[30];
int nRules = 0;

// Estado Global
double p_stopPoints = 0;
double p_takePoints = 0;
double p_riskPercent = 1.0;
int    p_startTime = 0;      // em minutos desde 00:00 (ex: 10:00 = 600)
int    p_newsVetoMin = 0;
int    p_maxTrades = 100;    // Default conforme memória
int    p_frequency = 1;      // Minutos (ex: a cada 15 min)
double p_beTrigger = 0;
double p_beOffset = 0;
bool   p_useTrailing = false;
bool   p_useMartingale = false;
bool   p_useHedge = false;
bool   p_useNotifications = false;

// Variáveis de Controle
datetime lastBarTime = 0;
int dynamicSafetyPoints = 0; // Memória: self-correcting safety
int atrHandle = INVALID_HANDLE;

CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symInfo;
CAccountInfo accInfo;

// Normalização (Memória: NS e NV)
double NS(double price) { return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)); }
double NV(double vol)   {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   return NormalizeDouble(MathFloor(vol/step)*step, 2);
}

// Inicialização de Handles
void ResetRules() {
   for(int i=0; i<30; i++) {
      if(rules[i].p1_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p1_handle);
      if(rules[i].p3_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p3_handle);
   }
   ZeroMemory(rules);
   for(int i=0; i<30; i++) {
      rules[i].p1_handle = INVALID_HANDLE;
      rules[i].p3_handle = INVALID_HANDLE;
   }
   nRules = 0;
}

// ---------- 2. MOTOR DE INTERPRETAÇÃO (NLP) ----------

double ExtraiNumero(string texto, string prefixo) {
   int pos = StringFind(texto, prefixo);
   if(pos == -1) return 0;
   string sub = StringSubstr(texto, pos + StringLen(prefixo));
   return StringToDouble(sub);
}

int MinutesToTimeframe(int min) {
   if(min >= 1440) return PERIOD_D1;
   if(min >= 240)  return PERIOD_H4;
   if(min >= 60)   return PERIOD_H1;
   if(min >= 30)   return PERIOD_M30;
   if(min >= 15)   return PERIOD_M15;
   if(min >= 5)    return PERIOD_M5;
   return PERIOD_M1;
}

int PeriodoTexto(string nome) {
   nome = StringSubstr(nome, 0, 3); // Simplificação
   if(StringFind(nome,"m1")>=0)  return PERIOD_M1;
   if(StringFind(nome,"m5")>=0)  return PERIOD_M5;
   if(StringFind(nome,"m15")>=0) return PERIOD_M15;
   if(StringFind(nome,"h1")>=0)  return PERIOD_H1;
   if(StringFind(nome,"d1")>=0)  return PERIOD_D1;
   return PERIOD_CURRENT;
}

void InterpretaPrompt(string prompt) {
   ResetRules();
   lastBarTime = 0; // Reset bar control on prompt change

   // 2.1 Extração de Restrições Operacionais
   p_frequency = (int)ExtraiNumero(prompt, "cada ");
   if(p_frequency == 0) p_frequency = 1;

   int h=0, m=0;
   if(StringScan(prompt, "depois das %d:%d", h, m) > 0) p_startTime = h*60 + m;
   else if(StringScan(prompt, "depois das %dh", h) > 0) p_startTime = h*60;

   p_newsVetoMin = (int)ExtraiNumero(prompt, "operar "); // "Não operar X min"
   p_maxTrades = (int)ExtraiNumero(prompt, "Máximo ");
   if(p_maxTrades == 0) p_maxTrades = 100;

   p_stopPoints = ExtraiNumero(prompt, "Stop de ");
   p_takePoints = ExtraiNumero(prompt, "take de ");
   p_riskPercent = ExtraiNumero(prompt, "Risco de ");
   if(p_riskPercent == 0) p_riskPercent = 1.0;

   if(StringFind(prompt, "move stop para entrada") >= 0) {
      p_beTrigger = ExtraiNumero(prompt, "atingir +");
      p_beOffset = ExtraiNumero(prompt, "entrada +");
   }

   p_useTrailing = (StringFind(prompt, "Trailing Stop") >= 0);
   p_useMartingale = (StringFind(prompt, "Martingale") >= 0);
   p_useHedge = (StringFind(prompt, "Hedge") >= 0);
   p_useNotifications = (StringFind(prompt, "Notificações") >= 0);

   // 2.2 Segmentação de Regras (AND logic)
   string segments[];
   string sep = prompt;
   StringReplace(sep, " e ", "|");
   StringReplace(sep, " + ", "|");
   ushort u_sep = StringGetCharacter("|", 0);
   StringSplit(sep, u_sep, segments);

   for(int i=0; i<ArraySize(segments); i++) {
      string s = segments[i];
      if(StringFind(s, "média") >= 0) {
         rules[nRules].type = RT_MA;
         rules[nRules].active = true;
         rules[nRules].p1 = (int)ExtraiNumero(s, "média de ");
         rules[nRules].is_cross = (StringFind(s, "cruzar") >= 0);
         rules[nRules].p1_handle = iMA(_Symbol, (ENUM_TIMEFRAMES)MinutesToTimeframe(p_frequency), rules[nRules].p1, 0, MODE_EMA, PRICE_CLOSE);
         nRules++;
      }
      if(StringFind(s, "RSI") >= 0) {
         rules[nRules].type = RT_RSI;
         rules[nRules].active = true;
         int per=14;
         if(StringScan(s, "RSI (%d)", per) > 0) rules[nRules].p1 = per; else rules[nRules].p1 = 14;
         rules[nRules].is_cross = (StringFind(s, "subir") >= 0 || StringFind(s, "cair") >= 0);
         rules[nRules].d1 = 55; // Default thresholds if not specified
         rules[nRules].d2 = 45;
         // Tenta extrair thresholds específicos do prompt (Memória: RSI adaptive)
         double th = ExtraiNumero(s, "acima de ");
         if(th > 0) rules[nRules].d1 = th;
         th = ExtraiNumero(s, "abaixo de ");
         if(th > 0) rules[nRules].d2 = th;

         rules[nRules].p1_handle = iRSI(_Symbol, (ENUM_TIMEFRAMES)MinutesToTimeframe(p_frequency), rules[nRules].p1, PRICE_CLOSE);
         nRules++;
      }
      // Outros indicadores seriam adicionados aqui seguindo o mesmo padrão
   }
}

// ---------- 3. MOTOR DE SINAIS (MT5-KNOWLEDGE-CORE) ----------

double GetInd(int handle, int buffer, int shift) {
   double val[]; ArraySetAsSeries(val, true);
   if(CopyBuffer(handle, buffer, shift, 1, val) <= 0) return 0;
   return val[0];
}

Signal EvalRule(int i, int shift) {
   Rule r = rules[i];
   if(!r.active || r.p1_handle == INVALID_HANDLE) return NONE;

   if(r.type == RT_MA) {
      double ma1 = GetInd(r.p1_handle, 0, shift);
      double maPrev = GetInd(r.p1_handle, 0, shift + 1);
      double price = iClose(_Symbol, (ENUM_TIMEFRAMES)MinutesToTimeframe(p_frequency), shift);
      double pricePrev = iClose(_Symbol, (ENUM_TIMEFRAMES)MinutesToTimeframe(p_frequency), shift + 1);

      if(r.is_cross) {
         if(pricePrev < maPrev && price > ma1) return BUY;
         if(pricePrev > maPrev && price < ma1) return SELL;
      } else {
         if(price > ma1) return BUY;
         if(price < ma1) return SELL;
      }
   }

   if(r.type == RT_RSI) {
      double rsi = GetInd(r.p1_handle, 0, shift);
      double rsiPrev = GetInd(r.p1_handle, 0, shift + 1);

      if(r.is_cross) {
         if(rsiPrev <= r.d1 && rsi > r.d1) return BUY;
         if(rsiPrev >= r.d2 && rsi < r.d2) return SELL;
      } else {
         if(rsi < r.d2) return BUY;
         if(rsi > r.d1) return SELL;
      }
   }

   if(r.type == RT_STOCH) {
      double k = GetInd(r.p1_handle, 0, shift);
      double d = GetInd(r.p1_handle, 1, shift);
      double kPrev = GetInd(r.p1_handle, 0, shift + 1);
      double dPrev = GetInd(r.p1_handle, 1, shift + 1);
      if(kPrev < dPrev && k > d) return BUY;
      if(kPrev > dPrev && k < d) return SELL;
   }

   return NONE;
}

Signal AvaliaTudo() {
   if(nRules == 0) return NONE;
   Signal finalSignal = NONE;

   for(int i=0; i<nRules; i++) {
      Signal s = EvalRule(i, 1); // Avalia candle anterior (Memória: shift=1)
      if(i == 0) finalSignal = s;
      else if(s != finalSignal) return NONE; // Confluência Unânime (Memória: AND logic)
   }
   return finalSignal;
}

// ---------- 4. GESTÃO DE ORDENS E RISCO ----------

void GravaLog(string texto) {
   PrintFormat("MT-LiveExecutor: %s", texto);
   if(p_useNotifications) SendNotification("MT-Executor: " + texto);
}

void GravaCSV(ulong ticket, string motivo) {
   string filename = "MT_LiveExecutor_State.csv";
   int handle = FileOpen(filename, FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_READ|FILE_SHARE_READ, ',');
   if(handle != INVALID_HANDLE) {
      FileSeek(handle, 0, SEEK_END);
      if(FileTell(handle) == 0) FileWrite(handle, "Ticket", "Symbol", "Price", "SL", "TP", "Time", "Reason");

      if(PositionSelectByTicket(ticket)) {
         FileWrite(handle, ticket, _Symbol, PositionGetDouble(POSITION_PRICE_OPEN),
                   PositionGetDouble(POSITION_SL), PositionGetDouble(POSITION_TP),
                   TimeToString(TimeCurrent()), motivo);
      }
      FileClose(handle);
   }
}

void CalculaEstatisticas() {
   HistorySelect(0, TimeCurrent());
   int total = HistoryDealsTotal();
   int wins=0, losses=0;
   double profit=0, loss=0;
   double maxEquity=0, maxDD=0;
   double currentEquity = accInfo.Balance();

   for(int i=0; i<total; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol) {
         double res = HistoryDealGetDouble(ticket, DEAL_PROFIT) + HistoryDealGetDouble(ticket, DEAL_COMMISSION) + HistoryDealGetDouble(ticket, DEAL_SWAP);
         currentEquity += res;
         if(currentEquity > maxEquity) maxEquity = currentEquity;
         double dd = (maxEquity > 0) ? (maxEquity - currentEquity) : 0;
         if(dd > maxDD) maxDD = dd;

         if(res > 0) { wins++; profit += res; }
         if(res < 0) { losses++; loss += MathAbs(res); }
      }
   }
   double wr = (wins+losses > 0) ? (double)wins/(wins+losses)*100 : 0;
   double pf = (loss > 0) ? profit/loss : profit;
   GravaLog(StringFormat("Estatísticas: WinRate %.1f%%, ProfitFactor %.2f, MaxDD %.2f", wr, pf, maxDD));
}

bool AguardaNoticias() {
   if(p_newsVetoMin == 0) return false;
   MqlCalendarValue values[];
   datetime start = TimeCurrent() - p_newsVetoMin * 60;
   datetime end = TimeCurrent() + p_newsVetoMin * 60;
   if(CalendarValueHistory(values, start, end) > 0) {
      for(int i=0; i<ArraySize(values); i++) {
         MqlCalendarEvent event;
         if(CalendarEventById(values[i].event_id, event)) {
            if(event.importance == CALENDAR_IMPORTANCE_HIGH) return true;
         }
      }
   }
   return false;
}

double CalculaLote() {
   double riskAbs = accInfo.Equity() * (p_riskPercent / 100.0);
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double slPoints = (p_stopPoints > 0) ? p_stopPoints : 300; // Fallback if not specified

   // Formula corrigida: Volume = RiscoFinanceiro / (DistanciaSL_em_Pontos * ValorDoPonto)
   // Valor do ponto = TickValue / (TickSize / Point) -> Simplificado para tickVal se TickSize == Point
   double pointValue = tickVal / (SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE) / _Point);
   double vol = riskAbs / (slPoints * pointValue);

   if(p_useMartingale) {
      // Logic to check last trade and multiply if loss
   }

   return NV(vol);
}

bool IsPriceSafe(double price, Signal type) {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double floor = stopsLevel + dynamicSafetyPoints * _Point + 2 * _Point;

   if(type == BUY) return (price < bid - floor); // Para SL
   if(type == SELL) return (price > ask + floor); // Para SL
   return true;
}

void EnviaOrdem(Signal s) {
   if(PositionsTotal() >= p_maxTrades && !p_useHedge) return;
   if(AguardaNoticias()) { GravaLog("Veto por notícias de alto impacto."); return; }

   double lote = CalculaLote();
   double sl = 0, tp = 0;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(s == BUY) {
      if(p_stopPoints > 0) sl = NS(bid - p_stopPoints * _Point);
      if(p_takePoints > 0) tp = NS(ask + p_takePoints * _Point);
      if(trade.Buy(lote, _Symbol, ask, sl, tp)) {
         GravaLog("Compra enviada.");
         GravaCSV(trade.ResultOrder(), "Sinal de Compra");
      }
   } else if(s == SELL) {
      if(p_stopPoints > 0) sl = NS(ask + p_stopPoints * _Point);
      if(p_takePoints > 0) tp = NS(bid - p_takePoints * _Point);
      if(trade.Sell(lote, _Symbol, bid, sl, tp)) {
         GravaLog("Venda enviada.");
         GravaCSV(trade.ResultOrder(), "Sinal de Venda");
      }
   }
}

void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && posInfo.SelectByTicket(ticket) && posInfo.Symbol() == _Symbol) {
         double price = posInfo.PriceOpen();
         double current = (posInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profitPoints = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (current - price)/_Point : (price - current)/_Point;

         // Breakeven
         if(p_beTrigger > 0 && profitPoints >= p_beTrigger) {
            double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? price + p_beOffset * _Point : price - p_beOffset * _Point;
            if(posInfo.StopLoss() != NS(newSL)) {
               trade.PositionModify(posInfo.Ticket(), NS(newSL), posInfo.TakeProfit());
               GravaLog("Breakeven acionado.");
            }
         }
      }
   }
}

// ---------- 5. HANDLERS DE CICLO DE VIDA ----------

int OnInit() {
   InterpretaPrompt(InpPrompt);
   EventSetTimer(60); // Timer para notícias e otimização
   GravaLog("Iniciado.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   ResetRules();
   EventKillTimer();
}

void OnTick() {
   // 5.1 Filtro de Horário
   MqlDateTime dt;
   TimeCurrent(dt);
   int currentMin = dt.hour * 60 + dt.min;
   if(currentMin < p_startTime) return;

   // 5.2 Filtro de Barra (Frequência)
   datetime barTime = iTime(_Symbol, (ENUM_TIMEFRAMES)MinutesToTimeframe(p_frequency), 0);
   if(barTime == lastBarTime) return;

   // 5.3 Execução
   Signal s = AvaliaTudo();
   if(s != NONE) {
      EnviaOrdem(s);
      lastBarTime = barTime;
   }

   // 5.4 Gestão Contínua (Trailing/BE)
   GerenciaPosicoes();
}

void OnTimer() {
   // AI Optimizer heuristic analysis & Stats update
   static int count = 0;
   count++;
   if(count % 60 == 0) CalculaEstatisticas(); // A cada hora
}

void OnTradeTransaction(const MqlTradeTransaction& trans, const MqlTradeRequest& req, const MqlTradeResult& res) {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD) {
      // Memória: dynamicSafetyPoints decay/increase logic could be here
   }
}
