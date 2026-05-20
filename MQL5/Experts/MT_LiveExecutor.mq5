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

//--- Defines
#define EA_MAGIC 123456
#define MAX_RULES 20
#define LOG_FILE "MT_LiveExecutor_Log.txt"
#define STATE_FILE "MT_LiveExecutor_State.csv"
#define PROMPT_FILE "prompt.txt"
#define NEWS_VETO_FILE "news_veto.txt"
#define CALENDAR_FILE "calendar.txt"

//--- Enums
enum ENUM_RULE_TYPE {
   RT_NONE = 0,
   RT_MA = 1,
   RT_RSI = 2,
   RT_STOCH = 3,
   RT_BB = 4,
   RT_DAILYBREAK = 5,
   RT_DELTA = 6,
   RT_VOL = 7,
   RT_AMA = 8,
   RT_BAR2 = 9,
   RT_RS = 10,
   RT_AI = 11
};

enum Signal { BUY = 1, SELL = -1, NONE = 0 };

//--- Structs
struct Rule {
   bool              active;
   ENUM_RULE_TYPE    type;
   Signal            intent;
   ENUM_TIMEFRAMES   tf;
   int               p1, p2, p3;
   double            d1, d2;
   string            s1;
   int               handle1, handle2;

   void Reset() {
      if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease(handle1);
      if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease(handle2);
      active = false;
      type = RT_NONE;
      intent = NONE;
      tf = PERIOD_CURRENT;
      p1 = 0; p2 = 0; p3 = 0;
      d1 = 0; d2 = 0;
      s1 = "";
      handle1 = INVALID_HANDLE;
      handle2 = INVALID_HANDLE;
   }
};

//--- Global Variables
Rule rules[MAX_RULES];
int nRules = 0;
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symbolInfo;
CAccountInfo accountInfo;

double p_riskPercent = 1.0;
int p_stopPoints = 300;
int p_takePoints = 500;
int p_maxTrades = 3;
bool p_useMartingale = false;
int p_beStart = 0;
int p_bePlus = 0;
int p_trailingStop = 0;
int p_trailingStep = 0;
string p_startTime = "00:00";
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

datetime lastPromptCheck = 0;
datetime lastStateSave = 0;
datetime lastAIUpdate = 0;

