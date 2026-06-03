//+------------------------------------------------------------------+
//|                                              MT_LiveExecutor.mq5 |
//|                                  Copyright 2024, Jules Developer |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Jules Developer"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

//=========================  MT5-KNOWLEDGE-CORE  =========================
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\HistoryOrderInfo.mqh>
#include <Trade\OrderInfo.mqh>

// ---------- 1. DEFINIÇÕES E GLOBAIS ----------
#define EA_MAGIC 123456

enum Signal {BUY=1, SELL=-1, NONE=0};

struct Rule {
   bool     active;
   int      type;   // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: DailyBreak, 6: Aggression, 7: VolCycle, 8: AMA, 9: Bar2, 10: RS
   Signal   intent; // BUY ou SELL associado a esta regra
   int      tf;
   int      p1, p2, p3;
   double   d1, d2;
   string   s1;
   int      handle1, handle2;

   void Reset() {
      if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease(handle1);
      if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease(handle2);
      active = false;
      type = 0;
      intent = NONE;
      tf = PERIOD_CURRENT;
      p1 = 0; p2 = 0; p3 = 0;
      d1 = 0; d2 = 0;
      s1 = "";
      handle1 = INVALID_HANDLE;
      handle2 = INVALID_HANDLE;
   }
};

// Variáveis Globais de Estratégia
Rule rules[20];
int nRules = 0;
double p_risk = 1.0;
int p_stopLoss = 300; // em pontos
int p_takeProfit = 500; // em pontos
int p_maxTrades = 3;
int p_beStart = 0;
int p_bePlus = 0;
int p_trailingStop = 0;
int p_trailingStep = 10;
bool p_martingale = false;
int p_newsVeto = 20; // minutos
string p_startTime = "00:00";
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

// Utilitários
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symInfo;
CAccountInfo accInfo;
datetime lastAI = 0;
datetime lastTickTime = 0;

// ---------- 2. HANDLERS MQL5 ----------

int OnInit() {
   trade.SetExpertMagicNumber(EA_MAGIC);
   symInfo.Name(_Symbol);
   EventSetTimer(1);
   GravaLog("MT-LiveExecutor iniciado.");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   EventKillTimer();
   for(int i=0; i<20; i++) rules[i].Reset();
}

void OnTimer() {
   static datetime lastPromptCheck = 0;
   if(TimeCurrent() - lastPromptCheck >= 1) {
      CheckPromptUpdate();
      lastPromptCheck = TimeCurrent();
   }

   if(TimeCurrent() - lastAI >= 3600) {
      // AIOptimizer placeholder logic
      lastAI = TimeCurrent();
   }
}

void OnTick() {
   if(!IsTimeAllowed()) return;
   if(AguardaNoticias()) return;

   GerenciaPosicoes();

   static datetime lastBar = 0;
   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar != lastBar) {
      Signal s = AvaliaTudo();
      if(s != NONE && PositionsTotal() < p_maxTrades) {
         double lote = CalculaLote(p_risk);
         EnviaOrdem(s, lote);
      }
      lastBar = currentBar;
   }

   static datetime lastCSV = 0;
   if(TimeCurrent() - lastCSV >= 5) {
      GravaCSV();
      lastCSV = TimeCurrent();
   }
}

// ---------- 3. PARSER NLP (InterpretaPrompt) ----------

void CheckPromptUpdate() {
   int handle = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON|FILE_SHARE_READ);
   if(handle != INVALID_HANDLE) {
      string prompt = FileReadString(handle);
      FileClose(handle);
      static string lastPrompt = "";
      if(prompt != lastPrompt && prompt != "") {
         InterpretaPrompt(prompt);
         lastPrompt = prompt;
      }
   }
}

