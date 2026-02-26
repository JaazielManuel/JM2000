//=========================  MT-LiveExecutor  =========================
// Agent: Bolt ⚡ (MT-LiveExecutor)
// Purpose: Real-time strategy interpreter and executor
// Version: 9.0 (Profit Master standard 2026 - AI Enhanced & Corrected)
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// --- Input ---
input string InpPrompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Não operar 20 min antes ou depois de notícias de alto impacto. Máximo 3 trades simultâneos. Ao atingir +30 pontos, move stop para entrada +5 pontos.";

// ---------- 1. BIBLIOTECA COMPLETA DE ENTRADAS ----------
enum Signal {BUY=1, SELL=-1, NONE=0};

double GetPrice(ENUM_SYMBOL_INFO_DOUBLE type) { return SymbolInfoDouble(_Symbol, type); }
double GetClose(int shift, ENUM_TIMEFRAMES tf = PERIOD_CURRENT) {
    double buf[1];
    if(CopyClose(_Symbol, tf, shift, 1, buf) > 0) return buf[0];
    return 0;
}

// ---------- 2. MOTOR DE INTERPRETAÇÃO DE PROMPT ----------

struct StrategyConfig {
   ENUM_TIMEFRAMES timeframe;
   int      startHour;
   int      stopPoints;
   int      takePoints;
   double   riskPercent;
   int      newsVetoMinutes;
   int      maxSimultaneousTrades;
   int      breakevenTrigger;
   int      breakevenProfit;
   int      trailingStopPoints;
   // Stats
   int      totalTrades;
   int      winTrades;
   double   profit;
};

struct Rule {
   bool     active;
   ENUM_TIMEFRAMES tf;
   int      handle;
   int      p1;
   double   d1, d2;
   int      type;
};

#define RULE_MA_PRICE 1
#define RULE_RSI_TREND 2

Rule rules[20];
int nRules = 0;
StrategyConfig config;
CTrade trade;
CPositionInfo posInfo;

// Helper to extract numeric values from string
double ExtractValue(string text, string keyword, int skip) {
    int pos = StringFind(text, keyword);
    if(pos < 0) return 0;
    string sub = StringSubstr(text, pos + skip);
    // Find first digit or decimal
    int i = 0;
    while(i < StringLen(sub) && !((sub[i] >= '0' && sub[i] <= '9') || sub[i] == '.')) i++;
    if(i >= StringLen(sub)) return 0;
    return StringToDouble(StringSubstr(sub, i));
}

void ReleaseRules() {
    for(int i=0; i<nRules; i++) if(rules[i].handle != INVALID_HANDLE) IndicatorRelease(rules[i].handle);
    nRules = 0;
    ZeroMemory(rules);
}

