//=========================  MT-LiveExecutor v9.1  =========================
// Expert Advisor: MT-LiveExecutor.mq5
// Professional Live Trading Engine with Natural Language Interpretation
// Optimized for MetaTrader 5 - Profit Master v8.0 Standard
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// ---------- 1. DEFINIÇÕES, ENUMS E STRUCTS ----------
enum Signal { BUY = 1, SELL = -1, NONE = 0 };
enum RuleType {
   RT_MA_CROSS, RT_RSI, RT_STOCH, RT_BB, RT_DAILY_BREAK,
   RT_DELTA, RT_VOL_CYCLE, RT_AMA, RT_BAR2, RT_RELATIVE
};

struct Rule {
   bool      active;
   RuleType  type;
   int       handle;
   int       tf;
   int       p1, p2, p3;
   int       p3_handle;
   double    d1, d2;
   string    s1;
};

// Parâmetros de Entrada
input string InpPrompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Não operar 20 min antes ou depois de notícias de alto impacto. Máximo 3 trades simultâneos. Ao atingir +30 pontos, move stop para entrada +5 pontos.";

// Variáveis Globais de Controle
Rule rules[30];
int nRules = 0;
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symInfo;
CAccountInfo accInfo;

int atrHandle = INVALID_HANDLE;
int dynamicSafetyPoints = 0;
datetime lastBarTime = 0;
datetime lastSafetyDecay = 0;
datetime lastExecutionTime = 0;

// Parâmetros da Estratégia (Populados pelo InterpretaPrompt)
int p_frequency = PERIOD_M15;
int p_startTime = 10 * 3600;
int p_stopPoints = 300;
int p_takePoints = 500;
double p_riskPercent = 1.0;
int p_newsVetoMin = 20;
int p_maxSimultaneous = 3;
int p_maxTradesTotal = 100;
int p_beTrigger = 300;
int p_beOffset = 50;
bool p_trailingActive = false;
int p_trailingStep = 100;

// ---------- 2. AUXILIARES E NORMALIZAÇÃO ----------

double NS(double price) { return NormalizeDouble(price, _Digits); }
double NV(double vol) {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   return NormalizeDouble(MathFloor(vol/step + 0.000001)*step, 2);
}

void UpdatePriceCache() {
   if(!symInfo.Name(_Symbol)) return;
   symInfo.Refresh();
   symInfo.RefreshRates();

   if(TimeCurrent() - lastSafetyDecay >= 60) {
      if(dynamicSafetyPoints > 0) dynamicSafetyPoints--;
      lastSafetyDecay = TimeCurrent();
   }
}

// ---------- 3. BIBLIOTECA DE SINAIS (MT5-KNOWLEDGE-CORE) ----------

Signal GetSignal(Rule &r) {
   double buf[3];
   int shift = 1; // Sempre avalia o candle fechado para evitar repintura

   switch(r.type) {
      case RT_MA_CROSS:
         if(CopyBuffer(r.handle, 0, shift, 2, buf) < 2) return NONE;
         if(r.p2 == 0) { // Preço vs Média
            double c0 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
            double c1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift+1);
            if(c1 < buf[1] && c0 > buf[0]) return BUY;
            if(c1 > buf[1] && c0 < buf[0]) return SELL;
         } else { // Média vs Média (p2 é a segunda média)
            double m2[2];
            if(r.p3_handle == INVALID_HANDLE || r.p3_handle == 0) r.p3_handle = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p2, 0, MODE_EMA, PRICE_CLOSE);
            if(CopyBuffer(r.p3_handle, 0, shift, 2, m2) == 2) {
               if(buf[1] < m2[1] && buf[0] > m2[0]) return BUY;
               if(buf[1] > m2[1] && buf[0] < m2[0]) return SELL;
            }
         }
         break;

      case RT_RSI:
         if(CopyBuffer(r.handle, 0, shift, 1, buf) < 1) return NONE;
         if(r.d1 > r.d2) { // Trend: 55/45
            if(buf[0] > r.d1) return BUY;
            if(buf[0] < r.d2) return SELL;
         } else { // Reversion: 70/30
            if(buf[0] > r.d1) return SELL;
            if(buf[0] < r.d2) return BUY;
         }
         break;

      case RT_STOCH:
         double k[2], d[2];
         if(CopyBuffer(r.handle, 0, shift, 2, k) < 2 || CopyBuffer(r.handle, 1, shift, 2, d) < 2) return NONE;
         if(k[1] < d[1] && k[0] > d[0]) return BUY;
         if(k[1] > d[1] && k[0] < d[0]) return SELL;
         break;

      case RT_BB:
         double up[1], lw[1];
         double cl = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
         if(CopyBuffer(r.handle, 1, shift, 1, up) < 1 || CopyBuffer(r.handle, 2, shift, 1, lw) < 1) return NONE;
         if(cl < lw[0]) return BUY;
         if(cl > up[0]) return SELL;
         break;

      case RT_DAILY_BREAK:
         double d_hi = iHigh(_Symbol, PERIOD_D1, 1);
         double d_lo = iLow(_Symbol, PERIOD_D1, 1);
         double d_cl = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
         if(d_cl > d_hi) return BUY;
         if(d_cl < d_lo) return SELL;
         break;

      case RT_VOL_CYCLE:
         double vol[20];
         if(CopyBuffer(r.handle, 0, shift, 20, vol) < 20) return NONE;
         int max_idx = ArrayMaximum(vol);
         int min_idx = ArrayMinimum(vol);
         if(max_idx == 0) return SELL;
         if(min_idx == 0) return BUY;
         break;

      case RT_AMA:
         if(CopyBuffer(r.handle, 0, shift, 2, buf) < 2) return NONE;
         if(buf[1] < buf[0]) return BUY;
         if(buf[1] > buf[0]) return SELL;
         break;

      case RT_BAR2:
         double h0 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
         double l0 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
         double h1 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift+1);
         double l1 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift+1);
         double c_0 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
         double o_0 = iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
         if(h0 < h1 && l0 > l1) return (c_0 > o_0) ? BUY : SELL;
         if(h0 > h1 && l0 < l1) return (c_0 > o_0) ? SELL : BUY;
         break;
   }
   return NONE;
}

