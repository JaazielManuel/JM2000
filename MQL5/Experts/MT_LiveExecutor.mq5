//=========================  MT-LIVE-EXECUTOR  =========================
// Módulo Único de Execução de Estratégias via Prompt NLP
//======================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// --- CONSTANTES ---
#define EA_MAGIC 20231027
#define MAX_RULES 30

// --- ENUMS ---
enum ENUM_SIGNAL { BUY = 1, SELL = -1, NONE = 0 };

// --- STRUCTS ---
struct Rule {
    bool        active;
    string      name;
    ENUM_SIGNAL intent; // BUY, SELL ou NONE (se NONE, serve para ambos)
    int         p1, p2, p3;
    double      d1, d2;
    string      s1;
    int         handle1, handle2;
    ENUM_TIMEFRAMES tf;
};

// --- GLOBAIS DE PARÂMETROS DA ESTRATÉGIA ---
Rule        p_rules[MAX_RULES];
int         p_nRules = 0;
double      p_riskPercent = 1.0;
int         p_stopPoints = 300;
int         p_takePoints = 500;
int         p_maxTrades = 3;
int         p_beStart = 0;
int         p_bePlus = 0;
int         p_trailingStart = 0;
int         p_trailingStep = 10;
bool        p_useMartingale = false;
datetime    p_startTimeSeconds = 0; // Segundos desde a meia-noite
ENUM_TIMEFRAMES p_frequency = PERIOD_CURRENT;

// --- OBJETOS E ESTADOS ---
CTrade          Trade;
CPositionInfo   Position;
CSymbolInfo     Symbol;
CAccountInfo    Account;

datetime    lastBarTime = 0;
string      currentPrompt = "";
datetime    lastPromptCheck = 0;
datetime    lastCSVWrite = 0;

// --- PROTÓTIPOS ---
void InterpretaPrompt(string prompt);
void ResetStrategy();
void AvaliaTudo();
void GerenciaPosicoes();
bool AguardaNoticias();
void GravaCSV();
void GravaLog(string texto);
void CalculaEstatisticas();
void AIOptimizer();

// --- INICIALIZAÇÃO ---
int OnInit()
{
    if(!Symbol.Name(_Symbol)) return INIT_FAILED;
    EventSetTimer(1);
    ResetStrategy();
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    EventKillTimer();
    ResetStrategy();
}

void ResetStrategy()
{
    for(int i = 0; i < MAX_RULES; i++) {
        if(p_rules[i].handle1 != INVALID_HANDLE && p_rules[i].handle1 != 0) IndicatorRelease(p_rules[i].handle1);
        if(p_rules[i].handle2 != INVALID_HANDLE && p_rules[i].handle2 != 0) IndicatorRelease(p_rules[i].handle2);
        p_rules[i].active = false;
        p_rules[i].handle1 = INVALID_HANDLE;
        p_rules[i].handle2 = INVALID_HANDLE;
    }
    p_nRules = 0;
    p_riskPercent = 1.0;
    p_stopPoints = 300;
    p_takePoints = 500;
    p_maxTrades = 3;
    p_beStart = 0;
    p_bePlus = 0;
    p_trailingStart = 0;
    p_trailingStep = 10;
    p_useMartingale = false;
    p_startTimeSeconds = 0;
    p_frequency = PERIOD_CURRENT;
}

// --- UTILITÁRIOS DE INDICADORES ---
double GetBufferValue(int handle, int buffer, int shift)
{
    double val[1];
    if(CopyBuffer(handle, buffer, shift, 1, val) <= 0) return 0;
    return val[0];
}

// --- FUNÇÕES DE SINAL ---