void InterpretaPrompt(string prompt) {
    ReleaseRules();
    ZeroMemory(config);

    GravaLog("Interpretando Prompt...");

    // Timeframe
    config.timeframe = PERIOD_M15;
    if(StringFind(prompt, "1 minuto") >= 0 || StringFind(prompt, "m1") >= 0) config.timeframe = PERIOD_M1;
    if(StringFind(prompt, "5 minutos") >= 0 || StringFind(prompt, "m5") >= 0) config.timeframe = PERIOD_M5;
    if(StringFind(prompt, "1 hora") >= 0 || StringFind(prompt, "h1") >= 0) config.timeframe = PERIOD_H1;

    // Parameters Extraction
    config.startHour = (int)ExtractValue(prompt, "depois das ", 11);
    config.riskPercent = ExtractValue(prompt, "Risco de ", 9);
    config.stopPoints = (int)ExtractValue(prompt, "Stop de ", 8);
    config.takePoints = (int)ExtractValue(prompt, "take de ", 8);
    config.maxSimultaneousTrades = (int)ExtractValue(prompt, "Máximo ", 7);
    config.newsVetoMinutes = (int)ExtractValue(prompt, "notícias", 0); // basic detection
    if(config.newsVetoMinutes == 0 && StringFind(prompt, "20 min") >= 0) config.newsVetoMinutes = 20;

    if(StringFind(prompt, "move stop para entrada") >= 0) {
        config.breakevenTrigger = (int)ExtractValue(prompt, "atingir +", 9);
        config.breakevenProfit = (int)ExtractValue(prompt, "entrada +", 9);
    }

    config.trailingStopPoints = (int)ExtractValue(prompt, "trailing de ", 12);

    // Rules Extraction
    if(StringFind(prompt, "média de") >= 0) {
        int period = (int)ExtractValue(prompt, "média de ", 9);
        if(period == 0) period = 20;
        rules[nRules].active = true;
        rules[nRules].type = RULE_MA_PRICE;
        rules[nRules].p1 = period;
        rules[nRules].tf = config.timeframe;
        rules[nRules].handle = iMA(_Symbol, config.timeframe, period, 0, MODE_EMA, PRICE_CLOSE);
        nRules++;
    }

    if(StringFind(prompt, "RSI") >= 0) {
        int rsiPeriod = (int)ExtractValue(prompt, "RSI (", 5);
        if(rsiPeriod == 0) rsiPeriod = 14;
        rules[nRules].active = true;
        rules[nRules].type = RULE_RSI_TREND;
        rules[nRules].p1 = rsiPeriod;
        rules[nRules].d1 = ExtractValue(prompt, "acima de ", 9);
        rules[nRules].d2 = ExtractValue(prompt, "abaixo de ", 10);
        if(rules[nRules].d1 == 0) rules[nRules].d1 = 55;
        if(rules[nRules].d2 == 0) rules[nRules].d2 = 45;
        rules[nRules].tf = config.timeframe;
        rules[nRules].handle = iRSI(_Symbol, config.timeframe, rsiPeriod, PRICE_CLOSE);
        nRules++;
    }

    GravaLog(StringFormat("Configuração carregada. Regras: %d, TF: %d, Start: %dh, Risk: %.1f%%", nRules, config.timeframe, config.startHour, config.riskPercent));
}

// ---------- 3. DECISÃO FINAL & EXECUÇÃO ----------

Signal AvaliaTudo() {
    int buyVotes = 0, sellVotes = 0;
    int activeRules = 0;

    for(int i=0; i<nRules; i++) {
        if(!rules[i].active) continue;
        activeRules++;

        if(rules[i].type == RULE_MA_PRICE) {
            double ma[2]; // 0: current, 1: previous
            if(CopyBuffer(rules[i].handle, 0, 0, 2, ma) < 2) continue;
            double price = GetClose(0, rules[i].tf);
            double price_p = GetClose(1, rules[i].tf);

            // Correct Crossover: PrevPrice < PrevMA AND CurrentPrice > CurrentMA
            if(price_p < ma[1] && price > ma[0]) buyVotes++;
            else if(price_p > ma[1] && price < ma[0]) sellVotes++;
        }
        else if(rules[i].type == RULE_RSI_TREND) {
            double rsi[2]; // 0: current, 1: previous
            if(CopyBuffer(rules[i].handle, 0, 0, 2, rsi) < 2) continue;

            // Rising above threshold: PrevRSI <= Threshold AND CurrentRSI > Threshold
            if(rsi[1] <= rules[i].d1 && rsi[0] > rules[i].d1) buyVotes++;
            else if(rsi[1] >= rules[i].d2 && rsi[0] < rules[i].d2) sellVotes++;
        }
    }

    if(activeRules > 0 && buyVotes == activeRules) return BUY;
    if(activeRules > 0 && sellVotes == activeRules) return SELL;
    return NONE;
}

double CalculaLote(double riscoPercent) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double stop = (config.stopPoints > 0 ? config.stopPoints : 100) * _Point;
   if(stop == 0) return 0.01;

   double riskAbs = capital * (riscoPercent / 100.0);
   double lot = riskAbs / ((stop / tickSize) * tickValue);

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / step) * step;
   return MathMin(maxLot, MathMax(minLot, lot));
}

