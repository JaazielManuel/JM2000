//=========================  MT5-LIVE-EXECUTOR  =========================
// Módulo Único de Execução de Estratégias via Linguagem Natural
//========================================================================

#property copyright "Copyright 2024, MT-LiveExecutor"
#property link      "https://github.com/MT-LiveExecutor"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

#define EA_MAGIC 123456

// ---------- ENUMS ----------
enum Signal { SIGNAL_BUY = 1, SIGNAL_SELL = -1, SIGNAL_NONE = 0 };

// ---------- STRUCTS ----------
struct Rule {
    int      type;      // 1: MA, 2: RSI, 3: Stoch, 4: BB, 10: Relative, 20: Delta, etc.
    int      intent;    // SIGNAL_BUY ou SIGNAL_SELL
    int      p1, p2, p3;
    double   d1, d2;
    string   s1;
    int      handle1;
    int      handle2;
    uint     timeframe;

    void Reset() {
        if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease(handle1);
        if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease(handle2);
        type = 0; intent = 0; p1 = 0; p2 = 0; p3 = 0; d1 = 0; d2 = 0; s1 = "";
        handle1 = INVALID_HANDLE; handle2 = INVALID_HANDLE; timeframe = PERIOD_CURRENT;
    }
};

struct HistoricalDeal {
    ulong    ticket;
    double   profit;
    int      type;
    datetime time;
};

// ---------- GLOBAIS DE ESTRATÉGIA ----------
Rule     g_rules[20];
int      g_nRules = 0;
string   g_lastPrompt = "";

double   p_riskPercent = 1.0;
int      p_stopPoints = 0;
int      p_takePoints = 0;
int      p_maxTrades = 3;
uint     p_frequency = PERIOD_M15;
string   p_startTime = "00:00";
bool     p_useMartingale = false;
int      p_beStart = 0;
int      p_bePlus = 0;
int      p_trailingStop = 0;
int      p_trailingStep = 0;
int      p_newsVetoMinutes = 20;

// ---------- OBJETOS NATIVOS ----------
CTrade          m_trade;
CPositionInfo   m_pos;
CSymbolInfo     m_symbol;
CAccountInfo    m_account;

// ---------- ESTADO DE EXECUÇÃO ----------
datetime g_lastBar = 0;
datetime g_lastPromptCheck = 0;
datetime g_lastCSVWrite = 0;
datetime g_lastAI = 0;

// Prototipagem de funções que serão implementadas nos próximos passos
void InterpretaPrompt(string prompt);
void ResetStrategy();
Signal AvaliaTudo();
void GerenciaPosicoes();
void EnviaOrdem(Signal s, string motivo);
double CalculaLote(double risco);
bool AguardaNoticias();
void GravaCSV();
void GravaLog(string txt);
void AIOptimizer();

// ---------- UTILS & PERSISTENCE ----------

void GravaCSV() {
    int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON);
    if(handle != INVALID_HANDLE) {
        FileWrite(handle, "Ticket", "Symbol", "Type", "OpenPrice", "CurrentPrice", "Profit");
        for(int i=0; i<PositionsTotal(); i++) {
            ulong ticket = PositionGetTicket(i);
            if(PositionSelectByTicket(ticket)) {
                FileWrite(handle, ticket, _Symbol, PositionGetInteger(POSITION_TYPE), PositionGetDouble(POSITION_PRICE_OPEN), PositionGetDouble(POSITION_PRICE_CURRENT), PositionGetDouble(POSITION_PROFIT));
            }
        }
        FileClose(handle);
    }
}

void GravaLog(string txt) {
    int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
    if(handle != INVALID_HANDLE) {
        FileSeek(handle, 0, SEEK_END);
        FileWrite(handle, StringFormat("[%s] %s", TimeToString(TimeCurrent()), txt));
        FileClose(handle);
    }
    Print(txt);
}

