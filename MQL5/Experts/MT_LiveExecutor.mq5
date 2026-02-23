//=========================  MT-LiveExecutor  =========================
// Real-time strategy interpreter for MetaTrader 5
// Translated from Portuguese natural language prompts
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// ---------- INPUTS ----------
input string InpPrompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Não operar 20 min antes ou depois de notícias de alto impacto. Máximo 3 trades simultâneos. Ao atingir +30 pontos, move stop para entrada +5 pontos.";

// ---------- ENUMS & STRUCTS ----------
enum ENUM_SIGNAL { SIGNAL_NONE = 0, SIGNAL_BUY = 1, SIGNAL_SELL = -1 };

struct Rule {
    bool active;
    int type;
    ENUM_TIMEFRAMES timeframe;
    int p1, p2, p3;
    double d1, d2;
    string s1;
    int handle;
};

struct StrategyRules {
    Rule rules[20];
    int nRules;
    ENUM_TIMEFRAMES interval;
    int startHour;
    double riskPercent;
    int stopLossPoints;
    int takeProfitPoints;
    int maxTrades;
    int newsVetoMinutes;
    int breakevenTriggerPoints;
    int breakevenProfitPoints;
};

// ---------- GLOBAL VARIABLES ----------
StrategyRules currentStrategy;
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symbolInfo;
CAccountInfo accountInfo;
string currentPrompt = "";
datetime lastExecutionTime = 0;

// ---------- BASE CORE FUNCTIONS ----------

