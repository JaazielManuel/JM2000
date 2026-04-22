//=========================  MT5-KNOWLEDGE-CORE  =========================
// MT_LiveExecutor - Sistema de Execução de Estratégias via Prompt NLP
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// --- Constantes e Enums ---
enum Signal {BUY=1, SELL=-1, NONE=0};
#define EA_MAGIC 123456

// --- Structs ---
struct Rule {
   bool     active;
   int      type;       // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: DailyBreak, 6: Delta, 7: Vol, 8: AMA, 9: Bar2, 10: RS, 11: AI
   int      tf;
   int      p1, p2, p3;
   double   d1, d2;
   string   s1;
   int      handle1, handle2;
   Signal   intent;     // BUY, SELL ou NONE (filtro)
};

// --- Variáveis Globais de Estratégia ---
Rule     p_rules[30];
int      p_nRules = 0;
double   p_riskPercent = 1.0;
int      p_stopPoints = 300;
int      p_takePoints = 500;
int      p_maxTrades = 3;
int      p_beStart = 0;
int      p_bePlus = 0;
int      p_trailingStart = 0;
int      p_trailingStep = 10;
string   p_startTime = "00:00";
bool     p_useMartingale = false;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
datetime p_lastBarTime = 0;

// --- Instâncias de Classes ---
CTrade         trade;
CPositionInfo  posInfo;
CSymbolInfo    symInfo;
CAccountInfo   accInfo;

// --- utilitários ---

double ExtraiNumero(string text, int startPos=0, int &endPos) {
   string res = "";
   bool foundDigit = false;
   endPos = startPos;
   for(int i=startPos; i<StringLen(text); i++) {
      ushort c = StringGetCharacter(text, i);
      if((c >= '0' && c <= '9') || c == '.') {
         res += ShortToString(c);
         foundDigit = true;
         endPos = i + 1;
      } else if(foundDigit) break;
      else endPos = i + 1;
   }
   return StringToDouble(res);
}

double ExtraiNumero(string text, int startPos=0) {
   int dummy;
   return ExtraiNumero(text, startPos, dummy);
}

double ExtraiValorApos(string text, string keyword) {
   int pos = StringFind(text, keyword);
   if(pos < 0) return 0;
   return ExtraiNumero(text, pos + StringLen(keyword));
}

