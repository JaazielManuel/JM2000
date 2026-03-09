//+------------------------------------------------------------------+
//|                                              MT_LiveExecutor.mq5 |
//|                                    Copyright 2026, Profit Master |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Profit Master"
#property link      "https://www.mql5.com"
#property version   "9.10"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// --- INPUTS ---
input string InpPrompt = "A cada 15 minutos, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade."; // Prompt da Estratégia

// --- GLOBAIS ---
enum Signal {BUY=1, SELL=-1, NONE=0};

struct Rule {
   bool     active;
   int      handle;
   int      handle2;
   int      tf;
   int      p1, p2, p3;
   double   d1, d2;
   string   s1;
   Signal   (*func)(int index, int shift);
};

Rule rules[30];
int nRules = 0;
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symInfo;
CAccountInfo accInfo;

int dynamicSafetyPoints = 0;
datetime lastSafetyDecay = 0;
datetime lastBarTime = 0;
string currentPrompt = "";

//+------------------------------------------------------------------+
//| NORMALIZAÇÃO E AJUDAS                                            |
//+------------------------------------------------------------------+
double NS(double price) { return NormalizeDouble(price, _Digits); }

bool IsPriceSafe(double price, ENUM_ORDER_TYPE type) {
   double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double buffer = (stopsLevel + dynamicSafetyPoints + 2) * _Point;

   if(type == ORDER_TYPE_BUY) {
      if(price > ask - buffer) return false;
   } else if(type == ORDER_TYPE_SELL) {
      if(price < bid + buffer) return false;
   }
   return true;
}
double NV(double vol) {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   return NormalizeDouble(MathFloor(vol/step)*step, 2);
}

