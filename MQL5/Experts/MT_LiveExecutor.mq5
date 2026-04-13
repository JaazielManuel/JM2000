//+------------------------------------------------------------------+
//|                                              MT_LiveExecutor.mq5 |
//|                                  Copyright 2024, MT-LiveExecutor |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MT-LiveExecutor"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// ---------- DEFINIÇÕES E ENUMS ----------
enum Signal { BUY=1, SELL=-1, NONE=0 };

enum RuleType {
   RT_MA_CROSS,
   RT_RSI,
   RT_STOCH,
   RT_BB_BOUNCE,
   RT_DAILY_BREAK,
   RT_DELTA,
   RT_VOLUME,
   RT_AMA,
   RT_BAR2,
   RT_RS_RELATIVE
};

struct Rule {
   bool      active;
   RuleType  type;
   int       tf;
   int       p1, p2, p3;
   double    d1, d2;
   string    s1;
   int       p1_handle, p2_handle;
   Signal    intent; // BUY, SELL ou NONE (neutro)
};

// ---------- VARIÁVEIS GLOBAIS ----------
#define EA_MAGIC 20260101
Rule rules[30];
int nRules = 0;
string currentPrompt = "";

// Parâmetros operacionais
double p_riskPercent = 1.0;
int    p_stopPoints = 300;
int    p_takePoints = 500;
int    p_beStart = 0;
int    p_bePlus = 0;
int    p_trailingStart = 0;
int    p_trailingStep = 10;
int    p_maxTrades = 3;
bool   p_useMartingale = false;
ENUM_TIMEFRAMES p_frequency = PERIOD_CURRENT;
datetime p_startTimeSeconds = 0;
datetime p_endTimeSeconds = 86400; // 24h

CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symInfo;
CAccountInfo accInfo;

datetime lastBarTime = 0;
datetime lastCSVWrite = 0;

// ---------- UTILITÁRIOS DE PARSING ----------

double ExtraiNumero(string txt, int startPos=0) {
   string res = "";
   bool achouDigito = false;
   for(int i=startPos; i<StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.') {
         res += CharToString((uchar)c);
         achouDigito = true;
      } else if(achouDigito) break;
   }
   return StringToDouble(res);
}

double ExtraiValorApos(string txt, string chave) {
   int pos = StringFind(txt, chave);
   if(pos < 0) return 0;
   return ExtraiNumero(txt, pos + StringLen(chave));
}

int PeriodoTexto(string nome) {
   string n = nome;
   StringToLower(n);
   if(StringFind(n, "m15") >= 0) return PERIOD_M15;
   if(StringFind(n, "m30") >= 0) return PERIOD_M30;
   if(StringFind(n, "m5") >= 0)  return PERIOD_M5;
   if(StringFind(n, "m1") >= 0)  return PERIOD_M1;
   if(StringFind(n, "h4") >= 0)  return PERIOD_H4;
   if(StringFind(n, "h1") >= 0)  return PERIOD_H1;
   if(StringFind(n, "d1") >= 0)  return PERIOD_D1;
   if(StringFind(n, "w1") >= 0)  return PERIOD_W1;
   if(StringFind(n, "minutos") >= 0 || StringFind(n, "min") >= 0) {
      double v = ExtraiNumero(n);
      if(v == 1) return PERIOD_M1;
      if(v == 5) return PERIOD_M5;
      if(v == 15) return PERIOD_M15;
      if(v == 30) return PERIOD_M30;
   }
   return PERIOD_CURRENT;
}

string ExtractTime(string txt) {
   int posH = StringFind(txt, "h");
   if(posH < 0) return "";

   string hStr = "";
   for(int i=posH-1; i>=0; i--) {
      ushort c = StringGetCharacter(txt, i);
      if(c >= '0' && c <= '9') hStr = CharToString((uchar)c) + hStr;
      else break;
   }

   string mStr = "00";
   if(posH + 1 < StringLen(txt)) {
      ushort c1 = StringGetCharacter(txt, posH+1);
      if(c1 >= '0' && c1 <= '9') {
         mStr = CharToString((uchar)c1);
         if(posH + 2 < StringLen(txt)) {
            ushort c2 = StringGetCharacter(txt, posH+2);
            if(c2 >= '0' && c2 <= '9') mStr += CharToString((uchar)c2);
         }
      }
   }

   if(StringLen(hStr) == 1) hStr = "0" + hStr;
   if(StringLen(mStr) == 1) mStr = "0" + mStr;

   return hStr + ":" + mStr;
}