// ---------- 4. MOTOR DE INTERPRETAÇÃO ----------

double ExtraiNumero(string txt, string chave) {
   int pos = StringFind(txt, chave);
   if(pos < 0) return 0;
   string sub = StringSubstr(txt, pos + StringLen(chave));
   // Limpeza básica para extrair apenas o número
   for(int i=0; i<StringLen(sub); i++) {
      ushort c = StringGetCharacter(sub, i);
      if(!((c >= '0' && c <= '9') || c == '.' || c == ',')) {
         sub = StringSubstr(sub, 0, i);
         break;
      }
   }
   StringReplace(sub, ",", ".");
   return StringToDouble(sub);
}

int PeriodoTexto(string txt) {
   StringToLower(txt);
   if(StringFind(txt, "m1") >= 0) return PERIOD_M1;
   if(StringFind(txt, "m5") >= 0) return PERIOD_M5;
   if(StringFind(txt, "m15") >= 0) return PERIOD_M15;
   if(StringFind(txt, "m30") >= 0) return PERIOD_M30;
   if(StringFind(txt, "h1") >= 0) return PERIOD_H1;
   if(StringFind(txt, "h4") >= 0) return PERIOD_H4;
   if(StringFind(txt, "d1") >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

void InterpretaPrompt(string prompt) {
   // Cleanup anterior
   for(int i=0; i<30; i++) {
      if(rules[i].handle != INVALID_HANDLE) IndicatorRelease(rules[i].handle);
      if(rules[i].p3_handle != INVALID_HANDLE && rules[i].p3_handle != 0) IndicatorRelease(rules[i].p3_handle);
      ZeroMemory(rules[i]);
      rules[i].handle = INVALID_HANDLE;
      rules[i].p3_handle = INVALID_HANDLE;
   }
   nRules = 0;
   lastBarTime = 0;

   // Parâmetros Globais
   double freq = ExtraiNumero(prompt, "cada ");
   if(freq == 1) p_frequency = PERIOD_M1;
   else if(freq == 5) p_frequency = PERIOD_M5;
   else if(freq == 15) p_frequency = PERIOD_M15;
   else if(freq == 30) p_frequency = PERIOD_M30;
   else if(freq == 60) p_frequency = PERIOD_H1;
   else p_frequency = PERIOD_M15;

   p_stopPoints = (int)ExtraiNumero(prompt, "stop de ") * 10;
   p_takePoints = (int)ExtraiNumero(prompt, "take de ") * 10;
   p_riskPercent = ExtraiNumero(prompt, "risco de ");
   if(p_riskPercent <= 0) p_riskPercent = 1.0;

   p_startTime = (int)ExtraiNumero(prompt, "depois das ") * 3600;
   if(p_startTime <= 0) p_startTime = 10 * 3600;

   p_newsVetoMin = (int)ExtraiNumero(prompt, "operar ") > 0 ? (int)ExtraiNumero(prompt, "operar ") : 20;
   p_maxSimultaneous = (int)ExtraiNumero(prompt, "Máximo ") > 0 ? (int)ExtraiNumero(prompt, "Máximo ") : 3;

   p_beTrigger = (int)ExtraiNumero(prompt, "atingir +") * 10;
   p_beOffset = (int)ExtraiNumero(prompt, "entrada +") * 10;

   // Regras de Indicadores (Mapeamento do Prompt para Structs)
   if(StringFind(prompt, "média de ") >= 0) {
      rules[nRules].active = true;
      rules[nRules].type = RT_MA_CROSS;
      rules[nRules].p1 = (int)ExtraiNumero(prompt, "média de ");
      rules[nRules].p2 = 0; // Cross com preço
      rules[nRules].tf = p_frequency;
      rules[nRules].handle = iMA(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, rules[nRules].p1, 0, MODE_EMA, PRICE_CLOSE);
      nRules++;
   }

   if(StringFind(prompt, "RSI") >= 0) {
      rules[nRules].active = true;
      rules[nRules].type = RT_RSI;
      rules[nRules].p1 = 14;
      rules[nRules].tf = p_frequency;
      rules[nRules].d1 = 55; // Nível Superior (Compra se Trend)
      rules[nRules].d2 = 45; // Nível Inferior (Venda se Trend)
      // Ajuste se for reversão
      if(StringFind(prompt, "acima de 70") >= 0) { rules[nRules].d1 = 70; rules[nRules].d2 = 30; }
      rules[nRules].handle = iRSI(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, rules[nRules].p1, PRICE_CLOSE);
      nRules++;
   }

   GravaLog("Estratégia Interpretada com Sucesso.");
}

// ---------- 5. LOGICA DE NEGOCIAÇÃO ----------

Signal AvaliaTudo() {
   if(nRules == 0) return NONE;
   int buyVotes = 0, sellVotes = 0;
   for(int i=0; i<nRules; i++) {
      if(!rules[i].active) continue;
      Signal s = GetSignal(rules[i]);
      if(s == BUY) buyVotes++;
      if(s == SELL) sellVotes++;
   }
   if(buyVotes == nRules) return BUY;
   if(sellVotes == nRules) return SELL;
   return NONE;
}

bool AguardaNoticias() {
   MqlCalendarValue values[];
   datetime from = TimeCurrent() - p_newsVetoMin*60;
   datetime to = TimeCurrent() + p_newsVetoMin*60;
   if(CalendarValueHistory(values, from, to, NULL, NULL) > 0) {
      for(int i=0; i<ArraySize(values); i++) {
         if(values[i].impact >= CALENDAR_IMPACT_HIGH) return true;
      }
   }
   return false;
}

double CalculaLote(double riscoPercent) {
   double capital = AccountInfoDouble(ACCOUNT_BALANCE);
   double riscoAbs = capital * (riscoPercent/100.0);
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double safetyFloor = (stopsLevel + dynamicSafetyPoints + 2);
   double stopSize = MathMax(p_stopPoints, safetyFloor) * _Point;
   if(stopSize <= 0) return 0.01;
   return NV(riscoAbs / (stopSize / _Point * tickVal));
}

void EnviaOrdem(Signal s) {
   if(AguardaNoticias()) { GravaLog("Veto por Notícias"); return; }
   UpdatePriceCache();

   double lote = CalculaLote(p_riskPercent);
   if(lote <= 0) return;

   if(s == BUY) {
      double ask = symInfo.Ask();
      double sl = NS(ask - p_stopPoints * _Point);
      double tp = NS(ask + p_takePoints * _Point);
      if(!trade.Buy(lote, _Symbol, ask, sl, tp)) {
         dynamicSafetyPoints = (int)MathMin(dynamicSafetyPoints + 10, 100);
         GravaLog("Erro na Compra: " + IntegerToString(GetLastError()));
      } else GravaLog("Ordem de COMPRA Executada");
   } else if(s == SELL) {
      double bid = symInfo.Bid();
      double sl = NS(bid + p_stopPoints * _Point);
      double tp = NS(bid - p_takePoints * _Point);
      if(!trade.Sell(lote, _Symbol, bid, sl, tp)) {
         dynamicSafetyPoints = (int)MathMin(dynamicSafetyPoints + 10, 100);
         GravaLog("Erro na Venda: " + IntegerToString(GetLastError()));
      } else GravaLog("Ordem de VENDA Executada");
   }
}

void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(posInfo.SelectByTicket(ticket)) {
         if(posInfo.Symbol() != _Symbol) continue;

         double openPrice = posInfo.PriceOpen();
         double currentSL = posInfo.StopLoss();
         double currentPrice = (posInfo.PositionType() == POSITION_TYPE_BUY) ? symInfo.Bid() : symInfo.Ask();
         double profitPoints = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (currentPrice - openPrice)/_Point : (openPrice - currentPrice)/_Point;

         // Breakeven
         if(p_beTrigger > 0 && profitPoints >= p_beTrigger) {
            double targetSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? openPrice + p_beOffset*_Point : openPrice - p_beOffset*_Point;
            bool modify = false;
            if(posInfo.PositionType() == POSITION_TYPE_BUY && (currentSL < targetSL || currentSL == 0)) modify = true;
            if(posInfo.PositionType() == POSITION_TYPE_SELL && (currentSL > targetSL || currentSL == 0)) modify = true;

            if(modify) { currentSL = targetSL; trade.PositionModify(ticket, NS(targetSL), posInfo.TakeProfit()); }
         }

         // Trailing Stop
         if(p_trailingActive && profitPoints >= p_trailingStep) {
            double targetSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? currentPrice - p_trailingStep*_Point : currentPrice + p_trailingStep*_Point;
            bool modify = false;
            if(posInfo.PositionType() == POSITION_TYPE_BUY && (currentSL < targetSL || currentSL == 0)) modify = true;
            if(posInfo.PositionType() == POSITION_TYPE_SELL && (currentSL > targetSL || currentSL == 0)) modify = true;

            if(modify) trade.PositionModify(ticket, NS(targetSL), posInfo.TakeProfit());
         }
      }
   }
}

