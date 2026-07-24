import os

p = '/opt/proxy-panel/templates/self.html'
c = open(p, encoding='utf-8').read()

old_func = """async function loadTraffic() {
  const days = document.querySelector('.period-btn.active')?.dataset.days || '14';
  try {
    const url = '/panel/api/v1/traffic/' + encodeURIComponent(currentUser) + '?days=' + days;
    const res = await fetch(url);
    if (!res.ok) return;
    const data = await res.json();
    const dates = [...new Set(data.map(d => d.date))].sort();
    const aggregated = dates.map(date => {
      const day = data.filter(d => d.date === date);
      return { date, up: day.reduce((s, d) => s + d.bytes_up, 0), down: day.reduce((s, d) => s + d.bytes_down, 0) };
    });
    if (trafficChart) trafficChart.destroy();
    if (aggregated.length === 0) return;
    const maxVal = Math.max(...aggregated.flatMap(d => [d.up, d.down]), 1);
    trafficChart = new Chart(document.getElementById('trafficChart'), {
      type: 'bar',
      data: {
        labels: dates,
        datasets: [
          { label: _('upload'), data: aggregated.map(d => d.up), backgroundColor: cssVar('--chart-up') },
          { label: _('download'), data: aggregated.map(d => d.down), backgroundColor: cssVar('--chart-down') },
        ]
      },
      options: {
        responsive: true,
        plugins: { legend: { labels: { color: cssVar('--muted') } } },
        scales: {
          x: { ticks: { color: cssVar('--muted') }, grid: { color: cssVar('--chart-grid') } },
          y: { ticks: { color: cssVar('--muted'), callback: v => fmtBytes(v) }, grid: { color: cssVar('--chart-grid') },
              min: 0, max: maxVal }
        }
      }
    });
  } catch(e) { console.log('Traffic chart error:', e); }
}"""

new_func = """async function loadTraffic() {
  const days = document.querySelector('.period-btn.active')?.dataset.days || '14';
  try {
    const url = '/panel/api/v1/traffic/' + encodeURIComponent(currentUser) + '?days=' + days;
    const res = await fetch(url);
    if (!res.ok) return;
    const data = await res.json();
    if (trafficChart) trafficChart.destroy();

    const allDates = [...new Set(data.map(d => d.date))].sort();
    const actualDays = allDates.length;
    const needDays = parseInt(days) || 0;

    if (days === '0' || (needDays > 0 && actualDays < needDays / 2)) {
      var totalUp = data.reduce((s, d) => s + d.bytes_up, 0);
      var totalDown = data.reduce((s, d) => s + d.bytes_down, 0);
      var label = allDates.length > 0 ? allDates[0].slice(5) + ' \\u2014 ' + allDates[allDates.length-1].slice(5) : _('total');
      trafficChart = new Chart(document.getElementById('trafficChart'), {
        type: 'bar',
        data: {
          labels: [label],
          datasets: [
            { label: _('upload'), data: [totalUp], backgroundColor: cssVar('--chart-up'), borderRadius: 6 },
            { label: _('download'), data: [totalDown], backgroundColor: cssVar('--chart-down'), borderRadius: 6 }
          ]
        },
        options: {
          responsive: true,
          plugins: { legend: { labels: { color: cssVar('--muted') } } },
          scales: {
            x: { ticks: { color: cssVar('--muted') }, grid: { color: cssVar('--chart-grid') } },
            y: { ticks: { color: cssVar('--muted'), callback: function(v) { return fmtBytes(v); } }, grid: { color: cssVar('--chart-grid') } }
          }
        }
      });
    } else {
      var aggregated = allDates.map(function(date) {
        var day = data.filter(d => d.date === date);
        return { date: date, up: day.reduce((s, d) => s + d.bytes_up, 0), down: day.reduce((s, d) => s + d.bytes_down, 0) };
      });
      trafficChart = new Chart(document.getElementById('trafficChart'), {
        type: 'bar',
        data: {
          labels: aggregated.map(d => d.date.slice(5)),
          datasets: [
            { label: _('upload'), data: aggregated.map(d => d.up), backgroundColor: cssVar('--chart-up'), borderRadius: 4 },
            { label: _('download'), data: aggregated.map(d => d.down), backgroundColor: cssVar('--chart-down'), borderRadius: 4 }
          ]
        },
        options: {
          responsive: true,
          plugins: { legend: { labels: { color: cssVar('--muted') } } },
          scales: {
            x: { ticks: { color: cssVar('--muted'), maxRotation: 45 }, grid: { color: cssVar('--chart-grid') } },
            y: { ticks: { color: cssVar('--muted'), callback: function(v) { return fmtBytes(v); } }, grid: { color: cssVar('--chart-grid') } }
          }
        }
      });
    }
  } catch(e) { console.log('Traffic chart error:', e); }
}"""

if old_func in c:
    c = c.replace(old_func, new_func)
    open(p, 'w', encoding='utf-8').write(c)
    print('loadTraffic() replaced successfully')
else:
    print('ERROR: old function not found')
    # Debug: show what's there
    idx = c.find('async function loadTraffic')
    if idx >= 0:
        print('Found at', idx)
        print(repr(c[idx:idx+200]))
    else:
        print('loadTraffic not found at all')