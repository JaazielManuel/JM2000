//=========================  MT5-LIVE-EXECUTOR  =========================
// Módulo Único: Executor de Estratégias por Prompt
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\DealInfo.mqh>
#include <Trade\HistoryOrderInfo.mqh>
#include <Indicators\Indicators.mqh>

// ---------- ENUMS E STRUCTS ----------
enum Signal {BUY=1, SELL=-1, NONE=0};
enum RuleType {
   RT_MA_CROSS, RT_RSI, RT_STOCH, RT_BB, RT_DAILY_BREAK,
   RT_DELTA, RT_VOLUME, RT_AMA, RT_BAR2, RT_RS_REL
};

struct Rule {
   bool      active;
   RuleType  type;
   ENUM_TIMEFRAMES tf;
   int       p1, p2, p3;
   double    d1, d2;
   string    s1;
   Signal    intent; // BUY, SELL ou NONE (filtro)
   int       h1, h2; // Handles para indicadores
};

// ---------- GLOBAIS E CONSTANTES ----------
#define EA_MAGIC 20260101
#define MAX_RULES 30

Rule     g_rules[MAX_RULES];
int      g_nRules = 0;

// Parâmetros de Gestão
double   p_riskPercent = 1.0;
int      p_stopPoints = 300;
int      p_takePoints = 500;
int      p_trailingStart = 0;
int      p_trailingStep = 10;
int      p_beStart = 0;
int      p_bePlus = 0;
int      p_maxTrades = 3;
bool     p_useMartingale = false;
long     p_startTimeSeconds = 0;
long     p_endTimeSeconds = 86399; // Fim do dia
ENUM_TIMEFRAMES p_frequency = PERIOD_CURRENT;

// Estado e Objetos
datetime lastBarTime = 0;
CTrade   trade;
CPositionInfo posInfo;
CAccountInfo account;
CDealInfo dealInfo;

// ---------- UTILITÁRIOS DE PARSING ----------

double ExtraiNumero(string txt, string chave, int startPos = 0) {
   int pos = StringFind(txt, chave, startPos);
   if(pos < 0) return 0;
   string sub = StringSubstr(txt, pos + StringLen(chave));
   string res = ""; bool found = false;
   for(int i=0; i<StringLen(sub); i++) {
      ushort c = StringGetCharacter(sub, i);
      if((c >= '0' && c <= '9') || c == '.') { res += StringSubstr(sub, i, 1); found = true; }
      else if (found) break;
   }
   return StringToDouble(res);
}

string ExtractTime(string txt) {
   int hPos = StringFind(txt, "h");
   if(hPos > 0) {
      string h = StringSubstr(txt, hPos-2, 2);
      StringReplace(h, " ", "0");
      return h + ":00";
   }
   return "00:00";
}

ENUM_TIMEFRAMES PeriodoTexto(string nome) {
   StringToLower(nome);
   if(StringFind(nome, "m15") >= 0 || StringFind(nome, "15 minutos") >= 0) return PERIOD_M15;
   if(StringFind(nome, "m30") >= 0 || StringFind(nome, "30 minutos") >= 0) return PERIOD_M30;
   if(StringFind(nome, "m5") >= 0 || StringFind(nome, "5 minutos") >= 0)  return PERIOD_M5;
   if(StringFind(nome, "m1") >= 0 || StringFind(nome, "1 minuto") >= 0)   return PERIOD_M1;
   if(StringFind(nome, "h1") >= 0 || StringFind(nome, "1 hora") >= 0)     return PERIOD_H1;
   if(StringFind(nome, "d1") >= 0 || StringFind(nome, "diário") >= 0)     return PERIOD_D1;
   return PERIOD_CURRENT;
}

// ---------- LOGS E PERSISTÊNCIA ----------

