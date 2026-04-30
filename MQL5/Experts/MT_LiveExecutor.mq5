//=========================  MT5-KNOWLEDGE-CORE  =========================
// MT-LiveExecutor - Agente de Execução Direta
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// --- Enums and Structs ---
enum Signal {BUY=1, SELL=-1, NONE=0};

struct Rule {
   bool     active;
   int      type;       // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: DailyBreak, 6: Delta, 7: Vol, 8: AMA, 9: Bar2, 10: RS, 11: AI
   int      tf;
   int      p1, p2, p3;
   double   d1, d2;
   string   s1;
   int      handle1, handle2;
   Signal   intent;     // Intent associated with the rule (BUY/SELL/NONE)
};

// --- Global Variables ---
#define EA_MAGIC 123456

Rule rules[20];
int nRules = 0;

ENUM_TIMEFRAMES p_frequency = PERIOD_M15; // Default from example
double p_riskPercent = 1.0;
int p_stopPoints = 0;
int p_takePoints = 0;
int p_maxTrades = 3;
int p_beStart = 0;
int p_bePlus = 0;
int p_trailingStart = 0;
int p_trailingStep = 10;
bool p_useMartingale = false;
string p_startTime = "00:00";
datetime p_lastUpdate = 0;

CTrade trade;
CPositionInfo m_position;

// --- Forward Declarations ---
void InterpretaPrompt(string prompt);
void ResetStrategy();
Signal AvaliaTudo();
Signal AvaliaRegra(Rule &r);
double CalculaLote(double risco);
void EnviaOrdem(Signal s, string reason);
void GerenciaPosicoes();
bool AguardaNoticias();
void GravaCSV();
void GravaLog(string texto);
void CalculaEstatisticas();
void AIOptimizer();
double GetBufferValue(int handle, int buffer, int shift);

// --- Helper Functions ---
double GetBufferValue(int handle, int buffer, int shift) {
   double val[1];
   if(CopyBuffer(handle, buffer, shift, 1, val) <= 0) return 0;
   return val[0];
}

void Stochastic(uint tf, int k, int d, int slowing, int buffer, int shift, double &kVal, double &dVal) {
   int h = iStochastic(NULL, (ENUM_TIMEFRAMES)tf, k, d, slowing, MODE_SMA, STO_LOWHIGH);
   kVal = GetBufferValue(h, 0, shift);
   dVal = GetBufferValue(h, 1, shift);
   IndicatorRelease(h);
}

// --- Indicator Signal Functions ---
Signal CruzamentoMA(int handle1, int handle2, int shift=1) {
   if(handle2 == INVALID_HANDLE || handle2 == 0) {
      double ma = GetBufferValue(handle1, 0, shift);
      double close = iClose(NULL, p_frequency, shift);
      double ma_p = GetBufferValue(handle1, 0, shift+1);
      double close_p = iClose(NULL, p_frequency, shift+1);
      if(close_p < ma_p && close > ma) return BUY;
      if(close_p > ma_p && close < ma) return SELL;
   } else {
      double f = GetBufferValue(handle1, 0, shift);
      double s = GetBufferValue(handle2, 0, shift);
      double fp = GetBufferValue(handle1, 0, shift+1);
      double sp = GetBufferValue(handle2, 0, shift+1);
      if(fp < sp && f > s) return BUY;
      if(fp > sp && f < s) return SELL;
   }
   return NONE;
}

Signal RSIThreshold(int handle, double threshold, Signal intent, int shift=1) {
   double v = GetBufferValue(handle, 0, shift);
   double vp = GetBufferValue(handle, 0, shift+1);
   if(intent == BUY && vp < threshold && v > threshold) return BUY;
   if(intent == SELL && vp > threshold && v < threshold) return SELL;
   return NONE;
}

Signal StochCross(int handle, int shift=1) {
   double k1 = GetBufferValue(handle, 0, shift);
   double d1 = GetBufferValue(handle, 1, shift);
   double k2 = GetBufferValue(handle, 0, shift+1);
   double d2 = GetBufferValue(handle, 1, shift+1);
   if(k2 < d2 && k1 > d1) return BUY;
   if(k2 > d2 && k1 < d1) return SELL;
   return NONE;
}