int PeriodoTexto(string nome) {
   nome = StringSubstr(nome, 0, 10);
   StringToLower(nome);
   if(StringFind(nome, "15 min") >= 0 || StringFind(nome, "m15") >= 0) return PERIOD_M15;
   if(StringFind(nome, "5 min") >= 0 || StringFind(nome, "m5") >= 0)  return PERIOD_M5;
   if(StringFind(nome, "1 min") >= 0 || StringFind(nome, "m1") >= 0)  return PERIOD_M1;
   if(StringFind(nome, "1 hora") >= 0 || StringFind(nome, "h1") >= 0) return PERIOD_H1;
   if(StringFind(nome, "diário") >= 0 || StringFind(nome, "d1") >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

string ExtractTime(string text) {
   string t = text;
   StringReplace(t, "h", ":00");
   // Simplificação para extração de HH:MM
   int pos = StringFind(t, ":");
   if(pos > 0) {
      string hh = StringSubstr(t, pos-2, 2);
      string mm = StringSubstr(t, pos+1, 2);
      return hh + ":" + mm;
   }
   return "00:00";
}

double GetBufferValue(int handle, int buffer, int shift) {
   double val[1];
   if(CopyBuffer(handle, buffer, shift, 1, val) > 0) return val[0];
   return 0;
}

// --- Funções de Sinais de Indicadores ---

Signal CruzamentoMA(Rule &r, int shift=1) {
   if(r.handle2 == INVALID_HANDLE || r.handle2 == 0) {
      // Preço vs MA
      double ma1 = GetBufferValue(r.handle1, 0, shift);
      double ma0 = GetBufferValue(r.handle1, 0, shift+1);
      double p1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
      double p0 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift+1);
      if(p0 < ma0 && p1 > ma1) return BUY;
      if(p0 > ma0 && p1 < ma1) return SELL;
   } else {
      // MA vs MA
      double f1 = GetBufferValue(r.handle1, 0, shift);
      double f0 = GetBufferValue(r.handle1, 0, shift+1);
      double s1 = GetBufferValue(r.handle2, 0, shift);
      double s0 = GetBufferValue(r.handle2, 0, shift+1);
      if(f0 < s0 && f1 > s1) return BUY;
      if(f0 > s0 && f1 < s1) return SELL;
   }
   return NONE;
}

Signal RSIThreshold(Rule &r, int shift=1) {
   double v = GetBufferValue(r.handle1, 0, shift);
   if(r.intent == BUY && v > r.d1) return BUY;
   if(r.intent == SELL && v < r.d2) return SELL;
   // Caso neutro (filtro)
   if(r.intent == NONE) {
      if(v > r.d1) return SELL; // Sobrecomprado
      if(v < r.d2) return BUY;  // Sobrevendido
   }
   return NONE;
}

Signal StochCross(Rule &r, int shift=1) {
   double k1 = GetBufferValue(r.handle1, 0, shift);
   double d1 = GetBufferValue(r.handle1, 1, shift);
   double k2 = GetBufferValue(r.handle1, 0, shift+1);
   double d2 = GetBufferValue(r.handle1, 1, shift+1);
   if(k2 < d2 && k1 > d1) return BUY;
   if(k2 > d2 && k1 < d1) return SELL;
   return NONE;
}

Signal BBounce(Rule &r, int shift=1) {
   double mid = GetBufferValue(r.handle1, 0, shift);
   double upper = GetBufferValue(r.handle1, 1, shift);
   double lower = GetBufferValue(r.handle1, 2, shift);
   double close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
   if(close < lower) return BUY;
   if(close > upper) return SELL;
   return NONE;
}

Signal DailyBreak(Rule &r, int shift=1) {
   double hi = iHigh(_Symbol, PERIOD_D1, 1);
   double lo = iLow(_Symbol, PERIOD_D1, 1);
   double close = iClose(_Symbol, PERIOD_M1, shift);
   if(close > hi) return BUY;
   if(close < lo) return SELL;
   return NONE;
}

Signal DeltaAggression(Rule &r, int shift=0) {
   MqlTick arr[];
   int n = CopyTicksRange(_Symbol, arr, COPY_TICKS_TRADE, TimeCurrent()-60, TimeCurrent());
   long buy=0, sell=0;
   for(int i=0; i<n; i++) if((arr[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++; else sell++;
   long delta = buy - sell;
   if(delta > r.p1) return BUY;
   if(delta < -r.p1) return SELL;
   return NONE;
}

Signal VolumeCycle(Rule &r, int shift=1) {
   long vol[]; ArraySetAsSeries(vol, true);
   CopyVolume(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift, r.p1, vol);
   int maxIdx = ArrayMaximum(vol);
   int minIdx = ArrayMinimum(vol);
   if(maxIdx == 0) return SELL;
   if(minIdx == 0) return BUY;
   return NONE;
}

Signal AMASignal(Rule &r, int shift=1) {
   double ama1 = GetBufferValue(r.handle1, 0, shift);
   double ama2 = GetBufferValue(r.handle1, 0, shift+1);
   if(ama1 > ama2) return BUY;
   if(ama1 < ama2) return SELL;
   return NONE;
}

Signal Bar2Pattern(Rule &r, int shift=1) {
   double h0 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
   double l0 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
   double h1 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift+1);
   double l1 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift+1);
   double c0 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
   double o0 = iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
   if(h0 < h1 && l0 > l1) return (c0 > o0) ? BUY : SELL;
   if(h0 > h1 && l0 < l1) return (c0 > o0) ? SELL : BUY;
   return NONE;
}

Signal RSRelative(Rule &r, int shift=1) {
   double r1 = GetBufferValue(r.handle1, 0, shift);
   double r2 = GetBufferValue(r.handle2, 0, shift);
   if(r1 > r2 + 5) return BUY;
   if(r1 < r2 - 5) return SELL;
   return NONE;
}

Signal AISignal(Rule &r, int shift=1) {
   double atr[1];
   int h_atr = iATR(_Symbol, (ENUM_TIMEFRAMES)r.tf, 14);
   CopyBuffer(h_atr, 0, shift, 1, atr);
   IndicatorRelease(h_atr);
   double body = MathAbs(iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift) - iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift));
   if(body > atr[0] * 1.5) return (iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift)) ? BUY : SELL;
   return NONE;
}