void AIOptimizer() {
    // Analisa as últimas 10 operações para ajustar risco
    HistorySelect(0, TimeCurrent());
    int total = HistoryDealsTotal();
    int win = 0, loss = 0;
    int count = 0;

    for(int i=total-1; i>=0 && count < 10; i--) {
        ulong t = HistoryDealGetTicket(i);
        if(HistoryDealGetString(t, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC) {
            double p = HistoryDealGetDouble(t, DEAL_PROFIT);
            if(p > 0) win++; else if(p < 0) loss++;
            count++;
        }
    }

    if(count >= 5) {
        double winRate = (double)win / (double)count;
        if(winRate < 0.40) {
            p_riskPercent *= 0.8; // Reduz risco em 20% se win rate < 40%
            GravaLog(StringFormat("AI Optimizer: Win rate baixo (%.2f). Risco reduzido para %.2f%%", winRate, p_riskPercent));
        } else if(winRate > 0.70) {
            p_riskPercent *= 1.1; // Aumenta risco em 10% se win rate > 70%
            GravaLog(StringFormat("AI Optimizer: Win rate alto (%.2f). Risco aumentado para %.2f%%", winRate, p_riskPercent));
        }
    }
}

// ---------- TRADE & POSITION MANAGEMENT ----------

bool IsTimeAllowed() {
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    string currentTime = StringFormat("%02d:%02d", dt.hour, dt.min);
    return (currentTime >= p_startTime);
}

void GerenciaPosicoes() {
    for(int i=PositionsTotal()-1; i>=0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(ticket <= 0) continue;
        if(!PositionSelectByTicket(ticket)) continue;
        if(PositionGetInteger(POSITION_MAGIC) != EA_MAGIC) continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

        double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        double currentPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        double currentSL = PositionGetDouble(POSITION_SL);
        int points = (int)(MathAbs(currentPrice - openPrice) / _Point);
        bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);

        // Breakeven
        if(p_beStart > 0 && points >= p_beStart) {
            double targetSL = isBuy ? (openPrice + p_bePlus * _Point) : (openPrice - p_bePlus * _Point);
            if((isBuy && currentSL < targetSL) || (!isBuy && (currentSL > targetSL || currentSL == 0))) {
                m_trade.PositionModify(ticket, targetSL, PositionGetDouble(POSITION_TP));
            }
        }

        // Trailing Stop
        if(p_trailingStop > 0 && points >= p_trailingStop) {
            double targetSL = isBuy ? (currentPrice - p_trailingStop * _Point) : (currentPrice + p_trailingStop * _Point);
            if((isBuy && targetSL > currentSL + p_trailingStep * _Point) || (!isBuy && (targetSL < currentSL - p_trailingStep * _Point || currentSL == 0))) {
                 m_trade.PositionModify(ticket, targetSL, PositionGetDouble(POSITION_TP));
            }
        }
    }
}