//+------------------------------------------------------------------+
//--- NLP Parsing Functions
void InterpretaPrompt(string prompt) {
   for(int i=0; i<MAX_RULES; i++) rules[i].Reset();
   nRules = 0;

   string work = prompt;
   StringToLower(work);

   // Extract global parameters
   double val = ExtraiValorApos(work, "risco");
   if(val > 0) p_riskPercent = val;

   val = ExtraiValorApos(work, "stop");
   if(val > 0) p_stopPoints = (int)val;

   val = ExtraiValorApos(work, "take");
   if(val > 0) p_takePoints = (int)val;

   val = ExtraiValorApos(work, "máximo");
   if(val > 0) p_maxTrades = (int)val;

   if(StringFind(work, "martingale") >= 0) p_useMartingale = true;

   val = ExtraiValorApos(work, "atingir");
   if(val > 0) p_beStart = (int)val;
   val = ExtraiValorApos(work, "entrada");
   if(val > 0) p_bePlus = (int)val;

   if(StringFind(work, "trailing") >= 0) {
      p_trailingStop = (int)ExtraiValorApos(work, "trailing");
      p_trailingStep = 10; // Default step
   }

   // Extract Frequency
   if(StringFind(work, "1 minuto") >= 0 || StringFind(work, "m1") >= 0) p_frequency = PERIOD_M1;
   else if(StringFind(work, "5 minutos") >= 0 || StringFind(work, "m5") >= 0) p_frequency = PERIOD_M5;
   else if(StringFind(work, "15 minutos") >= 0 || StringFind(work, "m15") >= 0) p_frequency = PERIOD_M15;
   else if(StringFind(work, "1 hora") >= 0 || StringFind(work, "h1") >= 0) p_frequency = PERIOD_H1;

   // Extract Start Time
   int startPos = StringFind(work, "depois das");
   if(startPos < 0) startPos = StringFind(work, "início");
   if(startPos < 0) startPos = StringFind(work, "começar");
   if(startPos >= 0) {
      int h=0;
      int searchPos = startPos + 10;
      while(searchPos < StringLen(work) && !((StringGetCharacter(work, searchPos) >= '0' && StringGetCharacter(work, searchPos) <= '9'))) searchPos++;
      h = (int)ExtraiNumero(work, searchPos);
      p_startTime = StringFormat("%02d:00", h);
   }

   // Split by segments and identify intent
   string segments[];
   ushort sep = StringGetCharacter(".", 0);
   int nSeg = StringSplit(work, sep, segments);
   Signal currentIntent = NONE;

   for(int i=0; i<nSeg && nRules < MAX_RULES; i++) {
      string seg = segments[i];
      if(StringFind(seg, "compra") >= 0) currentIntent = BUY;
      else if(StringFind(seg, "vende") >= 0) currentIntent = SELL;

      if(currentIntent == NONE) continue;

      // MA Rule
      if(StringFind(seg, "média") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = RT_MA;
         rules[nRules].intent = currentIntent;
         int pos = 0;
         rules[nRules].p1 = (int)ExtraiNumero(seg, pos);
         if(rules[nRules].p1 == 0) rules[nRules].p1 = 20; // Default
         rules[nRules].tf = p_frequency;
         rules[nRules].handle1 = iMA(_Symbol, rules[nRules].tf, rules[nRules].p1, 0, MODE_SMA, PRICE_CLOSE);
         if(rules[nRules].handle1 != INVALID_HANDLE) nRules++;
      }

      // RSI Rule
      else if(StringFind(seg, "rsi") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = RT_RSI;
         rules[nRules].intent = currentIntent;
         int pos = 0;
         int first = (int)ExtraiNumero(seg, pos);
         int second = (int)ExtraiNumero(seg, pos);
         if(second > 0) {
            rules[nRules].p1 = first;
            rules[nRules].d1 = second;
         } else {
            rules[nRules].p1 = 14;
            rules[nRules].d1 = first;
         }
         rules[nRules].tf = p_frequency;
         rules[nRules].handle1 = iRSI(_Symbol, rules[nRules].tf, rules[nRules].p1, PRICE_CLOSE);
         if(rules[nRules].handle1 != INVALID_HANDLE) nRules++;
      }

      // STOCH Rule
      else if(StringFind(seg, "estocástico") >= 0 || StringFind(seg, "stoch") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = RT_STOCH;
         rules[nRules].intent = currentIntent;
         rules[nRules].tf = p_frequency;
         rules[nRules].handle1 = iStochastic(_Symbol, rules[nRules].tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
         if(rules[nRules].handle1 != INVALID_HANDLE) nRules++;
      }

      // BB Rule
      else if(StringFind(seg, "bollinger") >= 0 || StringFind(seg, "bandas") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = RT_BB;
         rules[nRules].intent = currentIntent;
         rules[nRules].tf = p_frequency;
         rules[nRules].handle1 = iBands(_Symbol, rules[nRules].tf, 20, 0, 2.0, PRICE_CLOSE);
         if(rules[nRules].handle1 != INVALID_HANDLE) nRules++;
      }

      // DAILYBREAK Rule
      else if(StringFind(seg, "máxima") >= 0 || StringFind(seg, "mínima") >= 0 || StringFind(seg, "romper") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = RT_DAILYBREAK;
         rules[nRules].intent = currentIntent;
         rules[nRules].tf = PERIOD_D1;
         nRules++;
      }

      // DELTA Rule
      else if(StringFind(seg, "delta") >= 0 || StringFind(seg, "agressão") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = RT_DELTA;
         rules[nRules].intent = currentIntent;
         rules[nRules].p1 = 60; // 60 seconds
         rules[nRules].p2 = 300; // threshold
         nRules++;
      }

      // VOL Rule
      else if(StringFind(seg, "volume") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = RT_VOL;
         rules[nRules].intent = currentIntent;
         rules[nRules].tf = p_frequency;
         nRules++;
      }

      // AMA Rule
      else if(StringFind(seg, "ama") >= 0 || StringFind(seg, "adaptativa") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = RT_AMA;
         rules[nRules].intent = currentIntent;
         rules[nRules].tf = p_frequency;
         rules[nRules].handle1 = iAMA(_Symbol, rules[nRules].tf, 10, 2, 30, 0, PRICE_CLOSE);
         if(rules[nRules].handle1 != INVALID_HANDLE) nRules++;
      }

      // BAR2 Rule
      else if(StringFind(seg, "padrão") >= 0 || StringFind(seg, "inside") >= 0 || StringFind(seg, "outside") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = RT_BAR2;
         rules[nRules].intent = currentIntent;
         rules[nRules].tf = p_frequency;
         nRules++;
      }

      // RS Rule
      else if(StringFind(seg, "relativa") >= 0 || StringFind(seg, "comparar") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = RT_RS;
         rules[nRules].intent = currentIntent;
         rules[nRules].s1 = "US30";
         rules[nRules].tf = p_frequency;
         rules[nRules].handle1 = iRSI(_Symbol, rules[nRules].tf, 14, PRICE_CLOSE);
         rules[nRules].handle2 = iRSI(rules[nRules].s1, rules[nRules].tf, 14, PRICE_CLOSE);
         if(rules[nRules].handle1 != INVALID_HANDLE && rules[nRules].handle2 != INVALID_HANDLE) nRules++;
      }

      // AI Rule
      else if(StringFind(seg, "ia") >= 0 || StringFind(seg, "inteligência") >= 0 || StringFind(seg, "previsão") >= 0) {
         rules[nRules].active = true;
         rules[nRules].type = RT_AI;
         rules[nRules].intent = currentIntent;
         rules[nRules].tf = p_frequency;
         rules[nRules].handle1 = iATR(_Symbol, rules[nRules].tf, 14);
         if(rules[nRules].handle1 != INVALID_HANDLE) nRules++;
      }
   }
}

double ExtraiNumero(string text, int &pos) {
   string res = "";
   bool found = false;
   while(pos < StringLen(text)) {
      ushort c = StringGetCharacter(text, pos);
      if(c >= '0' && c <= '9') {
         res += ShortToString(c);
         found = true;
      } else if(found) break;
      pos++;
   }
   if(res == "") return 0;
   return StringToDouble(res);
}

double ExtraiValorApos(string text, string keyword) {
   int pos = StringFind(text, keyword);
   if(pos < 0) return 0;
   pos += StringLen(keyword);
   return ExtraiNumero(text, pos);
}

ENUM_TIMEFRAMES PeriodoTexto(string nome) {
   StringToLower(nome);
   if(StringFind(nome, "m15") >= 0) return PERIOD_M15;
   if(StringFind(nome, "m1") >= 0 && StringFind(nome, "m15") < 0) return PERIOD_M1;
   if(StringFind(nome, "m5") >= 0 && StringFind(nome, "m15") < 0) return PERIOD_M5;
   if(StringFind(nome, "h1") >= 0) return PERIOD_H1;
   if(StringFind(nome, "d1") >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

//--- Signal Evaluation Functions
Signal AvaliaTudo() {
   int buyVotes = 0;
   int sellVotes = 0;
   int buyTotal = 0;
   int sellTotal = 0;

   for(int i=0; i<nRules; i++) {
      if(!rules[i].active) continue;
      Signal res = AvaliaRegra(rules[i]);
      if(rules[i].intent == BUY) {
         buyTotal++;
         if(res == BUY) buyVotes++;
      } else if(rules[i].intent == SELL) {
         sellTotal++;
         if(res == SELL) sellVotes++;
      }
   }

   if(buyTotal > 0 && buyVotes == buyTotal) return BUY;
   if(sellTotal > 0 && sellVotes == sellTotal) return SELL;
   return NONE;
}

//--- Trade Execution Functions
void EnviaOrdem(Signal s, string reason) {
   if(s == NONE) return;
   if(PositionsTotal() >= p_maxTrades) return;
   if(AguardaNoticias()) return;
   if(!IsTimeAllowed()) return;

   double lote = CalculaLote(p_riskPercent);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double price = (s == BUY) ? ask : bid;
   double sl = 0, tp = 0;

   if(s == BUY) {
      sl = (p_stopPoints > 0) ? bid - p_stopPoints * _Point : 0;
      tp = (p_takePoints > 0) ? ask + p_takePoints * _Point : 0;
   } else {
      sl = (p_stopPoints > 0) ? ask + p_stopPoints * _Point : 0;
      tp = (p_takePoints > 0) ? bid - p_takePoints * _Point : 0;
   }

   // Margin Check
   double margin;
   if(!OrderCalcMargin((s == BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL), _Symbol, lote, price, margin)) {
      GravaLog("Erro ao calcular margem");
      return;
   }
   if(margin > AccountInfoDouble(ACCOUNT_FREEMARGIN)) {
      GravaLog(StringFormat("Margem insuficiente: precisa %.2f, tem %.2f", margin, AccountInfoDouble(ACCOUNT_FREEMARGIN)));
      return;
   }

   // Retry loop
   for(int i=0; i<3; i++) {
      trade.SetExpertMagicNumber(EA_MAGIC);
      bool res = (s == BUY) ? trade.Buy(lote, _Symbol, price, sl, tp, reason) : trade.Sell(lote, _Symbol, price, sl, tp, reason);
      if(res && trade.ResultRetcode() == TRADE_RETCODE_DONE) {
         GravaLog(StringFormat("Ordem %s executada: %.2f lotes, SL: %.5f, TP: %.5f", (s == BUY ? "BUY" : "SELL"), lote, sl, tp));
         SendNotification(StringFormat("Trade %s: %s", (s == BUY ? "BUY" : "SELL"), reason));
         break;
      } else {
         uint ret = trade.ResultRetcode();
         if(ret == TRADE_RETCODE_REQUOTES || ret == TRADE_RETCODE_OFFQUOTES) {
            ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            price = (s == BUY) ? ask : bid;
            trade.SetDeviationInPoints(30);
            continue;
         }
         GravaLog(StringFormat("Erro ao enviar ordem: %d", ret));
         break;
      }
   }
}

void GerenciaPosicoes() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(posInfo.SelectByIndex(i)) {
         if(posInfo.Magic() != EA_MAGIC || posInfo.Symbol() != _Symbol) continue;

         double curPrice = (posInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double openPrice = posInfo.PriceOpen();
         double profitPoints = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (curPrice - openPrice) / _Point : (openPrice - curPrice) / _Point;

         // Breakeven
         if(p_beStart > 0 && profitPoints >= p_beStart) {
            double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? openPrice + p_bePlus * _Point : openPrice - p_bePlus * _Point;
            if(posInfo.StopLoss() == 0 || (posInfo.PositionType() == POSITION_TYPE_BUY && newSL > posInfo.StopLoss()) || (posInfo.PositionType() == POSITION_TYPE_SELL && newSL < posInfo.StopLoss())) {
               trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
               GravaLog("Breakeven ativado");
            }
         }

         // Trailing Stop
         if(p_trailingStop > 0 && profitPoints >= p_trailingStop) {
            double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? curPrice - p_trailingStop * _Point : curPrice + p_trailingStop * _Point;
            if(posInfo.PositionType() == POSITION_TYPE_BUY) {
               if(newSL > posInfo.StopLoss() + p_trailingStep * _Point) {
                  trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
               }
            } else {
               if(posInfo.StopLoss() == 0 || newSL < posInfo.StopLoss() - p_trailingStep * _Point) {
                  trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
               }
            }
         }
      }
   }
}

double CalculaLote(double risco) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riscoAbs = capital * risco / 100.0;
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   int sl = p_stopPoints;
   if(sl == 0) sl = 300;

   double volume = riscoAbs / (sl * (tickVal / (tickSize / _Point)));

   // Martingale
   if(p_useMartingale) {
      HistorySelect(TimeCurrent() - 86400 * 7, TimeCurrent());
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) volume *= 2.0;
            break;
         }
      }
   }

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   volume = MathFloor(volume / step) * step;
   double min = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(volume < min) volume = min;
   if(volume > max) volume = max;

   return volume;
}