// --- NLP e Parsing ---

void ResetStrategy() {
   for(int i=0; i<p_nRules; i++) {
      if(p_rules[i].handle1 != INVALID_HANDLE && p_rules[i].handle1 != 0) IndicatorRelease(p_rules[i].handle1);
      if(p_rules[i].handle2 != INVALID_HANDLE && p_rules[i].handle2 != 0) IndicatorRelease(p_rules[i].handle2);
   }
   ZeroMemory(p_rules);
   p_nRules = 0;
   p_riskPercent = 1.0;
   p_stopPoints = 300;
   p_takePoints = 500;
   p_maxTrades = 3;
   p_beStart = 0; p_bePlus = 0;
   p_trailingStart = 0;
   p_startTime = "00:00";
   p_useMartingale = false;
   p_frequency = PERIOD_M15;
}

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   string work = prompt;
   StringToLower(work);

   // Parâmetros Globais
   if(StringFind(work, "risco de") >= 0) p_riskPercent = ExtraiValorApos(work, "risco de");
   if(StringFind(work, "stop de") >= 0) p_stopPoints = (int)ExtraiValorApos(work, "stop de");
   if(StringFind(work, "take de") >= 0) p_takePoints = (int)ExtraiValorApos(work, "take de");
   if(StringFind(work, "máximo") >= 0 && StringFind(work, "trades") >= 0) p_maxTrades = (int)ExtraiValorApos(work, "máximo");
   if(StringFind(work, "depois das") >= 0) p_startTime = ExtractTime(work);
   if(StringFind(work, "martingale") >= 0) p_useMartingale = true;
   if(StringFind(work, "move stop para entrada") >= 0) {
      p_beStart = (int)ExtraiValorApos(work, "atingir");
      p_bePlus = (int)ExtraiValorApos(work, "entrada");
   }
   p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(work);

   // Divisão por Regras
   string segments[];
   string sep = "|";
   StringReplace(work, " e ", sep);
   StringReplace(work, ".", sep);
   StringReplace(work, ",", sep);
   ushort u_sep = StringGetCharacter(sep, 0);
   int nSeg = StringSplit(work, u_sep, segments);

   Signal currentIntent = NONE;

   for(int i=0; i<nSeg; i++) {
      string s = segments[i];
      if(StringFind(s, "compra") >= 0) currentIntent = BUY;
      else if(StringFind(s, "vende") >= 0) currentIntent = SELL;

      // MA
      if(StringFind(s, "média") >= 0 || StringFind(s, " ma ") >= 0) {
         p_rules[p_nRules].active = true;
         p_rules[p_nRules].type = 1;
         p_rules[p_nRules].tf = PeriodoTexto(s);
         p_rules[p_nRules].intent = currentIntent;
         int p1 = (int)ExtraiNumero(s);
         if(p1 == 0) p1 = 20;
         p_rules[p_nRules].p1 = p1;
         p_rules[p_nRules].handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)p_rules[p_nRules].tf, p1, 0, MODE_SMA, PRICE_CLOSE);
         // Check for second MA
         int pos2 = StringFind(s, "/");
         if(pos2 > 0) {
            int p2 = (int)ExtraiNumero(s, pos2+1);
            p_rules[p_nRules].p2 = p2;
            p_rules[p_nRules].handle2 = iMA(_Symbol, (ENUM_TIMEFRAMES)p_rules[p_nRules].tf, p2, 0, MODE_SMA, PRICE_CLOSE);
         }
         p_nRules++;
      }
      // RSI
      int rsiPos = StringFind(s, "rsi");
      if(rsiPos >= 0) {
         p_rules[p_nRules].active = true;
         p_rules[p_nRules].type = 2;
         p_rules[p_nRules].tf = PeriodoTexto(s);
         p_rules[p_nRules].intent = currentIntent;
         int endP;
         int per = (int)ExtraiNumero(s, rsiPos + 3, endP);
         if(per == 0) per = 14;
         p_rules[p_nRules].p1 = per;

         double val1 = ExtraiNumero(s, endP, endP);
         if(val1 > 0) {
            if(currentIntent == BUY) p_rules[p_nRules].d1 = val1;
            else if(currentIntent == SELL) p_rules[p_nRules].d2 = val1;
            else { p_rules[p_nRules].d1 = val1; p_rules[p_nRules].d2 = 30; }
         } else {
            p_rules[p_nRules].d1 = 70; p_rules[p_nRules].d2 = 30;
         }

         p_rules[p_nRules].handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)p_rules[p_nRules].tf, per, PRICE_CLOSE);
         p_nRules++;
      }
      // Outros indicadores seguem lógica similar...
      if(p_nRules >= 30) break;
   }
}

