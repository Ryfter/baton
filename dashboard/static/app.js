// dashboard/static/app.js
(function () {
  'use strict';

  const canvas = document.getElementById('costChart');
  if (!canvas) return;

  const PALETTE = [
    '#3fb950', '#58a6ff', '#f0883e', '#bc8cff',
    '#ff7b72', '#79c0ff', '#ffa657', '#d2a8ff',
  ];

  new Chart(canvas, {
    type: 'doughnut',
    data: {
      labels: typeof chartLabels !== 'undefined' ? chartLabels : [],
      datasets: [{
        data: typeof chartData !== 'undefined' ? chartData : [],
        backgroundColor: PALETTE,
        borderColor: '#161b22',
        borderWidth: 2,
      }],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: {
          position: 'right',
          labels: {
            color: '#e6edf3',
            font: { size: 11 },
            padding: 12,
            boxWidth: 12,
          },
        },
        tooltip: {
          callbacks: {
            label: (ctx) => ` ${ctx.label}: $${ctx.parsed.toFixed(4)}`,
          },
        },
      },
    },
  });
}());