void InterpretaPrompt(string prompt) {
   GravaLog("Interpretando prompt: " + prompt);
   ResetStrategy();

   string lowerPrompt = prompt;
   StringReplace(lowerPrompt, " e ", ".");
   StringReplace(lowerPrompt, ",", ".");

   string segments[];
   StringSplit(lowerPrompt, '.', segments);

   Signal currentIntent = NONE;

   for(int i=0; i<ArraySize(segments); i++) {
      string txt = segments[i];
      StringTrimLeft(txt);
      StringTrimRight(txt);

      // Identificar Intenção
      if(StringFind(txt, "compra") >= 0) currentIntent = BUY;
      else if(StringFind(txt, "vende") >= 0) currentIntent = SELL;

      // Parâmetros Globais
      int cursor = 0;
      if(StringFind(txt, "risco") >= 0) p_risk = ExtraiNumero(txt, StringFind(txt, "risco"), cursor);
      if(StringFind(txt, "stop") >= 0) p_stopLoss = (int)ExtraiNumero(txt, StringFind(txt, "stop"), cursor);
      if(StringFind(txt, "take") >= 0) p_takeProfit = (int)ExtraiNumero(txt, StringFind(txt, "take"), cursor);
      if(StringFind(txt, "máximo") >= 0) p_maxTrades = (int)ExtraiNumero(txt, StringFind(txt, "máximo"), cursor);
      if(StringFind(txt, "atingir") >= 0) p_beStart = (int)ExtraiNumero(txt, StringFind(txt, "atingir"), cursor);
      if(StringFind(txt, "entrada +") >= 0) p_bePlus = (int)ExtraiNumero(txt, StringFind(txt, "entrada +"), cursor);
      if(StringFind(txt, "trailing") >= 0) {
         int c2 = StringFind(txt, "trailing");
         p_trailingStop = (int)ExtraiNumero(txt, c2, cursor);
         p_trailingStep = (int)ExtraiNumero(txt, cursor, cursor);
      }
      if(StringFind(txt, "martingale") >= 0) p_martingale = true;
      if(StringFind(txt, "notícias") >= 0) p_newsVeto = (int)ExtraiNumero(txt, StringFind(txt, "notícias"), cursor);

      if(StringFind(txt, "depois das") >= 0 || StringFind(txt, "início") >= 0) {
         int pos = StringFind(txt, "h");
         if(pos > 0) {
            int h = (int)ExtraiNumero(txt, pos-3, cursor);
            p_startTime = IntegerToString(h, 2, '0') + ":00";
         }
      }

      if(StringFind(txt, "cada") >= 0) {
         p_frequency = PeriodoTexto(txt);
      }

      // Adicionar Regras de Indicadores
      if(currentIntent != NONE) {
         AddRule(txt, currentIntent);
      }
   }
   GravaLog("Configuração: Risk=" + DoubleToString(p_risk, 2) + " SL=" + (string)p_stopLoss + " TP=" + (string)p_takeProfit + " Start=" + p_startTime);
}

void ResetStrategy() {
   for(int i=0; i<20; i++) rules[i].Reset();
   nRules = 0;
   p_risk = 1.0; p_stopLoss = 300; p_takeProfit = 500; p_maxTrades = 3;
   p_beStart = 0; p_bePlus = 0; p_trailingStop = 0; p_trailingStep = 10;
   p_martingale = false; p_newsVeto = 20; p_startTime = "00:00";
   p_frequency = PERIOD_M15;
}

void AddRule(string txt, Signal intent) {
   if(nRules >= 20) return;
   Rule r; r.Reset();
   r.intent = intent;
   r.tf = PeriodoTexto(txt);
   bool match = false;
   int cursor = 0;

   // Média Móvel
   if(StringFind(txt, "média") >= 0) {
      r.type = 1;
      r.p1 = (int)ExtraiNumero(txt, StringFind(txt, "média"), cursor);
      if(r.p1 == 0) r.p1 = 20;
      r.handle1 = iMA(_Symbol, r.tf, r.p1, 0, MODE_SMA, PRICE_CLOSE);
      match = true;
   }
   // RSI
   if(StringFind(txt, "rsi") >= 0) {
      r.type = 2;
      int pos = StringFind(txt, "rsi");
      double v1 = ExtraiNumero(txt, pos + 3, cursor);
      double v2 = ExtraiNumero(txt, cursor, cursor);
      if(v2 == 0) { // Apenas um número encontrado
         if(v1 >= 40) { r.p1 = 14; r.d1 = v1; } // Threshold
         else { r.p1 = (int)v1; r.d1 = (intent == BUY ? 30 : 70); } // Periodo
      } else {
         r.p1 = (int)v1; r.d1 = v2;
      }
      r.handle1 = iRSI(_Symbol, r.tf, r.p1, PRICE_CLOSE);
      match = true;
   }
   // Estocástico
   if(StringFind(txt, "estocástico") >= 0 || StringFind(txt, "stoch") >= 0) {
      r.type = 3;
      r.handle1 = iStochastic(_Symbol, r.tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
      match = true;
   }
   // Bollinger
   if(StringFind(txt, "bollinger") >= 0 || StringFind(txt, "bandas") >= 0) {
      r.type = 4;
      r.handle1 = iBands(_Symbol, r.tf, 20, 0, 2.0, PRICE_CLOSE);
      match = true;
   }

   if(match) {
      if(r.handle1 != INVALID_HANDLE) {
         r.active = true;
         rules[nRules] = r;
         nRules++;
      } else {
         GravaLog("Erro ao criar handle para regra " + (string)r.type);
      }
   }
}

double ExtraiNumero(string txt, int startPos, int &cursor) {
   string res = "";
   bool found = false;
   for(int i = MathMax(0, startPos); i < StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.' || c == ',') {
         res += (c == ',' ? "." : CharToString((char)c));
         found = true;
      } else if(found) {
         cursor = i;
         break;
      }
   }
   if(res == "") return 0;
   return StringToDouble(res);
}