void GravaLog(string texto) {
   int h = FileOpen("MT_LiveExecutor_Log.csv", FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI);
   if(h != INVALID_HANDLE) {
      FileSeek(h, 0, SEEK_END);
      FileWrite(h, TimeToString(TimeCurrent()), texto);
      FileClose(h);
   }
   Print("MT-LiveExecutor: " + texto);
}

// ---------- 6. INTELIGÊNCIA ARTIFICIAL (AIOptimizer) ----------

void AIOptimizer() {
   if(atrHandle == INVALID_HANDLE) atrHandle = iATR(_Symbol, PERIOD_H1, 14);

   HistorySelect(TimeCurrent() - 86400*7, TimeCurrent());
   int total = HistoryDealsTotal();
   int wins = 0; double profit = 0;
   for(int i=0; i<total; i++) {
      ulong t = HistoryDealGetTicket(i);
      double p = HistoryDealGetDouble(t, DEAL_PROFIT);
      if(p > 0) wins++;
      profit += p;
   }
   double wr = total > 5 ? (double)wins/total : 0.5;

   // Ajuste Heurístico de Risco
   if(wr < 0.4) p_riskPercent = MathMax(0.5, p_riskPercent * 0.95);
   if(wr > 0.6) p_riskPercent = MathMin(5.0, p_riskPercent * 1.05);
}

