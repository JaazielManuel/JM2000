//=========================  MT5-LIVE-EXECUTOR  =========================
// Módulo de execução dinâmica baseada em linguagem natural (NLP).
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// ---------- ENUMS E ESTRUTURAS ----------
enum Signal {BUY=1, SELL=-1, NONE=0};

struct Rule {
   bool     active;
   int      type;       // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: DailyBreak, 6: Delta, 7: Vol, 8: AMA, 9: Bar2, 10: RS, 11: AI
   ENUM_TIMEFRAMES tf;
   int      p1, p2, p3;
   double   d1, d2;
   string   s1;
   int      handle1, handle2;
   Signal   intent;     // BUY, SELL ou NONE (se for filtro para ambos)
};

// ---------- PARÂMETROS GLOBAIS DA ESTRATÉGIA ----------
ENUM_TIMEFRAMES p_frequency      = PERIOD_M15;
double          p_riskPercent    = 1.0;
int             p_stopPoints     = 300;
int             p_takePoints     = 500;
int             p_maxTrades      = 3;
int             p_beStart        = 0;   // Pontos para ativar break-even
int             p_bePlus         = 0;   // Pontos acima da entrada no BE
int             p_trailingStart  = 0;   // Pontos para iniciar trailing
int             p_trailingStep   = 10;  // Passo do trailing
string          p_startTime      = "00:00";
bool            p_useMartingale  = false;
datetime        lastBarTime      = 0;
int             EA_MAGIC         = 123456;

Rule rules[20];
int nRules = 0;
CTrade trade;

// ---------- UTILITÁRIOS DE NLP ----------

// Extrai o primeiro número encontrado em uma string a partir de uma posição
double ExtraiNumero(string txt, int startPos = 0) {
   string res = "";
   bool found = false;
   for(int i = startPos; i < StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.') {
         res += ShortToString(c);
         found = true;
      } else if(found) break;
   }
   return StringToDouble(res);
}

// Sobrecarga de ExtraiNumero para atualizar a posição final
double ExtraiNumero(string txt, int startPos, int &endPos) {
   string res = "";
   bool found = false;
   int i = startPos;
   for(; i < StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.') {
         res += ShortToString(c);
         found = true;
      } else if(found) break;
   }
   endPos = i;
   return StringToDouble(res);
}

// Extrai um valor numérico que aparece após uma palavra-chave específica
double ExtraiValorApos(string txt, string chave) {
   int pos = StringFind(txt, chave);
   if(pos < 0) return 0;
   return ExtraiNumero(txt, pos + StringLen(chave));
}

// Converte texto de timeframe (ex: "15 minutos", "m15", "h1") para ENUM_TIMEFRAMES
ENUM_TIMEFRAMES PeriodoTexto(string nome) {
   nome = StringSubstr(nome, 0);
   StringToLower(nome);

   if(StringFind(nome, "15 minutos") >= 0 || StringFind(nome, "m15") >= 0) return PERIOD_M15;
   if(StringFind(nome, "5 minutos") >= 0 || StringFind(nome, "m5") >= 0) return PERIOD_M5;
   if(StringFind(nome, "1 minuto") >= 0 || StringFind(nome, "minuto") >= 0 || StringFind(nome, "m1") >= 0) return PERIOD_M1;
   if(StringFind(nome, "1 hora") >= 0 || StringFind(nome, "h1") >= 0) return PERIOD_H1;
   if(StringFind(nome, "diário") >= 0 || StringFind(nome, "d1") >= 0) return PERIOD_D1;

   return PERIOD_CURRENT;
}

// Padroniza horários como "10h" ou "10:30" para "HH:MM"
string ExtractTime(string txt) {
   int pos = StringFind(txt, "h");
   if(pos > 0) {
      string h = StringSubstr(txt, pos-2, 2);
      string m = "00";
      if(StringGetCharacter(txt, pos+1) >= '0' && StringGetCharacter(txt, pos+1) <= '9')
         m = StringSubstr(txt, pos+1, 2);
      return h + ":" + m;
   }
   return "00:00";
}