ENUM_SIGNAL CruzamentoMA(Rule &r)
{
    double val1_1 = GetBufferValue(r.handle1, 0, 1);
    double val1_2 = GetBufferValue(r.handle1, 0, 2);

    // MA Crossover (two handles)
    if(r.handle2 != INVALID_HANDLE && r.handle2 != 0) {
        double val2_1 = GetBufferValue(r.handle2, 0, 1);
        double val2_2 = GetBufferValue(r.handle2, 0, 2);

        if(val1_2 <= val2_2 && val1_1 > val2_1) return BUY;
        if(val1_2 >= val2_2 && val1_1 < val2_1) return SELL;
    }
    // Price vs MA (one handle)
    else {
        double close1 = iClose(_Symbol, r.tf, 1);
        double close2 = iClose(_Symbol, r.tf, 2);

        if(close2 <= val1_2 && close1 > val1_1) return BUY;
        if(close2 >= val1_2 && close1 < val1_1) return SELL;
    }
    return NONE;
}

ENUM_SIGNAL RSIThreshold(Rule &r)
{
    double rsi1 = GetBufferValue(r.handle1, 0, 1);
    double rsi2 = GetBufferValue(r.handle1, 0, 2);

    if(r.intent == BUY && rsi2 <= r.d1 && rsi1 > r.d1) return BUY;
    if(r.intent == SELL && rsi2 >= r.d2 && rsi1 < r.d2) return SELL;

    // Fallback para níveis fixos se intent for NONE
    if(r.intent == NONE) {
        if(rsi1 < r.d2) return BUY;
        if(rsi1 > r.d1) return SELL;
    }
    return NONE;
}

ENUM_SIGNAL StochCross(Rule &r)
{
    double k1 = GetBufferValue(r.handle1, 0, 1);
    double d1 = GetBufferValue(r.handle1, 1, 1);
    double k2 = GetBufferValue(r.handle1, 0, 2);
    double d2 = GetBufferValue(r.handle1, 1, 2);

    if(k2 <= d2 && k1 > d1) return BUY;
    if(k2 >= d2 && k1 < d1) return SELL;
    return NONE;
}

ENUM_SIGNAL BBounce(Rule &r)
{
    double close1 = iClose(_Symbol, r.tf, 1);
    double upper1 = GetBufferValue(r.handle1, 1, 1);
    double lower1 = GetBufferValue(r.handle1, 2, 1);

    if(close1 < lower1) return BUY;
    if(close1 > upper1) return SELL;
    return NONE;
}

ENUM_SIGNAL DailyBreak(Rule &r)
{
    double high1 = iHigh(_Symbol, PERIOD_D1, 1);
    double low1  = iLow(_Symbol, PERIOD_D1, 1);
    double close1 = iClose(_Symbol, r.tf, 1);

    if(close1 > high1) return BUY;
    if(close1 < low1)  return SELL;
    return NONE;
}