double GetBufferValue(int handle, int buffer, int shift) {
   double res[];
   ArraySetAsSeries(res, true);
   if(CopyBuffer(handle, buffer, shift, 1, res) > 0) return res[0];
   return 0;
}

// ---------- INDICADORES TÉCNICOS (TENDÊNCIA E MOMENTUM) ----------

Signal CruzamentoMA(int handle1, int handle2, int shift=1) {
   double fast1 = GetBufferValue(handle1, 0, shift);
   double fast2 = GetBufferValue(handle1, 0, shift+1);
   double slow1 = GetBufferValue(handle2, 0, shift);
   double slow2 = GetBufferValue(handle2, 0, shift+1);

   if(fast2 <= slow2 && fast1 > slow1) return BUY;
   if(fast2 >= slow2 && fast1 < slow1) return SELL;
   return NONE;
}

Signal RSIThreshold(int handle, double over, double under, Signal intent, int shift=1) {
   double val = GetBufferValue(handle, 0, shift);
   if(intent == BUY && val > under) return BUY;
   if(intent == SELL && val < over) return SELL;
   // Reversão
   if(val > over) return SELL;
   if(val < under) return BUY;
   return NONE;
}

Signal StochCross(int handle, int shift=1) {
   double k1 = GetBufferValue(handle, 0, shift);
   double d1 = GetBufferValue(handle, 1, shift);
   double k2 = GetBufferValue(handle, 0, shift+1);
   double d2 = GetBufferValue(handle, 1, shift+1);

   if(k2 <= d2 && k1 > d1) return BUY;
   if(k2 >= d2 && k1 < d1) return SELL;
   return NONE;
}

Signal BBounce(int handle, int shift=1) {
   double upper = GetBufferValue(handle, 1, shift);
   double lower = GetBufferValue(handle, 2, shift);
   double close = iClose(_Symbol, PERIOD_CURRENT, shift);

   if(close < lower) return BUY;
   if(close > upper) return SELL;
   return NONE;
}

Signal DailyBreak(int shift=1) {
   double hi = iHigh(_Symbol, PERIOD_D1, 1);
   double lo = iLow(_Symbol, PERIOD_D1, 1);
   double close = iClose(_Symbol, PERIOD_CURRENT, shift);

   if(close > hi) return BUY;
   if(close < lo) return SELL;
   return NONE;
}

// ---------- INDICADORES AVANÇADOS E ESTRUTURAIS ----------