// ---------- RESET E LIMPEZA ----------
void ResetStrategy() {
   for(int i = 0; i < nRules; i++) {
      if(rules[i].handle1 != INVALID_HANDLE && rules[i].handle1 != 0) IndicatorRelease(rules[i].handle1);
      if(rules[i].handle2 != INVALID_HANDLE && rules[i].handle2 != 0) IndicatorRelease(rules[i].handle2);
   }
   nRules = 0;
   p_frequency = PERIOD_M15;
   p_riskPercent = 1.0;
   p_stopPoints = 300;
   p_takePoints = 500;
   p_maxTrades = 3;
   p_beStart = 0;
   p_bePlus = 0;
   p_trailingStart = 0;
   p_startTime = "00:00";
   p_useMartingale = false;
}

// ---------- INTERPRETAÇÃO DO PROMPT ----------
void InterpretaPrompt(string prompt) {
   ResetStrategy();
   string originalPrompt = prompt;
   StringToLower(prompt);

   // Extração de parâmetros globais
   p_frequency = PeriodoTexto(prompt);
   if(StringFind(prompt, "risco de") >= 0) p_riskPercent = ExtraiValorApos(prompt, "risco de");
   if(StringFind(prompt, "stop de") >= 0) p_stopPoints = (int)ExtraiValorApos(prompt, "stop de");
   if(StringFind(prompt, "take de") >= 0) p_takePoints = (int)ExtraiValorApos(prompt, "take de");
   if(StringFind(prompt, "máximo") >= 0 && StringFind(prompt, "trades") >= 0) p_maxTrades = (int)ExtraiValorApos(prompt, "máximo");
   if(StringFind(prompt, "depois das") >= 0) p_startTime = ExtractTime(prompt);
   if(StringFind(prompt, "martingale") >= 0) p_useMartingale = true;

   // Break-even e Trailing
   if(StringFind(prompt, "atingir +") >= 0) p_beStart = (int)ExtraiValorApos(prompt, "atingir +");
   if(StringFind(prompt, "entrada +") >= 0) p_bePlus = (int)ExtraiValorApos(prompt, "entrada +");
   if(StringFind(prompt, "trailing stop") >= 0) p_trailingStart = (int)ExtraiValorApos(prompt, "trailing stop");

   // Divisão em segmentos de regras
   string segments[];
   string tempPrompt = prompt;
   StringReplace(tempPrompt, " e ", "|");
   StringReplace(tempPrompt, ".", "|");
   StringReplace(tempPrompt, ",", "|");
   ushort sep = StringGetCharacter("|", 0);
   StringSplit(tempPrompt, sep, segments);

   Signal currentIntent = NONE;

   for(int i = 0; i < ArraySize(segments); i++) {
      string seg = segments[i];
      if(StringLen(seg) < 5) continue;

      if(StringFind(seg, "compra") >= 0) currentIntent = BUY;
      else if(StringFind(seg, "vende") >= 0) currentIntent = SELL;

      ENUM_TIMEFRAMES segTF = PeriodoTexto(seg);
      if(segTF == PERIOD_CURRENT) segTF = p_frequency;

      // 1. Médias Móveis
      if(StringFind(seg, " ma ") >= 0 || StringFind(seg, "média") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = 1;
         rules[nRules].tf = segTF;
         rules[nRules].intent = currentIntent;
         int p1 = (int)ExtraiNumero(seg);
         int p2 = 0;
         int pos = StringFind(seg, "/");
         if(pos > 0) p2 = (int)ExtraiNumero(seg, pos + 1);

         if(p2 > 0) {
            rules[nRules].handle1 = iMA(_Symbol, segTF, p1, 0, MODE_EMA, PRICE_CLOSE);
            rules[nRules].handle2 = iMA(_Symbol, segTF, p2, 0, MODE_EMA, PRICE_CLOSE);
         } else {
            if(p1 == 0) p1 = 20; // Default
            rules[nRules].handle1 = iMA(_Symbol, segTF, p1, 0, MODE_EMA, PRICE_CLOSE);
         }
         nRules++;
      }
      // 2. RSI
      else if(StringFind(seg, "rsi") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = 2;
         rules[nRules].tf = segTF;
         rules[nRules].intent = currentIntent;
         int endPos;
         double val1 = ExtraiNumero(seg, 0, endPos);
         double val2 = ExtraiNumero(seg, endPos);
         if(val2 == 0) { rules[nRules].p1 = 14; rules[nRules].d1 = val1; }
         else { rules[nRules].p1 = (int)val1; rules[nRules].d1 = val2; }
         rules[nRules].handle1 = iRSI(_Symbol, segTF, rules[nRules].p1, PRICE_CLOSE);
         nRules++;
      }
      // 3. Estocástico
      else if(StringFind(seg, "stoch") >= 0 || StringFind(seg, "estocástico") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = 3;
         rules[nRules].tf = segTF;
         rules[nRules].intent = currentIntent;
         rules[nRules].handle1 = iStochastic(_Symbol, segTF, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
         nRules++;
      }
      // 4. Bollinger
      else if(StringFind(seg, "bollinger") >= 0 || StringFind(seg, " b bands ") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = 4;
         rules[nRules].tf = segTF;
         rules[nRules].intent = currentIntent;
         rules[nRules].handle1 = iBands(_Symbol, segTF, 20, 0, 2.0, PRICE_CLOSE);
         nRules++;
      }
      // 11. AI Prediction
      else if(StringFind(seg, "previsão") >= 0 || StringFind(seg, "ai") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = 11;
         rules[nRules].tf = segTF;
         rules[nRules].intent = currentIntent;
         rules[nRules].handle1 = iATR(_Symbol, segTF, 14);
         nRules++;
      }
   }
}

// ---------- FUNÇÕES DE SINAL TÉCNICO ----------

double GetBufferValue(int handle, int buffer, int shift) {
   double val[];
   ArraySetAsSeries(val, true);
   if(CopyBuffer(handle, buffer, shift, 1, val) <= 0) return 0;
   return val[0];
}

Signal CruzamentoMA(Rule &r) {
   if(r.handle2 != INVALID_HANDLE && r.handle2 != 0) {
      double f1 = GetBufferValue(r.handle1, 0, 1);
      double s1 = GetBufferValue(r.handle2, 0, 1);
      double f2 = GetBufferValue(r.handle1, 0, 2);
      double s2 = GetBufferValue(r.handle2, 0, 2);
      if(f2 < s2 && f1 > s1) return BUY;
      if(f2 > s2 && f1 < s1) return SELL;
   } else {
      double ma1 = GetBufferValue(r.handle1, 0, 1);
      double ma2 = GetBufferValue(r.handle1, 0, 2);
      double c1 = iClose(_Symbol, r.tf, 1);
      double c2 = iClose(_Symbol, r.tf, 2);
      if(c2 < ma2 && c1 > ma1) return BUY;
      if(c2 > ma2 && c1 < ma1) return SELL;
   }
   return NONE;
}

Signal RSIThreshold(Rule &r) {
   double v1 = GetBufferValue(r.handle1, 0, 1);
   double v2 = GetBufferValue(r.handle1, 0, 2);
   if(r.intent == BUY && v2 < r.d1 && v1 > r.d1) return BUY;
   if(r.intent == SELL && v2 > r.d1 && v1 < r.d1) return SELL;
   if(r.intent == NONE) {
      if(v1 > 70) return SELL;
      if(v1 < 30) return BUY;
   }
   return NONE;
}

Signal StochSignal(Rule &r) {
   double k1 = GetBufferValue(r.handle1, 0, 1);
   double d1 = GetBufferValue(r.handle1, 1, 1);
   double k2 = GetBufferValue(r.handle1, 0, 2);
   double d2 = GetBufferValue(r.handle1, 1, 2);
   if(k2 < d2 && k1 > d1) return BUY;
   if(k2 > d2 && k1 < d1) return SELL;
   return NONE;
}

Signal BBSignal(Rule &r) {
   double up = GetBufferValue(r.handle1, 1, 1);
   double lo = GetBufferValue(r.handle1, 2, 1);
   double cl = iClose(_Symbol, r.tf, 1);
   if(cl < lo) return BUY;
   if(cl > up) return SELL;
   return NONE;
}

Signal AISignal(Rule &r) {
   double atr = GetBufferValue(r.handle1, 0, 1);
   double body = MathAbs(iClose(_Symbol, r.tf, 1) - iOpen(_Symbol, r.tf, 1));
   if(body > 1.5 * atr) {
      return (iClose(_Symbol, r.tf, 1) > iOpen(_Symbol, r.tf, 1)) ? BUY : SELL;
   }
   return NONE;
}

Signal DailyBreakSignal(Rule &r) {
   double hi = iHigh(_Symbol, PERIOD_D1, 1);
   double lo = iLow(_Symbol, PERIOD_D1, 1);
   double cl = iClose(_Symbol, PERIOD_M1, 1);
   if(cl > hi) return BUY;
   if(cl < lo) return SELL;
   return NONE;
}

Signal DeltaSignal(Rule &r) {
   MqlTick ticks[];
   int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, TimeCurrent() - 60, TimeCurrent());
   long buy = 0, sell = 0;
   for(int i = 0; i < n; i++) {
      if((ticks[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++;
      else if((ticks[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sell++;
   }
   if(buy - sell > 300) return BUY;
   if(sell - buy > 300) return SELL;
   return NONE;
}

Signal VolumeSignal(Rule &r) {
   long vol[];
   ArraySetAsSeries(vol, true);
   CopyVolume(_Symbol, r.tf, 1, 12, vol);
   int maxIdx = ArrayMaximum(vol);
   int minIdx = ArrayMinimum(vol);
   if(vol[0] == vol[maxIdx]) return SELL;
   if(vol[0] == vol[minIdx]) return BUY;
   return NONE;
}

Signal AMASignal(Rule &r) {
   double ama1 = GetBufferValue(r.handle1, 0, 1);
   double ama2 = GetBufferValue(r.handle1, 0, 2);
   if(ama1 > ama2) return BUY;
   if(ama1 < ama2) return SELL;
   return NONE;
}

Signal Bar2Signal(Rule &r) {
   double h0 = iHigh(_Symbol, r.tf, 1);
   double l0 = iLow(_Symbol, r.tf, 1);
   double h1 = iHigh(_Symbol, r.tf, 2);
   double l1 = iLow(_Symbol, r.tf, 2);
   bool bullish = iClose(_Symbol, r.tf, 1) > iOpen(_Symbol, r.tf, 1);
   if(h0 < h1 && l0 > l1) return bullish ? BUY : SELL; // Inside Bar
   if(h0 > h1 && l0 < l1) return bullish ? SELL : BUY; // Outside Bar
   return NONE;
}

Signal RSSignal(Rule &r) {
   double r1 = GetBufferValue(r.handle1, 0, 1);
   double r2 = GetBufferValue(r.handle2, 0, 1);
   if(r1 > r2 + 5) return BUY;
   if(r1 < r2 - 5) return SELL;
   return NONE;
}

// ---------- AVALIAÇÃO E EXECUÇÃO ----------

Signal AvaliaTudo() {
   int buyVotos = 0, buyTotal = 0;
   int sellVotos = 0, sellTotal = 0;

   for(int i = 0; i < nRules; i++) {
      if(!rules[i].active) continue;

      Signal s = NONE;
      switch(rules[i].type) {
         case 1: s = CruzamentoMA(rules[i]); break;
         case 2: s = RSIThreshold(rules[i]); break;
         case 3: s = StochSignal(rules[i]); break;
         case 4: s = BBSignal(rules[i]); break;
         case 5: s = DailyBreakSignal(rules[i]); break;
         case 6: s = DeltaSignal(rules[i]); break;
         case 7: s = VolumeSignal(rules[i]); break;
         case 8: s = AMASignal(rules[i]); break;
         case 9: s = Bar2Signal(rules[i]); break;
         case 10: s = RSSignal(rules[i]); break;
         case 11: s = AISignal(rules[i]); break;
      }

      if(rules[i].intent == BUY || rules[i].intent == NONE) {
         buyTotal++;
         if(s == BUY) buyVotos++;
      }
      if(rules[i].intent == SELL || rules[i].intent == NONE) {
         sellTotal++;
         if(s == SELL) sellVotos++;
      }
   }

   if(buyTotal > 0 && buyVotos == buyTotal) return BUY;
   if(sellTotal > 0 && sellVotos == sellTotal) return SELL;
   return NONE;
}

double CalculaLote(double riscoPercent) {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (riscoPercent / 100.0);

   if(p_useMartingale) {
      HistorySelect(TimeCurrent() - 86400, TimeCurrent());
      int total = HistoryDealsTotal();
      for(int i = total - 1; i >= 0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) riskAmount *= 2.0;
            break;
         }
      }
   }

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   double pointsValue = (tickValue / (tickSize / _Point));
   double lot = riskAmount / (p_stopPoints * pointsValue);

   lot = MathFloor(lot / lotStep) * lotStep;
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return lot;
}

bool AguardaNoticias() {
   string path = "news_veto.txt";
   if(!FileIsExist(path)) return false;
   int h = FileOpen(path, FILE_READ | FILE_TXT);
   if(h == INVALID_HANDLE) return false;
   string content = FileReadString(h);
   FileClose(h);

   if(content == "1") return true;

   datetime eventTime = (datetime)StringToTime(content);
   if(eventTime > 0) {
      if(TimeCurrent() >= eventTime - 1200 && TimeCurrent() <= eventTime + 1200) return true;
   }

   return false;
}

void EnviaOrdem(Signal s, string reason) {
   if(PositionsTotal() >= p_maxTrades) return;
   if(AguardaNoticias()) return;

   datetime start = StringToTime(p_startTime);
   if(TimeCurrent() < start) return;

   double lot = CalculaLote(p_riskPercent);
   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = (s == BUY) ? price - p_stopPoints * _Point : price + p_stopPoints * _Point;
   double tp = (s == BUY) ? price + p_takePoints * _Point : price - p_takePoints * _Point;

   // Check margin
   double margin;
   if(!OrderCalcMargin((s == BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL), _Symbol, lot, price, margin)) return;
   if(margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE)) return;

   trade.SetExpertMagicNumber(EA_MAGIC);
   if(s == BUY) trade.Buy(lot, _Symbol, price, sl, tp, reason);
   else trade.Sell(lot, _Symbol, price, sl, tp, reason);
}

void GerenciaPosicoes() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(PositionSelectByTicket(PositionGetTicket(i))) {
         if(PositionGetInteger(POSITION_MAGIC) != EA_MAGIC) continue;

         double open = PositionGetDouble(POSITION_PRICE_OPEN);
         double curSL = PositionGetDouble(POSITION_SL);
         double price = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double diff = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? (price - open) : (open - price);

         // Break-even
         if(p_beStart > 0 && diff >= p_beStart * _Point) {
            double targetSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? (open + p_bePlus * _Point) : (open - p_bePlus * _Point);
            if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && curSL < targetSL) ||
               (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (curSL > targetSL || curSL == 0))) {
               trade.PositionModify(PositionGetTicket(i), targetSL, PositionGetDouble(POSITION_TP));
            }
         }

         // Trailing Stop
         if(p_trailingStart > 0 && diff >= p_trailingStart * _Point) {
            double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? (price - p_trailingStart * _Point) : (price + p_trailingStart * _Point);
            if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && newSL > curSL + p_trailingStep * _Point) ||
               (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (newSL < curSL - p_trailingStep * _Point || curSL == 0))) {
               trade.PositionModify(PositionGetTicket(i), newSL, PositionGetDouble(POSITION_TP));
            }
         }
      }
   }
}