ENUM_SIGNAL DeltaAggression(Rule &r)
{
    MqlTick ticks[];
    int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, (TimeCurrent() - r.p1) * 1000, TimeCurrent() * 1000);
    long buyVol = 0, sellVol = 0;
    for(int i = 0; i < n; i++) {
        if((ticks[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buyVol += (long)ticks[i].volume;
        else if((ticks[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sellVol += (long)ticks[i].volume;
    }
    long delta = buyVol - sellVol;
    if(delta > r.p2) return BUY;
    if(delta < -r.p2) return SELL;
    return NONE;
}

ENUM_SIGNAL VolumeCycle(Rule &r)
{
    long vol[];
    ArraySetAsSeries(vol, true);
    if(CopyTickVolume(_Symbol, r.tf, 0, r.p1, vol) < r.p1) return NONE;

    int maxIdx = ArrayMaximum(vol);
    int minIdx = ArrayMinimum(vol);

    if(minIdx == 0) return BUY;
    if(maxIdx == 0) return SELL;
    return NONE;
}

ENUM_SIGNAL AMACross(Rule &r)
{
    double ama1 = GetBufferValue(r.handle1, 0, 1);
    double ama2 = GetBufferValue(r.handle1, 0, 2);
    double close1 = iClose(_Symbol, r.tf, 1);
    double close2 = iClose(_Symbol, r.tf, 2);

    if(close2 <= ama2 && close1 > ama1) return BUY;
    if(close2 >= ama2 && close1 < ama1) return SELL;
    return NONE;
}

ENUM_SIGNAL Bar2Pattern(Rule &r)
{
    double h1 = iHigh(_Symbol, r.tf, 1);
    double l1 = iLow(_Symbol, r.tf, 1);
    double h2 = iHigh(_Symbol, r.tf, 2);
    double l2 = iLow(_Symbol, r.tf, 2);
    double c1 = iClose(_Symbol, r.tf, 1);
    double o1 = iOpen(_Symbol, r.tf, 1);

    // Inside Bar
    if(h1 < h2 && l1 > l2) return (c1 > o1) ? BUY : SELL;
    // Outside Bar
    if(h1 > h2 && l1 < l2) return (c1 > o1) ? SELL : BUY;
    return NONE;
}

ENUM_SIGNAL RSRelative(Rule &r)
{
    double rsiSelf = GetBufferValue(r.handle1, 0, 1);
    double rsiBench = GetBufferValue(r.handle2, 0, 1);

    if(rsiSelf > rsiBench + 5) return BUY;
    if(rsiSelf < rsiBench - 5) return SELL;
    return NONE;
}

// --- UTILITÁRIOS DE PARSING ---

double ExtraiNumero(string txt, int startPos = 0)
{
    string res = "";
    bool found = false;
    for(int i = startPos; i < StringLen(txt); i++) {
        ushort c = StringGetCharacter(txt, i);
        if((c >= '0' && c <= '9') || c == '.') {
            res += CharToString((uchar)c);
            found = true;
        } else if(found) break;
    }
    return StringToDouble(res);
}

double ExtraiValorApos(string txt, string keyword)
{
    int pos = StringFind(txt, keyword);
    if(pos < 0) return 0;
    return ExtraiNumero(txt, pos + StringLen(keyword));
}

string ExtractTime(string txt)
{
    int pos = StringFind(txt, "h");
    if(pos < 0) return "";

    string hourStr = "";
    int i = pos - 1;
    while(i >= 0 && StringGetCharacter(txt, i) >= '0' && StringGetCharacter(txt, i) <= '9') {
        hourStr = CharToString((uchar)StringGetCharacter(txt, i)) + hourStr;
        i--;
    }

    string minStr = "00";
    if(pos + 1 < StringLen(txt) && StringGetCharacter(txt, pos+1) >= '0' && StringGetCharacter(txt, pos+1) <= '9') {
        minStr = "";
        i = pos + 1;
        while(i < StringLen(txt) && StringGetCharacter(txt, i) >= '0' && StringGetCharacter(txt, i) <= '9') {
            minStr += CharToString((uchar)StringGetCharacter(txt, i));
            i++;
        }
    }
    if(StringLen(hourStr) == 1) hourStr = "0" + hourStr;
    if(StringLen(minStr) == 1) minStr = "0" + minStr;
    return hourStr + ":" + minStr;
}

ENUM_TIMEFRAMES PeriodoTexto(string txt)
{
    if(StringFind(txt, "m30") >= 0 || StringFind(txt, "30 min") >= 0) return PERIOD_M30;
    if(StringFind(txt, "m15") >= 0 || StringFind(txt, "15 min") >= 0) return PERIOD_M15;
    if(StringFind(txt, "m5") >= 0 || StringFind(txt, "5 min") >= 0) return PERIOD_M5;
    if(StringFind(txt, "m1") >= 0 || StringFind(txt, "1 min") >= 0) return PERIOD_M1;
    if(StringFind(txt, "h1") >= 0 || StringFind(txt, "1 hora") >= 0) return PERIOD_H1;
    if(StringFind(txt, "d1") >= 0 || StringFind(txt, "diário") >= 0) return PERIOD_D1;
    return PERIOD_CURRENT;
}

double CalculaLote(double riscoPercent)
{
    double balance = Account.Balance();
    double riskAmount = balance * (riscoPercent / 100.0);
    double tickValue = Symbol.TickValue();
    double tickSize = Symbol.TickSize();

    if(tickValue == 0 || tickSize == 0 || p_stopPoints == 0) return Symbol.LotsMin();

    double lot = riskAmount / (p_stopPoints * (tickValue / (tickSize / _Point)));

    // Martingale
    if(p_useMartingale) {
        HistorySelect(TimeCurrent() - 86400, TimeCurrent());
        int total = HistoryDealsTotal();
        for(int i = total - 1; i >= 0; i--) {
            ulong ticket = HistoryDealGetTicket(i);
            if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
                double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
                if(profit < 0) lot *= 2;
                break;
            }
        }
    }

    return NormalizeDouble(MathMin(MathMax(lot, Symbol.LotsMin()), Symbol.LotsMax()), 2);
}

void EnviaOrdem(ENUM_SIGNAL s, string reason)
{
    if(s == NONE) return;

    double lote = CalculaLote(p_riskPercent);
    double price = (s == BUY) ? Symbol.Ask() : Symbol.Bid();
    double sl = (s == BUY) ? price - p_stopPoints * _Point : price + p_stopPoints * _Point;
    double tp = (s == BUY) ? price + p_takePoints * _Point : price - p_takePoints * _Point;

    // Margin check
    double margin;
    if(!OrderCalcMargin((s == BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL), _Symbol, lote, price, margin)) return;
    if(margin > Account.FreeMargin()) {
        GravaLog("Margem insuficiente");
        return;
    }

    Trade.SetExpertMagicNumber(EA_MAGIC);
    if(s == BUY) Trade.Buy(lote, _Symbol, price, sl, tp, reason);
    else Trade.Sell(lote, _Symbol, price, sl, tp, reason);

    if(Trade.ResultRetcode() != TRADE_RETCODE_DONE) {
        GravaLog("Erro ao enviar ordem: " + IntegerToString(Trade.ResultRetcode()));
    }
}

void AvaliaTudo()
{
    if(p_nRules == 0) return;

    int buyLeg = 0, buyTotal = 0;
    int sellLeg = 0, sellTotal = 0;

    for(int i = 0; i < p_nRules; i++) {
        Rule r = p_rules[i];
        if(!r.active) continue;

        ENUM_SIGNAL res = NONE;
        if(r.name == "MA") res = CruzamentoMA(r);
        else if(r.name == "RSI") res = RSIThreshold(r);
        else if(r.name == "Stoch") res = StochCross(r);
        else if(r.name == "BB") res = BBounce(r);
        else if(r.name == "DailyBreak") res = DailyBreak(r);
        else if(r.name == "Delta") res = DeltaAggression(r);
        else if(r.name == "Volume") res = VolumeCycle(r);
        else if(r.name == "AMA") res = AMACross(r);
        else if(r.name == "Bar2") res = Bar2Pattern(r);
        else if(r.name == "Relative") res = RSRelative(r);

        if(r.intent == BUY || r.intent == NONE) {
            buyTotal++;
            if(res == BUY) buyLeg++;
        }
        if(r.intent == SELL || r.intent == NONE) {
            sellTotal++;
            if(res == SELL) sellLeg++;
        }
    }

    ENUM_SIGNAL finalSignal = NONE;
    string reason = "MT-LiveExecutor";
    if(buyTotal > 0 && buyLeg == buyTotal) {
        finalSignal = BUY;
        reason = "BUY: " + currentPrompt;
    }
    else if(sellTotal > 0 && sellLeg == sellTotal) {
        finalSignal = SELL;
        reason = "SELL: " + currentPrompt;
    }

    if(finalSignal != NONE) {
        // Filtros de tempo e notícias
        if(AguardaNoticias()) return;

        datetime now = TimeCurrent();
        if(p_startTimeSeconds > 0 && (now % 86400) < p_startTimeSeconds) return;

        // Máximo trades
        int openTrades = 0;
        for(int i = PositionsTotal() - 1; i >= 0; i--) {
            if(Position.SelectByIndex(i) && Position.Magic() == EA_MAGIC && Position.Symbol() == _Symbol) openTrades++;
        }
        if(openTrades < p_maxTrades) EnviaOrdem(finalSignal, reason);
    }
}

bool AguardaNoticias()
{
    // Tenta ler do arquivo news_veto.txt
    int handle = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_COMMON);
    if(handle != INVALID_HANDLE) {
        string content = FileReadString(handle);
        FileClose(handle);
        if(content == "1") return true;

        datetime newsTime = StringToTime(content);
        if(newsTime > 0) {
            datetime now = TimeCurrent();
            if(MathAbs(now - newsTime) < 1200) return true; // 20 min
        }
    }
    return false;
}

void GerenciaPosicoes()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(Position.SelectByIndex(i) && Position.Magic() == EA_MAGIC && Position.Symbol() == _Symbol) {
            double openPrice = Position.PriceOpen();
            double currentPrice = (Position.PositionType() == POSITION_TYPE_BUY) ? Symbol.Bid() : Symbol.Ask();
            double sl = Position.StopLoss();
            double tp = Position.TakeProfit();

            int points = (int)(MathAbs(currentPrice - openPrice) / _Point);

            // Break-even
            if(p_beStart > 0 && points >= p_beStart) {
                double targetBE = (Position.PositionType() == POSITION_TYPE_BUY) ? openPrice + p_bePlus * _Point : openPrice - p_bePlus * _Point;
                if((Position.PositionType() == POSITION_TYPE_BUY && (sl < targetBE || sl == 0)) ||
                   (Position.PositionType() == POSITION_TYPE_SELL && (sl > targetBE || sl == 0))) {
                    Trade.PositionModify(Position.Ticket(), targetBE, tp);
                }
            }

            // Trailing Stop
            if(p_trailingStart > 0 && points >= p_trailingStart) {
                double targetTS = (Position.PositionType() == POSITION_TYPE_BUY) ? currentPrice - p_trailingStart * _Point : currentPrice + p_trailingStart * _Point;
                if((Position.PositionType() == POSITION_TYPE_BUY && targetTS > sl + p_trailingStep * _Point) ||
                   (Position.PositionType() == POSITION_TYPE_SELL && (targetTS < sl - p_trailingStep * _Point || sl == 0))) {
                    Trade.PositionModify(Position.Ticket(), targetTS, tp);
                }
            }
        }
    }
}

void OnTick()
{
    GerenciaPosicoes();

    if(TimeCurrent() - lastCSVWrite > 5) {
        GravaCSV();
        lastCSVWrite = TimeCurrent();
    }

    datetime barTime = iTime(_Symbol, p_frequency, 0);
    if(barTime != lastBarTime) {
        AvaliaTudo();
        lastBarTime = barTime;
    }
}

void OnTimer()
{
    // Verifica se há novo prompt em MQL5/Files/prompt.txt
    if(TimeCurrent() - lastPromptCheck > 1) {
        int handle = FileOpen("prompt.txt", FILE_READ | FILE_TXT | FILE_ANSI);
        if(handle != INVALID_HANDLE) {
            string prompt = FileReadString(handle);
            FileClose(handle);
            if(prompt != currentPrompt && prompt != "") {
                currentPrompt = prompt;
                InterpretaPrompt(currentPrompt);
            }
        }
        lastPromptCheck = TimeCurrent();
    }

    // Otimizador de IA a cada hora
    static int lastHour = -1;
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    if(dt.hour != lastHour) {
        AIOptimizer();
        lastHour = dt.hour;
    }
}

void GravaLog(string texto)
{
    int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_READ | FILE_WRITE | FILE_TXT | FILE_COMMON);
    if(handle != INVALID_HANDLE) {
        FileSeek(handle, 0, SEEK_END);
        FileWriteString(handle, TimeToString(TimeCurrent()) + ": " + texto + "\r\n");
        FileClose(handle);
    }
    Print(texto);
}