// Price vs MA Cross
ENUM_SIGNAL PriceCrossMA(int &handle, int period, ENUM_TIMEFRAMES tf, int shift) {
    if (handle == INVALID_HANDLE) handle = iMA(_Symbol, tf, period, 0, MODE_SMA, PRICE_CLOSE);

    double ma[], close[];
    ArraySetAsSeries(ma, true); ArraySetAsSeries(close, true);

    if (CopyBuffer(handle, 0, shift, 2, ma) < 2) return SIGNAL_NONE;
    if (CopyClose(_Symbol, tf, shift, 2, close) < 2) return SIGNAL_NONE;

    if (close[1] < ma[1] && close[0] > ma[0]) return SIGNAL_BUY;
    if (close[1] > ma[1] && close[0] < ma[0]) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

// RSI Level Check
ENUM_SIGNAL RSICheck(int &handle, int period, double buyLevel, double sellLevel, ENUM_TIMEFRAMES tf, int shift) {
    if (handle == INVALID_HANDLE) handle = iRSI(_Symbol, tf, period, PRICE_CLOSE);

    double rsi[];
    ArraySetAsSeries(rsi, true);
    if (CopyBuffer(handle, 0, shift, 1, rsi) < 1) return SIGNAL_NONE;

    if (rsi[0] > buyLevel) return SIGNAL_BUY;
    if (rsi[0] < sellLevel) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

// ---------- INTERPRETER ----------

double GetNextNumber(string text, int startPos) {
    string res = ""; bool started = false;
    for(int i=startPos; i<StringLen(text); i++) {
        ushort c = StringGetCharacter(text, i);
        if(c >= '0' && c <= '9' || c == '.') { res += StringSubstr(text, i, 1); started = true; }
        else if(started) break;
    }
    return StringToDouble(res);
}

void InterpretaPrompt(string prompt) {
    StringToLower(prompt);

    // Release existing handles
    for (int i = 0; i < currentStrategy.nRules; i++) {
        if (currentStrategy.rules[i].handle != INVALID_HANDLE) IndicatorRelease(currentStrategy.rules[i].handle);
    }

    ZeroMemory(currentStrategy);
    currentStrategy.maxTrades = 1; // Default

    Print("MT-LiveExecutor: Interpretando prompt: ", prompt);

    // Timeframe
    if (StringFind(prompt, "15 min") >= 0) currentStrategy.interval = PERIOD_M15;
    else if (StringFind(prompt, "5 min") >= 0) currentStrategy.interval = PERIOD_M5;
    else if (StringFind(prompt, "1 min") >= 0) currentStrategy.interval = PERIOD_M1;
    else currentStrategy.interval = PERIOD_CURRENT;

    // Start Hour
    int pos = StringFind(prompt, "depois das ");
    if (pos >= 0) currentStrategy.startHour = (int)GetNextNumber(prompt, pos + 11);

    // Signals - Price vs MA
    pos = StringFind(prompt, "média de ");
    if (pos >= 0) {
        int period = (int)GetNextNumber(prompt, pos + 9);
        if (period > 0) {
            Rule r; r.handle = INVALID_HANDLE;
            r.active = true; r.type = 1; r.p1 = period; r.timeframe = currentStrategy.interval;
            currentStrategy.rules[currentStrategy.nRules++] = r;
            Print("Regra Adicionada: Preço vs MA(", period, ")");
        }
    }

    // Signals - RSI
    pos = StringFind(prompt, "rsi");
    if (pos >= 0) {
        Rule r; r.handle = INVALID_HANDLE;
        r.active = true; r.type = 2; r.p1 = (int)GetNextNumber(prompt, pos + 3);
        if (r.p1 <= 0) r.p1 = 14; // Default
        r.d1 = 55; r.d2 = 45; // Defaults

        int pAbove = StringFind(prompt, "acima de ", pos);
        if (pAbove >= 0) r.d1 = GetNextNumber(prompt, pAbove + 9);

        int pBelow = StringFind(prompt, "abaixo de ", pos);
        if (pBelow >= 0) r.d2 = GetNextNumber(prompt, pBelow + 10);

        r.timeframe = currentStrategy.interval;
        currentStrategy.rules[currentStrategy.nRules++] = r;
        PrintFormat("Regra Adicionada: RSI(%d) níveis %.1f/%.1f", r.p1, r.d1, r.d2);
    }

    // Money Management
    pos = StringFind(prompt, "stop de ");
    if (pos >= 0) currentStrategy.stopLossPoints = (int)GetNextNumber(prompt, pos + 8);

    pos = StringFind(prompt, "take de ");
    if (pos >= 0) currentStrategy.takeProfitPoints = (int)GetNextNumber(prompt, pos + 8);

    pos = StringFind(prompt, "risco de ");
    if (pos >= 0) currentStrategy.riskPercent = GetNextNumber(prompt, pos + 9);

    pos = StringFind(prompt, "máximo ");
    if (pos >= 0) currentStrategy.maxTrades = (int)GetNextNumber(prompt, pos + 7);

    // News Filter
    pos = StringFind(prompt, "notícias");
    if (pos >= 0) {
        int nPos = StringFind(prompt, " min", pos - 10); // Look back or forward
        if (nPos < 0) nPos = StringFind(prompt, " min", pos);
        if (nPos >= 0) {
            // Find number before " min"
            int searchPos = nPos - 1;
            while(searchPos > 0 && (StringGetCharacter(prompt, searchPos) < '0' || StringGetCharacter(prompt, searchPos) > '9')) searchPos--;
            while(searchPos > 0 && (StringGetCharacter(prompt, searchPos) >= '0' && StringGetCharacter(prompt, searchPos) <= '9')) searchPos--;
            currentStrategy.newsVetoMinutes = (int)GetNextNumber(prompt, searchPos);
        } else currentStrategy.newsVetoMinutes = 20;
    }

    // Breakeven
    pos = StringFind(prompt, "atingir +");
    if (pos >= 0) currentStrategy.breakevenTriggerPoints = (int)GetNextNumber(prompt, pos + 9);
    pos = StringFind(prompt, "entrada +");
    if (pos >= 0) currentStrategy.breakevenProfitPoints = (int)GetNextNumber(prompt, pos + 9);

    PrintFormat("MT-LiveExecutor: Configuração carregada. Risco: %.1f%%, SL: %d, TP: %d, BE: +%d/+%d",
                currentStrategy.riskPercent, currentStrategy.stopLossPoints, currentStrategy.takeProfitPoints,
                currentStrategy.breakevenTriggerPoints, currentStrategy.breakevenProfitPoints);
}

// ---------- DECISION & EXECUTION ----------

void GravaLog(string text) {
    string timeStr = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);
    PrintFormat("[%s] MT-LiveExecutor: %s", timeStr, text);

    int handle = FileOpen("MT_LiveExecutor_Log.csv", FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ);
    if (handle != INVALID_HANDLE) {
        FileSeek(handle, 0, SEEK_END);
        FileWrite(handle, timeStr, text);
        FileClose(handle);
    }
}

bool AguardaNoticias() {
    if (currentStrategy.newsVetoMinutes <= 0) return false;

    MqlCalendarValue values[];
    datetime from = TimeCurrent() - currentStrategy.newsVetoMinutes * 60;
    datetime to = TimeCurrent() + currentStrategy.newsVetoMinutes * 60;

    // Get news from calendar
    if (CalendarValueHistory(values, from, to)) {
        for (int i = 0; i < ArraySize(values); i++) {
            MqlCalendarEvent event;
            if (CalendarEventById(values[i].event_id, event)) {
                if (event.importance == CALENDAR_IMPORTANCE_HIGH) {
                    GravaLog("Notícia de alto impacto detectada. Operação vetada.");
                    return true;
                }
            }
        }
    }
    return false;
}

void AIOptimizer() {
    // Heuristic: adjust SL suggestion based on ATR volatility
    static int atrHandle = INVALID_HANDLE;
    if (atrHandle == INVALID_HANDLE) atrHandle = iATR(_Symbol, PERIOD_H1, 14);

    double atr[];
    ArraySetAsSeries(atr, true);
    if (CopyBuffer(atrHandle, 0, 0, 1, atr) > 0) {
        double currentAtr = atr[0];
        int suggestedSL = (int)(currentAtr / _Point);
        if (suggestedSL > currentStrategy.stopLossPoints * 1.5) {
            PrintFormat("MT-LiveExecutor AI Optimizer: Volatilidade alta detectada (ATR: %.5f). Sugestão de SL: %d pontos.", currentAtr, suggestedSL);
        }
    }
}

ENUM_SIGNAL AvaliaCondicoes() {
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    if (dt.hour < currentStrategy.startHour) return SIGNAL_NONE;
    if (AguardaNoticias()) return SIGNAL_NONE;
    if (PositionsTotal() >= currentStrategy.maxTrades) return SIGNAL_NONE;

    int buyVotes = 0, sellVotes = 0;
    int activeRules = 0;

    for (int i = 0; i < currentStrategy.nRules; i++) {
        if (!currentStrategy.rules[i].active) continue;
        activeRules++;
        ENUM_SIGNAL s = SIGNAL_NONE;
        if (currentStrategy.rules[i].type == 1)
            s = PriceCrossMA(currentStrategy.rules[i].handle, currentStrategy.rules[i].p1, currentStrategy.rules[i].timeframe, 1);
        else if (currentStrategy.rules[i].type == 2)
            s = RSICheck(currentStrategy.rules[i].handle, currentStrategy.rules[i].p1, currentStrategy.rules[i].d1, currentStrategy.rules[i].d2, currentStrategy.rules[i].timeframe, 1);

        if (s == SIGNAL_BUY) buyVotes++;
        if (s == SIGNAL_SELL) sellVotes++;
    }

    if (activeRules > 0) {
        if (buyVotes == activeRules) return SIGNAL_BUY;
        if (sellVotes == activeRules) return SIGNAL_SELL;
    }

    return SIGNAL_NONE;
}

double CalculaLote(double riskPercent) {
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskMoney = equity * (riskPercent / 100.0);
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    if (currentStrategy.stopLossPoints <= 0) return 0.01;

    double lot = riskMoney / ((currentStrategy.stopLossPoints * _Point) * (tickValue / tickSize));
    return NormalizeDouble(lot, 2);
}

void GerenciaPosicoes() {
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        if (posInfo.SelectByIndex(i)) {
            if (posInfo.Magic() != 123456) continue;

            // Breakeven logic
            if (currentStrategy.breakevenTriggerPoints > 0) {
                double openPrice = posInfo.PriceOpen();
                double currentPrice = posInfo.PriceCurrent();
                double stopLoss = posInfo.StopLoss();

                if (posInfo.PositionType() == POSITION_TYPE_BUY) {
                    if (currentPrice >= openPrice + currentStrategy.breakevenTriggerPoints * _Point) {
                        double newSL = openPrice + currentStrategy.breakevenProfitPoints * _Point;
                        if (stopLoss < newSL) trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
                    }
                } else if (posInfo.PositionType() == POSITION_TYPE_SELL) {
                    if (currentPrice <= openPrice - currentStrategy.breakevenTriggerPoints * _Point) {
                        double newSL = openPrice - currentStrategy.breakevenProfitPoints * _Point;
                        if (stopLoss > newSL || stopLoss == 0) trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
                    }
                }
            }
        }
    }
}