double CalculaLote(double riscoPercent) {
    double capital = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskAmount = capital * (riscoPercent / 100.0);

    // Martingale check
    if(p_useMartingale) {
        HistorySelect(0, TimeCurrent());
        int total = HistoryDealsTotal();
        for(int i=total-1; i>=0; i--) {
            ulong t = HistoryDealGetTicket(i);
            if(HistoryDealGetString(t, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC) {
                if(HistoryDealGetDouble(t, DEAL_PROFIT) < 0) riskAmount *= 2.0;
                break;
            }
        }
    }

    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    int stopP = (p_stopPoints > 0) ? p_stopPoints : 300;

    double lot = riskAmount / (stopP * (tickValue / (tickSize / _Point)));
    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    lot = MathFloor(lot / step) * step;

    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    if(lot < minLot) lot = minLot;
    if(lot > maxLot) lot = maxLot;

    return lot;
}

void EnviaOrdem(Signal s, string motivo) {
    if(s == SIGNAL_NONE) return;
    if(!IsTimeAllowed()) return;
    if(PositionsTotal() >= p_maxTrades) return;

    double lot = CalculaLote(p_riskPercent);
    double sl = 0, tp = 0;
    double price = (s == SIGNAL_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

    if(s == SIGNAL_BUY) {
        if(p_stopPoints > 0) sl = price - p_stopPoints * _Point;
        if(p_takePoints > 0) tp = price + p_takePoints * _Point;
    } else {
        if(p_stopPoints > 0) sl = price + p_stopPoints * _Point;
        if(p_takePoints > 0) tp = price - p_takePoints * _Point;
    }

    // Margin check
    double margin;
    if(!OrderCalcMargin((s == SIGNAL_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL), _Symbol, lot, price, margin)) {
        GravaLog("Erro ao calcular margem.");
        return;
    }
    if(margin > AccountInfoDouble(ACCOUNT_FREEMARGIN)) {
        GravaLog(StringFormat("Margem insuficiente: %.2f necessária vs %.2f disponível", margin, AccountInfoDouble(ACCOUNT_FREEMARGIN)));
        return;
    }

    // Retry loop for requotes/offquotes
    for(int i=0; i<3; i++) {
        bool res = (s == SIGNAL_BUY) ? m_trade.Buy(lot, _Symbol, price, sl, tp, motivo) : m_trade.Sell(lot, _Symbol, price, sl, tp, motivo);
        if(res) {
            uint ret = m_trade.ResultRetcode();
            if(ret == TRADE_RETCODE_DONE || ret == TRADE_RETCODE_PLACED) {
                GravaLog(StringFormat("Ordem executada: %s, Lote: %.2f, Motivo: %s", (s == SIGNAL_BUY ? "BUY" : "SELL"), lot, motivo));
                SendNotification("Trade Executado: " + motivo);
                return;
            }
            if(ret == TRADE_RETCODE_REQUOTES || ret == TRADE_RETCODE_OFFQUOTES) {
                price = (s == SIGNAL_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
                continue;
            }
            GravaLog("Erro na execução: " + (string)ret);
            break;
        }
    }
}

bool AguardaNoticias() {
    // 1. Check direct veto flag
    int h1 = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
    if(h1 != INVALID_HANDLE) {
        string content = FileReadString(h1);
        FileClose(h1);
        if(StringFind(content, "VETO=1") >= 0) return true;
    }

    // 2. Scan calendar.txt for high impact news
    int h2 = FileOpen("calendar.txt", FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
    if(h2 != INVALID_HANDLE) {
        while(!FileIsEnding(h2)) {
            string line = FileReadString(h2);
            if(StringFind(line, "High") >= 0) {
                // Heurística simples: se encontrar 'High', assume veto por segurança (em impl real usaria parsing de data)
                FileClose(h2);
                return true;
            }
        }
        FileClose(h2);
    }
    return false;
}

// ---------- INDICATOR & SIGNAL LOGIC ----------

double GetBufferValue(int handle, int buffer, int index) {
    double arr[];
    ArraySetAsSeries(arr, true);
    if(CopyBuffer(handle, buffer, index, 1, arr) <= 0) return 0;
    return arr[0];
}

bool AvaliaRegra(Rule &r) {
    if(r.type == 1) { // Média Móvel
        double ma1 = GetBufferValue(r.handle1, 0, 1);
        double ma2 = GetBufferValue(r.handle1, 0, 2);
        double c1 = iClose(_Symbol, p_frequency, 1);
        double c2 = iClose(_Symbol, p_frequency, 2);

        if(r.intent == SIGNAL_BUY) return (c2 < ma2 && c1 > ma1);
        if(r.intent == SIGNAL_SELL) return (c2 > ma2 && c1 < ma1);
    }

    if(r.type == 2) { // RSI
        double rsi1 = GetBufferValue(r.handle1, 0, 1);
        double rsi2 = GetBufferValue(r.handle1, 0, 2);

        if(r.intent == SIGNAL_BUY) return (rsi2 < r.d1 && rsi1 > r.d1);
        if(r.intent == SIGNAL_SELL) return (rsi2 > r.d1 && rsi1 < r.d1);
    }

    if(r.type == 3) { // Estocástico
        double k1 = GetBufferValue(r.handle1, 0, 1);
        double d1 = GetBufferValue(r.handle1, 1, 1);
        double k2 = GetBufferValue(r.handle1, 0, 2);
        double d2 = GetBufferValue(r.handle1, 1, 2);

        if(r.intent == SIGNAL_BUY) return (k2 < d2 && k1 > d1);
        if(r.intent == SIGNAL_SELL) return (k2 > d2 && k1 < d1);
    }

    if(r.type == 4) { // Bollinger Bands
        double up = GetBufferValue(r.handle1, 1, 1);
        double lo = GetBufferValue(r.handle1, 2, 1);
        double close = iClose(_Symbol, p_frequency, 1);

        if(r.intent == SIGNAL_BUY) return (close < lo);
        if(r.intent == SIGNAL_SELL) return (close > up);
    }

    if(r.type == 10) { // Relative Strength (Inter-symbol)
        double r1 = GetBufferValue(r.handle1, 0, 1);
        double r2 = GetBufferValue(r.handle2, 0, 1);
        if(r.intent == SIGNAL_BUY) return (r1 > r2 + 5);
        if(r.intent == SIGNAL_SELL) return (r1 < r2 - 5);
    }

    if(r.type == 20) { // RT_DELTA
        MqlTick arr[];
        int n = CopyTicksRange(_Symbol, arr, COPY_TICKS_TRADE, TimeCurrent() - r.p1, TimeCurrent());
        long buy = 0, sell = 0;
        for(int i=0; i<n; i++) if((arr[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++; else if((arr[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sell++;
        long delta = buy - sell;
        if(r.intent == SIGNAL_BUY) return (delta > r.p2);
        if(r.intent == SIGNAL_SELL) return (delta < -r.p2);
    }

    return false;
}

Signal AvaliaTudo() {
    if(g_nRules == 0) return SIGNAL_NONE;

    int buyConfirmations = 0;
    int sellConfirmations = 0;
    int buyRules = 0;
    int sellRules = 0;

    for(int i=0; i<g_nRules; i++) {
        if(g_rules[i].intent == SIGNAL_BUY) {
            buyRules++;
            if(AvaliaRegra(g_rules[i])) buyConfirmations++;
        } else if(g_rules[i].intent == SIGNAL_SELL) {
            sellRules++;
            if(AvaliaRegra(g_rules[i])) sellConfirmations++;
        }
    }

    if(buyRules > 0 && buyConfirmations == buyRules) return SIGNAL_BUY;
    if(sellRules > 0 && sellConfirmations == sellRules) return SIGNAL_SELL;

    return SIGNAL_NONE;
}

// ---------- NLP PARSER & RULES ----------

void ResetStrategy() {
    for(int i=0; i<20; i++) g_rules[i].Reset();
    g_nRules = 0;

    // Reseta globais para valores padrão
    p_riskPercent = 1.0;
    p_stopPoints = 0;
    p_takePoints = 0;
    p_maxTrades = 3;
    p_frequency = PERIOD_M15;
    p_startTime = "00:00";
    p_useMartingale = false;
    p_beStart = 0;
    p_bePlus = 0;
    p_trailingStop = 0;
    p_trailingStep = 0;
    p_newsVetoMinutes = 20;
}

double ExtraiNumero(string txt, int &cursor, int &endPos) {
    string work = txt;
    string numStr = "";
    bool found = false;
    int start = -1;

    for(int i = cursor; i < StringLen(work); i++) {
        ushort c = StringGetCharacter(work, i);
        if((c >= '0' && c <= '9') || c == '.' || c == ',') {
            if(!found) { start = i; found = true; }
            if(c == ',') numStr += ".";
            else {
                uchar temp[2]; temp[0] = (uchar)c; temp[1] = 0;
                numStr += CharArrayToString(temp);
            }
        } else if(found) {
            endPos = i;
            cursor = i;
            return StringToDouble(numStr);
        }
    }
    if(found) {
        endPos = StringLen(work);
        cursor = StringLen(work);
        return StringToDouble(numStr);
    }
    return -1;
}

double ExtraiValorApos(string txt, string keyword) {
    int pos = StringFind(txt, keyword);
    if(pos < 0) return -1;
    int cursor = pos + StringLen(keyword);
    int end = 0;
    return ExtraiNumero(txt, cursor, end);
}

void AddRule(string txt, int intent) {
    if(g_nRules >= 20) return;
    string work = txt;
    StringToLower(work);

    // Rule 1: Média Móvel (MA)
    if(StringFind(work, "média") >= 0 || StringFind(work, "ma") >= 0) {
        int cursor = StringFind(work, "média");
        if(cursor < 0) cursor = StringFind(work, "ma");
        cursor += 3;
        int end = 0;
        int p = (int)ExtraiNumero(work, cursor, end);
        if(p <= 0) p = 20;

        g_rules[g_nRules].type = 1;
        g_rules[g_nRules].intent = intent;
        g_rules[g_nRules].p1 = p;
        g_rules[g_nRules].handle1 = iMA(_Symbol, p_frequency, p, 0, MODE_SMA, PRICE_CLOSE);
        if(g_rules[g_nRules].handle1 != INVALID_HANDLE) {
            g_nRules++;
        }
    }

    // Rule 2: RSI
    if(StringFind(work, "rsi") >= 0) {
        int cursor = StringFind(work, "rsi") + 3;
        int end = 0;
        double v1 = ExtraiNumero(work, cursor, end);
        double v2 = ExtraiNumero(work, cursor, end);

        int period = 14;
        double threshold = 50;

        if(v2 != -1) { period = (int)v1; threshold = v2; }
        else if(v1 != -1) {
            if(v1 >= 40) threshold = v1;
            else period = (int)v1;
        }

        g_rules[g_nRules].type = 2;
        g_rules[g_nRules].intent = intent;
        g_rules[g_nRules].p1 = period;
        g_rules[g_nRules].d1 = threshold;
        g_rules[g_nRules].handle1 = iRSI(_Symbol, p_frequency, period, PRICE_CLOSE);
        if(g_rules[g_nRules].handle1 != INVALID_HANDLE) {
            g_nRules++;
        }
    }

    // Rule 3: Estocástico
    if(StringFind(work, "estocástico") >= 0 || StringFind(work, "stoch") >= 0) {
        g_rules[g_nRules].type = 3;
        g_rules[g_nRules].intent = intent;
        g_rules[g_nRules].handle1 = iStochastic(_Symbol, p_frequency, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
        if(g_rules[g_nRules].handle1 != INVALID_HANDLE) g_nRules++;
    }

    // Rule 4: Bollinger Bands
    if(StringFind(work, "bollinger") >= 0 || StringFind(work, "bb") >= 0) {
        g_rules[g_nRules].type = 4;
        g_rules[g_nRules].intent = intent;
        g_rules[g_nRules].handle1 = iBands(_Symbol, p_frequency, 20, 0, 2.0, PRICE_CLOSE);
        if(g_rules[g_nRules].handle1 != INVALID_HANDLE) g_nRules++;
    }

    // Rule 10: Força Relativa
    if(StringFind(work, "relativa") >= 0) {
        g_rules[g_nRules].type = 10;
        g_rules[g_nRules].intent = intent;
        g_rules[g_nRules].handle1 = iRSI(_Symbol, p_frequency, 14, PRICE_CLOSE);
        g_rules[g_nRules].handle2 = iRSI("US30", p_frequency, 14, PRICE_CLOSE);
        if(g_rules[g_nRules].handle1 != INVALID_HANDLE && g_rules[g_nRules].handle2 != INVALID_HANDLE) g_nRules++;
    }

    // Rule 20: Delta de Agressão
    if(StringFind(work, "delta") >= 0 || StringFind(work, "agressão") >= 0) {
        g_rules[g_nRules].type = 20;
        g_rules[g_nRules].intent = intent;
        g_rules[g_nRules].p1 = 60; // 60 segundos padrão
        g_rules[g_nRules].p2 = 300; // 300 delta padrão
        g_nRules++;
    }
}

uint PeriodoTexto(string work) {
    if(StringFind(work, "1 minuto") >= 0 || StringFind(work, "m1") >= 0) return PERIOD_M1;
    if(StringFind(work, "5 minuto") >= 0 || StringFind(work, "m5") >= 0) return PERIOD_M5;
    if(StringFind(work, "15 minuto") >= 0 || StringFind(work, "m15") >= 0) return PERIOD_M15;
    if(StringFind(work, "30 minuto") >= 0 || StringFind(work, "m30") >= 0) return PERIOD_M30;
    if(StringFind(work, "1 hora") >= 0 || StringFind(work, "h1") >= 0) return PERIOD_H1;
    if(StringFind(work, "4 hora") >= 0 || StringFind(work, "h4") >= 0) return PERIOD_H4;
    if(StringFind(work, "diário") >= 0 || StringFind(work, "d1") >= 0) return PERIOD_D1;
    return PERIOD_CURRENT;
}

void InterpretaPrompt(string prompt) {
    ResetStrategy();
    string work = prompt;
    StringToLower(work);

    // Globais
    double r = ExtraiValorApos(work, "risco");
    if(r > 0) p_riskPercent = r;

    double s = ExtraiValorApos(work, "stop");
    if(s > 0) p_stopPoints = (int)s;

    double t = ExtraiValorApos(work, "take");
    if(t > 0) p_takePoints = (int)t;

    double m = ExtraiValorApos(work, "máximo");
    if(m > 0) p_maxTrades = (int)m;

    p_frequency = PeriodoTexto(work);

    if(StringFind(work, "martingale") >= 0) p_useMartingale = true;

    int startPos = StringFind(work, "depois das");
    if(startPos >= 0) {
        int c = startPos + 10;
        int e = 0;
        int h = (int)ExtraiNumero(work, c, e);
        int mi = 0;
        if(StringGetCharacter(work, e) == ':' || StringGetCharacter(work, e) == 'h') {
            c = e + 1;
            mi = (int)ExtraiNumero(work, c, e);
        }
        p_startTime = StringFormat("%02d:%02d", h, mi);
    }

    // Breakeven
    if(StringFind(work, "atingir") >= 0) {
        p_beStart = (int)ExtraiValorApos(work, "atingir");
        p_bePlus = (int)ExtraiValorApos(work, "entrada");
    }

    // Trailing
    if(StringFind(work, "trailing") >= 0) {
        p_trailingStop = (int)ExtraiValorApos(work, "trailing");
        p_trailingStep = 10; // Default
    }

    // News
    if(StringFind(work, "notícias") >= 0) {
        double nv = ExtraiValorApos(work, "notícias");
        if(nv > 0) p_newsVetoMinutes = (int)nv;
    }

    // Regras por segmento
    string segments[];
    string tempPrompt = prompt;
    StringReplace(tempPrompt, " e ", ".");
    StringSplit(tempPrompt, '.', segments);

    int currentIntent = SIGNAL_NONE;
    for(int i=0; i<ArraySize(segments); i++) {
        string seg = segments[i];
        StringToLower(seg);
        if(StringFind(seg, "compra") >= 0) currentIntent = SIGNAL_BUY;
        else if(StringFind(seg, "vende") >= 0) currentIntent = SIGNAL_SELL;

        if(currentIntent != SIGNAL_NONE) {
            AddRule(seg, currentIntent);
        }
    }

    GravaLog(StringFormat("Estratégia interpretada. Regras: %d. Início: %s. Risco: %.2f%%", g_nRules, p_startTime, p_riskPercent));
}

// ---------- EVENT HANDLERS ----------

int OnInit() {
    m_trade.SetExpertMagicNumber(EA_MAGIC);
    m_symbol.Name(_Symbol);

    EventSetTimer(1);
    g_lastPromptCheck = 0;

    GravaLog("MT-LiveExecutor iniciado.");
    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
    EventKillTimer();
    ResetStrategy();
    GravaLog("MT-LiveExecutor finalizado.");
}

void OnTick() {
    // 1. Gestão de posições abertas (sempre)
    GerenciaPosicoes();

    // 2. Persistência de estado (a cada 5s)
    if(TimeCurrent() - g_lastCSVWrite >= 5) {
        GravaCSV();
        g_lastCSVWrite = TimeCurrent();
    }

    // 3. Verificação de novo candle (Sinais)
    datetime currentBar = iTime(_Symbol, p_frequency, 0);
    if(currentBar != g_lastBar) {
        if(g_lastBar != 0) {
            if(!AguardaNoticias()) {
                Signal s = AvaliaTudo();
                if(s != SIGNAL_NONE) {
                    EnviaOrdem(s, "Sinal confirmado");
                }
            } else {
                GravaLog("Operação vetada por notícias.");
            }
        }
        g_lastBar = currentBar;
    }
}

void OnTimer() {
    // 1. Checa por novos prompts em MQL5/Files/prompt.txt
    if(TimeCurrent() - g_lastPromptCheck >= 2) {
        int handle = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
        if(handle != INVALID_HANDLE) {
            string prompt = "";
            while(!FileIsEnding(handle)) prompt += FileReadString(handle);
            FileClose(handle);

            if(prompt != "" && prompt != g_lastPrompt) {
                GravaLog("Novo prompt detectado: " + prompt);
                InterpretaPrompt(prompt);
                g_lastPrompt = prompt;
            }
        }
        g_lastPromptCheck = TimeCurrent();
    }

    // 2. Otimizador de IA (a cada 1 hora)
    if(TimeCurrent() - g_lastAI >= 3600) {
        AIOptimizer();
        g_lastAI = TimeCurrent();
    }
}