void GravaLog(string texto) {
   int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_READ|FILE_WRITE|FILE_TXT|FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      FileSeek(handle, 0, SEEK_END);
      FileWrite(handle, TimeToString(TimeCurrent()) + ": " + texto);
      FileClose(handle);
   }
   Print(texto);
}

void GravaCSV() {
   static datetime lastCSV = 0;
   if(TimeCurrent() - lastCSV < 5) return;
   lastCSV = TimeCurrent();
   int handle = FileOpen("executor_state.csv", FILE_WRITE|FILE_CSV|FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      FileWrite(handle, "Ticket", "Symbol", "Type", "PriceOpen", "SL", "TP", "Profit");
      for(int i=0; i<PositionsTotal(); i++) {
         if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC) {
            FileWrite(handle, posInfo.Ticket(), posInfo.Symbol(), posInfo.PositionType(),
                      posInfo.PriceOpen(), posInfo.StopLoss(), posInfo.TakeProfit(), posInfo.Profit());
         }
      }
      FileClose(handle);
   }
}

bool AguardaNoticias() {
   int handle = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      string content = FileReadString(handle);
      FileClose(handle);
      if(content == "1") return true;
      datetime eventTime = StringToTime(content);
      if(eventTime > 0 && MathAbs(TimeCurrent() - eventTime) < 1200) return true;
   }
   return false;
}

void CalculaEstatisticas() {
   double profit = 0; int wins = 0, losses = 0;
   HistorySelect(0, TimeCurrent());
   for(int i=0; i<HistoryDealsTotal(); i++) {
      if(dealInfo.SelectByIndex(i) && dealInfo.Magic() == EA_MAGIC && dealInfo.Entry() == DEAL_ENTRY_OUT) {
         double p = dealInfo.Profit();
         profit += p;
         if(p > 0) wins++; else if(p < 0) losses++;
      }
   }
   double wr = (wins + losses > 0) ? (double)wins / (wins + losses) * 100.0 : 0;
   GravaLog(StringFormat("Estatísticas: Profit=%.2f, WinRate=%.1f%%", profit, wr));
}

// ---------- INDICADORES (SINAIS) ----------

double GetBufferValue(int handle, int buffer, int shift) {
   double val[];
   ArraySetAsSeries(val, true);
   if(CopyBuffer(handle, buffer, shift, 1, val) > 0) return val[0];
   return 0;
}

Signal EvalRule(int idx, int shift) {
   Rule r = g_rules[idx];
   if(!r.active) return NONE;

   switch(r.type) {
      case RT_MA_CROSS: {
         double f1 = GetBufferValue(r.h1, 0, shift);
         double f2 = GetBufferValue(r.h1, 0, shift+1);
         double s1, s2;
         if(r.p2 > 0) {
            s1 = GetBufferValue(r.h2, 0, shift);
            s2 = GetBufferValue(r.h2, 0, shift+1);
         } else {
            s1 = iClose(_Symbol, r.tf, shift);
            s2 = iClose(_Symbol, r.tf, shift+1);
         }

         if(r.p2 == 0) { // Preço cruza MA
            if(s2 <= f2 && s1 > f1) return BUY;
            if(s2 >= f2 && s1 < f1) return SELL;
         } else { // MA curta cruza MA longa
            if(f2 <= s2 && f1 > s1) return BUY;
            if(f2 >= s2 && f1 < s1) return SELL;
         }
         break;
      }
      case RT_RSI: {
         double v1 = GetBufferValue(r.h1, 0, shift);
         double v2 = GetBufferValue(r.h1, 0, shift+1);
         double thresh = (r.intent == BUY) ? (r.d1 > 0 ? r.d1 : r.d2) : (r.d2 > 0 ? r.d2 : r.d1);
         if(r.intent == BUY && v1 > thresh && v2 <= thresh) return BUY;
         if(r.intent == SELL && v1 < thresh && v2 >= thresh) return SELL;
         if(r.intent == NONE) {
            if(v1 < r.d2 && r.d2 > 0) return BUY;
            if(v1 > r.d1 && r.d1 > 0) return SELL;
         }
         break;
      }
      case RT_BB: {
         double low1 = GetBufferValue(r.h1, 2, shift); // Lower
         double up1  = GetBufferValue(r.h1, 1, shift); // Upper
         double close = iClose(_Symbol, r.tf, shift);
         if(close < low1) return BUY;
         if(close > up1) return SELL;
         break;
      }
      case RT_STOCH: {
         double k1 = GetBufferValue(r.h1, 0, shift);
         double d1 = GetBufferValue(r.h1, 1, shift);
         double k2 = GetBufferValue(r.h1, 0, shift+1);
         double d2 = GetBufferValue(r.h1, 1, shift+1);
         if(k2 <= d2 && k1 > d1) return BUY;
         if(k2 >= d2 && k1 < d1) return SELL;
         break;
      }
   }
   return NONE;
}