int PeriodoTexto(string txt) {
   if(StringFind(txt, "m15") >= 0) return PERIOD_M15;
   if(StringFind(txt, "m1") >= 0 && StringFind(txt, "m15") < 0) return PERIOD_M1;
   if(StringFind(txt, "m5") >= 0 && StringFind(txt, "m15") < 0) return PERIOD_M5;
   if(StringFind(txt, "h1") >= 0) return PERIOD_H1;
   if(StringFind(txt, "d1") >= 0) return PERIOD_D1;
   if(StringFind(txt, "minutos") >= 0) {
      int cursor = 0;
      int m = (int)ExtraiNumero(txt, StringFind(txt, "minutos") - 5, cursor);
      if(m == 1) return PERIOD_M1;
      if(m == 5) return PERIOD_M5;
      if(m == 15) return PERIOD_M15;
      if(m == 30) return PERIOD_M30;
   }
   return PERIOD_CURRENT;
}

// ---------- 4. MOTOR DE SINAL (AvaliaTudo) ----------

Signal AvaliaTudo() {
   if(nRules == 0) return NONE;

   int buyVotes = 0;
   int sellVotes = 0;
   int activeBuyRules = 0;
   int activeSellRules = 0;

   for(int i=0; i<nRules; i++) {
      if(!rules[i].active) continue;

      Signal res = AvaliaRegra(rules[i]);

      if(rules[i].intent == BUY) {
         activeBuyRules++;
         if(res == BUY) buyVotes++;
      } else if(rules[i].intent == SELL) {
         activeSellRules++;
         if(res == SELL) sellVotes++;
      }
   }

   // Confluência Estrita: Todas as regras de um lado devem concordar
   if(activeBuyRules > 0 && buyVotes == activeBuyRules) return BUY;
   if(activeSellRules > 0 && sellVotes == activeSellRules) return SELL;

   return NONE;
}

Signal AvaliaRegra(Rule &r) {
   double b1[], b2[];
   ArraySetAsSeries(b1, true);
   ArraySetAsSeries(b2, true);

   switch(r.type) {
      case 1: // MA vs Price
         if(CopyBuffer(r.handle1, 0, 0, 2, b1) < 2) return NONE;
         if(r.intent == BUY) {
            if(iClose(_Symbol, r.tf, 1) > b1[0] && iClose(_Symbol, r.tf, 2) <= b1[1]) return BUY;
         } else {
            if(iClose(_Symbol, r.tf, 1) < b1[0] && iClose(_Symbol, r.tf, 2) >= b1[1]) return SELL;
         }
         break;

      case 2: // RSI Threshold
         if(CopyBuffer(r.handle1, 0, 0, 2, b1) < 2) return NONE;
         if(r.intent == BUY) {
            if(b1[0] > r.d1 && b1[1] <= r.d1) return BUY;
         } else {
            if(b1[0] < r.d1 && b1[1] >= r.d1) return SELL;
         }
         break;

      case 3: // Stochastic Cross
         if(CopyBuffer(r.handle1, 0, 0, 2, b1) < 2) return NONE; // Main
         if(CopyBuffer(r.handle1, 1, 0, 2, b2) < 2) return NONE; // Signal
         if(r.intent == BUY) {
            if(b1[0] > b2[0] && b1[1] <= b2[1]) return BUY;
         } else {
            if(b1[0] < b2[0] && b1[1] >= b2[1]) return SELL;
         }
         break;

      case 4: // Bollinger Break
         if(CopyBuffer(r.handle1, 1, 0, 1, b1) < 1) return NONE; // Upper
         if(CopyBuffer(r.handle1, 2, 0, 1, b2) < 1) return NONE; // Lower
         if(r.intent == BUY) {
            if(iClose(_Symbol, r.tf, 1) < b2[0]) return BUY;
         } else {
            if(iClose(_Symbol, r.tf, 1) > b1[0]) return SELL;
         }
         break;
   }
   return NONE;
}