Signal BBounce(int handle, int shift=0) {
   double upper = GetBufferValue(handle, 1, shift);
   double lower = GetBufferValue(handle, 2, shift);
   double close = iClose(NULL, p_frequency, shift);
   if(close < lower) return BUY;
   if(close > upper) return SELL;
   return NONE;
}

Signal DailyBreak(int shift=0) {
   double hi = iHigh(NULL, PERIOD_D1, 1);
   double lo = iLow(NULL, PERIOD_D1, 1);
   double close = iClose(NULL, PERIOD_M1, shift);
   if(close > hi) return BUY;
   if(close < lo) return SELL;
   return NONE;
}

Signal DeltaAggression(int seconds=60, int deltaTrigger=300) {
   MqlTick arr[];
   int n = CopyTicksRange(_Symbol, arr, COPY_TICKS_TRADE, TimeCurrent()-seconds, TimeCurrent());
   long buy = 0, sell = 0;
   for(int i=0; i<n; i++) if(arr[i].flags & TICK_FLAG_BUY) buy++; else if(arr[i].flags & TICK_FLAG_SELL) sell++;
   long delta = buy - sell;
   if(delta > deltaTrigger) return BUY;
   if(delta < -deltaTrigger) return SELL;
   return NONE;
}

Signal VolumeCycle(int len=12, int shift=0) {
   double vol[]; ArraySetAsSeries(vol, true);
   CopyVolume(_Symbol, p_frequency, shift, len, vol);
   int highIdx = ArrayMaximum(vol);
   int lowIdx = ArrayMinimum(vol);
   if(highIdx == 0) return SELL;
   if(lowIdx == 0) return BUY;
   return NONE;
}

Signal AMA(int handle, int shift=0) {
   double ama = GetBufferValue(handle, 0, shift);
   double p = GetBufferValue(handle, 0, shift+1);
   if(p < ama) return BUY;
   if(p > ama) return SELL;
   return NONE;
}

Signal Bar2Pattern(int shift=0) {
   double h0 = iHigh(NULL, p_frequency, shift);
   double l0 = iLow(NULL, p_frequency, shift);
   double h1 = iHigh(NULL, p_frequency, shift+1);
   double l1 = iLow(NULL, p_frequency, shift+1);
   bool bullish = iClose(NULL, p_frequency, shift) > iOpen(NULL, p_frequency, shift);
   if(h0 < h1 && l0 > l1) return bullish ? BUY : SELL;
   if(h0 > h1 && l0 < l1) return bullish ? SELL : BUY;
   return NONE;
}

Signal RSRelative(int h1, int h2) {
   double r1 = GetBufferValue(h1, 0, 0);
   double r2 = GetBufferValue(h2, 0, 0);
   if(r1 > r2 + 5) return BUY;
   if(r1 < r2 - 5) return SELL;
   return NONE;
}

Signal AISignal(int atrHandle) {
   double atr = GetBufferValue(atrHandle, 0, 1);
   double body = MathAbs(iClose(NULL, p_frequency, 1) - iOpen(NULL, p_frequency, 1));
   bool bullish = iClose(NULL, p_frequency, 1) > iOpen(NULL, p_frequency, 1);
   if(body > 1.5 * atr) return bullish ? BUY : SELL;
   return NONE;
}

// --- NLP Parsing Helpers ---
double ExtraiNumero(string txt, int &endPos) {
   string res = "";
   int start = -1;
   for(int i=endPos; i<StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.' || c == ',') {
         if(start == -1) start = i;
         if(c == ',') res += "."; else res += StringSubstr(txt, i, 1);
      } else if(start != -1) {
         endPos = i;
         break;
      }
   }
   if(start == -1) return 0;
   return StringToDouble(res);
}

double ExtraiValorApos(string txt, string keyword) {
   int pos = StringFind(txt, keyword);
   if(pos < 0) return 0;
   int end = pos + StringLen(keyword);
   return ExtraiNumero(txt, end);
}