Signal DeltaAggression(int seconds=60, int deltaTrigger=300) {
   MqlTick ticks[];
   int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, (TimeCurrent()-seconds)*1000, TimeCurrent()*1000);
   if(n <= 0) return NONE;

   long buyVol = 0, sellVol = 0;
   for(int i=0; i<n; i++) {
      if((ticks[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buyVol += (long)ticks[i].volume;
      else if((ticks[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sellVol += (long)ticks[i].volume;
   }

   long delta = buyVol - sellVol;
   if(delta > deltaTrigger) return BUY;
   if(delta < -deltaTrigger) return SELL;
   return NONE;
}

Signal VolumeCycle(int length=12, int shift=1) {
   long vol[];
   if(CopyVolume(_Symbol, PERIOD_CURRENT, shift, length, vol) < length) return NONE;

   int maxIdx = ArrayMaximum(vol);
   int minIdx = ArrayMinimum(vol);

   if(maxIdx == 0) return SELL; // Volume climático no candle atual (shift)
   if(minIdx == 0) return BUY;  // Volume exaustão
   return NONE;
}

Signal AMA(int handle, int shift=1) {
   double val = GetBufferValue(handle, 0, shift);
   double prev = GetBufferValue(handle, 0, shift+1);

   if(val > prev) return BUY;
   if(val < prev) return SELL;
   return NONE;
}

Signal Bar2Pattern(int shift=1) {
   double h0 = iHigh(_Symbol, PERIOD_CURRENT, shift);
   double l0 = iLow(_Symbol, PERIOD_CURRENT, shift);
   double c0 = iClose(_Symbol, PERIOD_CURRENT, shift);
   double o0 = iOpen(_Symbol, PERIOD_CURRENT, shift);

   double h1 = iHigh(_Symbol, PERIOD_CURRENT, shift+1);
   double l1 = iLow(_Symbol, PERIOD_CURRENT, shift+1);

   // Inside Bar
   if(h0 < h1 && l0 > l1) return (c0 > o0) ? BUY : SELL;
   // Outside Bar
   if(h0 > h1 && l0 < l1) return (c0 > o0) ? SELL : BUY;

   return NONE;
}

Signal RSRelative(int handle1, int handle2, int shift=1) {
   double r1 = GetBufferValue(handle1, 0, shift);
   double r2 = GetBufferValue(handle2, 0, shift);

   if(r1 > r2 + 5) return BUY;
   if(r1 < r2 - 5) return SELL;
   return NONE;
}

// ---------- PARSER NLP E GERENCIAMENTO DE REGRAS ----------

void ResetStrategy() {
   for(int i=0; i<nRules; i++) {
      if(rules[i].p1_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p1_handle);
      if(rules[i].p2_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p2_handle);
      rules[i].active = false;
   }
   nRules = 0;

   // Reseta parâmetros para defaults
   p_riskPercent = 1.0;
   p_stopPoints = 300;
   p_takePoints = 500;
   p_beStart = 0;
   p_bePlus = 0;
   p_trailingStart = 0;
   p_trailingStep = 10;
   p_maxTrades = 3;
   p_useMartingale = false;
   p_frequency = PERIOD_CURRENT;
   p_startTimeSeconds = 0;
   p_endTimeSeconds = 86400;
}

void AddRule(string segment, Signal currentIntent) {
   if(nRules >= 30) return;

   string s = segment;
   StringToLower(s);

   Rule r;
   r.active = false;
   r.intent = currentIntent;
   r.p1_handle = INVALID_HANDLE;
   r.p2_handle = INVALID_HANDLE;
   r.tf = PeriodoTexto(s);

   // Média Móvel
   if(StringFind(s, "média") >= 0 || StringFind(s, "ma") >= 0) {
      r.type = RT_MA_CROSS;
      int p1 = (int)ExtraiNumero(s);
      int p2 = (int)ExtraiNumero(s, StringFind(s, "/") + 1);
      if(p2 == 0) p2 = 21; // Default
      if(p1 == 0) p1 = 9;  // Default
      r.p1 = p1; r.p2 = p2;
      r.p1_handle = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, p1, 0, MODE_EMA, PRICE_CLOSE);
      r.p2_handle = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, p2, 0, MODE_EMA, PRICE_CLOSE);
      r.active = true;
   }
   // RSI
   else if(StringFind(s, "rsi") >= 0) {
      r.type = RT_RSI;
      int per = (int)ExtraiNumero(s);
      if(per == 0) per = 14;
      double threshold = ExtraiNumero(s, StringFind(s, "rsi") + 3);
      if(threshold < 10) threshold = ExtraiNumero(s, StringFind(s, "abaixo") >= 0 ? StringFind(s, "abaixo") : StringFind(s, "acima"));

      r.p1 = per;
      r.d1 = 70; r.d2 = 30; // Defaults
      if(StringFind(s, "acima de") >= 0) r.d1 = threshold;
      if(StringFind(s, "abaixo de") >= 0) r.d2 = threshold;

      r.p1_handle = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, per, PRICE_CLOSE);
      r.active = true;
   }
   // Estocástico
   else if(StringFind(s, "estocástico") >= 0 || StringFind(s, "stoch") >= 0) {
      r.type = RT_STOCH;
      r.p1_handle = iStochastic(_Symbol, (ENUM_TIMEFRAMES)r.tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
      r.active = true;
   }
   // Bollinger
   else if(StringFind(s, "bollinger") >= 0 || StringFind(s, "bb") >= 0) {
      r.type = RT_BB_BOUNCE;
      r.p1_handle = iBands(_Symbol, (ENUM_TIMEFRAMES)r.tf, 20, 0, 2.0, PRICE_CLOSE);
      r.active = true;
   }
   // Breakout Diário
   else if(StringFind(s, "rompimento diário") >= 0) {
      r.type = RT_DAILY_BREAK;
      r.active = true;
   }
   // Força Relativa
   else if(StringFind(s, "força relativa") >= 0) {
      r.type = RT_RS_RELATIVE;
      r.p1_handle = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, 14, PRICE_CLOSE);
      r.p2_handle = iRSI("US30", (ENUM_TIMEFRAMES)r.tf, 14, PRICE_CLOSE);
      r.active = true;
   }

   if(r.active) {
      rules[nRules] = r;
      nRules++;
   }
}

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   currentPrompt = prompt;
   string p = prompt;
   StringToLower(p);

   // Normaliza separadores para evitar divisões dentro de palavras (ex: "venda", "média")
   StringReplace(p, " e ", "|");
   StringReplace(p, ".", "|");
   StringReplace(p, ",", "|");
   StringReplace(p, "+", "|");

   string segments[];
   int nSegs = StringSplit(p, '|', segments);

   Signal currentIntent = NONE;
   for(int i=0; i<nSegs; i++) {
      StringTrimLeft(segments[i]);
      StringTrimRight(segments[i]);
      if(segments[i] == "") continue;

      if(StringFind(segments[i], "compra") >= 0) currentIntent = BUY;
      else if(StringFind(segments[i], "venda") >= 0) currentIntent = SELL;

      AddRule(segments[i], currentIntent);
   }

   ParseOperationalParams(p);
}

// ---------- PARSER NLP PARA PARÂMETROS OPERACIONAIS ----------

void ParseOperationalParams(string prompt) {
   string p = prompt;
   StringToLower(p);

   if(StringFind(p, "risco de") >= 0) p_riskPercent = ExtraiValorApos(p, "risco de");
   if(StringFind(p, "stop de") >= 0) p_stopPoints = (int)ExtraiValorApos(p, "stop de");
   if(StringFind(p, "take de") >= 0) p_takePoints = (int)ExtraiValorApos(p, "take de");

   if(StringFind(p, "move stop para entrada") >= 0) {
      p_beStart = (int)ExtraiValorApos(p, "atingir +");
      p_bePlus = (int)ExtraiValorApos(p, "entrada +");
   }

   if(StringFind(p, "trailing") >= 0 || StringFind(p, "trailing stop") >= 0) {
      p_trailingStart = (int)ExtraiValorApos(p, "trailing de");
      if(p_trailingStart == 0) p_trailingStart = (int)ExtraiValorApos(p, "trailing stop de");
   }

   if(StringFind(p, "máximo") >= 0 && StringFind(p, "simultâneos") >= 0) {
      p_maxTrades = (int)ExtraiValorApos(p, "máximo");
   }

   if(StringFind(p, "martingale") >= 0) p_useMartingale = true;

   if(StringFind(p, "a cada") >= 0) {
      p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(p);
   }

   if(StringFind(p, "depois das") >= 0) {
      string t = ExtractTime(p);
      if(t != "") p_startTimeSeconds = (datetime)StringToTime(t) % 86400;
   }
}

// ---------- AVALIAÇÃO DE REGRAS E CÁLCULO DE RISCO ----------

Signal AvaliaRegra(int index, int shift=1) {
   Rule r = rules[index];
   if(!r.active) return NONE;

   switch(r.type) {
      case RT_MA_CROSS:    return CruzamentoMA(r.p1_handle, r.p2_handle, shift);
      case RT_RSI:         return RSIThreshold(r.p1_handle, r.d1, r.d2, r.intent, shift);
      case RT_STOCH:       return StochCross(r.p1_handle, shift);
      case RT_BB_BOUNCE:   return BBounce(r.p1_handle, shift);
      case RT_DAILY_BREAK: return DailyBreak(shift);
      case RT_DELTA:       return DeltaAggression(60, 300);
      case RT_VOLUME:      return VolumeCycle(12, shift);
      case RT_AMA:         return AMA(r.p1_handle, shift);
      case RT_BAR2:        return Bar2Pattern(shift);
      case RT_RS_RELATIVE: return RSRelative(r.p1_handle, r.p2_handle, shift);
   }
   return NONE;
}

Signal AvaliaTudo() {
   int buyVotos = 0;
   int sellVotos = 0;
   int buyRules = 0;
   int sellRules = 0;

   for(int i=0; i<nRules; i++) {
      Signal s = AvaliaRegra(i, 1);

      if(rules[i].intent == BUY) {
         buyRules++;
         if(s == BUY) buyVotos++;
      }
      else if(rules[i].intent == SELL) {
         sellRules++;
         if(s == SELL) sellVotos++;
      }
      else { // Neutro (filtro para ambos)
         if(s == BUY) buyVotos++;
         if(s == SELL) sellVotos++;
         buyRules++;
         sellRules++;
      }
   }

   if(buyRules > 0 && buyVotos == buyRules) return BUY;
   if(sellRules > 0 && sellVotos == sellRules) return SELL;

   return NONE;
}

double CalculaLote(double riscoPercent) {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * (riscoPercent / 100.0);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(p_stopPoints <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double riskInTicks = p_stopPoints * (_Point / tickSize);
   double lot = riskMoney / (riskInTicks * tickValue);

   // Normalização
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / stepLot) * stepLot;
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);

   return lot;
}