double GetBufferValue(int handle, int buffer, int shift) {
   double res[];
   if(CopyBuffer(handle, buffer, shift, 1, res) > 0) return res[0];
   return 0;
}
// ---------- 5. GESTÃO DE ORDENS E POSIÇÕES ----------

void EnviaOrdem(Signal s, double lote) {
   double sl = 0, tp = 0, preco = 0;
   string tipo = "";

   if(s == BUY) {
      preco = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl = (p_stopLoss > 0) ? preco - p_stopLoss * _Point : 0;
      tp = (p_takeProfit > 0) ? preco + p_takeProfit * _Point : 0;
      tipo = "COMPRA";
   } else if(s == SELL) {
      preco = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl = (p_stopLoss > 0) ? preco + p_stopLoss * _Point : 0;
      tp = (p_takeProfit > 0) ? preco - p_takeProfit * _Point : 0;
      tipo = "VENDA";
   }

   // Check Margin
   double marginReq;
   if(!OrderCalcMargin((s == BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL), _Symbol, lote, preco, marginReq)) {
      GravaLog("Erro ao calcular margem.");
      return;
   }
   if(marginReq > AccountInfoDouble(ACCOUNT_FREEMARGIN)) {
      GravaLog("Margem insuficiente. Requerido: " + DoubleToString(marginReq, 2));
      return;
   }

   bool res = false;
   for(int i=0; i<3; i++) {
      if(s == BUY) res = trade.Buy(lote, _Symbol, preco, sl, tp, "MT-LiveExecutor");
      else res = trade.Sell(lote, _Symbol, preco, sl, tp, "MT-LiveExecutor");

      if(res) break;

      uint code = trade.ResultRetcode();
      if(code == TRADE_RETCODE_REQUOTES || code == TRADE_RETCODE_OFFQUOTES) {
         preco = (s == BUY ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID));
         continue;
      }
      break;
   }

   if(res) {
      GravaLog(tipo + " executada: Lote=" + DoubleToString(lote, 2) + " SL=" + DoubleToString(sl, _Digits) + " TP=" + DoubleToString(tp, _Digits));
      SendNotification("MT-LiveExecutor: " + tipo + " em " + _Symbol);
      SendMail("Trade Executado", "Tipo: " + tipo + "\nSymbol: " + _Symbol + "\nLote: " + DoubleToString(lote, 2));
   } else {
      GravaLog("Erro ao executar " + tipo + ": " + trade.ResultRetcodeDescription());
   }
}

double CalculaLote(double riscoPercent) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = capital * (riscoPercent / 100.0);

   if(p_martingale) {
      HistorySelect(TimeCurrent() - 86400 * 7, TimeCurrent());
      int total = HistoryDealsTotal();
      for(int i = total - 1; i >= 0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) riskAmount *= 2;
            break;
         }
      }
   }

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(p_stopLoss == 0 || tickValue == 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double lossInPoints = p_stopLoss * _Point;
   double lot = riskAmount / ((lossInPoints / tickSize) * tickValue);

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / stepLot) * stepLot;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return NormalizeDouble(lot, 2);
}