// ---------- GESTÃO DE RISCO E ORDENS ----------

double CalculaLote(double riscoPercent, int stopPoints) {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(stopPoints <= 0) stopPoints = p_stopPoints;
   double riskAmount = balance * (riscoPercent / 100.0);
   double pointsInMoney = stopPoints * (tickVal / (tickSize / _Point));
   double lot = riskAmount / pointsInMoney;

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / step) * step;
   double min = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   return MathMax(min, MathMin(max, lot));
}

void EnviaOrdem(Signal s, double volume) {
   if(PositionsTotal() >= p_maxTrades) return;
   double sl = 0, tp = 0;
   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double safety = stopsLevel + 6;
   double actualStop = MathMax(p_stopPoints, safety);
   bool res = false;
   if(s == BUY) {
      sl = price - actualStop * _Point;
      tp = price + p_takePoints * _Point;
      res = trade.Buy(volume, _Symbol, price, sl, tp, "LiveExecutor");
   } else {
      sl = price + actualStop * _Point;
      tp = price - p_takePoints * _Point;
      res = trade.Sell(volume, _Symbol, price, sl, tp, "LiveExecutor");
   }

   if(!res) {
      GravaLog("Erro ao enviar ordem: " + (string)trade.ResultRetcode() + " - " + trade.ResultRetcodeDescription());
   } else {
      GravaLog("Ordem enviada com sucesso. Ticket: " + (string)trade.ResultOrder());
   }
}

// ---------- CORE ----------