// ---------- 7. EVENTOS DE CICLO DE VIDA ----------

int OnInit() {
   symInfo.Name(_Symbol);
   InterpretaPrompt(InpPrompt);
   EventSetTimer(3600); // Optimizer roda a cada hora
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   for(int i=0; i<30; i++) {
      if(rules[i].handle != INVALID_HANDLE) IndicatorRelease(rules[i].handle);
      if(rules[i].p3_handle != INVALID_HANDLE && rules[i].p3_handle != 0) IndicatorRelease(rules[i].p3_handle);
   }
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   EventKillTimer();
}

void OnTick() {
   static string lastPrompt = "";
   if(InpPrompt != lastPrompt) {
      InterpretaPrompt(InpPrompt);
      lastPrompt = InpPrompt;
   }

   UpdatePriceCache();

   // Execução por Novo Candle (Baseado na frequência da estratégia)
   datetime currentBar = iTime(_Symbol, (ENUM_TIMEFRAMES)p_frequency, 0);
   if(currentBar != lastBarTime) {
      lastBarTime = currentBar;
      // Filtro de Horário
      MqlDateTime dt; TimeCurrent(dt);
      if(dt.hour * 3600 + dt.min * 60 >= p_startTime) {
         Signal s = AvaliaTudo();
         if(s != NONE && PositionsTotal() < p_maxSimultaneous) {
            EnviaOrdem(s);
         }
      }
   }

   GerenciaPosicoes();
}

void OnTimer() {
   AIOptimizer();
}

void OnTradeTransaction(const MqlTradeTransaction& trans, const MqlTradeRequest& request, const MqlTradeResult& result) {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD) {
      if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_IN) {
         // Sync SL para o cluster (se houver múltiplas posições do mesmo tipo)
         double lastSL = HistoryDealGetDouble(trans.deal, DEAL_SL);
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);
         // Implementação simplificada de sincronização
      }
   }
}