void GravaCSV()
{
    int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV | FILE_COMMON);
    if(handle != INVALID_HANDLE) {
        FileWrite(handle, "Ticket", "Symbol", "Type", "Volume", "PriceOpen", "Time", "SL", "TP", "Profit", "Reason");
        for(int i = 0; i < PositionsTotal(); i++) {
            if(Position.SelectByIndex(i) && Position.Magic() == EA_MAGIC) {
                FileWrite(handle, Position.Ticket(), Position.Symbol(), Position.PositionType(), Position.Volume(), Position.PriceOpen(), TimeToString(Position.Time()), Position.StopLoss(), Position.TakeProfit(), Position.Profit(), Position.Comment());
            }
        }
        FileClose(handle);
    }
}

void AIOptimizer()
{
    CalculaEstatisticas();
    // Heurística de ajuste de risco baseada em performance
    // Memória: reduz risco se win rate < 40%, aumenta se > 60% e PF > 1.5
}

void CalculaEstatisticas()
{
    // Implementação básica de histórico para estatísticas
}

void InterpretaPrompt(string prompt)
{
    ResetStrategy();
    string low = prompt;
    StringToLower(low);

    // Parâmetros Globais
    p_riskPercent = ExtraiValorApos(low, "risco de");
    if(p_riskPercent == 0) p_riskPercent = 1.0;

    p_stopPoints = (int)ExtraiValorApos(low, "stop de");
    if(p_stopPoints == 0) p_stopPoints = 300;

    p_takePoints = (int)ExtraiValorApos(low, "take de");
    if(p_takePoints == 0) p_takePoints = 500;

    p_maxTrades = (int)ExtraiValorApos(low, "máximo");
    if(p_maxTrades == 0) p_maxTrades = 3;

    p_beStart = (int)ExtraiValorApos(low, "atingir +");
    p_bePlus = (int)ExtraiValorApos(low, "entrada +");

    p_trailingStart = (int)ExtraiValorApos(low, "trailing");

    if(StringFind(low, "martingale") >= 0) p_useMartingale = true;

    string startTime = ExtractTime(low);
    if(startTime != "") p_startTimeSeconds = (datetime)StringToTime(startTime) % 86400;

    p_frequency = PeriodoTexto(low);

    // Divisão de Regras
    string segments[];
    string work = low;
    StringReplace(work, " e ", "|");
    StringReplace(work, ".", "|");
    StringReplace(work, ",", "|");
    ushort sep = StringGetCharacter("|", 0);
    StringSplit(work, sep, segments);

    ENUM_SIGNAL currentIntent = NONE;

    for(int i = 0; i < ArraySize(segments); i++) {
        string seg = segments[i];
        if(StringFind(seg, "compra") >= 0) currentIntent = BUY;
        else if(StringFind(seg, "vende") >= 0) currentIntent = SELL;

        if(p_nRules >= MAX_RULES) break;
        Rule r;
        r.active = false;
        r.intent = currentIntent;
        r.tf = p_frequency;
        r.handle1 = INVALID_HANDLE;
        r.handle2 = INVALID_HANDLE;

        // MA
        if(StringFind(seg, " média") >= 0 || StringFind(seg, " ma ") >= 0 || StringFind(seg, " ma/") >= 0) {
            r.active = true;
            r.name = "MA";
            r.p1 = (int)ExtraiNumero(seg);
            if(r.p1 == 0) r.p1 = 20;
            // Checar se tem segunda média
            int nextPos = StringFind(seg, "/", StringFind(seg, IntegerToString(r.p1)));
            if(nextPos >= 0) r.p2 = (int)ExtraiNumero(seg, nextPos);
            else r.p2 = 0;

            if(r.p2 > 0) {
                r.handle1 = iMA(_Symbol, r.tf, r.p1, 0, MODE_EMA, PRICE_CLOSE);
                r.handle2 = iMA(_Symbol, r.tf, r.p2, 0, MODE_EMA, PRICE_CLOSE);
            } else {
                r.handle1 = iMA(_Symbol, r.tf, r.p1, 0, MODE_EMA, PRICE_CLOSE);
                r.handle2 = INVALID_HANDLE; // Price action vs MA se p2=0
            }
        }
        // RSI
        else if(StringFind(seg, "rsi") >= 0) {
            r.active = true;
            r.name = "RSI";
            r.p1 = (int)ExtraiNumero(seg);
            if(r.p1 == 0) r.p1 = 14;
            r.d1 = ExtraiValorApos(seg, "acima de");
            if(r.d1 == 0) r.d1 = 70;
            r.d2 = ExtraiValorApos(seg, "abaixo de");
            if(r.d2 == 0) r.d2 = 30;
            r.handle1 = iRSI(_Symbol, r.tf, r.p1, PRICE_CLOSE);
        }
        // Stochastic
        else if(StringFind(seg, "estocástico") >= 0 || StringFind(seg, "stoch") >= 0) {
            r.active = true;
            r.name = "Stoch";
            r.p1 = 5; r.p2 = 3; r.p3 = 3;
            r.handle1 = iStochastic(_Symbol, r.tf, r.p1, r.p2, r.p3, MODE_SMA, STO_LOWHIGH);
        }
        // Bollinger
        else if(StringFind(seg, "bollinger") >= 0 || StringFind(seg, "bb") >= 0) {
            r.active = true;
            r.name = "BB";
            r.p1 = 20; r.d1 = 2.0;
            r.handle1 = iBands(_Symbol, r.tf, r.p1, 0, r.d1, PRICE_CLOSE);
        }
        // Daily Breakout
        else if(StringFind(seg, "rompimento diário") >= 0) {
            r.active = true;
            r.name = "DailyBreak";
        }
        // Delta
        else if(StringFind(seg, "delta") >= 0) {
            r.active = true;
            r.name = "Delta";
            r.p1 = 60; // 60 segundos
            r.p2 = (int)ExtraiNumero(seg);
            if(r.p2 == 0) r.p2 = 300;
        }
        // Volume
        else if(StringFind(seg, "volume") >= 0) {
            r.active = true;
            r.name = "Volume";
            r.p1 = (int)ExtraiNumero(seg);
            if(r.p1 == 0) r.p1 = 12;
        }
        // AMA
        else if(StringFind(seg, "ama") >= 0 || StringFind(seg, "adaptativa") >= 0) {
            r.active = true;
            r.name = "AMA";
            r.p1 = 10;
            r.handle1 = iAMA(_Symbol, r.tf, r.p1, 2, 30, 0, PRICE_CLOSE);
        }
        // Bar Pattern
        else if(StringFind(seg, "padrão barras") >= 0) {
            r.active = true;
            r.name = "Bar2";
        }
        // Force Relative
        else if(StringFind(seg, "força relativa") >= 0) {
            r.active = true;
            r.name = "Relative";
            r.s1 = "US30"; // Default benchmark
            r.p1 = 14;
            r.handle1 = iRSI(_Symbol, r.tf, r.p1, PRICE_CLOSE);
            r.handle2 = iRSI(r.s1, r.tf, r.p1, PRICE_CLOSE);
        }

        if(r.active) {
            p_rules[p_nRules] = r;
            p_nRules++;
        }
    }
    GravaLog("Prompt interpretado: " + prompt);
}