// ---------- EXECUÇÃO E GESTÃO DE POSIÇÕES ----------

bool EnviaOrdem(Signal s) {
   if(s == NONE) return false;

   double lot = CalculaLote(p_riskPercent);
   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0, tp = 0;

   if(s == BUY) {
      if(p_stopPoints > 0) sl = price - p_stopPoints * _Point;
      if(p_takePoints > 0) tp = price + p_takePoints * _Point;
   } else {
      if(p_stopPoints > 0) sl = price + p_stopPoints * _Point;
      if(p_takePoints > 0) tp = price - p_takePoints * _Point;
   }

   // Verifica margem
   double margin;
   if(!OrderCalcMargin((s == BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL), _Symbol, lot, price, margin)) return false;
   if(margin > AccountInfoDouble(ACCOUNT_FREEMARGIN)) return false;

   trade.SetExpertMagicNumber(EA_MAGIC);
   bool res = false;
   if(s == BUY) res = trade.Buy(lot, _Symbol, price, sl, tp, "MT-LiveExecutor");
   else res = trade.Sell(lot, _Symbol, price, sl, tp, "MT-LiveExecutor");

   return res;
}

void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(posInfo.SelectByIndex(i)) {
         if(posInfo.Magic() != EA_MAGIC || posInfo.Symbol() != _Symbol) continue;

         double currentPrice = (posInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double openPrice = posInfo.PriceOpen();
         double currentSL = posInfo.StopLoss();

         int pointsProfit = (int)(MathAbs(currentPrice - openPrice) / _Point);
         bool isBuy = (posInfo.PositionType() == POSITION_TYPE_BUY);

         // Break-even
         if(p_beStart > 0 && pointsProfit >= p_beStart) {
            double bePrice = isBuy ? (openPrice + p_bePlus * _Point) : (openPrice - p_bePlus * _Point);
            if(isBuy) {
               if(currentSL < bePrice) trade.PositionModify(posInfo.Ticket(), bePrice, posInfo.TakeProfit());
            } else {
               if(currentSL > bePrice || currentSL == 0) trade.PositionModify(posInfo.Ticket(), bePrice, posInfo.TakeProfit());
            }
         }

         // Trailing Stop
         if(p_trailingStart > 0 && pointsProfit >= p_trailingStart) {
            double newSL = isBuy ? (currentPrice - p_trailingStart * _Point) : (currentPrice + p_trailingStart * _Point);
            if(isBuy) {
               if(newSL > currentSL + p_trailingStep * _Point) trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
            } else {
               if(newSL < currentSL - p_trailingStep * _Point || currentSL == 0) trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
            }
         }
      }
   }
}