void ResetStrategy() {
   for(int i=0; i<MAX_RULES; i++) {
      if(g_rules[i].active) {
         if(g_rules[i].h1 != INVALID_HANDLE) IndicatorRelease(g_rules[i].h1);
         if(g_rules[i].h2 != INVALID_HANDLE) IndicatorRelease(g_rules[i].h2);
      }
      g_rules[i].active = false;
      g_rules[i].h1 = INVALID_HANDLE;
      g_rules[i].h2 = INVALID_HANDLE;
   }
   g_nRules = 0;
   p_riskPercent = 1.0; p_stopPoints = 300; p_takePoints = 500;
   p_trailingStart = 0; p_beStart = 0; p_maxTrades = 3;
   p_useMartingale = false;
   p_startTimeSeconds = 0; p_endTimeSeconds = 86399;
}

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   string lower = prompt; StringToLower(lower);

   // 1. Parâmetros Globais
   p_riskPercent = ExtraiNumero(lower, "risco de");
   if(p_riskPercent == 0) p_riskPercent = 1.0;

   p_stopPoints = (int)ExtraiNumero(lower, "stop de");
   if(p_stopPoints == 0) p_stopPoints = 300;

   p_takePoints = (int)ExtraiNumero(lower, "take de");
   if(p_takePoints == 0) p_takePoints = 500;

   p_maxTrades = (int)ExtraiNumero(lower, "máximo");
   if(p_maxTrades == 0) p_maxTrades = 3;

   p_beStart = (int)ExtraiNumero(lower, "atingir +");
   p_bePlus = (int)ExtraiNumero(lower, "entrada +");

   p_trailingStart = (int)ExtraiNumero(lower, "trailing de");

   if(StringFind(lower, "martingale") >= 0) p_useMartingale = true;

   p_frequency = PeriodoTexto(lower);

   // 2. Horários
   string sTime = ExtractTime(lower);
   p_startTimeSeconds = (StringToTime(sTime) % 86400);

   // 3. Regras de Indicadores
   string segments[];
   StringSplit(lower, '.', segments);
   for(int i=0; i<ArraySize(segments); i++) {
      string seg = segments[i];
      Signal currentIntent = NONE;
      if(StringFind(seg, "compra") >= 0) currentIntent = BUY;
      else if(StringFind(seg, "vende") >= 0) currentIntent = SELL;

      // MA Cross
      if(StringFind(seg, "média") >= 0) {
         int p1 = (int)ExtraiNumero(seg, "média de");
         if(p1 == 0) p1 = 20;
         g_rules[g_nRules].active = true;
         g_rules[g_nRules].type = RT_MA_CROSS;
         g_rules[g_nRules].tf = p_frequency;
         g_rules[g_nRules].p1 = p1;
         g_rules[g_nRules].p2 = 0; // Preço
         g_rules[g_nRules].h1 = iMA(_Symbol, p_frequency, p1, 0, MODE_EMA, PRICE_CLOSE);
         g_rules[g_nRules].intent = currentIntent;
         g_nRules++;
      }

      // RSI
      if(StringFind(seg, "rsi") >= 0) {
         int per = (int)ExtraiNumero(seg, "rsi (");
         if(per == 0) per = 14;
         g_rules[g_nRules].active = true;
         g_rules[g_nRules].type = RT_RSI;
         g_rules[g_nRules].tf = p_frequency;
         g_rules[g_nRules].p1 = per;
         g_rules[g_nRules].d1 = ExtraiNumero(seg, "acima de");
         g_rules[g_nRules].d2 = ExtraiNumero(seg, "abaixo de");
         if(g_rules[g_nRules].d1 == 0) g_rules[g_nRules].d1 = 70;
         if(g_rules[g_nRules].d2 == 0) g_rules[g_nRules].d2 = 30;
         g_rules[g_nRules].h1 = iRSI(_Symbol, p_frequency, per, PRICE_CLOSE);
         g_rules[g_nRules].intent = currentIntent;
         g_nRules++;
      }

      // Bollinger
      if(StringFind(seg, "bollinger") >= 0) {
         int per = (int)ExtraiNumero(seg, "bollinger de");
         if(per == 0) per = 20;
         double dev = ExtraiNumero(seg, "desvio");
         if(dev == 0) dev = 2.0;
         g_rules[g_nRules].active = true;
         g_rules[g_nRules].type = RT_BB;
         g_rules[g_nRules].tf = p_frequency;
         g_rules[g_nRules].p1 = per;
         g_rules[g_nRules].d1 = dev;
         g_rules[g_nRules].h1 = iBands(_Symbol, p_frequency, per, 0, dev, PRICE_CLOSE);
         g_rules[g_nRules].intent = currentIntent;
         g_nRules++;
      }

      // Estocástico
      if(StringFind(seg, "estocástico") >= 0 || StringFind(seg, "stoch") >= 0) {
         g_rules[g_nRules].active = true;
         g_rules[g_nRules].type = RT_STOCH;
         g_rules[g_nRules].tf = p_frequency;
         g_rules[g_nRules].h1 = iStochastic(_Symbol, p_frequency, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
         g_rules[g_nRules].intent = currentIntent;
         g_nRules++;
      }
   }

   GravaLog("Prompt interpretado. Regras: " + (string)g_nRules);
}

