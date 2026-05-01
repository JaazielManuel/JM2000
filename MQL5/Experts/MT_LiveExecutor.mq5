//=========================  MT5-LIVE-EXECUTOR-CORE  =========================
// MT-LiveExecutor: Interpreta prompts em português e executa trades ao vivo.
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\HistoryOrderInfo.mqh>
#include <Trade\HistoryDealInfo.mqh>

// ---------- DEFINES E ENUMS ----------
#define EA_MAGIC 123456
enum ENUM_INTENT { INTENT_BUY, INTENT_SELL, INTENT_NONE };

struct Rule {
   bool        active;
   int         type;       // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: DailyBreak, 6: Delta, 7: Vol, 8: AMA, 9: Bar2, 10: RS, 11: AI
   ENUM_INTENT intent;
   ENUM_TIMEFRAMES tf;
   int         p1, p2, p3;
   double      d1, d2;
   string      s1;
   int         handle1, handle2;
};

// ---------- VARIÁVEIS GLOBAIS DE ESTRATÉGIA ----------
Rule              rules[20];
int               nRules = 0;
ENUM_TIMEFRAMES   p_frequency = PERIOD_M15;
double            p_riskPercent = 1.0;
int               p_stopPoints = 300;
int               p_takePoints = 500;
int               p_maxTrades = 3;
int               p_beStart = 0;
int               p_bePlus = 0;
int               p_trailingStart = 0;
int               p_trailingStep = 10;
bool              p_useMartingale = false;
string            p_startTime = "00:00";
datetime          p_lastPromptTime = 0;

// Objetos MQL5
CTrade            trade;
CPositionInfo     posInfo;
CSymbolInfo       symbolInfo;
CAccountInfo      accountInfo;
CHistoryDealInfo  dealInfo;

// ---------- PROTÓTIPOS ----------
void InterpretaPrompt(string prompt);
void ResetStrategy();
void OnTick();
void OnTimer();
void GerenciaPosicoes();
void GravaCSV();
void GravaLog(string texto);
bool AguardaNoticias();
double CalculaLote(double risco);
void EnviaOrdem(ENUM_INTENT intent, string reason);
int PeriodoTexto(string nome);
double ExtraiNumero(string txt, int &startPos);
double ExtraiValorApos(string txt, string keyword);
double GetBufferValue(int handle, int buffer, int shift);
void AIOptimizer();

