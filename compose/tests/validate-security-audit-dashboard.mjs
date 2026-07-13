#!/usr/bin/env node

import { readFileSync } from "node:fs";

const expectedSections = [
  ["Current situation", 0],
  ["Trend and collection coverage", 9],
  ["Immediate investigation", 26],
  ["Access and authentication", 45],
  ["Security domains", 64],
  ["Full audit timeline", 81],
];

const expectedControlFields = [
  "labels.audit_source.keyword",
  "labels.team.keyword",
  "labels.audit_alert",
  "actor.name",
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
  "Access and authentication": [
    [0, 0, 32, 16],
    [32, 0, 16, 8],
    [32, 8, 16, 8],
  ],
  "Security domains": [
    [0, 0, 24, 14],
    [24, 0, 24, 14],
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
  "Recent proxy access",
  "Authentication failures",
  "Top requested paths",
  "Identity and privileged activity",
  "Wazuh host security",
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
    "dashboard must not use the incompatible ECS user object",
  );
  assert(
    !serializedDashboard.includes("user.keyword"),
    "dashboard must not present the collection team as an actor",
  );
  assert(
    serializedDashboard.includes("actor.name"),
    "dashboard must use the normalized actor field",
  );
  assert(
    !serializedDashboard.includes("event.severity"),
    "dashboard must not use string event.severity as a cross-source priority",
  );

  const panelByTitle = new Map(
    sections.flatMap((section) => section.panels).map((panel) => [panel.config.title, panel.config]),
  );
  const immediate = panelByTitle.get("Recent high-signal events");
  assert(immediate, "missing Recent high-signal events panel");
  assert(
    immediate.data_source.query.includes("labels.alert_severity") &&
      immediate.data_source.query.includes("app.rule.level"),
    "Immediate investigation must show priority and Wazuh level",
  );
  assert(
    immediate.rows.some(
      (row) => row.column === "labels.alert_severity" && row.label === "Priority",
    ),
    "Immediate investigation is missing the Priority column",
  );
  assert(
    immediate.rows.some((row) => row.column === "app.rule.level" && row.label === "Wazuh Level"),
    "Immediate investigation is missing the Wazuh Level column",
  );

  const wazuhHost = panelByTitle.get("Wazuh host security");
  assert(wazuhHost, "missing Wazuh host security panel");
  assert(
    wazuhHost.data_source.query.includes("app.rule.level"),
    "Wazuh host security must query the original Wazuh level",
  );
  assert(
    wazuhHost.rows.some((row) => row.column === "app.rule.level" && row.label === "Wazuh Level"),
    "Wazuh host security is missing the Wazuh Level column",
  );

  const queries = [];
  collectEsqlQueries(dashboard, queries);
  assert(queries.length === 14, `expected 14 ES|QL queries, received ${queries.length}`);
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
    assert(
      query.includes('event.action IS NULL'),
      `query does not exclude historical unnormalized proxy/identity rows: ${query}`,
    );
    const unsafeAggregations = [
      /COUNT_DISTINCT\(labels\.audit_source\)/,
      /BY source = labels\.audit_source(?:\s|,|\|)/,
      /BY action = event\.action(?:\s|,|\|)/,
      /BY actor = actor\.name\.keyword(?:\s|,|\|)/,
      /BY host = host\.name(?:\s|,|\|)/,
    ];
    assert(
      unsafeAggregations.every((pattern) => !pattern.test(query)),
      `query aggregates a non-keyword text field: ${query}`,
    );
  }
  assert(queries.some((query) => query.includes('labels.audit_source.keyword IN ("traefik", "oauth2-proxy")') && query.includes("http.request.method")), "missing proxy access query");
  assert(queries.some((query) => query.includes('event.outcome == "failure"')), "missing authentication failure query");
  assert(queries.some((query) => query.includes("url.path.keyword")), "missing requested-path aggregation");
  assert(queries.some((query) => query.includes('labels.audit_source.keyword IN ("keycloak", "vault", "teleport")')), "missing identity and privileged query");
  assert(queries.some((query) => query.includes('labels.audit_source.keyword == "wazuh"') && query.includes("event.code")), "missing Wazuh investigation query");
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
