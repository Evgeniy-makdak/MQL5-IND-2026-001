//+------------------------------------------------------------------+
//|                                      VVEC_Support_Resistance.mq5 |
//|                        Copyright 2026, Evgeniy Acteck            |
//|                        ТЗ № MQL5-IND-2026-002                    |
//+------------------------------------------------------------------+
#property copyright     "Copyright 2026, Evgeniy Acteck"
#property link          "https://github.com/Evgeniy-makdak/MQL5-IND-2026-001"
#property version       "1.0"
#property description   "VVEC Support & Resistance — уровни на основе"
#property description   "кластеризации экстремумов с верификацией объёмом."

//--- Индикатор в основном окне
#property indicator_chart_window
#property indicator_buffers   0
#property indicator_plots     0

//+------------------------------------------------------------------+
//| ВХОДНЫЕ ПАРАМЕТРЫ                                                |
//+------------------------------------------------------------------+
input group "=== Параметры поиска экстремумов ==="
input int      ExtremaDepth           = 5;              // Глубина экстремума (плечо, баров слева/справа)
input double   ClusterPriceGap        = 0.0025;         // Макс. расстояние между экстремумами в кластере (абс. цена)
input int      MinClusterSize         = 3;              // Мин. кол-во экстремумов для формирования кластера
input int      StrongMinTouches       = 5;              // Мин. касаний для значимого (сильного) уровня
input bool     ShowOnlyStrongLevels   = true;           // Показывать только значимые уровни (убирает мусор)

input group "=== Фильтр объёма ==="
input int      VolumeThresholdPercentile = 80;          // Процентиль объёма для верификации (60–95)
input bool     UseTickVolume          = true;           // Использовать тиковый объём

input group "=== Механизм старения ==="
input int      BarsToLive             = 300;            // Баров жизни уровня после последнего касания
input bool     AgingEnabled           = true;           // Включить удаление старых уровней

input group "=== Визуализация ==="
input bool     ShowSupport            = true;           // Показывать уровни поддержки
input bool     ShowResistance         = true;           // Показывать уровни сопротивления
input color    SupportColor           = clrDodgerBlue;  // Цвет линий поддержки
input color    ResistanceColor        = clrOrangeRed;   // Цвет линий сопротивления
input int      LineStyle              = 1;              // Стиль линии (0=сплошная,1=пунктир,2=штрихпунктир)
input int      LineWidth              = 1;              // Толщина линии
input bool     ShowLevelStrength      = true;           // Показывать силу уровня текстом

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
   bool     is_support;   // true = SUPPORT (минимум), false = RESISTANCE (максимум)
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
};

//+------------------------------------------------------------------+
//| ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ                                             |
//+------------------------------------------------------------------+
string   g_prefix;              // Префикс имён объектов
SLevel   g_levels[];            // Активные уровни
int      g_tickCounter;         // Счётчик тиков
int      g_prevCalculated;      // Предыдущее значение prev_calculated

//+------------------------------------------------------------------+
//| Вспомогательные функции                                          |
//+------------------------------------------------------------------+

//--- Медиана массива
double MedianOfArray(double &arr[])
{
   int n = ArraySize(arr);
   if(n == 0) return 0.0;
   if(n == 1) return arr[0];
   
   ArraySort(arr);
   if(n % 2 == 1)
      return arr[n / 2];
   else
      return (arr[n / 2 - 1] + arr[n / 2]) / 2.0;
}

//--- Процентиль объёма
long GetVolumePercentile(SExtremum &extremums[], int percentile)
{
   int n = ArraySize(extremums);
   if(n == 0) return 0;
   
   long volumes[];
   ArrayResize(volumes, n);
   for(int i = 0; i < n; i++)
      volumes[i] = extremums[i].volume;
   
   ArraySort(volumes);
   int idx = (int)MathFloor(percentile / 100.0 * (n - 1));
   return volumes[idx];
}

