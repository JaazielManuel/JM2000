//=========================  MT5-KNOWLEDGE-CORE  =========================
// MT-LiveExecutor - High-performance Strategy Executor
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\OrderInfo.mqh>
#include <Indicators\Indicators.mqh>

// --- Global Constants ---
#define EA_MAGIC 123456
#define LOG_FILE "MT_LiveExecutor_Log.txt"
#define STATE_FILE "MT_LiveExecutor_State.csv"
#define PROMPT_FILE "prompt.txt"
#define NEWS_FILE "news_veto.txt"

// --- Enums ---
enum ENUM_SIGNAL { SIGNAL_NONE=0, SIGNAL_BUY=1, SIGNAL_SELL=-1 };
enum ENUM_INTENT { INTENT_NONE=0, INTENT_BUY=1, INTENT_SELL=-1 };

// --- Structs ---
struct Rule {
    bool        active;
    int         type;       // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: DailyBreak, 6: Delta, 7: Vol, 8: AMA, 9: Bar2, 10: RS, 11: AI
    ENUM_INTENT intent;
    ENUM_TIMEFRAMES tf;
    int         p1, p2, p3;
    double      d1, d2;
    string      s1;
    int         handle1;
    int         handle2;

    Rule() : active(false), type(0), intent(INTENT_NONE), tf(PERIOD_CURRENT),
             p1(0), p2(0), p3(0), d1(0), d2(0), s1(""),
             handle1(INVALID_HANDLE), handle2(INVALID_HANDLE) {}
};

// --- Global Parameters ---
Rule            g_rules[20];
int             g_nRules = 0;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
int             p_maxTrades = 3;
double          p_riskPercent = 1.0;
string          p_startTime = "00:00";
int             p_beStart = 0;
int             p_bePlus = 0;
int             p_trailingStart = 0;
int             p_trailingStep = 10;
bool            p_useMartingale = false;
int             p_stopPoints = 300;
int             p_takePoints = 500;

// --- Global Objects ---
CTrade          trade;
CPositionInfo   posInfo;
CSymbolInfo     symInfo;
CAccountInfo    accInfo;

// --- Performance Metrics ---
double g_winRate = 0;
double g_profitFactor = 0;
double g_drawdown = 0;
int    g_totalTrades = 0;

// Forward declarations for mandatory functions from prompt
void InterpretaPrompt(string prompt);
void ResetStrategy();
ENUM_SIGNAL AvaliaTudo();
ENUM_SIGNAL AvaliaRegra(Rule &r);
double CalculaLote(double riscoPercent);
void EnviaOrdem(ENUM_SIGNAL s, string reason);
void GerenciaPosicoes();
bool AguardaNoticias();
void GravaLog(string texto);
void GravaCSV();
void CalculaEstatisticas();
void AIOptimizer();

// NLP Utilities
double ExtraiNumero(string txt, int &pos);
double ExtraiNumero(string txt);
double ExtraiValorApos(string txt, string keyword);
ENUM_TIMEFRAMES PeriodoTexto(string nome);
string ExtractTime(string txt);

// Indicator Utilities
double GetBufferValue(int handle, int buffer, int shift);

// --- NLP Utilities Implementation ---

double ExtraiNumero(string txt, int &pos) {
    string res = "";
    bool found = false;
    int len = StringLen(txt);
    for(int i=pos; i<len; i++) {
        ushort c = StringGetCharacter(txt, i);
        if((c >= '0' && c <= '9') || c == '.') {
            res += CharToString((uchar)c);
            found = true;
        } else if(found) {
            pos = i;
            return StringToDouble(res);
        }
    }
    pos = len;
    return (res == "") ? 0 : StringToDouble(res);
}

double ExtraiNumero(string txt) {
    int p = 0;
    return ExtraiNumero(txt, p);
}

double ExtraiValorApos(string txt, string keyword) {
    int pos = StringFind(txt, keyword);
    if(pos < 0) return 0;
    pos += StringLen(keyword);
    return ExtraiNumero(txt, pos);
}

