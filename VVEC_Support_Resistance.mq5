//+------------------------------------------------------------------+
//|                                      VVEC_Support_Resistance.mq5 |
//|                        Copyright 2026, Evgeniy Acteck            |
//|                        ТЗ № MQL5-IND-2026-002 v2.0 ProRarefaction|
//+------------------------------------------------------------------+
#property copyright     "Copyright 2026, Evgeniy Acteck"
#property link          "https://github.com/Evgeniy-makdak/MQL5-IND-2026-001"
#property version       "2.0"
#property description   "VVEC Support & Resistance v2.0 — ProRarefaction"
#property description   "Уровни с 5 фильтрами прореживания, динамическим старением"
#property description   "и экспоненциальным затуханием силы."

//--- Индикатор в основном окне
#property indicator_chart_window
#property indicator_buffers   0
#property indicator_plots     0

//+------------------------------------------------------------------+
//| ВХОДНЫЕ ПАРАМЕТРЫ                                                |
//+------------------------------------------------------------------+
input group "=== Параметры поиска экстремумов ==="
input int      ExtremaDepth           = 5;              // Глубина экстремума (плечо, баров слева/справа)
input int      ClusterPriceGap        = 25;             // Макс. расстояние между экстремумами (в пипсах)
input int      MinClusterSize         = 3;              // Мин. кол-во экстремумов для формирования кластера

input group "=== Фильтры прореживания ==="
input bool     RequireVolumeConfirmation = true;        // Только уровни с объёмом >80-го перцентиля
input int      MinTouchCountForDisplay   = 3;           // Мин. касаний для отображения (2–10)
input int      MaxLevelsToShow           = 6;           // Макс. уровней на тип (поддержка/сопротивление)
input bool     EnableSpatialPruning      = true;        // Убирать близкие уровни, оставляя сильнейший
input bool     IgnoreNearPriceLevels     = true;        // Не показывать уровни рядом с текущей ценой
input bool     ShowStrengthPercent       = true;        // Показывать % актуальности рядом с уровнем

input group "=== Фильтр объёма ==="
input int      VolumeThresholdPercentile = 80;          // Процентиль объёма для верификации (60–95)
input bool     UseTickVolume          = true;           // Использовать тиковый объём

input group "=== Механизм старения ==="
input double   AgingMultiplier        = 1.0;            // Множитель времени жизни (0.5–3.0)
input bool     AgingEnabled           = true;           // Включить удаление старых уровней

input group "=== Визуализация ==="
input bool     ShowSupport            = true;           // Показывать уровни поддержки
input bool     ShowResistance         = true;           // Показывать уровни сопротивления
input color    SupportColor           = clrDodgerBlue;  // Цвет линий поддержки
input color    ResistanceColor        = clrOrangeRed;   // Цвет линий сопротивления
input int      LineWidth              = 1;              // Толщина линии

input group "=== Оптимизация ==="
input int      RecalcIntervalTicks    = 200;            // Интервал полного пересчёта в тиках

//+------------------------------------------------------------------+
//| СТРУКТУРЫ ДАННЫХ                                                 |
//+------------------------------------------------------------------+
struct SExtremum
{
   double   price;
   int      bar_index;
   long     volume;
   bool     is_support;
};

struct SLevel
{
   double   price;
   int      last_touch_bar;
   int      touch_count;
   long     max_volume;
   bool     is_support;
   bool     is_strong;
   bool     is_active;
   double   strength;
   double   rating;
};

//+------------------------------------------------------------------+
//| ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ                                             |
//+------------------------------------------------------------------+
string   g_prefix;
SLevel   g_levels[];
int      g_tickCounter;
int      g_prevCalculated;
double   g_effectiveGap;
int      g_barsToLive;
long     g_volThreshold;

//+------------------------------------------------------------------+
//| Вспомогательные функции                                          |
//+------------------------------------------------------------------+