int PeriodoTexto(string nome) {
   StringToLower(nome);
   if(StringFind(nome, "m1") >= 0 || nome == "1") return PERIOD_M1;
   if(StringFind(nome, "m5") >= 0 || nome == "5") return PERIOD_M5;
   if(StringFind(nome, "m15") >= 0 || nome == "15") return PERIOD_M15;
   if(StringFind(nome, "m30") >= 0 || nome == "30") return PERIOD_M30;
   if(StringFind(nome, "h1") >= 0 || nome == "60") return PERIOD_H1;
   if(StringFind(nome, "h4") >= 0 || nome == "240") return PERIOD_H4;
   if(StringFind(nome, "d1") >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

double ExtraiNumero(string txt, string chave) {
   int pos = StringFind(txt, chave);
   if(pos < 0) return 0;
   string sub = StringSubstr(txt, pos + StringLen(chave));

   // Remover caracteres não numéricos iniciais se houver (ex: " (14)")
   int i = 0;
   while(i < StringLen(sub) &&
         (StringGetCharacter(sub, i) < '0' || StringGetCharacter(sub, i) > '9') &&
         StringGetCharacter(sub, i) != '.' && StringGetCharacter(sub, i) != '-') {
      i++;
   }
   if(i > 0) sub = StringSubstr(sub, i);

   return StringToDouble(sub);
}

//+------------------------------------------------------------------+
//| MQL5 WRAPPERS FOR COMPATIBILITY                                  |
//+------------------------------------------------------------------+
double iClose(string symbol, ENUM_TIMEFRAMES tf, int index) {
   double val[1];
   if(CopyClose(symbol, tf, index, 1, val) > 0) return val[0];
   return 0;
}
double iHigh(string symbol, ENUM_TIMEFRAMES tf, int index) {
   double val[1];
   if(CopyHigh(symbol, tf, index, 1, val) > 0) return val[0];
   return 0;
}
double iLow(string symbol, ENUM_TIMEFRAMES tf, int index) {
   double val[1];
   if(CopyLow(symbol, tf, index, 1, val) > 0) return val[0];
   return 0;
}
double iOpen(string symbol, ENUM_TIMEFRAMES tf, int index) {
   double val[1];
   if(CopyOpen(symbol, tf, index, 1, val) > 0) return val[0];
   return 0;
}
datetime iTime(string symbol, ENUM_TIMEFRAMES tf, int index) {
   datetime val[1];
   if(CopyTime(symbol, tf, index, 1, val) > 0) return val[0];
   return 0;
}

//+------------------------------------------------------------------+
//| MT5-KNOWLEDGE-CORE SIGNALS                                       |
//+------------------------------------------------------------------+
Signal CruzamentoMA(int idx, int shift) {
   double bufF[2], bufS[2];
   if(CopyBuffer(rules[idx].handle, 0, shift, 2, bufF) < 2) return NONE;
   double f = bufF[1]; double fp = bufF[0];

   double s=0, sp=0;
   if(rules[idx].handle2 != INVALID_HANDLE) {
      if(CopyBuffer(rules[idx].handle2, 0, shift, 2, bufS) < 2) return NONE;
      s = bufS[1]; sp = bufS[0];
   } else {
      s = iClose(_Symbol, (ENUM_TIMEFRAMES)rules[idx].tf, shift);
      sp = iClose(_Symbol, (ENUM_TIMEFRAMES)rules[idx].tf, shift + 1);
   }

   if(fp <= sp && f > s) return BUY;
   if(fp >= sp && f < s) return SELL;
   return NONE;
}

Signal RSIThreshold(int idx, int shift) {
   double buf[2];
   if(CopyBuffer(rules[idx].handle, 0, shift, 2, buf) < 2) return NONE;
   double v = buf[1];
   double vp = buf[0];

   if(rules[idx].d1 < rules[idx].d2) {
      if(v < rules[idx].d1) return BUY;
      if(v > rules[idx].d2) return SELL;
   } else {
      if(vp <= rules[idx].d1 && v > rules[idx].d1) return BUY;
      if(vp >= rules[idx].d2 && v < rules[idx].d2) return SELL;
   }
   return NONE;
}

Signal StochCross(int idx, int shift) {
   double k[2], d[2];
   if(CopyBuffer(rules[idx].handle, 0, shift, 2, k) < 2 || CopyBuffer(rules[idx].handle, 1, shift, 2, d) < 2) return NONE;
   if(k[0] <= d[0] && k[1] > d[1]) return BUY;
   if(k[0] >= d[0] && k[1] < d[1]) return SELL;
   return NONE;
}

Signal BBounce(int idx, int shift) {
   double up[1], low[1];
   if(CopyBuffer(rules[idx].handle, 1, shift, 1, up) < 1 || CopyBuffer(rules[idx].handle, 2, shift, 1, low) < 1) return NONE;
   double close = iClose(_Symbol, (ENUM_TIMEFRAMES)rules[idx].tf, shift);
   if(close < low[0]) return BUY;
   if(close > up[0]) return SELL;
   return NONE;
}

Signal DailyBreak(int idx, int shift) {
   double hi = iHigh(_Symbol, PERIOD_D1, 1);
   double lo = iLow(_Symbol, PERIOD_D1, 1);
   double close = iClose(_Symbol, PERIOD_M1, shift);
   if(close > hi) return BUY;
   if(close < lo) return SELL;
   return NONE;
}

Signal DeltaAggression(int idx, int shift) {
   MqlTick arr[];
   int n = CopyTicksRange(_Symbol, arr, COPY_TICKS_TRADE, TimeCurrent()-60, TimeCurrent());
   long buy=0, sell=0;
   for(int i=0; i<n; i++) if((arr[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++; else sell++;
   if(buy - sell > rules[idx].d1) return BUY;
   if(buy - sell < -rules[idx].d1) return SELL;
   return NONE;
}

Signal AMA(int idx, int shift) {
   double buf[2];
   if(CopyBuffer(rules[idx].handle, 0, shift, 2, buf) < 2) return NONE;
   if(buf[0] < buf[1]) return BUY;
   if(buf[0] > buf[1]) return SELL;
   return NONE;
}

// --- Parâmetros de Gestão Estratégica ---
int p_stopPoints = 300;
int p_takePoints = 500;
double p_risk = 1.0;
int p_frequency = 15;
int p_newsVeto = 20;
int p_beTrigger = 300;
int p_beOffset = 50;
int p_startHour = 0;
int p_maxTrades = 3;
int p_trailingStop = 0;

void InterpretaPrompt(string prompt) {
   Print("Interpretando prompt: ", prompt);
   for(int i=0; i<30; i++) {
      if(rules[i].handle != INVALID_HANDLE) IndicatorRelease(rules[i].handle);
      if(rules[i].handle2 != INVALID_HANDLE) IndicatorRelease(rules[i].handle2);
      ZeroMemory(rules[i]);
      rules[i].handle = INVALID_HANDLE;
      rules[i].handle2 = INVALID_HANDLE;
   }
   nRules = 0;
   currentPrompt = prompt;
   lastBarTime = 0; // Reset para permitir execução imediata se as condições forem atendidas
   string pLow = prompt; StringToLower(pLow);

   // Extração de parâmetros de gestão
   p_stopPoints = (int)ExtraiNumero(pLow, "stop de ");
   if(p_stopPoints == 0) p_stopPoints = (int)ExtraiNumero(pLow, "sl de ");

   p_takePoints = (int)ExtraiNumero(pLow, "take de ");
   if(p_takePoints == 0) p_takePoints = (int)ExtraiNumero(pLow, "tp de ");

   p_risk = ExtraiNumero(pLow, "risco de ");
   if(p_risk == 0) p_risk = 1.0;

   p_frequency = (int)ExtraiNumero(pLow, "cada ");
   if(p_frequency == 0) p_frequency = 1;

   p_newsVeto = (int)ExtraiNumero(pLow, "operar ");
   if(p_newsVeto == 0) p_newsVeto = (int)ExtraiNumero(pLow, "notícias de ");
   if(p_newsVeto == 0) p_newsVeto = 20;

   p_maxTrades = (int)ExtraiNumero(pLow, "máximo ");
   if(p_maxTrades == 0) p_maxTrades = 3;

   p_trailingStop = (int)ExtraiNumero(pLow, "trailing de ");

   // Divisão do prompt em partes por conectivos para detectar timeframes específicos
   string partes[];
   StringSplit(pLow, '.', partes);
   if(ArraySize(partes) <= 1) StringSplit(pLow, ' e ', partes);

   for(int j=0; j<ArraySize(partes); j++) {
      string s = partes[j];

      // Regra MA
      if(StringFind(s, "média") >= 0) {
         rules[nRules].active = true;
         rules[nRules].p1 = (int)ExtraiNumero(s, "média de ");
         rules[nRules].tf = PeriodoTexto(s);
         rules[nRules].handle = iMA(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, rules[nRules].p1, 0, MODE_EMA, PRICE_CLOSE);
         rules[nRules].func = &CruzamentoMA;
         nRules++;
      }

      // Regra RSI
      if(StringFind(s, "rsi") >= 0) {
         rules[nRules].active = true;
         rules[nRules].p1 = (int)ExtraiNumero(s, "rsi (");
         if(rules[nRules].p1 == 0) rules[nRules].p1 = (int)ExtraiNumero(s, "rsi ");
         rules[nRules].d1 = ExtraiNumero(s, "acima de ");
         rules[nRules].d2 = ExtraiNumero(s, "abaixo de ");
         rules[nRules].tf = PeriodoTexto(s);
         rules[nRules].handle = iRSI(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, rules[nRules].p1, PRICE_CLOSE);
         rules[nRules].func = &RSIThreshold;
         nRules++;
      }

      if(StringFind(s, "estocástico") >= 0) {
         rules[nRules].active = true;
         rules[nRules].p1 = 5; rules[nRules].p2 = 3;
         rules[nRules].tf = PeriodoTexto(s);
         rules[nRules].handle = iStochastic(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, rules[nRules].p1, rules[nRules].p2, 3, MODE_SMA, STO_LOWHIGH);
         rules[nRules].func = &StochCross;
         nRules++;
      }

      if(StringFind(s, "bollinger") >= 0) {
         rules[nRules].active = true;
         rules[nRules].p1 = 20; rules[nRules].d1 = 2.0;
         rules[nRules].tf = PeriodoTexto(s);
         rules[nRules].handle = iBands(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, rules[nRules].p1, 0, rules[nRules].d1, PRICE_CLOSE);
         rules[nRules].func = &BBounce;
         nRules++;
      }
   }

   if(StringFind(pLow, "rompimento diário") >= 0) {
      rules[nRules].active = true;
      rules[nRules].func = &DailyBreak;
      nRules++;
   }

   // Breakeven
   p_beTrigger = (int)ExtraiNumero(pLow, "atingir +");
   p_beOffset = (int)ExtraiNumero(pLow, "entrada +");

   p_startHour = (int)ExtraiNumero(pLow, "depois das ");

   PrintFormat("Regras carregadas: %d. SL: %d, TP: %d, Risco: %.2f%%, Freq: %d min, Hora: %dh", nRules, p_stopPoints, p_takePoints, p_risk, p_frequency, p_startHour);
}

bool AguardaNoticias() {
   MqlCalendarValue values[];
   datetime start = TimeCurrent() - p_newsVeto * 60;
   datetime end = TimeCurrent() + p_newsVeto * 60;

   if(CalendarValueHistory(values, start, end)) {
      for(int i=0; i<ArraySize(values); i++) {
         MqlCalendarEvent event;
         if(CalendarEventById(values[i].event_id, event)) {
            if(event.importance == CALENDAR_IMPORTANCE_HIGH) return true;
         }
      }
   }
   return false;
}

ENUM_TIMEFRAMES MinutesToTimeframe(int min) {
   if(min >= 1440) return PERIOD_D1;
   if(min >= 240)  return PERIOD_H4;
   if(min >= 60)   return PERIOD_H1;
   if(min >= 30)   return PERIOD_M30;
   if(min >= 15)   return PERIOD_M15;
   if(min >= 5)    return PERIOD_M5;
   return PERIOD_M1;
}

Signal AvaliaTudo() {
   if(nRules == 0) return NONE;

   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.hour < p_startHour) return NONE;

   if(AguardaNoticias()) {
      Print("Operação vetada por notícias.");
      return NONE;
   }

   Signal consolidated = NONE;
   for(int i=0; i<nRules; i++) {
      if(rules[i].active) {
         Signal s = rules[i].func(i, 0);
         if(s == NONE) return NONE; // Requisito unânime (AND)
         if(consolidated == NONE) consolidated = s;
         else if(consolidated != s) return NONE; // Conflito de sinais
      }
   }

   return consolidated;
}

void SynchronizeClusterSL(double newSL, ENUM_POSITION_TYPE type) {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(posInfo.SelectByTicket(ticket)) {
         if(posInfo.Symbol() == _Symbol && posInfo.PositionType() == type) {
            if(MathAbs(posInfo.StopLoss() - newSL) > _Point) {
               trade.PositionModify(ticket, NS(newSL), posInfo.TakeProfit());
            }
         }
      }
   }
}

void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(posInfo.SelectByTicket(ticket)) {
         if(posInfo.Symbol() != _Symbol) continue;

         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double openPrice = posInfo.PriceOpen();

         // Breakeven
         if(p_beTrigger > 0) {
            if(posInfo.PositionType() == POSITION_TYPE_BUY) {
               if(bid >= openPrice + p_beTrigger * _Point && posInfo.StopLoss() < openPrice) {
                  trade.PositionModify(ticket, NS(openPrice + p_beOffset * _Point), posInfo.TakeProfit());
               }
            } else {
               if(ask <= openPrice - p_beTrigger * _Point && (posInfo.StopLoss() > openPrice || posInfo.StopLoss() == 0)) {
                  trade.PositionModify(ticket, NS(openPrice - p_beOffset * _Point), posInfo.TakeProfit());
               }
            }
         }

         // Trailing Stop
         if(p_trailingStop > 0) {
            if(posInfo.PositionType() == POSITION_TYPE_BUY) {
               double newSL = bid - p_trailingStop * _Point;
               if(newSL > posInfo.StopLoss() + _Point && bid > openPrice + p_trailingStop * _Point) {
                  trade.PositionModify(ticket, NS(newSL), posInfo.TakeProfit());
               }
            } else {
               double newSL = ask + p_trailingStop * _Point;
               if((newSL < posInfo.StopLoss() - _Point || posInfo.StopLoss() == 0) && ask < openPrice - p_trailingStop * _Point) {
                  trade.PositionModify(ticket, NS(newSL), posInfo.TakeProfit());
               }
            }
         }
      }
   }
}

void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result) {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD) {
      if(HistoryDealSelect(trans.deal)) {
         long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_IN) {
            // Sincronizar SL do Cluster se necessário
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);
            double sl = HistoryDealGetDouble(trans.deal, DEAL_SL);
            if(sl > 0) SynchronizeClusterSL(sl, type);
         }
      }
   }
}