ENUM_TIMEFRAMES PeriodoTexto(string nome) {
    nome = StringSubstr(nome, 0, 10);
    StringToLower(nome);
    if(StringFind(nome, "m15") >= 0 || StringFind(nome, "15 minutos") >= 0 || StringFind(nome, "15 min") >= 0) return PERIOD_M15;
    if(StringFind(nome, "m1") >= 0 || StringFind(nome, "1 minuto") >= 0 || StringFind(nome, "1 min") >= 0) return PERIOD_M1;
    if(StringFind(nome, "m5") >= 0 || StringFind(nome, "5 minutos") >= 0 || StringFind(nome, "5 min") >= 0) return PERIOD_M5;
    if(StringFind(nome, "m30") >= 0 || StringFind(nome, "30 minutos") >= 0) return PERIOD_M30;
    if(StringFind(nome, "h1") >= 0 || StringFind(nome, "1 hora") >= 0) return PERIOD_H1;
    if(StringFind(nome, "h4") >= 0 || StringFind(nome, "4 horas") >= 0) return PERIOD_H4;
    if(StringFind(nome, "d1") >= 0 || StringFind(nome, "diário") >= 0) return PERIOD_D1;
    return PERIOD_CURRENT;
}

string ExtractTime(string txt) {
    int pos = StringFind(txt, "h");
    if(pos <= 0) return "00:00";

    string h = "", m = "00";
    int i = pos - 1;
    while(i >= 0 && StringGetCharacter(txt, i) >= '0' && StringGetCharacter(txt, i) <= '9') {
        h = CharToString((uchar)StringGetCharacter(txt, i)) + h;
        i--;
    }

    if(StringGetCharacter(txt, pos+1) >= '0' && StringGetCharacter(txt, pos+1) <= '9') {
        m = "";
        i = pos + 1;
        while(i < StringLen(txt) && StringGetCharacter(txt, i) >= '0' && StringGetCharacter(txt, i) <= '9') {
            m += CharToString((uchar)StringGetCharacter(txt, i));
            i++;
        }
    }

    if(StringLen(h) == 1) h = "0" + h;
    if(StringLen(m) == 1) m = "0" + m;
    if(h == "") h = "00";

    return h + ":" + m;
}

void ResetStrategy() {
    for(int i=0; i<20; i++) {
        if(g_rules[i].handle1 != INVALID_HANDLE && g_rules[i].handle1 != 0) IndicatorRelease(g_rules[i].handle1);
        if(g_rules[i].handle2 != INVALID_HANDLE && g_rules[i].handle2 != 0) IndicatorRelease(g_rules[i].handle2);
        g_rules[i].active = false;
    }
    g_nRules = 0;
    p_frequency = PERIOD_M15;
    p_maxTrades = 3;
    p_riskPercent = 1.0;
    p_startTime = "00:00";
    p_beStart = 0; p_bePlus = 0;
    p_trailingStart = 0;
    p_useMartingale = false;
    p_stopPoints = 300;
    p_takePoints = 500;
}

