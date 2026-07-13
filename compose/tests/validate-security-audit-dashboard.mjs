#!/usr/bin/env node

import { readFileSync } from "node:fs";

const expectedSections = [
  ["Current situation", 0],
  ["Trend and collection coverage", 9],
  ["Immediate investigation", 26],
  ["Behavioral pivots", 45],
  ["Full audit timeline", 61],
];

const expectedControlFields = [
  "labels.audit_source.keyword",
  "labels.team.keyword",
  "labels.audit_alert",
  "user.keyword",
  "host.name.keyword",
];

const expectedLayouts = {
  "Current situation": [
    [0, 0, 12, 6],
    [12, 0, 12, 6],
    [24, 0, 12, 6],
    [36, 0, 12, 6],
  ],
  "Trend and collection coverage": [
    [0, 0, 32, 14],
    [32, 0, 16, 7],
    [32, 7, 16, 7],
  ],
  "Immediate investigation": [[0, 0, 48, 16]],
  "Behavioral pivots": [
    [0, 0, 24, 13],
    [24, 0, 12, 13],
    [36, 0, 12, 13],
  ],
  "Full audit timeline": [[0, 0, 48, 20]],
};

const expectedPanelTitles = new Set([
  "Total audit events",
  "High-signal events",
  "Wazuh audit events",
  "Active audit sources",
  "Audit events over time",
  "Events by source",
  "Source freshness",
  "Recent high-signal events",
  "Top actions",
  "Top users",
  "Top hosts",
  "Full audit timeline",
]);

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function sameJson(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function sortedLayout(layout) {
  return layout.map((entry) => [...entry]).sort((left, right) => {
    for (let index = 0; index < left.length; index += 1) {
      if (left[index] !== right[index]) {
        return left[index] - right[index];
      }
    }
    return 0;
  });
}

function panelsOverlap(left, right) {
  return (
    left.x < right.x + right.w &&
    left.x + left.w > right.x &&
    left.y < right.y + right.h &&
    left.y + left.h > right.y
  );
}

function collectEsqlQueries(value, queries) {
  if (Array.isArray(value)) {
    for (const child of value) {
      collectEsqlQueries(child, queries);
    }
  } else if (value !== null && typeof value === "object") {
    if (value.data_source?.type === "esql") {
      queries.push(value.data_source.query);
    }
    for (const child of Object.values(value)) {
      collectEsqlQueries(child, queries);
    }
  }
}

function validate(path) {
  const dashboard = JSON.parse(readFileSync(path, "utf8"));
  const serializedDashboard = JSON.stringify(dashboard);

  assert(dashboard.title === "Security Audit Overview", "unexpected dashboard title");
  assert(
    sameJson(dashboard.time_range, { from: "now-24h", to: "now", mode: "relative" }),
    "unexpected dashboard time range",
  );
  assert(
    sameJson(dashboard.refresh_interval, { pause: false, value: 60000 }),
    "unexpected dashboard refresh interval",
  );

  const sections = dashboard.panels;
  const actualSections = sections.map((section) => [section.title, section.grid.y]);
  assert(sameJson(actualSections, expectedSections), "section order or Y coordinates changed");

  const controls = dashboard.pinned_panels;
  const actualControlFields = controls.map((control) => control.config.field_name);
  assert(sameJson(actualControlFields, expectedControlFields), "audit controls changed");
  assert(
    controls.every((control) => control.type === "options_list_control"),
    "every audit control must be an options list",
  );
  assert(
    controls.every((control) => control.config.data_view_id === "acer-audit"),
    "every audit control must use the stable acer-audit data view",
  );

  const allIds = controls.map((control) => control.id);
  const panelTitles = new Set();
  let metricCount = 0;

  for (const section of sections) {
    allIds.push(section.id);
    const actualLayout = section.panels.map((panel) => [
      panel.grid.x,
      panel.grid.y,
      panel.grid.w,
      panel.grid.h,
    ]);
    assert(
      sameJson(sortedLayout(actualLayout), sortedLayout(expectedLayouts[section.title])),
      `layout changed in ${section.title}`,
    );

    for (const [index, panel] of section.panels.entries()) {
      allIds.push(panel.id);
      const grid = panel.grid;
      assert(grid.x >= 0 && grid.y >= 0, `${panel.id} has a negative coordinate`);
      assert(grid.w >= 1 && grid.h >= 1, `${panel.id} has an invalid size`);
      assert(grid.x + grid.w <= 48, `${panel.id} exceeds the 48-column grid`);
      panelTitles.add(panel.config.title);
      metricCount += panel.config.type === "metric" ? 1 : 0;

      for (const other of section.panels.slice(index + 1)) {
        assert(
          !panelsOverlap(grid, other.grid),
          `overlap in ${section.title}: ${panel.id} and ${other.id}`,
        );
      }
    }
  }

  assert(allIds.every(Boolean), "section/control/panel IDs must be non-empty");
  assert(new Set(allIds).size === allIds.length, "section/control/panel IDs must be unique");
  assert(metricCount === 4, `expected 4 metric panels, received ${metricCount}`);
  assert(
    sameJson([...panelTitles].sort(), [...expectedPanelTitles].sort()),
    "operational panel titles changed",
  );
  assert(
    !serializedDashboard.includes("labels.audit_alert.keyword"),
    "alert signature must use the explicitly mapped keyword field",
  );
  assert(
    !serializedDashboard.includes("user.name"),
    "dashboard must use the live scalar user field contract",
  );

  const queries = [];
  collectEsqlQueries(dashboard, queries);
  assert(queries.length === 12, `expected 12 ES|QL queries, received ${queries.length}`);
  for (const query of queries) {
    assert(
      query.startsWith('SET unmapped_fields="NULLIFY"; FROM acer-audit-* METADATA _index'),
      `query does not nullify optional unmapped fields: ${query}`,
    );
    assert(
      query.includes("@timestamp >= ?_tstart AND @timestamp < ?_tend"),
      `query is missing the dashboard time boundary: ${query}`,
    );
    assert(
      query.includes('NOT (_index LIKE "acer-audit-alerts-*")'),
      `query can double count alert-routing copies: ${query}`,
    );
    const unsafeAggregations = [
      /COUNT_DISTINCT\(labels\.audit_source\)/,
      /BY source = labels\.audit_source(?:\s|,|\|)/,
      /BY action = event\.action(?:\s|,|\|)/,
      /BY user = user\.name(?:\s|,|\|)/,
      /BY host = host\.name(?:\s|,|\|)/,
    ];
    assert(
      unsafeAggregations.every((pattern) => !pattern.test(query)),
      `query aggregates a non-keyword text field: ${query}`,
    );
  }
  assert(
    queries.some((query) => query.includes("BY user = user.keyword")),
    "Top users must aggregate the scalar user keyword multi-field",
  );
  assert(
    queries.filter((query) => query.includes("| KEEP ") && query.includes(", user,")).length === 2,
    "both investigation tables must display the scalar user field",
  );
}

if (process.argv.length !== 3) {
  console.error(`usage: ${process.argv[1]} DASHBOARD_JSON`);
  process.exit(2);
}

try {
  validate(process.argv[2]);
  console.log("security audit dashboard contract valid");
} catch (error) {
  console.error(`dashboard contract invalid: ${error.message}`);
  process.exit(1);
}