double CalculaLote(double riscoPercent) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riscoAbs = capital * riscoPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(p_stopPoints <= 0) return NV(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));

   double lot = riscoAbs / ((p_stopPoints * _Point) * (tickValue / tickSize));
   return NV(lot);
}

void executaSignal(Signal s) {
   if(s == NONE) return;

   // Verificar máximo de trades simultâneos
   int count = 0;
   for(int i=0; i<PositionsTotal(); i++) if(PositionGetSymbol(i) == _Symbol) count++;
   if(count >= p_maxTrades) return;

   // Frequência alinhada ao candle
   datetime currentBar = iTime(_Symbol, MinutesToTimeframe(p_frequency), 0);
   if(currentBar == lastBarTime) return;

   double lote = CalculaLote(p_risk);
   double sl = 0, tp = 0;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(s == BUY) {
      sl = bid - p_stopPoints * _Point;
      tp = ask + p_takePoints * _Point;
      if(!IsPriceSafe(sl, ORDER_TYPE_BUY)) {
         dynamicSafetyPoints++;
         GravaLog("SL de compra muito próximo. Aumentando safety points.");
      }
      if(trade.Buy(lote, _Symbol, ask, NS(sl), NS(tp))) {
         lastBarTime = currentBar;
         GravaLog("Compra executada com sucesso.");
      } else {
         dynamicSafetyPoints += 5;
         GravaLog("Erro na compra: " + (string)trade.ResultRetcode());
      }
   } else if(s == SELL) {
      sl = ask + p_stopPoints * _Point;
      tp = bid - p_takePoints * _Point;
      if(!IsPriceSafe(sl, ORDER_TYPE_SELL)) {
         dynamicSafetyPoints++;
         GravaLog("SL de venda muito próximo. Aumentando safety points.");
      }
      if(trade.Sell(lote, _Symbol, bid, NS(sl), NS(tp))) {
         lastBarTime = currentBar;
         GravaLog("Venda executada com sucesso.");
      } else {
         dynamicSafetyPoints += 5;
         GravaLog("Erro na venda: " + (string)trade.ResultRetcode());
      }
   }
}