void InterpretaPrompt(string prompt) {
    ResetStrategy();
    string original = prompt;
    StringToLower(prompt);

    // Global parameters
    p_frequency = PeriodoTexto(prompt);
    if(StringFind(prompt, "risco de") >= 0) p_riskPercent = ExtraiValorApos(prompt, "risco de");
    if(StringFind(prompt, "stop de") >= 0) p_stopPoints = (int)ExtraiValorApos(prompt, "stop de");
    if(StringFind(prompt, "take de") >= 0) p_takePoints = (int)ExtraiValorApos(prompt, "take de");
    if(StringFind(prompt, "máximo") >= 0 && StringFind(prompt, "trades") >= 0) p_maxTrades = (int)ExtraiValorApos(prompt, "máximo");
    if(StringFind(prompt, "depois das") >= 0) p_startTime = ExtractTime(prompt);
    if(StringFind(prompt, "martingale") >= 0) p_useMartingale = true;

    if(StringFind(prompt, "move stop para entrada") >= 0) {
        p_beStart = (int)ExtraiValorApos(prompt, "atingir +");
        p_bePlus = (int)ExtraiValorApos(prompt, "entrada +");
    }
    if(StringFind(prompt, "atingir +") >= 0 && StringFind(prompt, "trailing") >= 0) {
        p_trailingStart = (int)ExtraiValorApos(prompt, "atingir +");
    }

    // Split rules
    string segments[];
    string work = prompt;
    StringReplace(work, " e ", "|");
    StringReplace(work, ".", "|");
    StringReplace(work, ",", "|");
    ushort sep = StringGetCharacter("|", 0);
    StringSplit(work, sep, segments);

    ENUM_INTENT currentIntent = INTENT_NONE;

    for(int i=0; i<ArraySize(segments); i++) {
        string s = segments[i];
        if(StringFind(s, "compra") >= 0) currentIntent = INTENT_BUY;
        else if(StringFind(s, "vende") >= 0) currentIntent = INTENT_SELL;

        Rule r;
        r.intent = currentIntent;
        r.tf = PeriodoTexto(s);
        if(r.tf == PERIOD_CURRENT) r.tf = p_frequency;

        // MA
        if(StringFind(s, " ma ") >= 0 || StringFind(s, "média") >= 0 || StringFind(s, " ma/") >= 0) {
            r.type = 1;
            int pos = 0;
            r.p1 = (int)ExtraiNumero(s, pos);
            r.p2 = (int)ExtraiNumero(s, pos);
            if(r.p2 == 0) { // Price vs MA
                r.handle1 = iMA(_Symbol, r.tf, r.p1, 0, MODE_SMA, PRICE_CLOSE);
            } else { // MA cross
                r.handle1 = iMA(_Symbol, r.tf, r.p1, 0, MODE_EMA, PRICE_CLOSE);
                r.handle2 = iMA(_Symbol, r.tf, r.p2, 0, MODE_EMA, PRICE_CLOSE);
            }
            r.active = true;
        }
        // RSI
        else if(StringFind(s, "rsi") >= 0) {
            r.type = 2;
            int pos = 0;
            double n1 = ExtraiNumero(s, pos);
            double n2 = ExtraiNumero(s, pos);
            if(n1 < 40) { r.p1 = (int)n1; r.d1 = n2; }
            else { r.p1 = 14; r.d1 = n1; }
            r.handle1 = iRSI(_Symbol, r.tf, r.p1, PRICE_CLOSE);
            r.active = true;
        }
        // Stochastic
        else if(StringFind(s, "estocástico") >= 0 || StringFind(s, "stoch") >= 0) {
            r.type = 3;
            r.handle1 = iStochastic(_Symbol, r.tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
            r.active = true;
        }
        // Bollinger
        else if(StringFind(s, "bollinger") >= 0 || StringFind(s, "bb ") >= 0) {
            r.type = 4;
            r.handle1 = iBands(_Symbol, r.tf, 20, 0, 2.0, PRICE_CLOSE);
            r.active = true;
        }
        // Daily Break
        else if(StringFind(s, "rompimento diário") >= 0) {
            r.type = 5;
            r.active = true;
        }
        // Volume
        else if(StringFind(s, "volume") >= 0) {
            r.type = 7;
            r.active = true;
        }
        // AMA
        else if(StringFind(s, "ama") >= 0 || StringFind(s, "adaptativa") >= 0) {
            r.type = 8;
            r.handle1 = iAMA(_Symbol, r.tf, 10, 2, 30, PRICE_CLOSE);
            r.active = true;
        }
        // Bar Pattern
        else if(StringFind(s, "padrão barras") >= 0 || StringFind(s, "barras") >= 0) {
            r.type = 9;
            r.active = true;
        }
        // AI
        else if(StringFind(s, "previsão") >= 0 || StringFind(s, "ai") >= 0) {
            r.type = 11;
            r.handle1 = iATR(_Symbol, r.tf, 14);
            r.active = true;
        }

        if(r.active && g_nRules < 20) {
            g_rules[g_nRules] = r;
            g_nRules++;
        }
    }
}

// --- Indicator Utilities Implementation ---

double GetBufferValue(int handle, int buffer, int shift) {
    double arr[];
    ArraySetAsSeries(arr);
    if(CopyBuffer(handle, buffer, shift, 1, arr) > 0) return arr[0];
    return 0;
}

// --- Signal Evaluation Implementation ---

ENUM_SIGNAL AvaliaRegra(Rule &r) {
    if(!r.active) return SIGNAL_NONE;

    // MA
    if(r.type == 1) {
        if(r.handle2 == INVALID_HANDLE) { // Price vs MA
            double ma = GetBufferValue(r.handle1, 0, 1);
            double close = iClose(_Symbol, r.tf, 1);
            if(r.intent == INTENT_BUY && close > ma) return SIGNAL_BUY;
            if(r.intent == INTENT_SELL && close < ma) return SIGNAL_SELL;
        } else { // MA Cross
            double f1 = GetBufferValue(r.handle1, 0, 1);
            double s1 = GetBufferValue(r.handle2, 0, 1);
            double f2 = GetBufferValue(r.handle1, 0, 2);
            double s2 = GetBufferValue(r.handle2, 0, 2);
            if(f2 < s2 && f1 > s1) return SIGNAL_BUY;
            if(f2 > s2 && f1 < s1) return SIGNAL_SELL;
        }
    }
    // RSI
    else if(r.type == 2) {
        double rsi1 = GetBufferValue(r.handle1, 0, 1);
        double rsi2 = GetBufferValue(r.handle1, 0, 2);
        if(r.intent == INTENT_BUY && rsi2 <= r.d1 && rsi1 > r.d1) return SIGNAL_BUY;
        if(r.intent == INTENT_SELL && rsi2 >= r.d1 && rsi1 < r.d1) return SIGNAL_SELL;
    }
    // Stoch
    else if(r.type == 3) {
        double k1 = GetBufferValue(r.handle1, 0, 1);
        double d1 = GetBufferValue(r.handle1, 1, 1);
        double k2 = GetBufferValue(r.handle1, 0, 2);
        double d2 = GetBufferValue(r.handle1, 1, 2);
        if(k2 < d2 && k1 > d1) return SIGNAL_BUY;
        if(k2 > d2 && k1 < d1) return SIGNAL_SELL;
    }
    // BB
    else if(r.type == 4) {
        double close = iClose(_Symbol, r.tf, 1);
        double up = GetBufferValue(r.handle1, 1, 1);
        double lo = GetBufferValue(r.handle1, 2, 1);
        if(close > up) return SIGNAL_SELL;
        if(close < lo) return SIGNAL_BUY;
    }
    // Daily Break
    else if(r.type == 5) {
        double hi = iHigh(_Symbol, PERIOD_D1, 1);
        double lo = iLow(_Symbol, PERIOD_D1, 1);
        double close = iClose(_Symbol, r.tf, 1);
        if(close > hi) return SIGNAL_BUY;
        if(close < lo) return SIGNAL_SELL;
    }
    // Vol
    else if(r.type == 7) {
        long v1 = iVolume(_Symbol, r.tf, 1);
        long v2 = iVolume(_Symbol, r.tf, 2);
        if(v1 > v2 * 1.5) return (iClose(_Symbol, r.tf, 1) > iOpen(_Symbol, r.tf, 1)) ? SIGNAL_BUY : SIGNAL_SELL;
    }
    // AMA
    else if(r.type == 8) {
        double ama1 = GetBufferValue(r.handle1, 0, 1);
        double ama2 = GetBufferValue(r.handle1, 0, 2);
        if(ama1 > ama2) return SIGNAL_BUY;
        if(ama1 < ama2) return SIGNAL_SELL;
    }
    // Bar Pattern
    else if(r.type == 9) {
        double h1 = iHigh(_Symbol, r.tf, 1);
        double l1 = iLow(_Symbol, r.tf, 1);
        double h2 = iHigh(_Symbol, r.tf, 2);
        double l2 = iLow(_Symbol, r.tf, 2);
        if(h1 < h2 && l1 > l2) return (iClose(_Symbol, r.tf, 1) > iOpen(_Symbol, r.tf, 1)) ? SIGNAL_BUY : SIGNAL_SELL;
        if(h1 > h2 && l1 < l2) return (iClose(_Symbol, r.tf, 1) > iOpen(_Symbol, r.tf, 1)) ? SIGNAL_SELL : SIGNAL_BUY;
    }
    // AI
    else if(r.type == 11) {
        double atr = GetBufferValue(r.handle1, 0, 1);
        double body = MathAbs(iClose(_Symbol, r.tf, 1) - iOpen(_Symbol, r.tf, 1));
        if(body > atr * 1.5) return (iClose(_Symbol, r.tf, 1) > iOpen(_Symbol, r.tf, 1)) ? SIGNAL_BUY : SIGNAL_SELL;
    }

    return SIGNAL_NONE;
}

ENUM_SIGNAL AvaliaTudo() {
    int buyVotes = 0;
    int sellVotes = 0;
    int activeBuy = 0;
    int activeSell = 0;

    for(int i=0; i<g_nRules; i++) {
        ENUM_SIGNAL s = AvaliaRegra(g_rules[i]);
        if(g_rules[i].intent == INTENT_BUY || g_rules[i].intent == INTENT_NONE) {
            activeBuy++;
            if(s == SIGNAL_BUY) buyVotes++;
        }
        if(g_rules[i].intent == INTENT_SELL || g_rules[i].intent == INTENT_NONE) {
            activeSell++;
            if(s == SIGNAL_SELL) sellVotes++;
        }
    }

    if(activeBuy > 0 && buyVotes == activeBuy) return SIGNAL_BUY;
    if(activeSell > 0 && sellVotes == activeSell) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

void AIOptimizer() {
    if(g_totalTrades < 10) return;
    if(g_winRate < 0.4) p_riskPercent = MathMax(0.5, p_riskPercent - 0.1);
    if(g_winRate > 0.6 && g_profitFactor > 1.5) p_riskPercent = MathMin(2.0, p_riskPercent + 0.1);
}

// --- Trade Execution Implementation ---

double CalculaLote(double riscoPercent) {
    double capital = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskAmount = capital * (riscoPercent / 100.0);
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    if(p_useMartingale) {
        HistorySelect(0, TimeCurrent());
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

    double volume = riskAmount / (p_stopPoints * (tickValue / (tickSize / _Point)));
    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    volume = MathFloor(volume / step) * step;

    double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    if(volume < minVol) volume = minVol;
    if(volume > maxVol) volume = maxVol;

    return volume;
}

void EnviaOrdem(ENUM_SIGNAL s, string reason) {
    if(s == SIGNAL_NONE) return;
    if(PositionsTotal() >= p_maxTrades) return;
    if(AguardaNoticias()) return;

    double price = (s == SIGNAL_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double margin = 0;
    ENUM_ORDER_TYPE type = (s == SIGNAL_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
    double volume = CalculaLote(p_riskPercent);

    if(!OrderCalcMargin(type, _Symbol, volume, price, margin)) {
        GravaLog("Erro ao calcular margem");
        return;
    }
    if(margin > AccountInfoDouble(ACCOUNT_FREEMARGIN)) {
        GravaLog("Margem insuficiente: " + DoubleToString(margin, 2));
        return;
    }

    double sl = 0, tp = 0;
    if(s == SIGNAL_BUY) {
        sl = price - p_stopPoints * _Point;
        tp = price + p_takePoints * _Point;
    } else {
        sl = price + p_stopPoints * _Point;
        tp = price - p_takePoints * _Point;
    }

    trade.SetExpertMagicNumber(EA_MAGIC);
    if(s == SIGNAL_BUY) {
        if(trade.Buy(volume, _Symbol, price, sl, tp, reason)) {
            GravaLog("Compra enviada: " + reason);
            SendNotification("MT-LiveExecutor: Compra em " + _Symbol);
        } else {
            GravaLog("Erro na compra: " + trade.ResultRetcodeDescription());
        }
    } else {
        if(trade.Sell(volume, _Symbol, price, sl, tp, reason)) {
            GravaLog("Venda enviada: " + reason);
            SendNotification("MT-LiveExecutor: Venda em " + _Symbol);
        } else {
            GravaLog("Erro na venda: " + trade.ResultRetcodeDescription());
        }
    }
}

// --- Position Management Implementation ---

void GerenciaPosicoes() {
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(posInfo.SelectByIndex(i)) {
            if(posInfo.Magic() != EA_MAGIC || posInfo.Symbol() != _Symbol) continue;

            double openPrice = posInfo.PriceOpen();
            double currentPrice = (posInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double currentSL = posInfo.StopLoss();
            int points = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (int)((currentPrice - openPrice) / _Point) : (int)((openPrice - currentPrice) / _Point);

            // Break-even
            if(p_beStart > 0 && points >= p_beStart) {
                double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? openPrice + p_bePlus * _Point : openPrice - p_bePlus * _Point;
                if((posInfo.PositionType() == POSITION_TYPE_BUY && (currentSL < newSL || currentSL == 0)) ||
                   (posInfo.PositionType() == POSITION_TYPE_SELL && (currentSL > newSL || currentSL == 0))) {
                    trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
                    GravaLog("Break-even acionado para ticket " + (string)posInfo.Ticket());
                }
            }

            // Trailing Stop
            if(p_trailingStart > 0 && points >= p_trailingStart) {
                double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? currentPrice - p_trailingStart * _Point : currentPrice + p_trailingStart * _Point;
                if((posInfo.PositionType() == POSITION_TYPE_BUY && newSL > currentSL + p_trailingStep * _Point) ||
                   (posInfo.PositionType() == POSITION_TYPE_SELL && (newSL < currentSL - p_trailingStep * _Point || currentSL == 0))) {
                    trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
                }
            }
        }
    }
}

bool AguardaNoticias() {
    int file = FileOpen(NEWS_FILE, FILE_READ | FILE_TXT );
    if(file == INVALID_HANDLE) return false;

    string content = FileReadString(file);
    FileClose(file);

    if(StringFind(content, "1") >= 0) return true;

    datetime newsTime = StringToTime(content);
    if(newsTime > 0) {
        datetime now = TimeCurrent();
        if(now >= newsTime - 20 * 60 && now <= newsTime + 20 * 60) return true;
    }

    return false;
}

// --- Persistence & Logging Implementation ---

void GravaLog(string texto) {
    int file = FileOpen(LOG_FILE, FILE_WRITE | FILE_READ | FILE_TXT );
    if(file != INVALID_HANDLE) {
        FileSeek(file, 0, SEEK_END);
        FileWriteString(file, TimeToString(TimeCurrent()) + ": " + texto + "\r\n");
        FileClose(file);
    }
    Print(texto);
}

void GravaCSV() {
    int file = FileOpen(STATE_FILE, FILE_WRITE | FILE_CSV | FILE_ANSI );
    if(file != INVALID_HANDLE) {
        FileWrite(file, "Ticket", "Symbol", "Type", "Volume", "PriceOpen", "Time", "SL", "TP", "Profit", "Reason");
        for(int i = 0; i < PositionsTotal(); i++) {
            if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC) {
                FileWrite(file, posInfo.Ticket(), posInfo.Symbol(), posInfo.PositionType(), posInfo.Volume(),
                          posInfo.PriceOpen(), posInfo.Time(), posInfo.StopLoss(), posInfo.TakeProfit(),
                          posInfo.Profit(), posInfo.Comment());
            }
        }
        FileClose(file);
    }
}

void CalculaEstatisticas() {
    HistorySelect(0, TimeCurrent());
    int total = HistoryDealsTotal();
    int wins = 0, losses = 0;
    double profit = 0, loss = 0;
    g_totalTrades = 0;

    for(int i = 0; i < total; i++) {
        ulong ticket = HistoryDealGetTicket(i);
        if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            double p = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            if(HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT) {
                g_totalTrades++;
                if(p > 0) { wins++; profit += p; }
                else if(p < 0) { losses++; loss += MathAbs(p); }
            }
        }
    }

    if(g_totalTrades > 0) g_winRate = (double)wins / g_totalTrades;
    if(loss > 0) g_profitFactor = profit / loss; else g_profitFactor = profit;
}

// --- Event Handlers Implementation ---

int OnInit() {
    EventSetTimer(1);
    ResetStrategy();

    // Initial prompt reading
    int file = FileOpen(PROMPT_FILE, FILE_READ | FILE_TXT );
    if(file != INVALID_HANDLE) {
        string prompt = FileReadString(file);
        FileClose(file);
        InterpretaPrompt(prompt);
        GravaLog("MT-LiveExecutor Iniciado. Prompt carregado.");
    } else {
        GravaLog("MT-LiveExecutor Iniciado. Aguardando prompt.txt");
    }

    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
    EventKillTimer();
    ResetStrategy();
}

void OnTick() {
    static datetime lastBar = 0;
    datetime currentBar = iTime(_Symbol, p_frequency, 0);

    // Trade management and persistence on every tick
    GerenciaPosicoes();
    GravaCSV();

    // Entry evaluation only on new bar
    if(currentBar != lastBar) {
        lastBar = currentBar;

        // Start time check
        datetime now = TimeCurrent();
        if(TimeToString(now, TIME_MINUTES) < p_startTime) return;

        ENUM_SIGNAL s = AvaliaTudo();
        if(s != SIGNAL_NONE) {
            EnviaOrdem(s, "Sinal validado por confluence");
        }
    }
}

void OnTimer() {
    // Check for prompt updates
    static datetime lastUpdate = 0;
    int file = FileOpen(PROMPT_FILE, FILE_READ | FILE_TXT );
    if(file != INVALID_HANDLE) {
        datetime modified = (datetime)FileGetInteger(PROMPT_FILE, FILE_MODIFY_DATE, false);
        if(modified > lastUpdate) {
            lastUpdate = modified;
            string prompt = FileReadString(file);
            InterpretaPrompt(prompt);
            GravaLog("Prompt atualizado com sucesso.");
        }
        FileClose(file);
    }

    // Hourly optimization and statistics
    static int hourCounter = 0;
    hourCounter++;
    if(hourCounter >= 3600) {
        hourCounter = 0;
        CalculaEstatisticas();
        AIOptimizer();
        GravaLog("Estatísticas e IA atualizadas.");
    }
}