void GerenciaPosicoes() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == EA_MAGIC) {
         double priceCurrent = (posInfo.PositionType() == POSITION_TYPE_BUY ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK));
         double openPrice = posInfo.PriceOpen();
         double currentSL = posInfo.StopLoss();
         double profitPoints = (posInfo.PositionType() == POSITION_TYPE_BUY ? (priceCurrent - openPrice) : (openPrice - priceCurrent)) / _Point;

         // Break-even
         if(p_beStart > 0 && profitPoints >= p_beStart) {
            double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY ? openPrice + p_bePlus * _Point : openPrice - p_bePlus * _Point);
            if(currentSL == 0 || (posInfo.PositionType() == POSITION_TYPE_BUY && newSL > currentSL) || (posInfo.PositionType() == POSITION_TYPE_SELL && (newSL < currentSL || currentSL == 0))) {
               trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
               GravaLog("Break-even ajustado para ticket " + (string)posInfo.Ticket());
            }
         }

         // Trailing Stop
         if(p_trailingStop > 0 && profitPoints >= p_trailingStop) {
            double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY ? priceCurrent - p_trailingStop * _Point : priceCurrent + p_trailingStop * _Point);
            if(posInfo.PositionType() == POSITION_TYPE_BUY) {
               if(newSL > currentSL + p_trailingStep * _Point) {
                  trade.PositionModify(posInfo.Ticket(), NormalizeDouble(newSL, _Digits), posInfo.TakeProfit());
               }
            } else {
               if(newSL < currentSL - p_trailingStep * _Point || currentSL == 0) {
                  trade.PositionModify(posInfo.Ticket(), NormalizeDouble(newSL, _Digits), posInfo.TakeProfit());
               }
            }
         }
      }
   }
}

bool IsTimeAllowed() {
   datetime now = TimeCurrent();
   string currentTime = IntegerToString(TimeHour(now), 2, '0') + ":" + IntegerToString(TimeMinute(now), 2, '0');
   if(currentTime < p_startTime) return false;
   return true;
}

bool AguardaNoticias() {
   // news_veto.txt
   int h1 = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(h1 != INVALID_HANDLE) {
      string veto = FileReadString(h1);
      FileClose(h1);
      if(veto == "1" || veto == "true") return true;
   }

   // calendar.txt
   int h2 = FileOpen("calendar.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(h2 != INVALID_HANDLE) {
      while(!FileIsEnding(h2)) {
         string line = FileReadString(h2);
         if(StringFind(line, "High") >= 0 || StringFind(line, "Alto") >= 0) {
            // Simplificação: se houver notícia de alto impacto na linha, checar hora se disponível
            // Aqui assumimos que se a linha está no arquivo, ela é relevante para o momento
            FileClose(h2);
            return true;
         }
      }
      FileClose(h2);
   }

   return false;
}
// ---------- 6. UTILITÁRIOS E ESTATÍSTICAS ----------

void GravaLog(string txt) {
   string msg = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + " | " + txt;
   Print(msg);
   int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_READ|FILE_WRITE|FILE_TXT|FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      FileSeek(handle, 0, SEEK_END);
      FileWrite(handle, msg);
      FileClose(handle);
   }
}

void GravaCSV() {
   int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_COMMON|FILE_ANSI);
   if(handle != INVALID_HANDLE) {
      FileWrite(handle, "Ticket", "Symbol", "Type", "OpenPrice", "SL", "TP", "Profit");
      for(int i = 0; i < PositionsTotal(); i++) {
         if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC) {
            FileWrite(handle, posInfo.Ticket(), posInfo.Symbol(), posInfo.PositionType(),
                      posInfo.PriceOpen(), posInfo.StopLoss(), posInfo.TakeProfit(), posInfo.Profit());
         }
      }
      FileClose(handle);
   }
}

void CalculaStats() {
   HistorySelect(0, TimeCurrent());
   int totalDeals = HistoryDealsTotal();
   int wins = 0, losses = 0;
   double profitFactor = 0, grossProfit = 0, grossLoss = 0;

   for(int i = 0; i < totalDeals; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
         double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         if(profit > 0) { wins++; grossProfit += profit; }
         else if(profit < 0) { losses++; grossLoss += MathAbs(profit); }
      }
   }

   double winRate = (wins + losses > 0) ? (double)wins / (wins + losses) * 100.0 : 0;
   profitFactor = (grossLoss > 0) ? grossProfit / grossLoss : grossProfit;

   GravaLog("Estatísticas: WinRate=" + DoubleToString(winRate, 1) + "% Trades=" + (string)(wins+losses) + " PF=" + DoubleToString(profitFactor, 2));
}