int PeriodoTexto(string nome) {
   nome = StringFormat(" %s ", nome);
   StringToLower(nome);
   if(StringFind(nome, " m1 ") >= 0) return PERIOD_M1;
   if(StringFind(nome, " m5 ") >= 0) return PERIOD_M5;
   if(StringFind(nome, " m15 ") >= 0 || StringFind(nome, " 15 minutos ") >= 0 || StringFind(nome, " 15 min ") >= 0) return PERIOD_M15;
   if(StringFind(nome, " m30 ") >= 0 || StringFind(nome, " 30 minutos ") >= 0 || StringFind(nome, " 30 min ") >= 0) return PERIOD_M30;
   if(StringFind(nome, " h1 ") >= 0) return PERIOD_H1;
   if(StringFind(nome, " h4 ") >= 0) return PERIOD_H4;
   if(StringFind(nome, " d1 ") >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

string ExtractTime(string txt) {
   int pos = StringFind(txt, "depois das ");
   if(pos < 0) return "00:00";
   int end = pos + 11;
   string timeStr = "";
   for(int i=end; i<StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == ':' || c == 'h') {
         if(c == 'h') timeStr += ":00"; else timeStr += StringSubstr(txt, i, 1);
      } else break;
   }
   if(StringLen(timeStr) == 2) timeStr += ":00";
   return timeStr;
}

void ResetStrategy() {
   for(int i=0; i<nRules; i++) {
      if(rules[i].handle1 != INVALID_HANDLE && rules[i].handle1 != 0) IndicatorRelease(rules[i].handle1);
      if(rules[i].handle2 != INVALID_HANDLE && rules[i].handle2 != 0) IndicatorRelease(rules[i].handle2);
   }
   ZeroMemory(rules);
   nRules = 0;
   p_frequency = PERIOD_M15;
   p_riskPercent = 1.0;
   p_stopPoints = 0;
   p_takePoints = 0;
   p_maxTrades = 3;
   p_beStart = 0;
   p_bePlus = 0;
   p_trailingStart = 0;
   p_startTime = "00:00";
}

// --- Main NLP Parser ---
void InterpretaPrompt(string prompt) {
   ResetStrategy();
   string fullPrompt = prompt;
   StringToLower(fullPrompt);

   p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(fullPrompt);
   p_riskPercent = ExtraiValorApos(fullPrompt, "risco de ");
   if(p_riskPercent == 0) p_riskPercent = 1.0;

   p_stopPoints = (int)ExtraiValorApos(fullPrompt, "stop de ");
   p_takePoints = (int)ExtraiValorApos(fullPrompt, "take de ");
   p_maxTrades = (int)ExtraiValorApos(fullPrompt, "máximo ");
   if(p_maxTrades == 0) p_maxTrades = 3;

   p_beStart = (int)ExtraiValorApos(fullPrompt, "atingir +");
   p_bePlus = (int)ExtraiValorApos(fullPrompt, "entrada +");
   p_trailingStart = (int)ExtraiValorApos(fullPrompt, "trailing stop de ");
   p_useMartingale = (StringFind(fullPrompt, "martingale") >= 0);
   p_startTime = ExtractTime(fullPrompt);

   string segments[];
   string sep = fullPrompt;
   StringReplace(sep, " e ", "|");
   StringReplace(sep, ".", "|");
   StringReplace(sep, ",", "|");
   ushort u_sep = StringGetCharacter("|", 0);
   int nSeg = StringSplit(sep, u_sep, segments);

   Signal currentIntent = NONE;
   int lastMA_p1 = 20;

   for(int i=0; i<nSeg && nRules < 20; i++) {
      string s = segments[i];
      if(StringFind(s, "compra") >= 0) currentIntent = BUY;
      if(StringFind(s, "vende") >= 0) currentIntent = SELL;

      // MA Rule
      if(StringFind(s, " ma ") >= 0 || StringFind(s, " ma/") >= 0 || StringFind(s, "média") >= 0) {
         int pos = 0;
         int p1 = (int)ExtraiNumero(s, pos);
         int p2 = (int)ExtraiNumero(s, pos);
         if(p1 == 0) p1 = lastMA_p1; else lastMA_p1 = p1;

         rules[nRules].active = true;
         rules[nRules].type = 1;
         rules[nRules].intent = currentIntent;
         rules[nRules].handle1 = iMA(_Symbol, p_frequency, p1, 0, MODE_EMA, PRICE_CLOSE);
         if(p2 > 0) rules[nRules].handle2 = iMA(_Symbol, p_frequency, p2, 0, MODE_EMA, PRICE_CLOSE);
         nRules++;
      }
      // RSI Rule
      else if(StringFind(s, "rsi") >= 0) {
         int pos = 0;
         int p = (int)ExtraiNumero(s, pos);
         double threshold = ExtraiNumero(s, pos);
         if(p >= 40) { threshold = p; p = 14; }
         if(p == 0) p = 14;
         if(threshold == 0) threshold = (currentIntent == BUY) ? 55 : 45;

         rules[nRules].active = true;
         rules[nRules].type = 2;
         rules[nRules].intent = currentIntent;
         rules[nRules].d1 = threshold;
         rules[nRules].handle1 = iRSI(_Symbol, p_frequency, p, PRICE_CLOSE);
         nRules++;
      }
      // Stoch Rule
      else if(StringFind(s, "estocástico") >= 0 || StringFind(s, "stoch") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = 3;
         rules[nRules].intent = currentIntent;
         rules[nRules].handle1 = iStochastic(_Symbol, p_frequency, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
         nRules++;
      }
      // BB Rule
      else if(StringFind(s, "bollinger") >= 0 || StringFind(s, " bbands ") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = 4;
         rules[nRules].intent = currentIntent;
         rules[nRules].handle1 = iBands(_Symbol, p_frequency, 20, 0, 2.0, PRICE_CLOSE);
         nRules++;
      }
      // Daily Break
      else if(StringFind(s, "rompimento diário") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = 5;
         rules[nRules].intent = currentIntent;
         nRules++;
      }
      // Volume
      else if(StringFind(s, "volume") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = 7;
         rules[nRules].intent = currentIntent;
         nRules++;
      }
      // AMA
      else if(StringFind(s, "ama") >= 0 || StringFind(s, "adaptativa") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = 8;
         rules[nRules].intent = currentIntent;
         rules[nRules].handle1 = iAMA(_Symbol, p_frequency, 10, 2, 30, PRICE_CLOSE);
         nRules++;
      }
      // Bar2
      else if(StringFind(s, "padrão barras") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = 9;
         rules[nRules].intent = currentIntent;
         nRules++;
      }
      // AI Signal
      else if(StringFind(s, "previsão") >= 0 || StringFind(s, " ai ") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = 11;
         rules[nRules].intent = currentIntent;
         rules[nRules].handle1 = iATR(_Symbol, p_frequency, 14);
         nRules++;
      }
   }
   GravaLog("Estratégia atualizada: " + fullPrompt);
}

// --- Logic Evaluation ---
Signal AvaliaRegra(Rule &r) {
   switch(r.type) {
      case 1: return CruzamentoMA(r.handle1, r.handle2);
      case 2: return RSIThreshold(r.handle1, r.d1, r.intent);
      case 3: return StochCross(r.handle1);
      case 4: return BBounce(r.handle1);
      case 5: return DailyBreak();
      case 7: return VolumeCycle();
      case 8: return AMA(r.handle1);
      case 9: return Bar2Pattern();
      case 11: return AISignal(r.handle1);
   }
   return NONE;
}

Signal AvaliaTudo() {
   int buyVotes = 0, sellVotes = 0;
   int buyRules = 0, sellRules = 0;

   for(int i=0; i<nRules; i++) {
      Signal s = AvaliaRegra(rules[i]);
      if(rules[i].intent == BUY) {
         buyRules++;
         if(s == BUY) buyVotes++;
      } else if(rules[i].intent == SELL) {
         sellRules++;
         if(s == SELL) sellVotes++;
      } else { // Neutral filter
         if(s == BUY) buyVotes++; else if(s == SELL) sellVotes++;
         buyRules++; sellRules++;
      }
   }

   if(buyRules > 0 && buyVotes == buyRules) return BUY;
   if(sellRules > 0 && sellVotes == sellRules) return SELL;
   return NONE;
}

// --- Order Execution ---
double CalculaLote(double riscoPercent) {
   double capital = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = capital * riscoPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   int stopPoints = (p_stopPoints > 0) ? p_stopPoints : 300;

   double lot = riskAmount / (stopPoints * (tickValue / (tickSize / _Point)));

   if(p_useMartingale) {
      HistorySelect(0, TimeCurrent());
      for(int i=HistoryDealsTotal()-1; i>=0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC &&
            HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol &&
            HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT) {
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) lot *= 2.0;
            break;
         }
      }
   }

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / stepLot) * stepLot;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   return lot;
}

