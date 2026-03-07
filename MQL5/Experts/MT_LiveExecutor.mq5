//=========================  MT-LiveExecutor  =========================
// Real-time strategy interpreter for MetaTrader 5
// Translated from Portuguese natural language prompts
// Optimized for Profit Master v8.0 standard (2026)
// Version: 9.1 (Consolidated, AI-Enhanced & Performance Optimized)
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// ---------- 1. CONFIGURAÇÕES E INPUTS ----------
input string InpPrompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Não operar 20 min antes ou depois de notícias de alto impacto. Máximo 3 trades simultâneos. Ao atingir +30 pontos, move stop para entrada +5 pontos.";

// ---------- 2. ESTRUTURAS DE DADOS ----------
enum ENUM_SIGNAL { SIGNAL_NONE = 0, SIGNAL_BUY = 1, SIGNAL_SELL = -1 };

struct Rule {
    bool active;
    int type;
    ENUM_TIMEFRAMES timeframe;
    int p1, p2, p3;
    double d1, d2;
    string s1;
    int handle;
    int handle2;
};

struct StrategyRules {
    Rule rules[30];
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
    int trailingStopPoints;
    int trailingStepPoints;
    double martingaleMultiplier;
    bool isHedge;
    bool notificationsEnabled;
};

// ---------- 3. VARIÁVEIS GLOBAIS (BOLT OPTIMIZED) ----------
StrategyRules currentStrategy;
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symbolInfo;
CAccountInfo accountInfo;
MqlTick currentTick;
datetime lastExecutionTime = 0;
int dynamicSafetyPoints = 0;

// ---------- 4. BIBLIOTECA MT5-KNOWLEDGE-CORE (SINAIS) ----------

