//=========================  MT-LiveExecutor  =========================
// Módulo único para execução de estratégias via Prompt em Português
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// ---------- DEFINIÇÕES E ENUMS ----------
enum Signal { BUY = 1, SELL = -1, NONE = 0 };

enum RuleType {
   RULE_MA_CROSS,
   RULE_RSI,
   RULE_STOCH,
   RULE_BB,
   RULE_DAILY_BREAK,
   RULE_DELTA,
   RULE_VOL_CYCLE,
   RULE_AMA,
   RULE_BAR_PATTERN,
   RULE_RELATIVE
};

struct Rule {
   bool      active;
   RuleType  type;
   ENUM_TIMEFRAMES tf;
   int       p1, p2, p3;
   double    d1, d2;
   string    s1;
   int       p1_handle, p2_handle, p3_handle; // Handles de indicadores
   Signal    intent; // BUY ou SELL
   bool      is_cross;
};

// ---------- VARIÁVEIS GLOBAIS ----------
#define EA_MAGIC 20260101
#define MAX_RULES 30

Rule rules[MAX_RULES];
int nRules = 0;

// Parâmetros operacionais (populados pelo prompt)
double p_riskPercent = 1.0;
int    p_stopPoints = 0;
int    p_takePoints = 0;
int    p_breakEvenPoints = 0;
int    p_breakEvenLock = 0;
int    p_trailingStopPoints = 0;
int    p_maxTrades = 3;
int    p_newsVetoMins = 0;
long   p_startTimeSeconds = 0; // Segundos desde meia-noite
bool   p_useMartingale = false;
bool   p_hedge = false;
ENUM_TIMEFRAMES p_mainTF = PERIOD_M15;

// Estado interno
datetime lastBarTime = 0;
int dynamicSafetyPoints = 0;
datetime lastSafetyDecay = 0;
datetime lastCSVWrite = 0;

CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symbolInfo;
CAccountInfo accountInfo;

// ---------- PROTÓTIPOS ----------
void InterpretaPrompt(string prompt);
Signal AvaliaTudo();
double CalculaLote(double riscoPercent);
void EnviaOrdem(Signal s, double risco);
void executaSignal(Signal s, double risco);
void GerenciaPosicoes();
bool AguardaNoticias();
void GravaCSV();
void ResetStrategy();
void AIOptimizer();
int PeriodoTexto(string nome);
double ExtractNumber(string txt, string keyword);
string ExtractTime(string txt, string keyword);
void AddRule(RuleType type, Signal intent, ENUM_TIMEFRAMES tf, int p1=0, int p2=0, double d1=0, double d2=0, bool is_cross=false);

// ---------- UTILITIES ----------
int PeriodoTexto(string nome) {
   StringToLower(nome);
   if(StringFind(nome,"m15")>=0) return PERIOD_M15;
   if(StringFind(nome,"m30")>=0) return PERIOD_M30;
   if(StringFind(nome,"m1")>=0)  return PERIOD_M1;
   if(StringFind(nome,"m5")>=0)  return PERIOD_M5;
   if(StringFind(nome,"h1")>=0)  return PERIOD_H1;
   if(StringFind(nome,"d1")>=0)  return PERIOD_D1;
   return PERIOD_CURRENT;
}

double ExtractNumber(string txt, string keyword) {
   int pos = StringFind(txt, keyword);
   if(pos < 0) return 0;
   string sub = StringSubstr(txt, pos + StringLen(keyword));
   string res = "";
   bool found = false;
   for(int i=0; i<StringLen(sub); i++) {
      ushort c = StringGetCharacter(sub, i);
      if((c >= '0' && c <= '9') || c == '.') {
         res += StringSubstr(sub, i, 1);
         found = true;
      } else if(found) break;
   }
   return StringToDouble(res);
}