void EnviaOrdem(Signal s, string reason) {
   if(s == NONE) return;
   if(AguardaNoticias()) return;

   int total = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
      if(m_position.SelectByIndex(i) && m_position.Magic() == EA_MAGIC) total++;
   if(total >= p_maxTrades) return;

   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0, tp = 0;

   if(s == BUY) {
      if(p_stopPoints > 0) sl = price - p_stopPoints * _Point;
      if(p_takePoints > 0) tp = price + p_takePoints * _Point;
   } else {
      if(p_stopPoints > 0) sl = price + p_stopPoints * _Point;
      if(p_takePoints > 0) tp = price - p_takePoints * _Point;
   }

   double lot = CalculaLote(p_riskPercent);

   double margin;
   if(!OrderCalcMargin((s == BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL), _Symbol, lot, price, margin)) {
      GravaLog("Erro ao calcular margem.");
      return;
   }
   if(margin > AccountInfoDouble(ACCOUNT_FREEMARGIN)) {
      GravaLog("Margem insuficiente.");
      return;
   }

   trade.SetExpertMagicNumber(EA_MAGIC);
   bool res = false;
   if(s == BUY) res = trade.Buy(lot, _Symbol, price, sl, tp, reason);
   else res = trade.Sell(lot, _Symbol, price, sl, tp, reason);

   if(res) {
      GravaLog(StringFormat("Ordem enviada: %s, Lote: %.2f, Motivo: %s", (s == BUY ? "BUY" : "SELL"), lot, reason));
      SendNotification("MT-LiveExecutor: Ordem executada - " + reason);
   } else {
      GravaLog(StringFormat("Erro ao enviar ordem: %d", trade.ResultRetcode()));
   }
}