// ---------- SCRIPT LIFECYCLE ----------

int OnInit() {
    symbolInfo.Name(_Symbol);
    trade.SetExpertMagicNumber(123456);
    Print("MT-LiveExecutor: Inicializado. Aguardando prompt...");
    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
    for (int i = 0; i < currentStrategy.nRules; i++) {
        if (currentStrategy.rules[i].handle != INVALID_HANDLE) IndicatorRelease(currentStrategy.rules[i].handle);
    }
    Print("MT-LiveExecutor: Desativado.");
}

void OnTick() {
    static string lastPrompt = "";
    if (InpPrompt != lastPrompt) {
        InterpretaPrompt(InpPrompt);
        lastPrompt = InpPrompt;
    }

    // Check for new bar if interval is set
    bool isNewBar = false;
    datetime currentBarTime = iTime(_Symbol, currentStrategy.interval, 0);
    if (currentBarTime != lastExecutionTime) {
        isNewBar = true;
        lastExecutionTime = currentBarTime;
    }

    if (isNewBar) {
        ENUM_SIGNAL sig = AvaliaCondicoes();
        if (sig != SIGNAL_NONE) {
            MqlTick tick;
            if (!SymbolInfoTick(_Symbol, tick)) return;

            double lot = CalculaLote(currentStrategy.riskPercent);
            double sl = 0, tp = 0;
            double price = (sig == SIGNAL_BUY) ? tick.ask : tick.bid;

            if (sig == SIGNAL_BUY) {
                sl = price - currentStrategy.stopLossPoints * _Point;
                tp = price + currentStrategy.takeProfitPoints * _Point;
                if (trade.Buy(lot, _Symbol, price, sl, tp, "MT-LiveExecutor BUY"))
                    GravaLog(StringFormat("COMPRA EXECUTADA: Lote %.2f, Preço %.5f, SL %.5f, TP %.5f", lot, price, sl, tp));
            } else {
                sl = price + currentStrategy.stopLossPoints * _Point;
                tp = price - currentStrategy.takeProfitPoints * _Point;
                if (trade.Sell(lot, _Symbol, price, sl, tp, "MT-LiveExecutor SELL"))
                    GravaLog(StringFormat("VENDA EXECUTADA: Lote %.2f, Preço %.5f, SL %.5f, TP %.5f", lot, price, sl, tp));
            }
        }
    }

    GerenciaPosicoes();

    static datetime lastAIUpdate = 0;
    if (TimeCurrent() - lastAIUpdate > 3600) {
        AIOptimizer();
        lastAIUpdate = TimeCurrent();
    }
}