string ExtractTime(string txt, string keyword) {
   int pos = StringFind(txt, keyword);
   if(pos < 0) return "";
   string sub = StringSubstr(txt, pos + StringLen(keyword));
   StringTrimLeft(sub);
   string res = "";
   for(int i=0; i<StringLen(sub); i++) {
      ushort c = StringGetCharacter(sub, i);
      if((c >= '0' && c <= '9') || c == ':' || c == 'h') {
         res += StringSubstr(sub, i, 1);
      } else break;
   }
   StringReplace(res, "h", ":");
   if(StringFind(res, ":") == StringLen(res) - 1) res += "00";
   return res;
}

void ResetStrategy() {
   for(int i=0; i<nRules; i++) {
      if(rules[i].p1_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p1_handle);
      if(rules[i].p2_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p2_handle);
      if(rules[i].p3_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p3_handle);
      rules[i].active = false;
   }
   nRules = 0;
   p_riskPercent = 1.0; p_stopPoints = 0; p_takePoints = 0;
   p_breakEvenPoints = 0; p_breakEvenLock = 0; p_trailingStopPoints = 0;
   p_maxTrades = 3; p_newsVetoMins = 0; p_startTimeSeconds = 0;
   p_useMartingale = false; p_hedge = false;
}

void AddRule(RuleType type, Signal intent, ENUM_TIMEFRAMES tf, int p1=0, int p2=0, double d1=0, double d2=0, bool is_cross=false) {
   if(nRules >= MAX_RULES) return;

   // Tenta atualizar regra existente do mesmo tipo e intenção
   for(int i=0; i<nRules; i++) {
      if(rules[i].type == type && rules[i].intent == intent && rules[i].tf == tf) {
         if(p1 != 0) rules[i].p1 = p1;
         if(p2 != 0) rules[i].p2 = p2;
         if(d1 != 0) rules[i].d1 = d1;
         if(d2 != 0) rules[i].d2 = d2;
         rules[i].is_cross = is_cross;
         return;
      }
   }

   rules[nRules].active = true;
   rules[nRules].type = type;
   rules[nRules].tf = tf;
   rules[nRules].p1 = p1;
   rules[nRules].p2 = p2;
   rules[nRules].d1 = d1;
   rules[nRules].d2 = d2;
   rules[nRules].intent = intent;
   rules[nRules].is_cross = is_cross;
   rules[nRules].p1_handle = INVALID_HANDLE;
   rules[nRules].p2_handle = INVALID_HANDLE;
   rules[nRules].p3_handle = INVALID_HANDLE;

   // Inicializa handles
   if(type == RULE_MA_CROSS) {
      rules[nRules].p1_handle = iMA(_Symbol, tf, p1, 0, MODE_EMA, PRICE_CLOSE);
      if(p2 != 0) rules[nRules].p2_handle = iMA(_Symbol, tf, p2, 0, MODE_EMA, PRICE_CLOSE);
   } else if(type == RULE_RSI) {
      rules[nRules].p1_handle = iRSI(_Symbol, tf, p1, PRICE_CLOSE);
   } else if(type == RULE_STOCH) {
      rules[nRules].p1_handle = iStochastic(_Symbol, tf, p1, p2, 3, MODE_SMA, STO_LOWHIGH);
   } else if(type == RULE_BB) {
      rules[nRules].p1_handle = iBands(_Symbol, tf, p1, 0, d1, PRICE_CLOSE);
   }

   nRules++;
}