// --- Position Management ---
void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(m_position.SelectByIndex(i) && m_position.Magic() == EA_MAGIC) {
         double price = m_position.PriceCurrent();
         double open = m_position.PriceOpen();
         double sl = m_position.StopLoss();
         double tp = m_position.TakeProfit();

         // Break-even
         if(p_beStart > 0 && sl != (open + p_bePlus * _Point)) {
            if(m_position.PositionType() == POSITION_TYPE_BUY && price >= open + p_beStart * _Point)
               trade.PositionModify(m_position.Ticket(), open + p_bePlus * _Point, tp);
            else if(m_position.PositionType() == POSITION_TYPE_SELL && price <= open - p_beStart * _Point)
               trade.PositionModify(m_position.Ticket(), open - p_bePlus * _Point, tp);
         }

         // Trailing Stop
         if(p_trailingStart > 0) {
            if(m_position.PositionType() == POSITION_TYPE_BUY && price >= open + p_trailingStart * _Point) {
               double newSL = price - p_trailingStart * _Point;
               if(newSL > sl + p_trailingStep * _Point) trade.PositionModify(m_position.Ticket(), newSL, tp);
            } else if(m_position.PositionType() == POSITION_TYPE_SELL && price <= open - p_trailingStart * _Point) {
               double newSL = price + p_trailingStart * _Point;
               if(newSL < sl - p_trailingStep * _Point || sl == 0) trade.PositionModify(m_position.Ticket(), newSL, tp);
            }
         }
      }
   }
}

// --- News Veto ---
bool AguardaNoticias() {
   int h = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE) return false;
   string content = FileReadString(h);
   FileClose(h);

   if(content == "1") return true;

   datetime newsTime = StringToTime(content);
   if(newsTime > 0) {
      if(TimeCurrent() >= newsTime - 1200 && TimeCurrent() <= newsTime + 1200) return true;
   }
   return false;
}