Signal AvaliaTudo() {
   int buyVotes = 0, sellVotes = 0, filterActive = 0;
   for(int i=0; i<g_nRules; i++) {
      Signal s = EvalRule(i, 1);
      if(g_rules[i].intent == BUY) { if(s == BUY) buyVotes++; else return NONE; }
      else if(g_rules[i].intent == SELL) { if(s == SELL) sellVotes++; else return NONE; }
      else { if(s == BUY) buyVotes++; if(s == SELL) sellVotes++; }
   }
   if(buyVotes > 0 && sellVotes == 0) return BUY;
   if(sellVotes > 0 && buyVotes == 0) return SELL;
   return NONE;
}

void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC && posInfo.Symbol() == _Symbol) {
         double price = (posInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double open = posInfo.PriceOpen();
         double sl = posInfo.StopLoss();
         double tp = posInfo.TakeProfit();

         // Break-even
         if(p_beStart > 0) {
            double profitPoints = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (price - open) : (open - price);
            profitPoints /= _Point;
            if(profitPoints >= p_beStart) {
               double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (open + p_bePlus * _Point) : (open - p_bePlus * _Point);
               if(sl == 0 || (posInfo.PositionType() == POSITION_TYPE_BUY && newSL > sl + 0.5 * _Point) || (posInfo.PositionType() == POSITION_TYPE_SELL && newSL < sl - 0.5 * _Point)) {
                  trade.PositionModify(posInfo.Ticket(), newSL, tp);
               }
            }
         }

         // Trailing
         if(p_trailingStart > 0) {
            double profitPoints = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (price - open) : (open - price);
            profitPoints /= _Point;
            if(profitPoints >= p_trailingStart) {
               double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (price - p_trailingStart * _Point) : (price + p_trailingStart * _Point);
               if(MathAbs(newSL - sl) >= p_trailingStep * _Point) {
                  trade.PositionModify(posInfo.Ticket(), newSL, tp);
               }
            }
         }
      }
   }
}

double GetMartingaleLot(double baseLot) {
   if(!p_useMartingale) return baseLot;
   HistorySelect(TimeCurrent() - 86400, TimeCurrent());
   for(int i=HistoryDealsTotal()-1; i>=0; i--) {
      if(dealInfo.SelectByIndex(i) && dealInfo.Magic() == EA_MAGIC && dealInfo.Symbol() == _Symbol && dealInfo.Entry() == DEAL_ENTRY_OUT) {
         if(dealInfo.Profit() < 0) return baseLot * 2.0;
         else break;
      }
   }
   return baseLot;
}

void OnTick() {
   GravaCSV();
   GerenciaPosicoes();
   if(AguardaNoticias()) return;

   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar != lastBarTime) {
      // Filtro de horário
      long nowSec = TimeCurrent() % 86400;
      if(nowSec >= p_startTimeSeconds && nowSec <= p_endTimeSeconds) {
         Signal s = AvaliaTudo();
         if(s != NONE) {
            double lot = CalculaLote(p_riskPercent, p_stopPoints);
            lot = GetMartingaleLot(lot);
            EnviaOrdem(s, lot);
         }
      }
      lastBarTime = currentBar;
   }
}

int OnInit() {
   EventSetTimer(1);
   trade.SetExpertMagicNumber(EA_MAGIC);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) { EventKillTimer(); }

void OnTimer() {
   static datetime lastPromptCheck = 0;
   if(TimeCurrent() - lastPromptCheck < 1) return;
   lastPromptCheck = TimeCurrent();

   int handle = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      string prompt = "";
      while(!FileIsEnding(handle)) prompt += FileReadString(handle);
      FileClose(handle);

      if(StringLen(prompt) > 0) {
         InterpretaPrompt(prompt);
         // Limpa o arquivo para evitar re-processamento
         handle = FileOpen("prompt.txt", FILE_WRITE|FILE_TXT|FILE_COMMON);
         FileClose(handle);
      }
   }
}