// ---------- MOTOR DE INTERPRETAÇÃO ----------
void InterpretaPrompt(string prompt) {
   ResetStrategy();
   string work = prompt;
   StringReplace(work, " e ", "|");
   StringReplace(work, " + ", "|");
   StringReplace(work, ". ", "|");

   string segments[];
   int nSeg = StringSplit(work, '|', segments);

   Signal currentIntent = NONE;
   ENUM_TIMEFRAMES currentTF = p_mainTF;

   for(int i=0; i<nSeg; i++) {
      string s = segments[i];
      StringToLower(s);

      if(StringFind(s, "compra") >= 0) currentIntent = BUY;
      if(StringFind(s, "vende") >= 0)  currentIntent = SELL;

      int tf_seg = PeriodoTexto(s);
      if(tf_seg != PERIOD_CURRENT) {
         currentTF = (ENUM_TIMEFRAMES)tf_seg;
         if(i==0) p_mainTF = currentTF;
      }

      // Indicadores
      if(StringFind(s, "média") >= 0) {
         int p1 = 0, p2 = 0;
         if(StringFind(s, "/") > 0) {
            string m_parts[];
            StringSplit(s, ' ', m_parts);
            for(int j=0; j<ArraySize(m_parts); j++) {
               if(StringFind(m_parts[j], "/") > 0) {
                  string subs[];
                  StringSplit(m_parts[j], '/', subs);
                  p1 = (int)StringToInteger(subs[0]);
                  p2 = (int)StringToInteger(subs[1]);
                  break;
               }
            }
         }
         if(p1 == 0) p1 = (int)ExtractNumber(s, "média de ");
         if(p1 == 0) p1 = 20;
         bool cross = (StringFind(s, "cruzar") >= 0);
         AddRule(RULE_MA_CROSS, currentIntent, currentTF, p1, p2, 0, 0, cross);
      }

      if(StringFind(s, "rsi") >= 0) {
         int per = (int)ExtractNumber(s, "rsi (");
         if(per == 0) per = (int)ExtractNumber(s, "rsi ");
         if(per == 0) per = 14;
         double threshold = ExtractNumber(s, "acima de ");
         if(threshold == 0) threshold = ExtractNumber(s, "abaixo de ");
         bool cross = (StringFind(s, "subir") >= 0 || StringFind(s, "cair") >= 0);
         AddRule(RULE_RSI, currentIntent, currentTF, per, 0, threshold, 0, cross);
      }

      // Parâmetros operacionais
      if(StringFind(s, "stop de") >= 0) p_stopPoints = (int)ExtractNumber(s, "stop de ");
      if(StringFind(s, "take de") >= 0) p_takePoints = (int)ExtractNumber(s, "take de ");
      if(StringFind(s, "risco de") >= 0) p_riskPercent = ExtractNumber(s, "risco de ");
      if(StringFind(s, "máximo") >= 0) p_maxTrades = (int)ExtractNumber(s, "máximo ");
      if(StringFind(s, "depois das") >= 0) {
         string t = ExtractTime(s, "depois das ");
         p_startTimeSeconds = StringToTime(t) % 86400;
      }
      if(StringFind(s, "notícias") >= 0) p_newsVetoMins = (int)ExtractNumber(s, "operar ");
      if(StringFind(s, "move stop") >= 0) {
         p_breakEvenPoints = (int)ExtractNumber(s, "atingir +");
         p_breakEvenLock = (int)ExtractNumber(s, "entrada +");
      }
      if(StringFind(s, "martingale") >= 0) p_useMartingale = true;
      if(StringFind(s, "hedge") >= 0) p_hedge = true;
   }
}