// ---------- HELPERS DE PARSING ----------
int PeriodoTexto(string nome) {
   nome.Lower();
   if(StringFind(nome, "1 minuto") >= 0 || StringFind(nome, "m1") >= 0) return PERIOD_M1;
   if(StringFind(nome, "5 minutos") >= 0 || StringFind(nome, "m5") >= 0) return PERIOD_M5;
   if(StringFind(nome, "15 minutos") >= 0 || StringFind(nome, "m15") >= 0) return PERIOD_M15;
   if(StringFind(nome, "30 minutos") >= 0 || StringFind(nome, "m30") >= 0) return PERIOD_M30;
   if(StringFind(nome, "1 hora") >= 0 || StringFind(nome, "h1") >= 0) return PERIOD_H1;
   if(StringFind(nome, "4 horas") >= 0 || StringFind(nome, "h4") >= 0) return PERIOD_H4;
   if(StringFind(nome, "diário") >= 0 || StringFind(nome, "d1") >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

double ExtraiNumero(string txt, int &startPos) {
   string res = "";
   bool found = false;
   for(int i = startPos; i < StringLen(txt); i++) {
      ushort c = txt.GetChar(i);
      if((c >= '0' && c <= '9') || c == '.') {
         res += CharToString((char)c);
         found = true;
      } else if(found) {
         startPos = i;
         return StringToDouble(res);
      }
   }
   return StringToDouble(res);
}

double ExtraiValorApos(string txt, string keyword) {
   int pos = StringFind(txt, keyword);
   if(pos < 0) return 0;
   pos += StringLen(keyword);
   return ExtraiNumero(txt, pos);
}

void ResetStrategy() {
   for(int i = 0; i < nRules; i++) {
      if(rules[i].handle1 != INVALID_HANDLE && rules[i].handle1 != 0) IndicatorRelease(rules[i].handle1);
      if(rules[i].handle2 != INVALID_HANDLE && rules[i].handle2 != 0) IndicatorRelease(rules[i].handle2);
      rules[i].active = false;
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
   p_useMartingale = false;
   p_startTime = "00:00";
}

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   string original = prompt;
   prompt.Lower();

   // Parâmetros Globais
   p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(prompt);

   double val = ExtraiValorApos(prompt, "risco de");
   if(val > 0) p_riskPercent = val;

   val = ExtraiValorApos(prompt, "stop de");
   if(val > 0) p_stopPoints = (int)val;

   val = ExtraiValorApos(prompt, "take de");
   if(val > 0) p_takePoints = (int)val;

   val = ExtraiValorApos(prompt, "máximo");
   if(val > 0) p_maxTrades = (int)val;

   if(StringFind(prompt, "martingale") >= 0) p_useMartingale = true;

   val = ExtraiValorApos(prompt, "atingir +");
   if(val > 0) p_beStart = (int)val;

   val = ExtraiValorApos(prompt, "entrada +");
   if(val > 0) p_bePlus = (int)val;

   val = ExtraiValorApos(prompt, "trailing stop de");
   if(val > 0) p_trailingStart = (int)val;

   int timePos = StringFind(prompt, "depois das ");
   if(timePos >= 0) {
      string sub = StringSubstr(prompt, timePos + 11); // "depois das " is 11 chars
      StringTrimLeft(sub);
      p_startTime = StringSubstr(sub, 0, 5);
      if(StringFind(p_startTime, "h") >= 0) { // handle "10h" style
         int hPos = StringFind(p_startTime, "h");
         string hPart = StringSubstr(p_startTime, 0, hPos);
         if(StringLen(hPart) == 1) hPart = "0" + hPart;
         p_startTime = hPart + ":00";
      }
   }

   // Divisão de Regras
   string segments[];
   string temp = prompt;
   StringReplace(temp, " e ", "|");
   StringReplace(temp, ".", "|");
   StringReplace(temp, ",", "|");
   ushort sep = StringGetCharacter("|", 0);
   StringSplit(temp, sep, segments);

   ENUM_INTENT currentIntent = INTENT_NONE;
   int lastMA_p1 = 20;

   for(int i = 0; i < ArraySize(segments) && nRules < 20; i++) {
      string s = segments[i];
      if(StringFind(s, "compra") >= 0) currentIntent = INTENT_BUY;
      else if(StringFind(s, "vende") >= 0) currentIntent = INTENT_SELL;

      // Rule: Moving Average
      if(StringFind(s, " média") >= 0 || StringFind(s, " ma ") >= 0 || StringFind(s, " ma/") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = 1;
         rules[nRules].intent = currentIntent;
         rules[nRules].tf = (ENUM_TIMEFRAMES)PeriodoTexto(s);
         if(rules[nRules].tf == PERIOD_CURRENT) rules[nRules].tf = p_frequency;

         int pos = 0;
         int p1 = (int)ExtraiNumero(s, pos);
         int p2 = (int)ExtraiNumero(s, pos);

         if(p1 == 0) p1 = lastMA_p1; else lastMA_p1 = p1;

         rules[nRules].p1 = p1;
         rules[nRules].p2 = p2; // if 0, price vs MA
         rules[nRules].handle1 = iMA(_Symbol, rules[nRules].tf, p1, 0, MODE_SMA, PRICE_CLOSE);
         if(p2 > 0) rules[nRules].handle2 = iMA(_Symbol, rules[nRules].tf, p2, 0, MODE_SMA, PRICE_CLOSE);
         nRules++;
      }

      // Rule: RSI
      if(StringFind(s, "rsi") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = 2;
         rules[nRules].intent = currentIntent;
         rules[nRules].tf = (ENUM_TIMEFRAMES)PeriodoTexto(s);
         if(rules[nRules].tf == PERIOD_CURRENT) rules[nRules].tf = p_frequency;

         int pos = 0;
         double v1 = ExtraiNumero(s, pos);
         double v2 = ExtraiNumero(s, pos);

         if(v1 < 40) { rules[nRules].p1 = (int)v1; rules[nRules].d1 = v2; }
         else { rules[nRules].p1 = 14; rules[nRules].d1 = v1; }

         if(rules[nRules].d1 == 0) rules[nRules].d1 = (currentIntent == INTENT_BUY) ? 30 : 70;

         rules[nRules].handle1 = iRSI(_Symbol, rules[nRules].tf, rules[nRules].p1, PRICE_CLOSE);
         nRules++;
      }

      // Rule: Stochastic
      if(StringFind(s, "estocástico") >= 0 || StringFind(s, "stoch") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = 3;
         rules[nRules].intent = currentIntent;
         rules[nRules].tf = (ENUM_TIMEFRAMES)PeriodoTexto(s);
         if(rules[nRules].tf == PERIOD_CURRENT) rules[nRules].tf = p_frequency;
         rules[nRules].handle1 = iStochastic(_Symbol, rules[nRules].tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
         nRules++;
      }

      // Rule: Bollinger Bands
      if(StringFind(s, "bollinger") >= 0 || StringFind(s, "bandas") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = 4;
         rules[nRules].intent = currentIntent;
         rules[nRules].tf = (ENUM_TIMEFRAMES)PeriodoTexto(s);
         if(rules[nRules].tf == PERIOD_CURRENT) rules[nRules].tf = p_frequency;
         rules[nRules].handle1 = iBands(_Symbol, rules[nRules].tf, 20, 0, 2.0, PRICE_CLOSE);
         nRules++;
      }

      // Rule: Daily Breakout
      if(StringFind(s, "rompimento diário") >= 0 || StringFind(s, "máxima/mínima de ontem") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = 5;
         rules[nRules].intent = currentIntent;
         nRules++;
      }

      // Rule: AI Prediction
      if(StringFind(s, "previsão") >= 0 || StringFind(s, "ai") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = 11;
         rules[nRules].intent = currentIntent;
         rules[nRules].handle1 = iATR(_Symbol, PERIOD_CURRENT, 14);
         nRules++;
      }
   }
   GravaLog("Novo prompt interpretado: " + original);
}

// ---------- LÓGICA DE SINAIS ----------
double GetBufferValue(int handle, int buffer, int shift) {
   double val[];
   ArraySetAsSeries(val, true);
   if(CopyBuffer(handle, buffer, shift, 1, val) > 0) return val[0];
   return 0;
}

ENUM_INTENT AvaliaRegra(Rule &r) {
   if(!r.active) return INTENT_NONE;

   // 1: Moving Average Crossover or Price vs MA
   if(r.type == 1) {
      double ma1_curr = GetBufferValue(r.handle1, 0, 1);
      double ma1_prev = GetBufferValue(r.handle1, 0, 2);

      if(r.handle2 != INVALID_HANDLE && r.handle2 != 0) {
         double ma2_curr = GetBufferValue(r.handle2, 0, 1);
         double ma2_prev = GetBufferValue(r.handle2, 0, 2);
         if(ma1_prev < ma2_prev && ma1_curr > ma2_curr) return INTENT_BUY;
         if(ma1_prev > ma2_prev && ma1_curr < ma2_curr) return INTENT_SELL;
      } else {
         double close_curr = iClose(_Symbol, r.tf, 1);
         double close_prev = iClose(_Symbol, r.tf, 2);
         if(close_prev < ma1_prev && close_curr > ma1_curr) return INTENT_BUY;
         if(close_prev > ma1_prev && close_curr < ma1_curr) return INTENT_SELL;
      }
   }

   // 2: RSI
   if(r.type == 2) {
      double rsi_curr = GetBufferValue(r.handle1, 0, 1);
      double rsi_prev = GetBufferValue(r.handle1, 0, 2);
      if(r.intent == INTENT_BUY && rsi_prev < r.d1 && rsi_curr > r.d1) return INTENT_BUY;
      if(r.intent == INTENT_SELL && rsi_prev > r.d1 && rsi_curr < r.d1) return INTENT_SELL;
   }

   // 3: Stochastic
   if(r.type == 3) {
      double k_curr = GetBufferValue(r.handle1, 0, 1);
      double d_curr = GetBufferValue(r.handle1, 1, 1);
      double k_prev = GetBufferValue(r.handle1, 0, 2);
      double d_prev = GetBufferValue(r.handle1, 1, 2);
      if(k_prev < d_prev && k_curr > d_curr) return INTENT_BUY;
      if(k_prev > d_prev && k_curr < d_curr) return INTENT_SELL;
   }

   // 4: Bollinger Bands
   if(r.type == 4) {
      double close = iClose(_Symbol, r.tf, 1);
      double lower = GetBufferValue(r.handle1, 2, 1);
      double upper = GetBufferValue(r.handle1, 1, 1);
      if(close < lower) return INTENT_BUY;
      if(close > upper) return INTENT_SELL;
   }

   // 5: Daily Breakout
   if(r.type == 5) {
      double hi = iHigh(_Symbol, PERIOD_D1, 1);
      double lo = iLow(_Symbol, PERIOD_D1, 1);
      double close = iClose(_Symbol, PERIOD_CURRENT, 1);
      if(close > hi) return INTENT_BUY;
      if(close < lo) return INTENT_SELL;
   }

   // 11: AI Prediction Heuristic
   if(r.type == 11) {
      double atr = GetBufferValue(r.handle1, 0, 1);
      double body = MathAbs(iClose(_Symbol, PERIOD_CURRENT, 1) - iOpen(_Symbol, PERIOD_CURRENT, 1));
      if(body > 1.5 * atr) {
         if(iClose(_Symbol, PERIOD_CURRENT, 1) > iOpen(_Symbol, PERIOD_CURRENT, 1)) return INTENT_BUY;
         else return INTENT_SELL;
      }
   }

   return INTENT_NONE;
}

ENUM_INTENT AvaliaTudo() {
   int buyLeg = 0, sellLeg = 0;
   int buyCount = 0, sellCount = 0;

   for(int i = 0; i < nRules; i++) {
      ENUM_INTENT signal = AvaliaRegra(rules[i]);
      if(rules[i].intent == INTENT_BUY || rules[i].intent == INTENT_NONE) {
         buyCount++;
         if(signal == INTENT_BUY) buyLeg++;
      }
      if(rules[i].intent == INTENT_SELL || rules[i].intent == INTENT_NONE) {
         sellCount++;
         if(signal == INTENT_SELL) sellLeg++;
      }
   }

   if(buyCount > 0 && buyLeg == buyCount) return INTENT_BUY;
   if(sellCount > 0 && sellLeg == sellCount) return INTENT_SELL;
   return INTENT_NONE;
}

// ---------- EXECUÇÃO E GESTÃO ----------
double CalculaLote(double riscoPercent) {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (riscoPercent / 100.0);

   if(p_useMartingale) {
      HistorySelect(TimeCurrent() - 86400 * 7, TimeCurrent());
      int total = HistoryDealsTotal();
      for(int i = total - 1; i >= 0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            if(profit < 0) riskAmount *= 2.0;
            break;
         }
      }
   }

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   int stopPts = p_stopPoints;
   if(stopPts <= 0) stopPts = 100;

   double denominator = stopPts * (tickValue / (tickSize / _Point));
   double lot = (denominator > 0) ? riskAmount / denominator : SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   lot = MathFloor(lot / lotStep) * lotStep;

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return lot;
}

void EnviaOrdem(ENUM_INTENT intent, string reason) {
   if(PositionsTotal() >= p_maxTrades) return;
   if(AguardaNoticias()) return;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string nowTime = StringFormat("%02d:%02d", dt.hour, dt.min);
   if(nowTime < p_startTime) return;

   double lot = CalculaLote(p_riskPercent);
   double price = (intent == INTENT_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Margin Check
   double margin;
   if(!OrderCalcMargin((intent == INTENT_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL), _Symbol, lot, price, margin)) return;
   if(margin > AccountInfoDouble(ACCOUNT_FREEMARGIN)) {
      GravaLog("Margem insuficiente para abrir ordem.");
      return;
   }

   double sl = 0, tp = 0;
   if(intent == INTENT_BUY) {
      sl = (p_stopPoints > 0) ? price - p_stopPoints * _Point : 0;
      tp = (p_takePoints > 0) ? price + p_takePoints * _Point : 0;
      if(trade.Buy(lot, _Symbol, price, sl, tp, reason)) {
         GravaLog("Compra executada: " + reason);
         SendNotification("MT-LiveExecutor: Compra em " + _Symbol);
      }
   } else {
      sl = (p_stopPoints > 0) ? price + p_stopPoints * _Point : 0;
      tp = (p_takePoints > 0) ? price - p_takePoints * _Point : 0;
      if(trade.Sell(lot, _Symbol, price, sl, tp, reason)) {
         GravaLog("Venda executada: " + reason);
         SendNotification("MT-LiveExecutor: Venda em " + _Symbol);
      }
   }
}

void GerenciaPosicoes() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(posInfo.SelectByIndex(i)) {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == EA_MAGIC) {
            double openPrice = posInfo.PriceOpen();
            double curPrice = (posInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double curSL = posInfo.StopLoss();

            // Break-even
            if(p_beStart > 0 && curSL != openPrice + (posInfo.PositionType() == POSITION_TYPE_BUY ? p_bePlus : -p_bePlus) * _Point) {
               double profitPoints = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (curPrice - openPrice) / _Point : (openPrice - curPrice) / _Point;
               if(profitPoints >= p_beStart) {
                  double newSL = openPrice + (posInfo.PositionType() == POSITION_TYPE_BUY ? p_bePlus : -p_bePlus) * _Point;
                  trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
               }
            }

            // Trailing Stop
            if(p_trailingStart > 0) {
               double profitPoints = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (curPrice - openPrice) / _Point : (openPrice - curPrice) / _Point;
               if(profitPoints >= p_trailingStart) {
                  double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? curPrice - p_trailingStart * _Point : curPrice + p_trailingStart * _Point;
                  if(posInfo.PositionType() == POSITION_TYPE_BUY) {
                     if(newSL > curSL + p_trailingStep * _Point || curSL == 0) trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
                  } else {
                     if(newSL < curSL - p_trailingStep * _Point || curSL == 0) trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
                  }
               }
            }
         }
      }
   }
}

// ---------- UTILITÁRIOS E PERSISTÊNCIA ----------
void GravaLog(string texto) {
   int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE | FILE_READ | FILE_TXT | FILE_ANSI);
   if(handle != INVALID_HANDLE) {
      FileSeek(handle, 0, SEEK_END);
      FileWrite(handle, TimeToString(TimeCurrent()) + ": " + texto);
      FileClose(handle);
   }
   Print(texto);
}