double MedianOfArray(double &arr[])
{
   int n = ArraySize(arr);
   if(n == 0) return 0.0;
   if(n == 1) return arr[0];
   ArraySort(arr);
   if(n % 2 == 1) return arr[n / 2];
   return (arr[n / 2 - 1] + arr[n / 2]) / 2.0;
}

long GetVolumePercentile(SExtremum &extremums[], int percentile)
{
   int n = ArraySize(extremums);
   if(n == 0) return 0;
   long volumes[];
   ArrayResize(volumes, n);
   for(int i = 0; i < n; i++) volumes[i] = extremums[i].volume;
   ArraySort(volumes);
   int idx = (int)MathFloor(percentile / 100.0 * (n - 1));
   return volumes[idx];
}

int GetBaseBarsForTF()
{
   ENUM_TIMEFRAMES tf = Period();
   switch(tf)
   {
      case PERIOD_M1:  return 96;
      case PERIOD_M2:  return 120;
      case PERIOD_M3:  return 140;
      case PERIOD_M4:  return 150;
      case PERIOD_M5:  return 96;
      case PERIOD_M6:  return 100;
      case PERIOD_M10: return 120;
      case PERIOD_M12: return 130;
      case PERIOD_M15: return 160;
      case PERIOD_M20: return 170;
      case PERIOD_M30: return 160;
      case PERIOD_H1:  return 168;
      case PERIOD_H2:  return 140;
      case PERIOD_H3:  return 130;
      case PERIOD_H4:  return 126;
      case PERIOD_H6:  return 120;
      case PERIOD_H8:  return 110;
      case PERIOD_H12: return 100;
      case PERIOD_D1:  return 60;
      case PERIOD_W1:  return 26;
      case PERIOD_MN1: return 12;
      default:         return 168;
   }
}

//+------------------------------------------------------------------+
//| Поиск экстремумов                                                |
//+------------------------------------------------------------------+
void FindExtremums(const double &high[], const double &low[],
                   const long &vol[], int rates_total,
                   SExtremum &extremums[])
{
   ArrayResize(extremums, 0);
   int total = 0;
   int start = ExtremaDepth;
   int end   = rates_total - ExtremaDepth - 1;
   if(end < start) return;
   
   for(int i = start; i <= end; i++)
   {
      bool isMax = true;
      for(int j = 1; j <= ExtremaDepth; j++)
      {
         if(high[i] <= high[i - j] || high[i] <= high[i + j])
         { isMax = false; break; }
      }
      if(isMax)
      {
         ArrayResize(extremums, total + 1);
         extremums[total].price      = high[i];
         extremums[total].bar_index  = i;
         extremums[total].volume     = UseTickVolume ? vol[i] : 0;
         extremums[total].is_support = false;
         total++;
         continue;
      }
      
      bool isMin = true;
      for(int j = 1; j <= ExtremaDepth; j++)
      {
         if(low[i] >= low[i - j] || low[i] >= low[i + j])
         { isMin = false; break; }
      }
      if(isMin)
      {
         ArrayResize(extremums, total + 1);
         extremums[total].price      = low[i];
         extremums[total].bar_index  = i;
         extremums[total].volume     = UseTickVolume ? vol[i] : 0;
         extremums[total].is_support = true;
         total++;
      }
   }
}