// ---------- AVALIAÇÃO DE REGRAS ----------
Signal AvaliaRegra(int index) {
   Rule r = rules[index];
   if(!r.active) return NONE;

   double buffer0[], buffer1[];
   ArraySetAsSeries(buffer0, true);
   ArraySetAsSeries(buffer1, true);

   if(r.type == RULE_MA_CROSS) {
      if(CopyBuffer(r.p1_handle, 0, 0, 2, buffer0) < 2) return NONE;

      if(r.p2_handle != INVALID_HANDLE) {
         if(CopyBuffer(r.p2_handle, 0, 0, 2, buffer1) < 2) return NONE;
         if(r.is_cross) {
            if(buffer0[1] < buffer1[1] && buffer0[0] > buffer1[0]) return BUY;
            if(buffer0[1] > buffer1[1] && buffer0[0] < buffer1[0]) return SELL;
         } else {
            if(buffer0[0] > buffer1[0]) return BUY;
            if(buffer0[0] < buffer1[0]) return SELL;
         }
      } else {
         double price0 = iClose(_Symbol, r.tf, 0);
         double price1 = iClose(_Symbol, r.tf, 1);
         if(r.is_cross) {
            if(price1 < buffer0[1] && price0 > buffer0[0]) return BUY;
            if(price1 > buffer0[1] && price0 < buffer0[0]) return SELL;
         } else {
            if(price0 > buffer0[0]) return BUY;
            if(price0 < buffer0[0]) return SELL;
         }
      }
   }

   if(r.type == RULE_RSI) {
      if(CopyBuffer(r.p1_handle, 0, 0, 2, buffer0) < 2) return NONE;
      if(r.is_cross) {
         if(buffer0[1] < r.d1 && buffer0[0] > r.d1) return (r.intent == BUY ? BUY : NONE);
         if(buffer0[1] > r.d1 && buffer0[0] < r.d1) return (r.intent == SELL ? SELL : NONE);
      } else {
         if(r.intent == BUY && buffer0[0] > r.d1) return BUY;
         if(r.intent == SELL && buffer0[0] < r.d1) return SELL;
      }
   }

   if(r.type == RULE_STOCH) {
      if(CopyBuffer(r.p1_handle, 0, 0, 2, buffer0) < 2) return NONE; // %K
      if(CopyBuffer(r.p1_handle, 1, 0, 2, buffer1) < 2) return NONE; // %D
      if(r.is_cross) {
         if(buffer0[1] < buffer1[1] && buffer0[0] > buffer1[0]) return BUY;
         if(buffer0[1] > buffer1[1] && buffer0[0] < buffer1[0]) return SELL;
      } else {
         if(buffer0[0] < 20) return BUY;
         if(buffer0[0] > 80) return SELL;
      }
   }

   if(r.type == RULE_BB) {
      if(CopyBuffer(r.p1_handle, 1, 0, 1, buffer0) < 1) return NONE; // Upper
      if(CopyBuffer(r.p1_handle, 2, 0, 1, buffer1) < 1) return NONE; // Lower
      double price = iClose(_Symbol, r.tf, 0);
      if(price < buffer1[0]) return BUY;
      if(price > buffer0[0]) return SELL;
   }

   return NONE;
}

Signal AvaliaTudo() {
   int buy_votos = 0;
   int sell_votos = 0;
   int buy_total = 0;
   int sell_total = 0;

   for(int i=0; i<nRules; i++) {
      Signal s = AvaliaRegra(i);
      if(rules[i].intent == BUY) {
         buy_total++;
         if(s == BUY) buy_votos++;
      } else if(rules[i].intent == SELL) {
         sell_total++;
         if(s == SELL) sell_votos++;
      }
   }

   if(buy_total > 0 && buy_votos == buy_total) return BUY;
   if(sell_total > 0 && sell_votos == sell_total) return SELL;

   return NONE;
}

// ---------- EXECUÇÃO E GESTÃO ----------
double CalculaLote(double riscoPercent) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riscoAbs = capital * riscoPercent / 100.0;

   if(p_useMartingale) {
      if(HistorySelect(TimeCurrent() - 86400, TimeCurrent())) {
         int total = HistoryDealsTotal();
         for(int i = total - 1; i >= 0; i--) {
            ulong ticket = HistoryDealGetTicket(i);
            if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol &&
               HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
               double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
               if(profit < 0) riscoAbs *= 2;
               break;
            }
         }
      }
   }

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   int slPoints = (p_stopPoints > 0) ? p_stopPoints : 300;

   double volume = riscoAbs / (slPoints * (tickValue / (tickSize / _Point)));
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   volume = MathFloor(volume / stepLot) * stepLot;
   return MathMax(minLot, MathMin(maxLot, volume));
}