// --- Execução e Gestão ---

double CalculaLote(double riscoPercent) {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (riscoPercent / 100.0);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(p_stopPoints <= 0 || tickValue <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double lot = riskAmount / (p_stopPoints * (tickValue / (tickSize / _Point)));

   if(p_useMartingale) {
      HistorySelect(0, TimeCurrent());
      for(int i=HistoryDealsTotal()-1; i>=0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC && HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol) {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            if(profit < 0) lot *= 2.0;
            break;
         }
      }
   }
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / step) * step;

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   // Margem Check
   double margin;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lot, SymbolInfoDouble(_Symbol, SYMBOL_ASK), margin)) return 0;
   if(margin > AccountInfoDouble(ACCOUNT_FREEMARGIN)) return 0;

   return lot;
}

Signal AvaliaTudo() {
   int buyLeg = 0, buyRules = 0;
   int sellLeg = 0, sellRules = 0;

   for(int i=0; i<p_nRules; i++) {
      Signal s = NONE;
      switch(p_rules[i].type) {
         case 1: s = CruzamentoMA(p_rules[i]); break;
         case 2: s = RSIThreshold(p_rules[i]); break;
         case 3: s = StochCross(p_rules[i]); break;
         case 4: s = BBounce(p_rules[i]); break;
         case 5: s = DailyBreak(p_rules[i]); break;
         case 7: s = VolumeCycle(p_rules[i]); break;
         case 8: s = AMASignal(p_rules[i]); break;
         case 9: s = Bar2Pattern(p_rules[i]); break;
         case 11: s = AISignal(p_rules[i]); break;
      }

      if(p_rules[i].intent == BUY || p_rules[i].intent == NONE) {
         buyRules++;
         if(s == BUY) buyLeg++;
      }
      if(p_rules[i].intent == SELL || p_rules[i].intent == NONE) {
         sellRules++;
         if(s == SELL) sellLeg++;
      }
   }

   if(buyRules > 0 && buyLeg == buyRules) return BUY;
   if(sellRules > 0 && sellLeg == sellRules) return SELL;
   return NONE;
}

void EnviaOrdem(Signal s, double lote, string reason) {
   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = (s == BUY) ? price - p_stopPoints * _Point : price + p_stopPoints * _Point;
   double tp = (s == BUY) ? price + p_takePoints * _Point : price - p_takePoints * _Point;

   if(p_stopPoints == 0) sl = 0;
   if(p_takePoints == 0) tp = 0;

   trade.SetExpertMagicNumber(EA_MAGIC);
   bool res = false;
   if(s == BUY) res = trade.Buy(lote, _Symbol, price, sl, tp, reason);
   else res = trade.Sell(lote, _Symbol, price, sl, tp, reason);

   if(!res) Print("Erro ao enviar ordem: ", trade.ResultRetcode(), " - ", trade.ResultComment());
}

void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC && posInfo.Symbol() == _Symbol) {
         double openPrice = posInfo.PriceOpen();
         double currentPrice = (posInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double points = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (currentPrice - openPrice)/_Point : (openPrice - currentPrice)/_Point;

         // Break-even
         if(p_beStart > 0 && points >= p_beStart) {
            double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? openPrice + p_bePlus * _Point : openPrice - p_bePlus * _Point;
            if(posInfo.PositionType() == POSITION_TYPE_BUY) {
               if(posInfo.StopLoss() < newSL || posInfo.StopLoss() == 0) trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
            } else {
               if(posInfo.StopLoss() > newSL || posInfo.StopLoss() == 0) trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
            }
         }

         // Trailing Stop
         if(p_trailingStart > 0 && points >= p_trailingStart) {
             double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? currentPrice - p_trailingStart * _Point : currentPrice + p_trailingStart * _Point;
             // Logic for stepping
             if(posInfo.PositionType() == POSITION_TYPE_BUY) {
                 if(newSL > posInfo.StopLoss() + p_trailingStep * _Point) trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
             } else {
                 if(newSL < posInfo.StopLoss() - p_trailingStep * _Point) trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
             }
         }
      }
   }
}