bool IsTimeAllowed() {
   string now = TimeToString(TimeCurrent(), TIME_MINUTES);
   return (now >= p_startTime);
}

//--- Persistence and Monitoring
void GravaCSV() {
   if(TimeCurrent() - lastStateSave < 5) return;
   lastStateSave = TimeCurrent();

   int handle = FileOpen(STATE_FILE, FILE_WRITE | FILE_CSV);
   if(handle != INVALID_HANDLE) {
      FileWrite(handle, "Ticket", "Symbol", "Type", "OpenPrice", "Profit", "SL", "TP");
      for(int i = 0; i < PositionsTotal(); i++) {
         if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC) {
            FileWrite(handle, posInfo.Ticket(), posInfo.Symbol(), posInfo.PositionType(), posInfo.PriceOpen(), posInfo.Profit(), posInfo.StopLoss(), posInfo.TakeProfit());
         }
      }
      FileClose(handle);
   }
}

void GravaLog(string texto) {
   int handle = FileOpen(LOG_FILE, FILE_READ | FILE_WRITE | FILE_TXT);
   if(handle != INVALID_HANDLE) {
      FileSeek(handle, 0, SEEK_END);
      FileWrite(handle, StringFormat("[%s] %s", TimeToString(TimeCurrent()), texto));
      FileClose(handle);
   }
   Print(texto);
}