void EnviaOrdem(Signal s, double risco) {
   if(s == NONE) return;

   if(!p_hedge) {
      for(int i = PositionsTotal() - 1; i >= 0; i--) {
         if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == EA_MAGIC) {
            if((s == BUY && posInfo.PositionType() == POSITION_TYPE_SELL) ||
               (s == SELL && posInfo.PositionType() == POSITION_TYPE_BUY)) {
               trade.PositionClose(posInfo.Ticket());
            }
         }
      }
   }

   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++) {
      if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == EA_MAGIC) count++;
   }
   if(count >= p_maxTrades) return;

   double lote = CalculaLote(risco);
   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double stopsLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double safetyBuffer = (stopsLevel + dynamicSafetyPoints + 1) * _Point;

   double sl = 0, tp = 0;
   if(s == BUY) {
      if(p_stopPoints > 0) sl = price - MathMax(p_stopPoints * _Point, safetyBuffer);
      if(p_takePoints > 0) tp = price + p_takePoints * _Point;
      trade.SetExpertMagicNumber(EA_MAGIC);
      trade.Buy(lote, _Symbol, price, sl, tp, "MT-LiveExecutor BUY");
   } else {
      if(p_stopPoints > 0) sl = price + MathMax(p_stopPoints * _Point, safetyBuffer);
      if(p_takePoints > 0) tp = price - p_takePoints * _Point;
      trade.SetExpertMagicNumber(EA_MAGIC);
      trade.Sell(lote, _Symbol, price, sl, tp, "MT-LiveExecutor SELL");
   }

   if(trade.ResultRetcode() == TRADE_RETCODE_REQUOTE || trade.ResultRetcode() == TRADE_RETCODE_PRICE_OFF) {
      dynamicSafetyPoints = MathMin(dynamicSafetyPoints + 5, 100);
   }
}

void GerenciaPosicoes() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == EA_MAGIC) {
         double price = posInfo.PriceOpen();
         double current = (posInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double diff = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (current - price) : (price - current);
         int points = (int)(diff / _Point);

         // Break-even
         if(p_breakEvenPoints > 0 && points >= p_breakEvenPoints) {
            double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (price + p_breakEvenLock * _Point) : (price - p_breakEvenLock * _Point);
            if(posInfo.StopLoss() == 0 || (posInfo.PositionType() == POSITION_TYPE_BUY && newSL > posInfo.StopLoss()) || (posInfo.PositionType() == POSITION_TYPE_SELL && (newSL < posInfo.StopLoss() || posInfo.StopLoss() == 0))) {
               trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
            }
         }

         // Trailing Stop (simplificado)
         if(p_trailingStopPoints > 0 && points >= p_trailingStopPoints) {
            double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (current - p_trailingStopPoints * _Point) : (current + p_trailingStopPoints * _Point);
            if((posInfo.PositionType() == POSITION_TYPE_BUY && newSL > posInfo.StopLoss()) || (posInfo.PositionType() == POSITION_TYPE_SELL && (newSL < posInfo.StopLoss() || posInfo.StopLoss() == 0))) {
               trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
            }
         }
      }
   }
}

bool AguardaNoticias() {
   // Veto manual via arquivo
   string path = "news_veto.txt";
   int handle = FileOpen(path, FILE_READ | FILE_TXT | FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      string val = FileReadString(handle);
      FileClose(handle);
      if(val == "1") return true;
   }

   // Fallback: Calendário Nativo MT5
   if(p_newsVetoMins > 0) {
      MqlCalendarValue values[];
      datetime from = TimeCurrent() - p_newsVetoMins * 60;
      datetime to = TimeCurrent() + p_newsVetoMins * 60;

      if(CalendarValueHistory(values, from, to)) {
         for(int i = 0; i < ArraySize(values); i++) {
            MqlCalendarEvent event;
            if(CalendarEventById(values[i].event_id, event)) {
               if(event.importance == CALENDAR_IMPORTANCE_HIGH) return true;
            }
         }
      }
   }

   return false;
}