//+------------------------------------------------------------------+
//| Кластеризация одного типа                                        |
//+------------------------------------------------------------------+
void ClusterOneType(SExtremum &arr[], bool isSupport, long volThreshold, SLevel &outLevels[])
{
   int count = ArraySize(arr);
   if(count == 0) return;
   
   for(int i = 0; i < count - 1; i++)
      for(int j = i + 1; j < count; j++)
         if(arr[i].price > arr[j].price)
         { SExtremum tmp = arr[i]; arr[i] = arr[j]; arr[j] = tmp; }
   
   SLevel tmpLevels[];
   int lCount = 0;
   
   for(int i = 0; i < count; i++)
   {
      bool added = false;
      for(int j = 0; j < lCount; j++)
      {
         if(MathAbs(arr[i].price - tmpLevels[j].price) <= g_effectiveGap)
         {
            tmpLevels[j].touch_count++;
            if(arr[i].volume > tmpLevels[j].max_volume) tmpLevels[j].max_volume = arr[i].volume;
            if(arr[i].bar_index > tmpLevels[j].last_touch_bar) tmpLevels[j].last_touch_bar = arr[i].bar_index;
            double prices[];
            int pCount = 0;
            for(int k = 0; k < count; k++)
               if(MathAbs(arr[k].price - tmpLevels[j].price) <= g_effectiveGap)
               { ArrayResize(prices, pCount + 1); prices[pCount++] = arr[k].price; }
            if(pCount > 0) tmpLevels[j].price = MedianOfArray(prices);
            added = true;
            break;
         }
      }
      if(!added)
      {
         ArrayResize(tmpLevels, lCount + 1);
         tmpLevels[lCount].price          = arr[i].price;
         tmpLevels[lCount].last_touch_bar = arr[i].bar_index;
         tmpLevels[lCount].touch_count    = 1;
         tmpLevels[lCount].max_volume     = arr[i].volume;
         tmpLevels[lCount].is_support     = isSupport;
         tmpLevels[lCount].is_active      = true;
         tmpLevels[lCount].strength       = 0.0;
         tmpLevels[lCount].rating         = 0.0;
         lCount++;
      }
   }
   
   for(int i = 0; i < lCount; i++)
   {
      bool volOK  = !RequireVolumeConfirmation || !UseTickVolume || (tmpLevels[i].max_volume >= volThreshold);
      bool countOK = tmpLevels[i].touch_count >= MinTouchCountForDisplay;
      tmpLevels[i].is_strong = volOK && countOK;
      
      if(countOK && (volOK || !RequireVolumeConfirmation))
      {
         int idx = ArraySize(outLevels);
         ArrayResize(outLevels, idx + 1);
         outLevels[idx] = tmpLevels[i];
      }
   }
}

//+------------------------------------------------------------------+
//| Кластеризация                                                    |
//+------------------------------------------------------------------+
void ClusterExtremums(SExtremum &extremums[], SLevel &levels[])
{
   ArrayResize(levels, 0);
   int n = ArraySize(extremums);
   if(n == 0) return;
   
   g_volThreshold = GetVolumePercentile(extremums, VolumeThresholdPercentile);
   
   SExtremum supports[], resistances[];
   int sCount = 0, rCount = 0;
   for(int i = 0; i < n; i++)
   {
      if(extremums[i].is_support)
      { ArrayResize(supports, sCount + 1); supports[sCount++] = extremums[i]; }
      else
      { ArrayResize(resistances, rCount + 1); resistances[rCount++] = extremums[i]; }
   }
   
   if(ShowSupport)    ClusterOneType(supports,    true,  g_volThreshold, levels);
   if(ShowResistance) ClusterOneType(resistances, false, g_volThreshold, levels);
}

//+------------------------------------------------------------------+
//| Расчёт силы уровня с экспоненциальным затуханием               |
//+------------------------------------------------------------------+
void CalculateLevelStrength(SLevel &lvls[], int current_bar)
{
   int n = ArraySize(lvls);
   if(n == 0) return;
   
   double maxStrength = 0.0;
   double lambda = 1.0 / (g_barsToLive / 2.0);
   if(lambda <= 0) lambda = 0.001;
   
   for(int i = 0; i < n; i++)
   {
      if(!lvls[i].is_active) continue;
      int t = current_bar - lvls[i].last_touch_bar;
      if(t < 0) t = 0;
      double baseStrength = lvls[i].touch_count * MathLog(1.0 + (double)lvls[i].max_volume / MathMax((double)g_volThreshold, 1.0));
      lvls[i].strength = baseStrength * MathExp(-lambda * t);
      if(lvls[i].strength > maxStrength) maxStrength = lvls[i].strength;
   }
   
   // Уровни со слишком низкой силой деактивируем
   for(int i = 0; i < n; i++)
   {
      if(!lvls[i].is_active) continue;
      if(maxStrength > 0 && lvls[i].strength < 0.3 * maxStrength)
         lvls[i].is_active = false;
   }
}