// --- Log, Stats e News ---

void GravaLog(string texto) {
   int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE|FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      FileSeek(handle, 0, SEEK_END);
      FileWriteString(handle, TimeToString(TimeCurrent()) + ": " + texto + "\r\n");
      FileClose(handle);
   }
}

void GravaCSV() {
   static datetime lastWrite = 0;
   if(TimeCurrent() - lastWrite < 5) return;
   lastWrite = TimeCurrent();

   int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON, ',');
   if(handle != INVALID_HANDLE) {
      FileWrite(handle, "Ticket", "Symbol", "Type", "Volume", "PriceOpen", "Time", "SL", "TP", "Profit", "Reason");
      for(int i=0; i<PositionsTotal(); i++) {
         if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC) {
            FileWrite(handle, posInfo.Ticket(), posInfo.Symbol(), posInfo.PositionType(), posInfo.Volume(),
                      posInfo.PriceOpen(), posInfo.Time(), posInfo.StopLoss(), posInfo.TakeProfit(), posInfo.Profit(), posInfo.Comment());
         }
      }
      FileClose(handle);
   }
}

bool AguardaNoticias() {
   int handle = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(handle == INVALID_HANDLE) return false;
   string content = FileReadString(handle);
   FileClose(handle);
   if(content == "1") return true;

   datetime newsTime = StringToTime(content);
   if(newsTime > 0) {
      if(TimeCurrent() > newsTime - 1200 && TimeCurrent() < newsTime + 1200) return true;
   }
   return false;
}

void CalculaEstatisticas() {
   HistorySelect(0, TimeCurrent());
   int total = HistoryDealsTotal();
   int wins = 0, losses = 0;
   double grossProfit = 0, grossLoss = 0;
   for(int i=0; i<total; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
         double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         if(profit > 0) { wins++; grossProfit += profit; }
         else if(profit < 0) { losses++; grossLoss += MathAbs(profit); }
      }
   }
   double winRate = (wins+losses > 0) ? (double)wins/(wins+losses) : 0;
   double pf = (grossLoss > 0) ? grossProfit/grossLoss : grossProfit;
   // Ajuste dinâmico de risco
   if(wins+losses > 10) {
      if(winRate < 0.4) p_riskPercent = MathMax(0.5, p_riskPercent * 0.9);
      if(winRate > 0.6 && pf > 1.5) p_riskPercent = MathMin(2.0, p_riskPercent * 1.1);
   }
}

void AIOptimizer() {
   static datetime lastOpt = 0;
   if(TimeCurrent() - lastOpt < 3600) return;
   lastOpt = TimeCurrent();
   CalculaEstatisticas();
   GravaLog("Optimizer executado. Risco atual: " + DoubleToString(p_riskPercent, 2));
}

// --- Handlers do Terminal ---

int OnInit() {
   EventSetTimer(1);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   EventKillTimer();
   ResetStrategy();
}

void OnTick() {
   if(AguardaNoticias()) return;

   datetime now = iTime(_Symbol, p_frequency, 0);
   if(now != p_lastBarTime) {
      p_lastBarTime = now;

      // Filtro de Horário
      if(TimeToString(TimeCurrent(), TIME_MINUTES) < p_startTime) return;

      // Limite de trades
      int total = 0;
      for(int i=0; i<PositionsTotal(); i++) if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC) total++;
      if(total >= p_maxTrades) return;

      Signal s = AvaliaTudo();
      if(s != NONE) {
         double lote = CalculaLote(p_riskPercent);
         if(lote > 0) {
            EnviaOrdem(s, lote, "NLP Strategy Signal");
            GravaLog("Sinal detectado: " + EnumToString(s));
         }
      }
   }

   GerenciaPosicoes();
   GravaCSV();
}

void OnTimer() {
   // Atualização dinâmica do prompt
   int handle = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      string prompt = FileReadString(handle);
      FileClose(handle);
      static string lastPrompt = "";
      if(prompt != lastPrompt && StringLen(prompt) > 5) {
         lastPrompt = prompt;
         InterpretaPrompt(prompt);
         GravaLog("Novo prompt carregado: " + prompt);
      }
   }

   AIOptimizer();
}