// 4.1 Cruzamento de Preço com Média Móvel
ENUM_SIGNAL PriceCrossMA(int &handle, int period, ENUM_TIMEFRAMES tf, int shift) {
    if (handle == INVALID_HANDLE) handle = iMA(_Symbol, tf, period, 0, MODE_SMA, PRICE_CLOSE);
    double ma[], close[];
    ArraySetAsSeries(ma, true); ArraySetAsSeries(close, true);
    if (CopyBuffer(handle, 0, shift, 2, ma) < 2) return SIGNAL_NONE;
    if (CopyClose(_Symbol, tf, shift, 2, close) < 2) return SIGNAL_NONE;
    if (close[1] <= ma[1] && close[0] > ma[0]) return SIGNAL_BUY;
    if (close[1] >= ma[1] && close[0] < ma[0]) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

// 4.2 RSI - Check de Níveis (Multi-Mode)
ENUM_SIGNAL RSICheck(int &handle, int period, double buyLevel, double sellLevel, ENUM_TIMEFRAMES tf, int shift) {
    if (handle == INVALID_HANDLE) handle = iRSI(_Symbol, tf, period, PRICE_CLOSE);
    double rsi[];
    ArraySetAsSeries(rsi, true);
    if (CopyBuffer(handle, 0, shift, 2, rsi) < 2) return SIGNAL_NONE;

    // Se buyLevel > sellLevel (ex: 55 > 45), opera crossover de tendência (Prompt Style)
    if(buyLevel > sellLevel) {
        if(rsi[1] <= buyLevel && rsi[0] > buyLevel) return SIGNAL_BUY;
        if(rsi[1] >= sellLevel && rsi[0] < sellLevel) return SIGNAL_SELL;
    } else {
        // Padrão: COMPRA sobrevendido (abaixo de 30), VENDA sobrecomprado (acima de 70)
        if(rsi[1] >= buyLevel && rsi[0] < buyLevel) return SIGNAL_BUY;
        if(rsi[1] <= sellLevel && rsi[0] > sellLevel) return SIGNAL_SELL;
    }
    return SIGNAL_NONE;
}

// 4.3 Estocástico - Cruzamento de Linhas
ENUM_SIGNAL StochCross(int &handle, int k, int d, int slowing, ENUM_TIMEFRAMES tf, int shift) {
    if (handle == INVALID_HANDLE) handle = iStochastic(_Symbol, tf, k, d, slowing, MODE_SMA, STO_LOWHIGH);
    double main[], signal[];
    ArraySetAsSeries(main, true); ArraySetAsSeries(signal, true);
    if (CopyBuffer(handle, 0, shift, 2, main) < 2) return SIGNAL_NONE;
    if (CopyBuffer(handle, 1, shift, 2, signal) < 2) return SIGNAL_NONE;
    if (main[1] < signal[1] && main[0] > signal[0]) return SIGNAL_BUY;
    if (main[1] > signal[1] && main[0] < signal[0]) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

// 4.4 Bollinger Bands - Rebote nas Bandas
ENUM_SIGNAL BBounce(int &handle, int period, double deviation, ENUM_TIMEFRAMES tf, int shift) {
    if (handle == INVALID_HANDLE) handle = iBands(_Symbol, tf, period, 0, deviation, PRICE_CLOSE);
    double upper[], lower[], close[];
    ArraySetAsSeries(upper, true); ArraySetAsSeries(lower, true); ArraySetAsSeries(close, true);
    if (CopyBuffer(handle, 1, shift, 1, upper) < 1) return SIGNAL_NONE;
    if (CopyBuffer(handle, 2, shift, 1, lower) < 1) return SIGNAL_NONE;
    if (CopyClose(_Symbol, tf, shift, 1, close) < 1) return SIGNAL_NONE;
    if (close[0] < lower[0]) return SIGNAL_BUY;
    if (close[0] > upper[0]) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

// 4.5 Rompimento Diário
ENUM_SIGNAL DailyBreak(int shift) {
    double hi = iHigh(_Symbol, PERIOD_D1, 1);
    double lo = iLow(_Symbol, PERIOD_D1, 1);
    double close = iClose(_Symbol, PERIOD_CURRENT, shift);
    if (close > hi) return SIGNAL_BUY;
    if (close < lo) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

// 4.6 Delta de Agressão (Volume Tick)
ENUM_SIGNAL DeltaAggression(int seconds, int deltaTrigger) {
    MqlTick ticks[];
    int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, (long)((TimeCurrent() - seconds) * 1000), (long)(TimeCurrent() * 1000));
    if (n <= 0) return SIGNAL_NONE;
    long buy = 0, sell = 0;
    for (int i = 0; i < n; i++) {
        if ((ticks[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++;
        else if ((ticks[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sell++;
    }
    long delta = buy - sell;
    if (delta > deltaTrigger) return SIGNAL_BUY;
    if (delta < -deltaTrigger) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

// 4.7 Ciclo de Volume
ENUM_SIGNAL VolumeCycle(int period, ENUM_TIMEFRAMES tf, int shift) {
    long vol[];
    ArraySetAsSeries(vol, true);
    if (CopyTickVolume(_Symbol, tf, shift, period, vol) < period) return SIGNAL_NONE;
    int maxIdx = ArrayMaximum(vol);
    int minIdx = ArrayMinimum(vol);
    if (maxIdx == 0) return SIGNAL_SELL;
    if (minIdx == 0) return SIGNAL_BUY;
    return SIGNAL_NONE;
}

// 4.8 AMA (Adaptive Moving Average)
ENUM_SIGNAL AMACheck(int &handle, int period, int fast, int slow, ENUM_TIMEFRAMES tf, int shift) {
    if (handle == INVALID_HANDLE) handle = iAMA(_Symbol, tf, period, fast, slow, 0, PRICE_CLOSE);
    double ama[];
    ArraySetAsSeries(ama, true);
    if (CopyBuffer(handle, 0, shift, 2, ama) < 2) return SIGNAL_NONE;
    if (ama[0] > ama[1]) return SIGNAL_BUY;
    if (ama[0] < ama[1]) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

// 4.9 Padrão de 2 Barras (Inside/Outside)
ENUM_SIGNAL Bar2Pattern(ENUM_TIMEFRAMES tf, int shift) {
    double h0 = iHigh(_Symbol, tf, shift);
    double l0 = iLow(_Symbol, tf, shift);
    double c0 = iClose(_Symbol, tf, shift);
    double o0 = iOpen(_Symbol, tf, shift);
    double h1 = iHigh(_Symbol, tf, shift + 1);
    double l1 = iLow(_Symbol, tf, shift + 1);
    if (h0 < h1 && l0 > l1) return (c0 > o0) ? SIGNAL_BUY : SIGNAL_SELL;
    if (h0 > h1 && l0 < l1) return (c0 > o0) ? SIGNAL_SELL : SIGNAL_BUY;
    return SIGNAL_NONE;
}

// 4.10 Força Relativa entre Ativos
ENUM_SIGNAL RSRelative(int &h1, int &h2, string bench, int period, ENUM_TIMEFRAMES tf, int shift) {
    if (h1 == INVALID_HANDLE) h1 = iRSI(_Symbol, tf, period, PRICE_CLOSE);
    if (h2 == INVALID_HANDLE) h2 = iRSI(bench, tf, period, PRICE_CLOSE);
    double r1[], r2[];
    ArraySetAsSeries(r1, true); ArraySetAsSeries(r2, true);
    if (CopyBuffer(h1, 0, shift, 1, r1) < 1) return SIGNAL_NONE;
    if (CopyBuffer(h2, 0, shift, 1, r2) < 1) return SIGNAL_NONE;
    if (r1[0] > r2[0] + 5) return SIGNAL_BUY;
    if (r1[0] < r2[0] - 5) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

// ---------- 5. MOTOR DE INTERPRETAÇÃO (NLP PORTUGUÊS) ----------

double ExtraiNumero(string text, int startPos) {
    string res = ""; bool started = false;
    for(int i=startPos; i<StringLen(text); i++) {
        ushort c = StringGetCharacter(text, i);
        if((c >= '0' && c <= '9') || c == '.') { res += StringSubstr(text, i, 1); started = true; }
        else if(started) break;
    }
    return StringToDouble(res);
}

ENUM_TIMEFRAMES PeriodoTexto(string nome) {
    StringToLower(nome);
    if (StringFind(nome, "m15") >= 0 || StringFind(nome, "15 min") >= 0) return PERIOD_M15;
    if (StringFind(nome, "m1") >= 0 || StringFind(nome, "1 min") >= 0) return PERIOD_M1;
    if (StringFind(nome, "m5") >= 0 || StringFind(nome, "5 min") >= 0) return PERIOD_M5;
    if (StringFind(nome, "m30") >= 0 || StringFind(nome, "30 min") >= 0) return PERIOD_M30;
    if (StringFind(nome, "h1") >= 0 || StringFind(nome, "1 hora") >= 0) return PERIOD_H1;
    if (StringFind(nome, "h4") >= 0 || StringFind(nome, "4 horas") >= 0) return PERIOD_H4;
    if (StringFind(nome, "d1") >= 0 || StringFind(nome, "diário") >= 0) return PERIOD_D1;
    return PERIOD_CURRENT;
}

void InterpretaPrompt(string prompt) {
    StringToLower(prompt);

    // Cleanup de handles antigos
    for (int i = 0; i < currentStrategy.nRules; i++) {
        if (currentStrategy.rules[i].handle != INVALID_HANDLE) IndicatorRelease(currentStrategy.rules[i].handle);
        if (currentStrategy.rules[i].handle2 != INVALID_HANDLE) IndicatorRelease(currentStrategy.rules[i].handle2);
        currentStrategy.rules[i].handle = INVALID_HANDLE;
        currentStrategy.rules[i].handle2 = INVALID_HANDLE;
    }

    ZeroMemory(currentStrategy);
    currentStrategy.maxTrades = 100;
    currentStrategy.martingaleMultiplier = 1.0;
    for(int i=0; i<30; i++) { currentStrategy.rules[i].handle = INVALID_HANDLE; currentStrategy.rules[i].handle2 = INVALID_HANDLE; }

    Print("MT-LiveExecutor: Interpretando novo prompt...");

    // 5.1 Timeframe / Intervalo
    currentStrategy.interval = PeriodoTexto(prompt);

    // 5.2 Horário de Início
    int pos = StringFind(prompt, "depois das ");
    if (pos >= 0) currentStrategy.startHour = (int)ExtraiNumero(prompt, pos + 11);

    // 5.3 Regras de Sinais

    // Média Móvel
    pos = StringFind(prompt, "média de ");
    if (pos >= 0) {
        int p = (int)ExtraiNumero(prompt, pos + 9);
        if (p > 0) {
            int idx = currentStrategy.nRules++;
            currentStrategy.rules[idx].active = true;
            currentStrategy.rules[idx].type = 1;
            currentStrategy.rules[idx].p1 = p;
            currentStrategy.rules[idx].timeframe = currentStrategy.interval;
            PrintFormat("Regra [%d]: Preço vs MA(%d)", idx, p);
        }
    }

    // RSI
    pos = StringFind(prompt, "rsi");
    if (pos >= 0) {
        int idx = currentStrategy.nRules++;
        currentStrategy.rules[idx].active = true;
        currentStrategy.rules[idx].type = 2;
        currentStrategy.rules[idx].p1 = (int)ExtraiNumero(prompt, pos + 3);
        if (currentStrategy.rules[idx].p1 <= 0) currentStrategy.rules[idx].p1 = 14;

        currentStrategy.rules[idx].d1 = 30; // Default BUY
        currentStrategy.rules[idx].d2 = 70; // Default SELL

        int pCompra = StringFind(prompt, "compra");
        int pVenda = StringFind(prompt, "vende");
        int pRsi = pos;

        int pAcima = StringFind(prompt, "acima de ", pRsi);
        int pAbaixo = StringFind(prompt, "abaixo de ", pRsi);

        if (pAcima >= 0 && pAcima < pRsi + 60) {
            double val = ExtraiNumero(prompt, pAcima + 9);
            if (MathAbs(pAcima - pCompra) < MathAbs(pAcima - pVenda)) currentStrategy.rules[idx].d1 = val;
            else currentStrategy.rules[idx].d2 = val;
        }

        if (pAbaixo >= 0 && pAbaixo < pRsi + 60) {
            double val = ExtraiNumero(prompt, pAbaixo + 10);
            if (MathAbs(pAbaixo - pCompra) < MathAbs(pAbaixo - pVenda)) currentStrategy.rules[idx].d1 = val;
            else currentStrategy.rules[idx].d2 = val;
        }

        currentStrategy.rules[idx].timeframe = currentStrategy.interval;
        PrintFormat("Regra [%d]: RSI(%d) Compra:%.1f / Venda:%.1f", idx, currentStrategy.rules[idx].p1, currentStrategy.rules[idx].d1, currentStrategy.rules[idx].d2);
    }

    // Estocástico
    if (StringFind(prompt, "estocástico") >= 0 || StringFind(prompt, "stoch") >= 0) {
        int idx = currentStrategy.nRules++;
        currentStrategy.rules[idx].active = true;
        currentStrategy.rules[idx].type = 3;
        currentStrategy.rules[idx].p1 = 5; currentStrategy.rules[idx].p2 = 3; currentStrategy.rules[idx].p3 = 3;
        currentStrategy.rules[idx].timeframe = currentStrategy.interval;
        PrintFormat("Regra [%d]: Stochastic Cross", idx);
    }

    // Bollinger
    if (StringFind(prompt, "bollinger") >= 0 || StringFind(prompt, "bandas") >= 0) {
        int idx = currentStrategy.nRules++;
        currentStrategy.rules[idx].active = true;
        currentStrategy.rules[idx].type = 4;
        currentStrategy.rules[idx].p1 = 20; currentStrategy.rules[idx].d1 = 2.0;
        currentStrategy.rules[idx].timeframe = currentStrategy.interval;
        PrintFormat("Regra [%d]: Bollinger Bounce", idx);
    }

    // Rompimento Diário
    if (StringFind(prompt, "rompimento diário") >= 0) {
        int idx = currentStrategy.nRules++;
        currentStrategy.rules[idx].active = true;
        currentStrategy.rules[idx].type = 5;
        PrintFormat("Regra [%d]: Rompimento Diário", idx);
    }

    // 5.4 Gestão de Risco & Ordens
    pos = StringFind(prompt, "stop de ");
    if (pos >= 0) currentStrategy.stopLossPoints = (int)ExtraiNumero(prompt, pos + 8);

    pos = StringFind(prompt, "take de ");
    if (pos >= 0) currentStrategy.takeProfitPoints = (int)ExtraiNumero(prompt, pos + 8);

    pos = StringFind(prompt, "risco de ");
    if (pos >= 0) currentStrategy.riskPercent = ExtraiNumero(prompt, pos + 9);

    pos = StringFind(prompt, "máximo ");
    if (pos >= 0) currentStrategy.maxTrades = (int)ExtraiNumero(prompt, pos + 7);

    // 5.5 Filtros e Recursos Avançados
    if (StringFind(prompt, "notícias") >= 0) currentStrategy.newsVetoMinutes = 20;

    // Breakeven
    pos = StringFind(prompt, "atingir +");
    if (pos >= 0) currentStrategy.breakevenTriggerPoints = (int)ExtraiNumero(prompt, pos + 9);
    pos = StringFind(prompt, "entrada +");
    if (pos >= 0) currentStrategy.breakevenProfitPoints = (int)ExtraiNumero(prompt, pos + 9);

    // Trailing
    pos = StringFind(prompt, "trailing stop de ");
    if (pos >= 0) {
        currentStrategy.trailingStopPoints = (int)ExtraiNumero(prompt, pos + 17);
        currentStrategy.trailingStepPoints = 5;
    }

    // Martingale
    if (StringFind(prompt, "martingale") >= 0) {
        currentStrategy.martingaleMultiplier = 2.0;
        pos = StringFind(prompt, "multiplicador ");
        if (pos >= 0) currentStrategy.martingaleMultiplier = ExtraiNumero(prompt, pos + 14);
    }

    if (StringFind(prompt, "hedge") >= 0) currentStrategy.isHedge = true;
    if (StringFind(prompt, "notificações") >= 0 || StringFind(prompt, "alertas") >= 0) currentStrategy.notificationsEnabled = true;

    Print("MT-LiveExecutor: Configuração finalizada.");
}

// ---------- 6. NÚCLEO DE DECISÃO E EXECUÇÃO ----------

ENUM_SIGNAL AvaliaTudo() {
    int buyVotes = 0, sellVotes = 0, activeRules = 0;

    for (int i = 0; i < currentStrategy.nRules; i++) {
        if (!currentStrategy.rules[i].active) continue;
        activeRules++;
        ENUM_SIGNAL s = SIGNAL_NONE;

        switch(currentStrategy.rules[i].type) {
            case 1: s = PriceCrossMA(currentStrategy.rules[i].handle, currentStrategy.rules[i].p1, currentStrategy.rules[i].timeframe, 1); break;
            case 2: s = RSICheck(currentStrategy.rules[i].handle, currentStrategy.rules[i].p1, currentStrategy.rules[i].d1, currentStrategy.rules[i].d2, currentStrategy.rules[i].timeframe, 1); break;
            case 3: s = StochCross(currentStrategy.rules[i].handle, currentStrategy.rules[i].p1, currentStrategy.rules[i].p2, currentStrategy.rules[i].p3, currentStrategy.rules[i].timeframe, 1); break;
            case 4: s = BBounce(currentStrategy.rules[i].handle, currentStrategy.rules[i].p1, currentStrategy.rules[i].d1, currentStrategy.rules[i].timeframe, 1); break;
            case 5: s = DailyBreak(1); break;
            case 6: s = DeltaAggression(60, 300); break;
            case 7: s = VolumeCycle(currentStrategy.rules[i].p1, currentStrategy.rules[i].timeframe, 1); break;
            case 8: s = AMACheck(currentStrategy.rules[i].handle, currentStrategy.rules[i].p1, currentStrategy.rules[i].p2, currentStrategy.rules[i].p3, currentStrategy.rules[i].timeframe, 1); break;
            case 9: s = Bar2Pattern(currentStrategy.rules[i].timeframe, 1); break;
            case 10: s = RSRelative(currentStrategy.rules[i].handle, currentStrategy.rules[i].handle2, currentStrategy.rules[i].s1, currentStrategy.rules[i].p1, currentStrategy.rules[i].timeframe, 1); break;
        }

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
    int slPoints = (currentStrategy.stopLossPoints > 0) ? currentStrategy.stopLossPoints : 100;

    double lot = riskMoney / ((slPoints * _Point) * (tickValue / tickSize));

    // Martingale
    if (currentStrategy.martingaleMultiplier > 1.0) {
        HistorySelect(TimeCurrent() - 86400, TimeCurrent());
        int total = HistoryDealsTotal();
        if (total > 0) {
            ulong ticket = HistoryDealGetTicket(total - 1);
            if (HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) lot *= currentStrategy.martingaleMultiplier;
        }
    }

    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    lot = NormalizeDouble(lot, 2);
    if (lot < minLot) lot = minLot;
    if (lot > maxLot) lot = maxLot;
    return lot;
}

void GerenciaPosicoes() {
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        if (posInfo.SelectByIndex(i)) {
            if (posInfo.Symbol() != _Symbol) continue;

            double open = posInfo.PriceOpen();
            double cur = posInfo.PriceCurrent();
            double sl = posInfo.StopLoss();
            double tp = posInfo.TakeProfit();

            // Breakeven
            if (currentStrategy.breakevenTriggerPoints > 0) {
                if (posInfo.PositionType() == POSITION_TYPE_BUY) {
                    if (cur >= open + currentStrategy.breakevenTriggerPoints * _Point) {
                        double nsl = NormalizeDouble(open + currentStrategy.breakevenProfitPoints * _Point, _Digits);
                        if (sl < nsl) trade.PositionModify(posInfo.Ticket(), nsl, tp);
                    }
                } else {
                    if (cur <= open - currentStrategy.breakevenTriggerPoints * _Point) {
                        double nsl = NormalizeDouble(open - currentStrategy.breakevenProfitPoints * _Point, _Digits);
                        if (sl > nsl || sl == 0) trade.PositionModify(posInfo.Ticket(), nsl, tp);
                    }
                }
            }

            // Trailing Stop
            if (currentStrategy.trailingStopPoints > 0) {
                if (posInfo.PositionType() == POSITION_TYPE_BUY) {
                    if (cur > open + currentStrategy.trailingStopPoints * _Point) {
                        double nsl = NormalizeDouble(cur - currentStrategy.trailingStopPoints * _Point, _Digits);
                        if (nsl > sl + currentStrategy.trailingStepPoints * _Point) trade.PositionModify(posInfo.Ticket(), nsl, tp);
                    }
                } else {
                    if (cur < open - currentStrategy.trailingStopPoints * _Point) {
                        double nsl = NormalizeDouble(cur + currentStrategy.trailingStopPoints * _Point, _Digits);
                        if (nsl < sl - currentStrategy.trailingStepPoints * _Point || sl == 0) trade.PositionModify(posInfo.Ticket(), nsl, tp);
                    }
                }
            }
        }
    }
}

// ---------- 7. UTILITÁRIOS E CICLO DE VIDA ----------

void GravaLog(string txt) {
    string t = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);
    PrintFormat("[%s] MT-LiveExecutor: %s", t, txt);
    int h = FileOpen("MT_LiveExecutor_Log.csv", FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ);
    if (h != INVALID_HANDLE) {
        FileSeek(h, 0, SEEK_END);
        FileWrite(h, t, txt);
        FileClose(h);
    }
    if (currentStrategy.notificationsEnabled) SendNotification("MT-LiveExecutor: " + txt);
}

bool AguardaNoticias() {
    if (currentStrategy.newsVetoMinutes <= 0) return false;
    MqlCalendarValue val[];
    datetime f = TimeCurrent() - currentStrategy.newsVetoMinutes * 60;
    datetime t = TimeCurrent() + currentStrategy.newsVetoMinutes * 60;
    if (CalendarValueHistory(val, f, t)) {
        for (int i = 0; i < ArraySize(val); i++) {
            MqlCalendarEvent e;
            if (CalendarEventById(val[i].event_id, e)) {
                if (e.importance == CALENDAR_IMPORTANCE_HIGH) {
                    GravaLog("Veto por notícia de alto impacto.");
                    return true;
                }
            }
        }
    }
    return false;
}

void AIOptimizer() {
    static int h = INVALID_HANDLE;
    if (h == INVALID_HANDLE) h = iATR(_Symbol, PERIOD_H1, 14);
    double atr[]; ArraySetAsSeries(atr, true);
    if (CopyBuffer(h, 0, 0, 1, atr) > 0) {
        int sug = (int)(atr[0] / _Point);
        if (sug > currentStrategy.stopLossPoints * 1.5)
            PrintFormat("IA Sugestão: Volatilidade alta (ATR: %.5f). Sugestão SL: %d pts", atr[0], sug);
    }

    // Win Rate & Stats logic
    HistorySelect(TimeCurrent() - 30 * 86400, TimeCurrent());
    int total = HistoryDealsTotal();
    int wins = 0, loss = 0;
    double totalProfit = 0, totalLoss = 0;
    for (int i = 0; i < total; i++) {
        ulong ticket = HistoryDealGetTicket(i);
        if (HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT) {
            double p = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            if (p > 0) { wins++; totalProfit += p; }
            else if (p < 0) { loss++; totalLoss += MathAbs(p); }
        }
    }
    if (wins + loss > 0) {
        double wr = (double)wins / (wins + loss) * 100.0;
        double pf = (totalLoss > 0) ? totalProfit / totalLoss : totalProfit;
        PrintFormat("MT-LiveExecutor Stats: WR: %.1f%% | PF: %.2f | Trades: %d", wr, pf, wins + loss);
    }
}

int OnInit() {
    symbolInfo.Name(_Symbol);
    trade.SetExpertMagicNumber(123456);
    InterpretaPrompt(InpPrompt);
    Print("MT-LiveExecutor: Pronto para operar.");
    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
    for (int i = 0; i < currentStrategy.nRules; i++) {
        if (currentStrategy.rules[i].handle != INVALID_HANDLE) IndicatorRelease(currentStrategy.rules[i].handle);
        if (currentStrategy.rules[i].handle2 != INVALID_HANDLE) IndicatorRelease(currentStrategy.rules[i].handle2);
    }
    Print("MT-LiveExecutor: Encerrado.");
}

void OnTick() {
    static string lp = "";
    if (InpPrompt != lp) { InterpretaPrompt(InpPrompt); lp = InpPrompt; }
    if (!SymbolInfoTick(_Symbol, currentTick)) return;

    bool nb = false;
    datetime cbt = iTime(_Symbol, currentStrategy.interval, 0);
    if (cbt != lastExecutionTime) { nb = true; lastExecutionTime = cbt; }

    if (nb) {
        MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
        if (dt.hour >= currentStrategy.startHour && !AguardaNoticias()) {
            if (currentStrategy.isHedge || PositionsTotal() < currentStrategy.maxTrades) {
                ENUM_SIGNAL sig = AvaliaTudo();
                if (sig != SIGNAL_NONE) {
                    double l = CalculaLote(currentStrategy.riskPercent);
                    double sl = 0, tp = 0;
                    double p = (sig == SIGNAL_BUY) ? currentTick.ask : currentTick.bid;
                    if (sig == SIGNAL_BUY) {
                        if (currentStrategy.stopLossPoints > 0) sl = p - currentStrategy.stopLossPoints * _Point;
                        if (currentStrategy.takeProfitPoints > 0) tp = p + currentStrategy.takeProfitPoints * _Point;
                        if (trade.Buy(l, _Symbol, p, sl, tp)) GravaLog("COMPRA EXECUTADA");
                    } else {
                        if (currentStrategy.stopLossPoints > 0) sl = p + currentStrategy.stopLossPoints * _Point;
                        if (currentStrategy.takeProfitPoints > 0) tp = p - currentStrategy.takeProfitPoints * _Point;
                        if (trade.Sell(l, _Symbol, p, sl, tp)) GravaLog("VENDA EXECUTADA");
                    }
                }
            }
        }
    }
    GerenciaPosicoes();
    static datetime lai = 0;
    if (TimeCurrent() - lai > 3600) { AIOptimizer(); lai = TimeCurrent(); }
}