//+------------------------------------------------------------------+
//| Рейтинг уровня                                                   |
//+------------------------------------------------------------------+
void CalculateRatings(SLevel &lvls[], int current_bar)
{
   int n = ArraySize(lvls);
   if(n == 0) return;
   
   for(int i = 0; i < n; i++)
   {
      if(!lvls[i].is_active) continue;
      double normVol = (double)lvls[i].max_volume / MathMax((double)g_volThreshold, 1.0);
      if(normVol > 2.0) normVol = 2.0;
      double recency = 1.0 - ((double)(current_bar - lvls[i].last_touch_bar) / MathMax((double)g_barsToLive, 1.0));
      if(recency < 0.0) recency = 0.0;
      lvls[i].rating = (lvls[i].touch_count * 0.4) + (normVol * 0.4) + (recency * 0.2);
   }
}

//+------------------------------------------------------------------+
//| Пространственное прореживание                                    |
//+------------------------------------------------------------------+
void SpatialPruning(SLevel &lvls[])
{
   if(!EnableSpatialPruning) return;
   int n = ArraySize(lvls);
   if(n == 0) return;
   
   double minGap = g_effectiveGap * 1.5;
   
   for(int i = 0; i < n; i++)
   {
      if(!lvls[i].is_active) continue;
      for(int j = i + 1; j < n; j++)
      {
         if(!lvls[j].is_active) continue;
         if(lvls[i].is_support != lvls[j].is_support) continue;
         if(MathAbs(lvls[i].price - lvls[j].price) < minGap)
         {
            // Убираем более слабый
            if(lvls[i].rating >= lvls[j].rating)
               lvls[j].is_active = false;
            else
               lvls[i].is_active = false;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Игнорирование уровней у текущей цены                             |
//+------------------------------------------------------------------+
void IgnoreNearPrice(SLevel &lvls[], double current_price)
{
   if(!IgnoreNearPriceLevels) return;
   int n = ArraySize(lvls);
   if(n == 0) return;
   double threshold = g_effectiveGap * 0.5;
   for(int i = 0; i < n; i++)
      if(lvls[i].is_active && MathAbs(lvls[i].price - current_price) < threshold)
         lvls[i].is_active = false;
}

//+------------------------------------------------------------------+
//| Топ-N уровней                                                    |
//+------------------------------------------------------------------+
void KeepTopN(SLevel &lvls[])
{
   int n = ArraySize(lvls);
   if(n == 0) return;
   
   // Собираем индексы поддержек и сопротивлений
   int supIdx[], resIdx[];
   int sCount = 0, rCount = 0;
   for(int i = 0; i < n; i++)
   {
      if(!lvls[i].is_active) continue;
      if(lvls[i].is_support)
      { ArrayResize(supIdx, sCount + 1); supIdx[sCount++] = i; }
      else
      { ArrayResize(resIdx, rCount + 1); resIdx[rCount++] = i; }
   }
   
   // Сортируем по рейтингу
   for(int i = 0; i < sCount - 1; i++)
      for(int j = i + 1; j < sCount; j++)
         if(lvls[supIdx[i]].rating < lvls[supIdx[j]].rating)
         { int tmp = supIdx[i]; supIdx[i] = supIdx[j]; supIdx[j] = tmp; }
   
   for(int i = 0; i < rCount - 1; i++)
      for(int j = i + 1; j < rCount; j++)
         if(lvls[resIdx[i]].rating < lvls[resIdx[j]].rating)
         { int tmp = resIdx[i]; resIdx[i] = resIdx[j]; resIdx[j] = tmp; }
   
   // Оставляем только топ-N
   for(int i = MaxLevelsToShow; i < sCount; i++)
      lvls[supIdx[i]].is_active = false;
   for(int i = MaxLevelsToShow; i < rCount; i++)
      lvls[resIdx[i]].is_active = false;
}

//+------------------------------------------------------------------+
//| Применение всех фильтров прореживания                            |
//+------------------------------------------------------------------+
void PruneLevels(SLevel &lvls[], int current_bar, double current_price)
{
   CalculateLevelStrength(lvls, current_bar);
   CalculateRatings(lvls, current_bar);
   SpatialPruning(lvls);
   IgnoreNearPrice(lvls, current_price);
   KeepTopN(lvls);
}

//+------------------------------------------------------------------+
//| Старение                                                         |
//+------------------------------------------------------------------+
void ApplyAging(int current_bar)
{
   if(!AgingEnabled) return;
   int n = ArraySize(g_levels);
   for(int i = 0; i < n; i++)
   {
      if(!g_levels[i].is_active) continue;
      if((current_bar - g_levels[i].last_touch_bar) > g_barsToLive)
         g_levels[i].is_active = false;
   }
}

//+------------------------------------------------------------------+
//| Цвет с альфа-каналом                                             |
//+------------------------------------------------------------------+
color ColorWithAlpha(color clr, int alpha)
{
   int r = (int)((clr >> 16) & 0xFF);
   int g = (int)((clr >> 8) & 0xFF);
   int b = (int)(clr & 0xFF);
   return (color)((alpha << 24) | (r << 16) | (g << 8) | b);
}

//+------------------------------------------------------------------+
//| Удаление объектов                                                |
//+------------------------------------------------------------------+
void DeleteAllObjects()
{
   int total = ObjectsTotal(0, 0, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, 0, -1);
      if(StringFind(name, g_prefix) == 0)
         ObjectDelete(0, name);
   }
}
   
//+------------------------------------------------------------------+
//| Отрисовка уровней с разной прозрачностью/стилем                 |
//+------------------------------------------------------------------+
void DrawLevels(int current_bar)
{
   int total = ObjectsTotal(0, 0, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, 0, -1);
      if(StringFind(name, g_prefix + "LVL_") == 0 || StringFind(name, g_prefix + "TXT_") == 0)
         ObjectDelete(0, name);
   }

   int n = ArraySize(g_levels);
   for(int i = 0; i < n; i++)
   {
      if(!g_levels[i].is_active) continue;
      
      string lineName = g_prefix + "LVL_" + IntegerToString(i);
      string txtName  = g_prefix + "TXT_" + IntegerToString(i);
      
      color baseClr = g_levels[i].is_support ? SupportColor : ResistanceColor;
      
      // Возраст как доля от BarsToLive
      int age = current_bar - g_levels[i].last_touch_bar;
      if(age < 0) age = 0;
      double ageRatio = (double)age / MathMax((double)g_barsToLive, 1.0);
      if(ageRatio > 1.0) ageRatio = 1.0;
      
      // Стиль и прозрачность в зависимости от возраста
      ENUM_LINE_STYLE style = STYLE_SOLID;
      int alpha = 255;
      int width = LineWidth;
      
      if(ageRatio <= 0.3)
      { style = STYLE_SOLID; alpha = 255; width = LineWidth + 1; }
      else if(ageRatio <= 0.7)
      { style = STYLE_DASH; alpha = 200; }
      else
      { style = STYLE_DOT; alpha = 128; width = 1; }
      
      color clr = ColorWithAlpha(baseClr, alpha);
      
      if(ObjectFind(0, lineName) < 0)
         if(!ObjectCreate(0, lineName, OBJ_HLINE, 0, 0, g_levels[i].price))
            continue;
      
      ObjectSetDouble(0, lineName, OBJPROP_PRICE, g_levels[i].price);
      ObjectSetInteger(0, lineName, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, lineName, OBJPROP_STYLE, style);
      ObjectSetInteger(0, lineName, OBJPROP_WIDTH, width);
      ObjectSetInteger(0, lineName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, lineName, OBJPROP_HIDDEN, true);
      
      // Текст
      if(ShowStrengthPercent)
      {
         string prefix = g_levels[i].is_support ? "S" : "R";
         string txt = prefix + ":" + IntegerToString(g_levels[i].touch_count);
         if(ShowStrengthPercent)
         {
            int pct = (int)((1.0 - ageRatio) * 100.0);
            txt += " (" + IntegerToString(pct) + "%)";
         }
         
         datetime timeRight = TimeCurrent() + PeriodSeconds() * 10;
         
         if(ObjectFind(0, txtName) < 0)
            if(!ObjectCreate(0, txtName, OBJ_TEXT, 0, timeRight, g_levels[i].price))
               continue;
         
         ObjectSetString(0, txtName, OBJPROP_TEXT, txt);
         ObjectSetInteger(0, txtName, OBJPROP_COLOR, clr);
         ObjectSetInteger(0, txtName, OBJPROP_FONTSIZE, 8);
         ObjectSetInteger(0, txtName, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
      }
   }
}

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   g_prefix = "VVEC_";
   g_tickCounter = 0;
   g_prevCalculated = 0;
   
   g_effectiveGap = ClusterPriceGap * _Point * 10.0;
   if(g_effectiveGap <= 0) g_effectiveGap = _Point * 10.0;
   
   int baseBars = GetBaseBarsForTF();
   g_barsToLive = (int)(baseBars * AgingMultiplier);
   if(g_barsToLive < 10) g_barsToLive = 10;
   
   ArrayResize(g_levels, 0);
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   DeleteAllObjects();
}

//+------------------------------------------------------------------+
//| OnCalculate                                                       |
//+------------------------------------------------------------------+
int OnCalculate(const int       rates_total,
                const int       prev_calculated,
                const datetime &time[],
                const double   &open[],
                const double   &high[],
                const double   &low[],
                const double   &close[],
                const long     &tick_volume[],
                const long     &volume[],
                const int      &spread[])
{
   if(rates_total < ExtremaDepth * 2 + 10)
      return(0);
   
   bool fullRecalc = false;
   
   if(prev_calculated == 0)
   { fullRecalc = true; g_tickCounter = 0; }
   else if(prev_calculated != g_prevCalculated)
   { fullRecalc = true; g_tickCounter = 0; }
   else
   {
      g_tickCounter++;
      if(g_tickCounter >= RecalcIntervalTicks)
      { fullRecalc = true; g_tickCounter = 0; }
   }
   
   g_prevCalculated = prev_calculated;
   
   if(fullRecalc)
   {
      SExtremum extremums[];
      if(UseTickVolume)
         FindExtremums(high, low, tick_volume, rates_total, extremums);
      else
         FindExtremums(high, low, volume, rates_total, extremums);
      
      SLevel oldLevels[];
      ArrayCopy(oldLevels, g_levels);
      
      ClusterExtremums(extremums, g_levels);
      
      // Омоложение
      int oldN = ArraySize(oldLevels);
      int newN = ArraySize(g_levels);
      for(int i = 0; i < newN; i++)
      {
         for(int j = 0; j < oldN; j++)
         {
            if(!oldLevels[j].is_active) continue;
            if(g_levels[i].is_support == oldLevels[j].is_support &&
               MathAbs(g_levels[i].price - oldLevels[j].price) <= g_effectiveGap * 1.5)
            {
               if(oldLevels[j].last_touch_bar > g_levels[i].last_touch_bar)
                  g_levels[i].last_touch_bar = oldLevels[j].last_touch_bar;
            }
         }
      }
   }
   
   int currentBar = rates_total - 1;  // Индекс текущего (последнего) бара
   
   ApplyAging(currentBar);
   
   double currentPrice = (rates_total > 0) ? close[currentBar] : 0.0;
   PruneLevels(g_levels, currentBar, currentPrice);
   
   DrawLevels(currentBar);
   
   return(rates_total);
}
//+------------------------------------------------------------------+