void EnviaOrdem(Signal s, double lote) {
   if(s == NONE || lote <= 0) return;
   double ask = GetPrice(SYMBOL_ASK);
   double bid = GetPrice(SYMBOL_BID);
   double sl = 0, tp = 0;

   if(s == BUY) {
      if(config.stopPoints > 0) sl = bid - config.stopPoints * _Point;
      if(config.takePoints > 0) tp = ask + config.takePoints * _Point;
      trade.Buy(lote, _Symbol, ask, sl, tp, "MT-LiveExecutor");
   } else {
      if(config.stopPoints > 0) sl = ask + config.stopPoints * _Point;
      if(config.takePoints > 0) tp = bid - config.takePoints * _Point;
      trade.Sell(lote, _Symbol, bid, sl, tp, "MT-LiveExecutor");
   }
}

void GerenciaPosicoes() {
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(posInfo.SelectByIndex(i)) {
            if(posInfo.Symbol() != _Symbol || posInfo.Comment() != "MT-LiveExecutor") continue;

            double openPrice = posInfo.PriceOpen();
            double currentPrice = (posInfo.PositionType() == POSITION_TYPE_BUY) ? GetPrice(SYMBOL_BID) : GetPrice(SYMBOL_ASK);
            double profitPoints = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (currentPrice - openPrice) / _Point : (openPrice - currentPrice) / _Point;

            // Breakeven logic
            if(config.breakevenTrigger > 0 && profitPoints >= config.breakevenTrigger) {
               double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? openPrice + config.breakevenProfit * _Point : openPrice - config.breakevenProfit * _Point;
               if((posInfo.PositionType() == POSITION_TYPE_BUY && (posInfo.StopLoss() < newSL || posInfo.StopLoss() == 0)) ||
                  (posInfo.PositionType() == POSITION_TYPE_SELL && (posInfo.StopLoss() > newSL || posInfo.StopLoss() == 0))) {
                   trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
               }
            }

            // Trailing Stop logic
            if(config.trailingStopPoints > 0 && profitPoints >= config.trailingStopPoints) {
                double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? GetPrice(SYMBOL_BID) - config.trailingStopPoints * _Point : GetPrice(SYMBOL_ASK) + config.trailingStopPoints * _Point;
                if((posInfo.PositionType() == POSITION_TYPE_BUY && newSL > posInfo.StopLoss() + 5*_Point) ||
                   (posInfo.PositionType() == POSITION_TYPE_SELL && (newSL < posInfo.StopLoss() - 5*_Point || posInfo.StopLoss() == 0))) {
                    trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
                }
            }
        }
    }
}

bool AguardaNoticias() {
    if(config.newsVetoMinutes <= 0) return false;
    MqlCalendarValue values[];
    datetime from = TimeCurrent() - config.newsVetoMinutes * 60;
    datetime to = TimeCurrent() + config.newsVetoMinutes * 60;
    if(CalendarValueHistory(values, from, to, NULL, NULL) > 0) {
        for(int i=0; i<ArraySize(values); i++) if(values[i].impact >= CALENDAR_IMPACT_HIGH) return true;
    }
    return false;
}

void GravaLog(string texto) { PrintFormat("[MT-LiveExecutor] %s", texto); }

// ---------- EVENT HANDLERS ----------

int OnInit() {
   InterpretaPrompt(InpPrompt);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { ReleaseRules(); }

void OnTick() {
   static string lastPrompt = "";
   if(InpPrompt != lastPrompt) { InterpretaPrompt(InpPrompt); lastPrompt = InpPrompt; }

   MqlDateTime dt; TimeCurrent(dt);
   if(dt.hour < config.startHour) return;

   static datetime lastSignalBar = 0;
   datetime currentBar = iTime(_Symbol, config.timeframe, 0);
   if(currentBar == lastSignalBar) { GerenciaPosicoes(); return; }

   if(AguardaNoticias()) return;
   if(PositionsTotal() >= config.maxSimultaneousTrades && config.maxSimultaneousTrades > 0) return;

   Signal s = AvaliaTudo();
   if(s != NONE) {
      double lote = CalculaLote(config.riskPercent);
      EnviaOrdem(s, lote);
      lastSignalBar = currentBar;
   }
   GerenciaPosicoes();
}