// ---------- LOGGING, ESTATÍSTICAS E PERSISTÊNCIA ----------

void GravaLog(string texto) {
   string time = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);
   string msg = "[" + time + "] " + texto;
   Print(msg);

   int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE|FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      FileSeek(handle, 0, SEEK_END);
      FileWrite(handle, msg);
      FileClose(handle);
   }
}

void GravaCSV() {
   if(TimeCurrent() - lastCSVWrite < 5) return;
   lastCSVWrite = TimeCurrent();

   int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      FileWrite(handle, "Ticket", "Symbol", "Type", "Lots", "OpenPrice", "SL", "TP", "Profit");
      for(int i=0; i<PositionsTotal(); i++) {
         if(posInfo.SelectByIndex(i)) {
            if(posInfo.Magic() == EA_MAGIC) {
               FileWrite(handle, posInfo.Ticket(), posInfo.Symbol(), posInfo.PositionType(), posInfo.Volume(), posInfo.PriceOpen(), posInfo.StopLoss(), posInfo.TakeProfit(), posInfo.Profit());
            }
         }
      }
      FileClose(handle);
   }
}

void CalculaEstatisticas() {
   HistorySelect(TimeCurrent() - 86400*30, TimeCurrent());
   int total = HistoryDealsTotal();
   double profit = 0;
   int wins = 0, losses = 0;

   for(int i=0; i<total; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
         double p = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         if(p != 0) {
            profit += p;
            if(p > 0) wins++; else losses++;
         }
      }
   }

   double winRate = (wins + losses > 0) ? (double)wins / (wins + losses) * 100.0 : 0;
   // GravaLog("Estatísticas: Profit=" + DoubleToString(profit, 2) + " WinRate=" + DoubleToString(winRate, 1) + "%");
}

