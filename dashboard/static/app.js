// dashboard/static/app.js
(function () {
  'use strict';

  const canvas = document.getElementById('costChart');
  if (!canvas) return;

  const PALETTE = [
    '#3b82f6', // blue
    '#a855f7', // purple
    '#10b981', // green
    '#f59e0b', // amber
    '#ef4444', // red
    '#06b6d4', // cyan
    '#ec4899', // pink
    '#6366f1', // indigo
  ];

  // Match the dashboard's system font stack (no web fonts loaded).
  const SYS_FONT =
    'ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif';

  new Chart(canvas, {
    type: 'doughnut',
    data: {
      labels: typeof chartLabels !== 'undefined' ? chartLabels : [],
      datasets: [{
        data: typeof chartData !== 'undefined' ? chartData : [],
        backgroundColor: PALETTE,
        borderColor: 'rgba(18, 24, 38, 0.8)',
        borderWidth: 2,
        hoverOffset: 4
      }],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      cutout: '65%',
      plugins: {
        legend: {
          position: 'right',
          labels: {
            color: '#a3b1c2',
            font: {
              family: SYS_FONT,
              size: 12,
              weight: '500'
            },
            padding: 15,
            boxWidth: 10,
            boxHeight: 10,
            usePointStyle: true,
            pointStyle: 'circle'
          },
        },
        tooltip: {
          bodyFont: {
            family: SYS_FONT,
            size: 13
          },
          titleFont: {
            family: SYS_FONT,
            size: 13,
            weight: 'bold'
          },
          callbacks: {
            label: (ctx) => ` $${ctx.parsed.toFixed(4)}`,
          },
        },
      },
    },
  });
}());