// ---------- PERSISTÊNCIA E RELATÓRIOS ----------

void GravaLog(string texto) {
   int h = FileOpen("MT_LiveExecutor_Log.txt", FILE_READ | FILE_WRITE | FILE_TXT | FILE_COMMON);
   if(h != INVALID_HANDLE) {
      FileSeek(h, 0, SEEK_END);
      FileWriteString(h, TimeToString(TimeCurrent()) + ": " + texto + "\r\n");
      FileClose(h);
   }
   Print(texto);
}

void GravaCSV() {
   static datetime lastWrite = 0;
   if(TimeCurrent() - lastWrite < 5) return;
   lastWrite = TimeCurrent();

   int h = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV | FILE_ANSI);
   if(h != INVALID_HANDLE) {
      FileWrite(h, "Ticket", "Symbol", "Type", "Volume", "PriceOpen", "Time", "SL", "TP", "Profit", "Reason");
      for(int i = 0; i < PositionsTotal(); i++) {
         if(PositionSelectByTicket(PositionGetTicket(i))) {
            if(PositionGetInteger(POSITION_MAGIC) != EA_MAGIC) continue;
            FileWrite(h, PositionGetInteger(POSITION_TICKET),
                        PositionGetString(POSITION_SYMBOL),
                        PositionGetInteger(POSITION_TYPE),
                        PositionGetDouble(POSITION_VOLUME),
                        PositionGetDouble(POSITION_PRICE_OPEN),
                        TimeToString((datetime)PositionGetInteger(POSITION_TIME)),
                        PositionGetDouble(POSITION_SL),
                        PositionGetDouble(POSITION_TP),
                        PositionGetDouble(POSITION_PROFIT),
                        PositionGetString(POSITION_COMMENT));
         }
      }
      FileClose(h);
   }
}

