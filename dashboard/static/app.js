// dashboard/static/app.js
(function () {
  'use strict';

  const canvas = document.getElementById('costChart');
  if (!canvas) return;

  const PALETTE = [
    '#3b82f6', // Electric Blue
    '#a855f7', // Neon Purple
    '#10b981', // Neon Green
    '#f59e0b', // Amber
    '#ef4444', // Coral/Red
    '#06b6d4', // Cyan
    '#ec4899', // Hot Pink
    '#6366f1', // Indigo
  ];

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
            color: '#94a3b8',
            font: {
              family: "'Outfit', sans-serif",
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
            family: "'Outfit', sans-serif",
            size: 13
          },
          titleFont: {
            family: "'Outfit', sans-serif",
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