//+------------------------------------------------------------------+
//| Поиск локальных экстремумов                                      |
//+------------------------------------------------------------------+
void FindExtremums(const double &high[], const double &low[],
                   const long &vol[], int rates_total,
                   SExtremum &extremums[])
{
   ArrayResize(extremums, 0);
   int total = 0;
   
   // Ищем экстремумы только на закрытых барах (не на текущем i=0)
   int start = ExtremaDepth;
   int end   = rates_total - ExtremaDepth - 1;
   if(end < start) return;
   
   for(int i = start; i <= end; i++)
   {
      // Проверка локального максимума
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
      
      // Проверка локального минимума
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
//| Кластеризация одного типа экстремумов                            |
//+------------------------------------------------------------------+
void ClusterOneType(SExtremum &arr[], bool isSupport, long volThreshold, SLevel &outLevels[])
{
   int count = ArraySize(arr);
   if(count == 0) return;
   
   // Сортируем по цене (простая сортировка пузырьком)
   for(int i = 0; i < count - 1; i++)
   {
      for(int j = i + 1; j < count; j++)
      {
         if(arr[i].price > arr[j].price)
         {
            SExtremum tmp = arr[i];
            arr[i] = arr[j];
            arr[j] = tmp;
         }
      }
   }
   
   // Кластеризация
   SLevel tmpLevels[];
   int lCount = 0;
   
   for(int i = 0; i < count; i++)
   {
      bool added = false;
      for(int j = 0; j < lCount; j++)
      {
         if(MathAbs(arr[i].price - tmpLevels[j].price) <= ClusterPriceGap)
         {
            // Обновляем кластер
            tmpLevels[j].touch_count++;
            if(arr[i].volume > tmpLevels[j].max_volume)
               tmpLevels[j].max_volume = arr[i].volume;
            if(arr[i].bar_index > tmpLevels[j].last_touch_bar)
               tmpLevels[j].last_touch_bar = arr[i].bar_index;
            // Пересчитываем цену как медиану всех экстремумов в кластере
            double prices[];
            int pCount = 0;
            for(int k = 0; k < count; k++)
            {
               if(MathAbs(arr[k].price - tmpLevels[j].price) <= ClusterPriceGap)
               {
                  ArrayResize(prices, pCount + 1);
                  prices[pCount++] = arr[k].price;
               }
            }
            if(pCount > 0)
               tmpLevels[j].price = MedianOfArray(prices);
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
         lCount++;
      }
   }
   
   // Фильтрация: уровень считается значимым только при одновременном выполнении:
   // 1) достаточно касаний (>= StrongMinTouches)
   // 2) подтверждён объёмом (если UseTickVolume = true)
   for(int i = 0; i < lCount; i++)
   {
      bool volOK  = !UseTickVolume || (tmpLevels[i].max_volume >= volThreshold);
      bool countOK = tmpLevels[i].touch_count >= StrongMinTouches;
      tmpLevels[i].is_strong = volOK && countOK;
      
      // Показываем либо все уровни с мин. касаниями, либо только сильные
      bool showThis = ShowOnlyStrongLevels ? tmpLevels[i].is_strong
                                           : (tmpLevels[i].touch_count >= MinClusterSize);
      if(showThis)
      {
         int idx = ArraySize(outLevels);
         ArrayResize(outLevels, idx + 1);
         outLevels[idx] = tmpLevels[i];
      }
   }
}

//+------------------------------------------------------------------+
//| Кластеризация экстремумов                                        |
//+------------------------------------------------------------------+
void ClusterExtremums(SExtremum &extremums[], SLevel &levels[])
{
   ArrayResize(levels, 0);
   int n = ArraySize(extremums);
   if(n == 0) return;
   
   // Вычисляем порог объёма
   long volThreshold = GetVolumePercentile(extremums, VolumeThresholdPercentile);
   
   // Разделяем на поддержки и сопротивления
   SExtremum supports[], resistances[];
   int sCount = 0, rCount = 0;
   for(int i = 0; i < n; i++)
   {
      if(extremums[i].is_support)
      {
         ArrayResize(supports, sCount + 1);
         supports[sCount++] = extremums[i];
      }
      else
      {
         ArrayResize(resistances, rCount + 1);
         resistances[rCount++] = extremums[i];
      }
   }
   
   if(ShowSupport)    ClusterOneType(supports,    true,  volThreshold, levels);
   if(ShowResistance) ClusterOneType(resistances, false, volThreshold, levels);
}

//+------------------------------------------------------------------+
//| Удаление старых уровней (старение)                               |
//+------------------------------------------------------------------+
void ApplyAging(int current_bar)
{
   int n = ArraySize(g_levels);
   for(int i = 0; i < n; i++)
   {
      if(!g_levels[i].is_active) continue;
      if(AgingEnabled && (current_bar - g_levels[i].last_touch_bar) > BarsToLive)
         g_levels[i].is_active = false;
   }
}

//+------------------------------------------------------------------+
//| Удаление всех графических объектов индикатора                    |
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
//| Отрисовка уровней с фильтром близости                            |
//| Уровни сортируются по убыванию силы (touch_count).               |
//| Если уровень ближе MinLevelGap к уже отрисованному — пропускается|
//+------------------------------------------------------------------+
void DrawLevels(int current_bar)
{
   // Удаляем старые линии
   int total = ObjectsTotal(0, 0, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, 0, -1);
      if(StringFind(name, g_prefix + "LVL_") == 0 || StringFind(name, g_prefix + "TXT_") == 0)
         ObjectDelete(0, name);
   }
   
   int n = ArraySize(g_levels);
   if(n == 0) return;
   
   // Собираем индексы активных уровней
   int indices[];
   int activeCount = 0;
   for(int i = 0; i < n; i++)
   {
      if(g_levels[i].is_active)
      {
         ArrayResize(indices, activeCount + 1);
         indices[activeCount++] = i;
      }
   }
   if(activeCount == 0) return;
   
   // Сортируем по убыванию touch_count (сильные первыми)
   for(int i = 0; i < activeCount - 1; i++)
   {
      for(int j = i + 1; j < activeCount; j++)
      {
         if(g_levels[indices[i]].touch_count < g_levels[indices[j]].touch_count)
         {
            int tmp = indices[i];
            indices[i] = indices[j];
            indices[j] = tmp;
         }
      }
   }
   
   // Минимальное расстояние между отображаемыми уровнями
   double minGap = ClusterPriceGap * 1.5;
   
   // Массивы для отслеживания уже отрисованных цен
   double drawnSup[], drawnRes[];
   int sDrawn = 0, rDrawn = 0;
   
   // Рисуем, пропуская слишком близкие
   for(int k = 0; k < activeCount; k++)
   {
      int i = indices[k];
      bool isSup = g_levels[i].is_support;
      double price = g_levels[i].price;
      
      // Проверяем близость к уже отрисованным уровням того же типа
      bool tooClose = false;
      if(isSup)
      {
         for(int d = 0; d < sDrawn; d++)
            if(MathAbs(price - drawnSup[d]) < minGap) { tooClose = true; break; }
      }
      else
      {
         for(int d = 0; d < rDrawn; d++)
            if(MathAbs(price - drawnRes[d]) < minGap) { tooClose = true; break; }
      }
      if(tooClose) continue;
      
      // Рисуем уровень
      string lineName = g_prefix + "LVL_" + IntegerToString(i);
      string txtName  = g_prefix + "TXT_" + IntegerToString(i);
      color clr = isSup ? SupportColor : ResistanceColor;
      
      if(ObjectFind(0, lineName) < 0)
         if(!ObjectCreate(0, lineName, OBJ_HLINE, 0, 0, price))
            continue;
      
      ObjectSetDouble(0, lineName, OBJPROP_PRICE, price);
      ObjectSetInteger(0, lineName, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, lineName, OBJPROP_STYLE, (ENUM_LINE_STYLE)LineStyle);
      ObjectSetInteger(0, lineName, OBJPROP_WIDTH, LineWidth);
      ObjectSetInteger(0, lineName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, lineName, OBJPROP_HIDDEN, true);
      
      // Текст силы уровня
      if(ShowLevelStrength)
      {
         string prefix = isSup ? "S" : "R";
         string suffix = g_levels[i].is_strong ? "v" : "";
         string txt = prefix + ":" + IntegerToString(g_levels[i].touch_count) + suffix;
         
         datetime timeRight = TimeCurrent() + PeriodSeconds() * 10;
         
         if(ObjectFind(0, txtName) < 0)
            if(!ObjectCreate(0, txtName, OBJ_TEXT, 0, timeRight, price))
               continue;
         
         ObjectSetString(0, txtName, OBJPROP_TEXT, txt);
         ObjectSetInteger(0, txtName, OBJPROP_COLOR, clr);
         ObjectSetInteger(0, txtName, OBJPROP_FONTSIZE, 8);
         ObjectSetInteger(0, txtName, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
      }
      
      // Запоминаем отрисованную цену
      if(isSup)
      {
         ArrayResize(drawnSup, sDrawn + 1);
         drawnSup[sDrawn++] = price;
      }
      else
      {
         ArrayResize(drawnRes, rDrawn + 1);
         drawnRes[rDrawn++] = price;
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
   {
      fullRecalc = true;
      g_tickCounter = 0;
   }
   else if(prev_calculated != g_prevCalculated)
   {
      // Новый бар
      fullRecalc = true;
      g_tickCounter = 0;
   }
   else
   {
      g_tickCounter++;
      if(g_tickCounter >= RecalcIntervalTicks)
      {
         fullRecalc = true;
         g_tickCounter = 0;
      }
   }
   
   g_prevCalculated = prev_calculated;
   
   if(fullRecalc)
   {
      // Полный пересчёт
      SExtremum extremums[];
      if(UseTickVolume)
         FindExtremums(high, low, tick_volume, rates_total, extremums);
      else
         FindExtremums(high, low, volume, rates_total, extremums);
      
      // Сохраняем старые last_touch_bar для "омоложения"
      SLevel oldLevels[];
      ArrayCopy(oldLevels, g_levels);
      
      ClusterExtremums(extremums, g_levels);
      
      // Омоложение: если новый кластер близок к старому уровню, обновляем last_touch_bar
      int oldN = ArraySize(oldLevels);
      int newN = ArraySize(g_levels);
      for(int i = 0; i < newN; i++)
      {
         for(int j = 0; j < oldN; j++)
         {
            if(!oldLevels[j].is_active) continue;
            if(g_levels[i].is_support == oldLevels[j].is_support &&
               MathAbs(g_levels[i].price - oldLevels[j].price) <= ClusterPriceGap * 1.5)
            {
               if(oldLevels[j].last_touch_bar > g_levels[i].last_touch_bar)
                  g_levels[i].last_touch_bar = oldLevels[j].last_touch_bar;
            }
         }
      }
   }
   
   // Применяем старение
   ApplyAging(0);
   
   // Отрисовка
   DrawLevels(0);
   
   return(rates_total);
}
//+------------------------------------------------------------------+