void CalculaEstatisticas(double &winRate, double &profitFactor, double &dd) {
   HistorySelect(0, TimeCurrent());
   int total = HistoryDealsTotal();
   double profit = 0, loss = 0;
   int wins = 0, trades = 0;
   double maxEquity = 0, currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   for(int i = 0; i < total; i++) {
      ulong t = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC) {
         double p = HistoryDealGetDouble(t, DEAL_PROFIT);
         if(p != 0) {
            trades++;
            if(p > 0) { profit += p; wins++; }
            else loss -= p;
         }
      }
   }
   winRate = (trades > 0) ? (double)wins / trades * 100.0 : 0;
   profitFactor = (loss > 0) ? profit / loss : profit;
   dd = 0; // Simplified drawdown
}

void AIOptimizer() {
   double wr, pf, dd;
   CalculaEstatisticas(wr, pf, dd);
   if(wr < 40 && wr > 0) p_riskPercent *= 0.9;
   if(wr > 60 && pf > 1.5) p_riskPercent = MathMin(p_riskPercent * 1.1, 2.0);
}

// ---------- HANDLERS DE EVENTOS ----------

int OnInit() {
   EventSetTimer(1);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   EventKillTimer();
   ResetStrategy();
}

void OnTimer() {
   static datetime lastPromptCheck = 0;
   static datetime lastAIUpdate = 0;

   // Atualização dinâmica do prompt
   if(TimeCurrent() - lastPromptCheck >= 1) {
      lastPromptCheck = TimeCurrent();
      if(FileIsExist("prompt.txt")) {
         int h = FileOpen("prompt.txt", FILE_READ | FILE_TXT);
         if(h != INVALID_HANDLE) {
            string p = FileReadString(h);
            FileClose(h);
            static string lastPrompt = "";
            if(p != lastPrompt) {
               lastPrompt = p;
               InterpretaPrompt(p);
               GravaLog("Novo prompt carregado: " + p);
            }
         }
      }
   }

   // Otimizador por hora
   if(TimeCurrent() - lastAIUpdate >= 3600) {
      lastAIUpdate = TimeCurrent();
      AIOptimizer();
   }

   GravaCSV();
}

void OnTick() {
   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar != lastBarTime) {
      lastBarTime = currentBar;
      Signal s = AvaliaTudo();
      if(s != NONE) EnviaOrdem(s, "NLP Signal");
   }
   GerenciaPosicoes();
}