void GravaCSV() {
   int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV | FILE_ANSI);
   if(handle != INVALID_HANDLE) {
      FileWrite(handle, "Ticket", "Symbol", "Type", "Volume", "PriceOpen", "Time", "SL", "TP", "Profit", "Reason");
      for(int i = 0; i < PositionsTotal(); i++) {
         if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC) {
            FileWrite(handle, posInfo.Ticket(), posInfo.Symbol(), posInfo.PositionType(), posInfo.Volume(),
                      posInfo.PriceOpen(), posInfo.Time(), posInfo.StopLoss(), posInfo.TakeProfit(), posInfo.Profit(), posInfo.Comment());
         }
      }
      FileClose(handle);
   }
}

bool AguardaNoticias() {
   if(FileIsExist("news_veto.txt")) {
      int handle = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_ANSI);
      if(handle != INVALID_HANDLE) {
         string content = FileReadString(handle);
         FileClose(handle);
         if(content == "1") return true;
      }
   }
   return false;
}

void AIOptimizer() {
   static datetime lastOpt = 0;
   if(TimeCurrent() - lastOpt < 3600) return;
   lastOpt = TimeCurrent();

   HistorySelect(TimeCurrent() - 86400 * 30, TimeCurrent());
   int total = HistoryDealsTotal();
   int wins = 0, count = 0;
   for(int i = total - 1; i >= 0 && count < 10; i--) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
         if(HistoryDealGetDouble(ticket, DEAL_PROFIT) > 0) wins++;
         count++;
      }
   }
   if(count >= 5 && (double)wins / count < 0.4) {
      p_riskPercent *= 0.8;
      GravaLog("AI Optimizer: Risco reduzido devido a baixa taxa de acerto.");
   }
}

// ---------- LOOP PRINCIPAL ----------
int OnInit() {
   EventSetTimer(1);
   trade.SetExpertMagicNumber(EA_MAGIC);
   symbolInfo.Name(_Symbol);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   EventKillTimer();
}

void OnTimer() {
   datetime lastMod = (datetime)FileGetInteger("prompt.txt", FILE_MODIFY_DATE);
   if(lastMod > p_lastPromptTime) {
      int handle = FileOpen("prompt.txt", FILE_READ | FILE_TXT | FILE_ANSI);
      if(handle != INVALID_HANDLE) {
         string prompt = FileReadString(handle);
         FileClose(handle);
         InterpretaPrompt(prompt);
         p_lastPromptTime = lastMod;
      }
   }
   AIOptimizer();
}

void OnTick() {
   static datetime lastBar = 0;
   datetime curBar = iTime(_Symbol, p_frequency, 0);

   if(curBar != lastBar) {
      ENUM_INTENT signal = AvaliaTudo();
      if(signal != INTENT_NONE) {
         EnviaOrdem(signal, "Sinal detectado em " + EnumToString(p_frequency));
      }
      lastBar = curBar;
   }

   GerenciaPosicoes();
   GravaCSV();
}