bool AguardaNoticias() {
   if(FileIsExist(NEWS_VETO_FILE)) {
      int handle = FileOpen(NEWS_VETO_FILE, FILE_READ | FILE_TXT);
      if(handle != INVALID_HANDLE) {
         string content = FileReadString(handle);
         FileClose(handle);
         if(StringFind(content, "true") >= 0) return true;
      }
   }
   // Advanced calendar check logic could go here
   return false;
}

void CalculaStats() {
   HistorySelect(0, TimeCurrent());
   int total = HistoryDealsTotal();
   int wins = 0, losses = 0;
   double profit = 0, drawdown = 0, maxEquity = 0;

   for(int i=0; i<total; i++) {
      ulong t = HistoryDealGetTicket(i);
      if(HistoryDealGetString(t, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC) {
         double p = HistoryDealGetDouble(t, DEAL_PROFIT);
         if(p > 0) wins++;
         else if(p < 0) losses++;
         profit += p;
      }
   }
   double wr = (wins + losses > 0) ? (double)wins / (wins + losses) * 100.0 : 0;
   GravaLog(StringFormat("Stats: WinRate: %.2f%%, Profit: %.2f", wr, profit));
}

void AIOptimizer() {
   if(TimeCurrent() - lastAIUpdate < 3600) return;
   lastAIUpdate = TimeCurrent();

   HistorySelect(TimeCurrent() - 86400, TimeCurrent());
   int total = 0, wins = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0 && total < 10; i--) {
      ulong t = HistoryDealGetTicket(i);
      if(HistoryDealGetString(t, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC) {
         total++;
         if(HistoryDealGetDouble(t, DEAL_PROFIT) > 0) wins++;
      }
   }
   if(total >= 5 && (double)wins / total < 0.4) {
      p_riskPercent *= 0.8;
      GravaLog("AI Optimizer: Reduzindo risco devido a performance baixa.");
   }
}

//--- MQL5 Event Handlers
int OnInit() {
   EventSetTimer(1);
   trade.SetExpertMagicNumber(EA_MAGIC);
   GravaLog("MT-LiveExecutor Iniciado");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   EventKillTimer();
   for(int i=0; i<MAX_RULES; i++) rules[i].Reset();
   GravaLog("MT-LiveExecutor Finalizado");
}

void OnTick() {
   static datetime lastBar = 0;
   datetime curBar = iTime(_Symbol, p_frequency, 0);

   GerenciaPosicoes();
   GravaCSV();

   if(curBar != lastBar) {
      lastBar = curBar;
      Signal s = AvaliaTudo();
      if(s != NONE) EnviaOrdem(s, "Sinal validado por confluence");
   }
}

void OnTimer() {
   // Check for prompt updates
   if(FileIsExist(PROMPT_FILE)) {
      datetime mod = (datetime)FileGetInteger(PROMPT_FILE, FILE_MODIFY_DATE);
      if(mod > lastPromptCheck) {
         lastPromptCheck = mod;
         int handle = FileOpen(PROMPT_FILE, FILE_READ | FILE_TXT);
         if(handle != INVALID_HANDLE) {
            string prompt = FileReadString(handle);
            FileClose(handle);
            InterpretaPrompt(prompt);
            GravaLog("Lógica atualizada via prompt.txt");
         }
      }
   }

   AIOptimizer();
}

Signal AvaliaRegra(Rule &r) {
   double val1[], val2[];
   ArraySetAsSeries(val1, true);
   ArraySetAsSeries(val2, true);

   switch(r.type) {
      case RT_MA:
         if(CopyBuffer(r.handle1, 0, 0, 2, val1) < 2) return NONE;
         double close1 = iClose(_Symbol, r.tf, 1);
         double close2 = iClose(_Symbol, r.tf, 2);
         if(r.intent == BUY && close2 < val1[1] && close1 > val1[0]) return BUY;
         if(r.intent == SELL && close2 > val1[1] && close1 < val1[0]) return SELL;
         break;

      case RT_RSI:
         if(CopyBuffer(r.handle1, 0, 0, 2, val1) < 2) return NONE;
         if(r.intent == BUY && val1[1] < r.d1 && val1[0] > r.d1) return BUY;
         if(r.intent == SELL && val1[1] > r.d1 && val1[0] < r.d1) return SELL;
         break;

      case RT_STOCH:
         if(CopyBuffer(r.handle1, 0, 0, 2, val1) < 2) return NONE; // %K
         if(CopyBuffer(r.handle1, 1, 0, 2, val2) < 2) return NONE; // %D
         if(r.intent == BUY && val1[1] < val2[1] && val1[0] > val2[0]) return BUY;
         if(r.intent == SELL && val1[1] > val2[1] && val1[0] < val2[0]) return SELL;
         break;

      case RT_BB:
         if(CopyBuffer(r.handle1, 1, 0, 2, val1) < 2) return NONE; // Upper
         if(CopyBuffer(r.handle1, 2, 0, 2, val2) < 2) return NONE; // Lower
         double c = iClose(_Symbol, r.tf, 0);
         if(r.intent == BUY && c < val2[0]) return BUY;
         if(r.intent == SELL && c > val1[0]) return SELL;
         break;

      case RT_DAILYBREAK:
         double hi = iHigh(_Symbol, PERIOD_D1, 1);
         double lo = iLow(_Symbol, PERIOD_D1, 1);
         double curr = iClose(_Symbol, PERIOD_M1, 0);
         if(r.intent == BUY && curr > hi) return BUY;
         if(r.intent == SELL && curr < lo) return SELL;
         break;

      case RT_DELTA:
         MqlTick ticks[];
         int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, TimeCurrent() - r.p1, TimeCurrent());
         long buyVol = 0, sellVol = 0;
         for(int i=0; i<n; i++) {
            if((ticks[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buyVol += (long)ticks[i].volume;
            else if((ticks[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sellVol += (long)ticks[i].volume;
         }
         long delta = buyVol - sellVol;
         if(r.intent == BUY && delta > r.p2) return BUY;
         if(r.intent == SELL && delta < -r.p2) return SELL;
         break;

      case RT_VOL:
         long v0 = iVolume(_Symbol, r.tf, 0);
         long v1 = iVolume(_Symbol, r.tf, 1);
         if(v0 > v1 * 1.5) return (r.intent == BUY) ? BUY : SELL;
         break;

      case RT_AMA:
         if(CopyBuffer(r.handle1, 0, 0, 2, val1) < 2) return NONE;
         if(r.intent == BUY && val1[0] > val1[1]) return BUY;
         if(r.intent == SELL && val1[0] < val1[1]) return SELL;
         break;

      case RT_BAR2:
         double h0 = iHigh(_Symbol, r.tf, 0);
         double l0 = iLow(_Symbol, r.tf, 0);
         double h1 = iHigh(_Symbol, r.tf, 1);
         double l1 = iLow(_Symbol, r.tf, 1);
         bool inside = (h0 < h1 && l0 > l1);
         bool outside = (h0 > h1 && l0 < l1);
         if(inside || outside) {
            bool bullish = iClose(_Symbol, r.tf, 0) > iOpen(_Symbol, r.tf, 0);
            if(r.intent == BUY && bullish) return BUY;
            if(r.intent == SELL && !bullish) return SELL;
         }
         break;

      case RT_RS:
         if(CopyBuffer(r.handle1, 0, 0, 1, val1) < 1) return NONE;
         if(CopyBuffer(r.handle2, 0, 0, 1, val2) < 1) return NONE;
         if(r.intent == BUY && val1[0] > val2[0] + 5) return BUY;
         if(r.intent == SELL && val1[0] < val2[0] - 5) return SELL;
         break;

      case RT_AI:
         if(CopyBuffer(r.handle1, 0, 0, 1, val1) < 1) return NONE;
         double body = MathAbs(iClose(_Symbol, r.tf, 1) - iOpen(_Symbol, r.tf, 1));
         if(body > val1[0] * 1.5) {
            bool bull = iClose(_Symbol, r.tf, 1) > iOpen(_Symbol, r.tf, 1);
            if(r.intent == BUY && bull) return BUY;
            if(r.intent == SELL && !bull) return SELL;
         }
         break;
   }
   return NONE;
}