void GravaCSV() {
   if(TimeCurrent() - lastCSVWrite < 5) return;
   lastCSVWrite = TimeCurrent();

   string path = "MT_LiveExecutor_State.csv";
   int handle = FileOpen(path, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      FileWrite(handle, "Ticket", "Symbol", "Type", "OpenPrice", "SL", "TP", "Profit");
      for(int i = 0; i < PositionsTotal(); i++) {
         if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC) {
            FileWrite(handle, posInfo.Ticket(), posInfo.Symbol(), posInfo.PositionType(), posInfo.PriceOpen(), posInfo.StopLoss(), posInfo.TakeProfit(), posInfo.Profit());
         }
      }
      FileClose(handle);
   }
}

void AIOptimizer() {
   if(HistorySelect(0, TimeCurrent())) {
      int total = HistoryDealsTotal();
      int wins = 0, losses = 0;
      double profit = 0, loss = 0;
      for(int i = 0; i < total; i++) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            double res = HistoryDealGetDouble(ticket, DEAL_PROFIT) + HistoryDealGetDouble(ticket, DEAL_COMMISSION) + HistoryDealGetDouble(ticket, DEAL_SWAP);
            if(res > 0) { wins++; profit += res; }
            else if(res < 0) { losses++; loss -= res; }
         }
      }
      double winRate = (wins + losses > 0) ? (double)wins / (wins + losses) : 0;
      double pf = (loss > 0) ? profit / loss : 0;

      // Heurística de Otimização IA
      if(wins + losses >= 10) {
         if(winRate < 0.40) p_riskPercent = MathMax(0.5, p_riskPercent * 0.9);
         else if(winRate > 0.60 && pf > 1.5) p_riskPercent = MathMin(2.0, p_riskPercent * 1.1);
      }

      if(winRate < 0.30 && (wins + losses) > 5) {
         SendNotification("MT-LiveExecutor: Alerta de Performance. Win Rate crítico: " + DoubleToString(winRate*100, 2) + "%");
      }
   }
}

// ---------- HANDLERS ----------
int OnInit() {
   EventSetTimer(1);
   lastSafetyDecay = TimeCurrent();

   string path = "MT_LiveExecutor_Prompt.txt";
   int handle = FileOpen(path, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      string prompt = FileReadString(handle, (int)FileSize(handle));
      FileClose(handle);
      InterpretaPrompt(prompt);
   }

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   ResetStrategy();
   EventKillTimer();
}

void OnTimer() {
   AIOptimizer();
   // Mecanismo de atualização sem reiniciar
   if(GlobalVariableCheck("MT_Executor_Prompt_Update") && GlobalVariableGet("MT_Executor_Prompt_Update") > 0) {
      string path = "MT_LiveExecutor_Prompt.txt";
      int handle = FileOpen(path, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
      if(handle != INVALID_HANDLE) {
         string prompt = FileReadString(handle, (int)FileSize(handle));
         FileClose(handle);
         InterpretaPrompt(prompt);
         GlobalVariableSet("MT_Executor_Prompt_Update", 0);
      }
   }

   // Decay do safety buffer
   if(TimeCurrent() - lastSafetyDecay >= 60) {
      if(dynamicSafetyPoints > 0) dynamicSafetyPoints--;
      lastSafetyDecay = TimeCurrent();
   }
}

void OnTick() {
   GerenciaPosicoes();
   GravaCSV();

   if(AguardaNoticias()) return;

   datetime currentBar = iTime(_Symbol, p_mainTF, 0);
   if(currentBar != lastBarTime) {
      long nowSec = TimeCurrent() % 86400;
      if(nowSec >= p_startTimeSeconds) {
         Signal s = AvaliaTudo();
         if(s != NONE) {
            executaSignal(s, p_riskPercent);
            lastBarTime = currentBar;
         }
      }
   }
}

void executaSignal(Signal s, double risco) {
   EnviaOrdem(s, risco);
}