void OnTick() {
   if(InpPrompt != currentPrompt) InterpretaPrompt(InpPrompt);
   GerenciaPosicoes();

   Signal s = AvaliaTudo();
   executaSignal(s);
}

int OnInit() {
   symInfo.Name(_Symbol);
   InterpretaPrompt(InpPrompt);
   EventSetTimer(60);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   for(int i=0; i<30; i++) {
      if(rules[i].handle != INVALID_HANDLE) IndicatorRelease(rules[i].handle);
      if(rules[i].handle2 != INVALID_HANDLE) IndicatorRelease(rules[i].handle2);
   }
}

void GravaLog(string texto) {
   int handle = FileOpen("MT_LiveExecutor_Log.csv", FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      FileSeek(handle, 0, SEEK_END);
      FileWrite(handle, TimeToString(TimeCurrent()), _Symbol, texto);
      FileClose(handle);
   }
   Print(texto);
}

void AIOptimizer() {
   if(!HistorySelect(TimeCurrent() - 30 * 86400, TimeCurrent())) return;

   int total = HistoryDealsTotal();
   int wins = 0, losses = 0;
   double profit = 0, loss = 0;

   for(int i=0; i<total; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT) {
         double p = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         if(p > 0) { wins++; profit += p; }
         else { losses++; loss += MathAbs(p); }
      }
   }

   double wr = (wins + losses > 0) ? (double)wins / (wins + losses) * 100.0 : 0;
   double pf = (loss > 0) ? profit / loss : profit;

   PrintFormat("AI Optimizer: WR %.2f%%, PF %.2f. Sugestão: Manter Risco em %.2f%%", wr, pf, p_risk);
}

void OnTimer() {
   static int count = 0;
   count++;

   // A cada 60 segundos, decai safety points
   if(dynamicSafetyPoints > 0) dynamicSafetyPoints--;

   // A cada hora, roda o otimizador
   if(count % 60 == 0) AIOptimizer();
}