// --- Persistence and Reporting ---
void GravaCSV() {
   int h = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV | FILE_ANSI);
   if(h == INVALID_HANDLE) return;
   FileWrite(h, "Ticket", "Symbol", "Type", "Volume", "PriceOpen", "Time", "SL", "TP", "Profit", "Reason");
   for(int i=0; i<PositionsTotal(); i++) {
      if(m_position.SelectByIndex(i) && m_position.Magic() == EA_MAGIC) {
         FileWrite(h, m_position.Ticket(), m_position.Symbol(), m_position.PositionType(), m_position.Volume(),
                   m_position.PriceOpen(), m_position.Time(), m_position.StopLoss(), m_position.TakeProfit(),
                   m_position.Profit(), m_position.Comment());
      }
   }
   FileClose(h);
}

void GravaLog(string texto) {
   int h = FileOpen("MT_LiveExecutor_Log.txt", FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h != INVALID_HANDLE) {
      FileSeek(h, 0, SEEK_END);
      FileWriteString(h, TimeToString(TimeCurrent()) + ": " + texto + "\r\n");
      FileClose(h);
   }
   Print(texto);
}

void CalculaEstatisticas() {
   HistorySelect(0, TimeCurrent());
   int total = HistoryDealsTotal();
   int wins = 0, losses = 0;
   double profit = 0, loss = 0;

   for(int i=0; i<total; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC && HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT) {
         double pr = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         if(pr > 0) { wins++; profit += pr; }
         else { losses++; loss += MathAbs(pr); }
      }
   }

   double winRate = (wins + losses > 0) ? (double)wins / (wins + losses) * 100 : 0;
   double pf = (loss > 0) ? profit / loss : profit;
   GravaLog(StringFormat("Estatísticas: WinRate: %.2f%%, ProfitFactor: %.2f", winRate, pf));
}

void AIOptimizer() {
   HistorySelect(TimeCurrent() - 86400 * 7, TimeCurrent());
   int total = HistoryDealsTotal();
   int wins = 0, count = 0;
   for(int i=total-1; i>=0 && count < 10; i--) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC && HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT) {
         if(HistoryDealGetDouble(ticket, DEAL_PROFIT) > 0) wins++;
         count++;
      }
   }
   if(count >= 5 && (double)wins/count < 0.4) {
      p_riskPercent *= 0.5;
      GravaLog("AI Optimizer: Risco reduzido devido à baixa performance.");
   }
}

// --- Lifecycle Handlers ---
int OnInit() {
   EventSetTimer(1);
   trade.SetExpertMagicNumber(EA_MAGIC);

   // Initial load
   int h = FileOpen("prompt.txt", FILE_READ | FILE_TXT | FILE_ANSI);
   if(h != INVALID_HANDLE) {
      string p = FileReadString(h);
      FileClose(h);
      InterpretaPrompt(p);
      p_lastUpdate = (datetime)FileGetInteger("prompt.txt", FILE_MODIFY_DATE);
   }

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   EventKillTimer();
   ResetStrategy();
}

void OnTick() {
   // Check start time
   if(TimeToString(TimeCurrent(), TIME_MINUTES) < p_startTime) return;

   // Only execute on new bar of p_frequency
   static datetime lastBar = 0;
   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar == lastBar) {
      GerenciaPosicoes();
      GravaCSV();
      return;
   }
   lastBar = currentBar;

   Signal s = AvaliaTudo();
   if(s != NONE) EnviaOrdem(s, "Estratégia NLP");

   GerenciaPosicoes();
   GravaCSV();
}

void OnTimer() {
   // Real-time prompt update
   datetime modDate = (datetime)FileGetInteger("prompt.txt", FILE_MODIFY_DATE);
   if(modDate > p_lastUpdate) {
      int h = FileOpen("prompt.txt", FILE_READ | FILE_TXT | FILE_ANSI);
      if(h != INVALID_HANDLE) {
         string p = FileReadString(h);
         FileClose(h);
         InterpretaPrompt(p);
         p_lastUpdate = modDate;
      }
   }

   // Hourly optimization and statistics
   static datetime lastHourly = 0;
   if(TimeCurrent() - lastHourly >= 3600) {
      AIOptimizer();
      CalculaEstatisticas();
      lastHourly = TimeCurrent();
   }
}