// ---------- VETO DE NOTÍCIAS E OTIMIZADOR IA ----------

bool AguardaNoticias() {
   int handle = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      string content = FileReadString(handle);
      FileClose(handle);
      if(content == "1") return true;

      datetime newsTime = (datetime)StringToTime(content);
      if(newsTime > 0) {
         if(TimeCurrent() >= newsTime - 1200 && TimeCurrent() <= newsTime + 1200) return true;
      }
   }

   // Fallback: Calendário nativo MQL5 (simplificado)
   MqlCalendarValue values[];
   if(CalendarValueHistory(values, TimeCurrent() - 3600, TimeCurrent() + 3600) > 0) {
      for(int i=0; i<ArraySize(values); i++) {
         if(values[i].importance == CALENDAR_IMPORTANCE_HIGH) return true;
      }
   }

   return false;
}

void AIOptimizer() {
   HistorySelect(TimeCurrent() - 86400*7, TimeCurrent());
   int total = 0;
   double profit = 0;
   int wins = 0;

   for(int i=HistoryDealsTotal()-1; i>=0 && total < 20; i--) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
         double p = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         if(p != 0) {
            profit += p;
            if(p > 0) wins++;
            total++;
         }
      }
   }

   if(total >= 10) {
      double winRate = (double)wins / total;
      if(winRate < 0.4) p_riskPercent = MathMax(0.5, p_riskPercent - 0.1);
      else if(winRate > 0.6) p_riskPercent = MathMin(2.0, p_riskPercent + 0.1);
   }
}

// ---------- HANDLERS DE EVENTOS ----------

int OnInit() {
   EventSetTimer(1);
   symInfo.Name(_Symbol);
   accInfo.Login();

   GravaLog("MT-LiveExecutor Iniciado.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   EventKillTimer();
   ResetStrategy();
   GravaLog("MT-LiveExecutor Encerrado.");
}

void OnTimer() {
   // Monitora arquivo de prompt
   int handle = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      string newPrompt = FileReadString(handle);
      FileClose(handle);

      if(newPrompt != "" && newPrompt != currentPrompt) {
         GravaLog("Novo prompt recebido: " + newPrompt);
         InterpretaPrompt(newPrompt);

         // Limpa arquivo para não ler repetidamente se não for desejado (opcional)
         // handle = FileOpen("prompt.txt", FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
         // if(handle != INVALID_HANDLE) { FileWrite(handle, ""); FileClose(handle); }
      }
   }

   CalculaEstatisticas();
   AIOptimizer();
}

void OnTick() {
   GerenciaPosicoes();
   GravaCSV();

   if(nRules == 0) return;

   // Filtro de Horário
   datetime nowSeconds = TimeCurrent() % 86400;
   if(nowSeconds < p_startTimeSeconds || nowSeconds > p_endTimeSeconds) return;

   // Veto de Notícias
   if(AguardaNoticias()) return;

   // Controle de frequência (OnBar)
   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar == lastBarTime) return;
   lastBarTime = currentBar;

   // Limite de trades
   int activeTrades = 0;
   for(int i=0; i<PositionsTotal(); i++) if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC) activeTrades++;
   if(activeTrades >= p_maxTrades) return;

   Signal s = AvaliaTudo();
   if(s != NONE) {
      if(EnviaOrdem(s)) {
         GravaLog("Ordem enviada com sucesso: " + EnumToString(s));
      } else {
         GravaLog("Erro ao enviar ordem: " + IntegerToString(trade.ResultRetcode()));
      }
   }
}
